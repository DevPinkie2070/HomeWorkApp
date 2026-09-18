import Foundation

/// Local adapter around the user-selected Schulmanager-API repository.
/// It only reads the timetable and never writes to Schulmanager.
struct SchoolManagerCalendarService {
    func todaySchedule(after referenceDate: Date = .now) async throws -> [DailyScheduleLesson] {
        guard SchoolSettings().schoolManagerAccessEnabled else {
            throw HomeworkServiceError.schoolManagerAccessDisabled
        }
        let lessons = try await run(subject: nil, referenceDate: referenceDate).schedule ?? []
        guard !lessons.isEmpty else {
            throw HomeworkServiceError.schoolManagerRequestFailed
        }
        return lessons
    }

    func nextLesson(for subject: String, after referenceDate: Date = .now) async throws -> Lesson {
        guard SchoolSettings().schoolManagerAccessEnabled else {
            throw HomeworkServiceError.schoolManagerAccessDisabled
        }
        guard let username = KeychainStore.value(for: "schoolManagerUsername"), !username.isEmpty,
              let password = KeychainStore.value(for: "schoolManagerPassword"), !password.isEmpty else {
            throw HomeworkServiceError.missingSchoolManagerCredentials
        }
        guard username.contains("@"),
              username.split(separator: "@", maxSplits: 1).count == 2,
              !username.hasPrefix("@"),
              !username.hasSuffix("@") else {
            throw HomeworkServiceError.invalidSchoolManagerEmail
        }

        let result = try await run(subject: subject, referenceDate: referenceDate)
        guard let date = result.date, let lessonSubject = result.subject else {
            throw HomeworkServiceError.schoolManagerRequestFailed
        }
        return Lesson(id: "\(lessonSubject)-\(date.timeIntervalSince1970)", subject: lessonSubject, startDate: date)
    }

    private func run(subject: String?, referenceDate: Date) async throws -> SchoolManagerLessonResult {
        guard let username = KeychainStore.value(for: "schoolManagerUsername"), !username.isEmpty,
              let password = KeychainStore.value(for: "schoolManagerPassword"), !password.isEmpty else {
            throw HomeworkServiceError.missingSchoolManagerCredentials
        }
        guard username.contains("@"),
              username.split(separator: "@", maxSplits: 1).count == 2,
              !username.hasPrefix("@"),
              !username.hasSuffix("@") else {
            throw HomeworkServiceError.invalidSchoolManagerEmail
        }
        return try await SchoolManagerPythonRunner().nextLesson(
            subject: subject,
            username: username,
            password: password,
            referenceDate: referenceDate
        )
    }
}

