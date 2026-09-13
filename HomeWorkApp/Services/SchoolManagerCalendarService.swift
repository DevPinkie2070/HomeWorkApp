import Foundation

/// Local adapter around the user-selected Schulmanager-API repository.
/// It only reads the timetable and never writes to Schulmanager.
struct SchoolManagerCalendarService {
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

        let result = try await SchoolManagerPythonRunner().nextLesson(
            subject: subject,
            username: username,
            password: password,
            referenceDate: referenceDate
        )
        return Lesson(id: "\(result.subject)-\(result.date.timeIntervalSince1970)", subject: result.subject, startDate: result.date)
    }
}

private struct SchoolManagerPythonRunner {
    func nextLesson(subject: String, username: String, password: String, referenceDate: Date) async throws -> SchoolManagerLessonResult {
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

    private func run(subject: String, username: String, password: String, referenceDate: Date) throws -> SchoolManagerLessonResult {
        let helperURL = try locateHelper()
        let apiURL = try locateAPIRepository()
        let pythonURL = try locatePython()
        let requestPayload = SchoolManagerRequest(
            subject: subject,
            username: username,
            password: password,
            referenceDate: Self.dateFormatter.string(from: referenceDate)
        )

        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [helperURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SCHULMANAGER_API_PATH": apiURL.path
        ]) { _, new in new }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        standardInput.fileHandleForWriting.write(try JSONEncoder().encode(requestPayload))
        try standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
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
                throw HomeworkServiceError.noNextLesson(subject)
            default:
                if error.hasPrefix("request_failed:") {
                    let type = String(error.dropFirst("request_failed:".count))
                    throw HomeworkServiceError.schoolManagerDiagnostic(type)
                }
                throw HomeworkServiceError.schoolManagerRequestFailed
            }
        }
        guard let dateString = result.date,
              let date = Self.dateFormatter.date(from: dateString),
              let lessonSubject = result.subject else {
            throw HomeworkServiceError.schoolManagerRequestFailed
        }

        return SchoolManagerLessonResult(subject: lessonSubject, date: date)
    }

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
        return try locate(relativePath: "Vendor/Schulmanager-API")
    }

    private func locatePython() throws -> URL {
        try locate(relativePath: ".venv/bin/python")
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
    let subject: String
    let username: String
    let password: String
    let referenceDate: String
}

private struct SchoolManagerResponse: Decodable {
    let date: String?
    let subject: String?
    let error: String?
}

private struct SchoolManagerLessonResult {
    let subject: String
    let date: Date
}