private struct SchoolManagerPythonRunner {
    func nextLesson(subject: String?, username: String, password: String, referenceDate: Date) async throws -> SchoolManagerLessonResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try run(subject: subject, username: username, password: password, referenceDate: referenceDate))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func run(subject: String?, username: String, password: String, referenceDate: Date) throws -> SchoolManagerLessonResult {
        let helperURL = try locateHelper()
        let apiURL = try locateAPIRepository()
        let runtime = try locatePythonRuntime()
        let requestPayload = SchoolManagerRequest(
            subject: subject,
            username: username,
            password: password,
            referenceDate: Self.dateFormatter.string(from: referenceDate)
        )

        let process = Process()
        process.executableURL = runtime.pythonURL
        process.arguments = [helperURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["SCHULMANAGER_API_PATH"] = apiURL.path
        if let extraPythonPath = runtime.extraPythonPath {
            environment["PYTHONPATH"] = [extraPythonPath, environment["PYTHONPATH"]]
                .compactMap { $0 }
                .joined(separator: ":")
        }
        process.environment = environment

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        standardInput.fileHandleForWriting.write(try JSONEncoder().encode(requestPayload))
        try standardInput.fileHandleForWriting.close()

        // Selenium/Chrome can hang (network stall, page never settling) with no internal ceiling
        // on the overall run. Without this, a stuck lookup would block every button in the app
        // forever, since isLoadingLesson/isSubmitting never resets. Kill the process past the
        // timeout so the UI reliably recovers with an error instead of freezing.
        let timeoutWorkItem = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.processTimeout, execute: timeoutWorkItem)
        process.waitUntilExit()
        timeoutWorkItem.cancel()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal {
                throw HomeworkServiceError.schoolManagerTimedOut
            }
            throw HomeworkServiceError.schoolManagerRequestFailed
        }
        guard let result = try? JSONDecoder().decode(SchoolManagerResponse.self, from: output) else {
            throw HomeworkServiceError.schoolManagerRequestFailed
        }
        if let error = result.error {
            switch error {
            case "adapter_missing":
                throw HomeworkServiceError.schoolManagerAdapterMissing
            case "login_failed":
                throw HomeworkServiceError.schoolManagerLoginFailed
            case "login_invalid_credentials":
                throw HomeworkServiceError.schoolManagerLoginFailed
            case "login_login_timeout":
                throw HomeworkServiceError.schoolManagerLoginTimeout
            case "no_next_lesson":
                throw HomeworkServiceError.noNextLesson(subject ?? "")
            default:
                if error.hasPrefix("request_failed:") {
                    let type = String(error.dropFirst("request_failed:".count))
                    throw HomeworkServiceError.schoolManagerDiagnostic(type)
                }
                throw HomeworkServiceError.schoolManagerRequestFailed
            }
        }
        let date = result.date.flatMap(Self.dateFormatter.date)
        let schedule = result.schedule?.map {
            DailyScheduleLesson(period: $0.period, title: $0.title, date: date ?? referenceDate)
        }
        return SchoolManagerLessonResult(subject: result.subject, date: date, schedule: schedule)
    }

    /// Upper bound for the whole helper run (Chrome startup, login, up to two weeks of
    /// timetable scraping). Generous relative to the script's own ~20-30s per-page waits.
    private static let processTimeout: TimeInterval = 90

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func locateHelper() throws -> URL {
        if let bundled = Bundle.main.url(forResource: "schulmanager_schedule", withExtension: "py") {
            return bundled
        }
        return try locate(relativePath: "HomeWorkApp/Support/schulmanager_schedule.py")
    }

    private func locateAPIRepository() throws -> URL {
        if let configured = ProcessInfo.processInfo.environment["SCHULMANAGER_API_PATH"],
           FileManager.default.fileExists(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }
        if let bundled = bundledRuntimeDirectory?.appendingPathComponent("Schulmanager-API"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("main/schedules.py").path) {
            return bundled
        }
        return try locate(relativePath: "Vendor/Schulmanager-API")
    }

    /// Locates a Python interpreter to run the Schulmanager helper with, in one of two setups:
    ///
    /// - Local development: `.venv/bin/python`, created by `script/setup_schulmanager_api.sh`,
    ///   which already has `selenium` installed.
    /// - A release build produced by `.github/workflows/release-build.yml`: the app bundles a
    ///   copy of `Vendor/Schulmanager-API` plus a portable, interpreter-independent copy of
    ///   `selenium`'s pure-Python packages (installed via `pip install --target`, so it isn't
    ///   pinned to an absolute interpreter path the way a `.venv` is). Baking the CI runner's own
    ///   `.venv` into the app wouldn't work, since its interpreter is a symlink into that runner's
    ///   filesystem; instead we point PYTHONPATH at the bundled packages and run them with
    ///   whatever `python3` is already installed on the user's own Mac.
    ///
    /// Either way, the user still needs a local Chrome install; Selenium drives the user's own
    /// browser, which isn't something that can be bundled into the app.
    private func locatePythonRuntime() throws -> PythonRuntime {
        if let venvPython = try? locate(relativePath: ".venv/bin/python") {
            return PythonRuntime(pythonURL: venvPython, extraPythonPath: nil)
        }
        if let sitePackages = bundledRuntimeDirectory?.appendingPathComponent("site-packages"),
           FileManager.default.fileExists(atPath: sitePackages.path) {
            guard let systemPython = Self.locateSystemPython() else {
                throw HomeworkServiceError.schoolManagerAdapterMissing
            }
            return PythonRuntime(pythonURL: systemPython, extraPythonPath: sitePackages.path)
        }
        throw HomeworkServiceError.schoolManagerAdapterMissing
    }

    private var bundledRuntimeDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("SchulmanagerRuntime")
    }

    private static func locateSystemPython() -> URL? {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map(URL.init(fileURLWithPath:))
    }

    private func locate(relativePath: String) throws -> URL {
        let sourceDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roots = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            sourceDirectory
        ]
        for startingRoot in roots {
            var root = startingRoot
            for _ in 0..<10 {
                let candidate = root.appendingPathComponent(relativePath)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                root.deleteLastPathComponent()
            }
        }
        throw HomeworkServiceError.schoolManagerAdapterMissing
    }
}

private struct SchoolManagerRequest: Encodable {
    let subject: String?
    let username: String
    let password: String
    let referenceDate: String
}

private struct SchoolManagerResponse: Decodable {
    let date: String?
    let subject: String?
    let error: String?
    let schedule: [SchedulePayload]?
}

private struct SchedulePayload: Decodable {
    let period: Int
    let title: String
    let date: String
}

private struct SchoolManagerLessonResult {
    let subject: String?
    let date: Date?
    let schedule: [DailyScheduleLesson]?
}

private struct PythonRuntime {
    let pythonURL: URL
    /// A PYTHONPATH entry pointing at a bundled, interpreter-independent package set. Nil when
    /// using a `.venv` that already has its dependencies installed.
    let extraPythonPath: String?
}
