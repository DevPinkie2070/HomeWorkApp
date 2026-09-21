import AppKit
import Combine
import Foundation

/// Checks GitHub Releases for a newer build and can download, install and relaunch it in place.
///
/// Releases are tagged `release-<GitHub Actions run number>` (see
/// `.github/workflows/release-build.yml`), not a semantic version, so "newer" is decided by
/// comparing that run number against this build's own `CFBundleVersion` (which CI stamps with
/// its own run number at archive time) rather than `CFBundleShortVersionString`.
@MainActor
final class AppUpdateService: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(build: Int, downloadURL: URL)
        case downloading(build: Int, progress: Double)
        case installing(build: Int)
        case relaunching
        case failed(message: String)

        /// Worth showing a banner for in the menu bar dropdown, as opposed to idle/checking/
        /// up-to-date states that would just add noise to every-day use.
        var isNoteworthy: Bool {
            switch self {
            case .idle, .checking, .upToDate:
                return false
            case .updateAvailable, .downloading, .installing, .relaunching, .failed:
                return true
            }
        }
    }

    @Published private(set) var state: State = .idle

    private let owner = "DevPinkie2070"
    private let repo = "HomeWorkApp"
    private var periodicCheckTask: Task<Void, Never>?
    private let periodicCheckInterval: TimeInterval = 6 * 60 * 60

    var currentBuild: Int {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return raw.flatMap(Int.init) ?? 0
    }

    init() {
        // Checks immediately at launch, then periodically - independent of any SwiftUI view
        // ever appearing (the MenuBarExtra dropdown only builds its content once opened).
        periodicCheckTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.checkForUpdates()
                try? await Task.sleep(for: .seconds(self.periodicCheckInterval))
            }
        }
    }

    deinit {
        periodicCheckTask?.cancel()
    }

    func checkForUpdates() async {
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            state = .failed(message: "Update-URL ist ungültig.")
            return
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                state = .failed(message: "Update-Informationen konnten nicht geladen werden.")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let latestBuild = Self.buildNumber(fromTag: release.tagName) else {
                state = .failed(message: "Die Release-Kennung „\(release.tagName)“ konnte nicht gelesen werden.")
                return
            }

            guard latestBuild > currentBuild else {
                state = .upToDate
                return
            }

            guard let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else {
                state = .failed(message: "Das Release \(release.tagName) enthält keine DMG-Datei.")
                return
            }

            state = .updateAvailable(build: latestBuild, downloadURL: dmgAsset.browserDownloadURL)
        } catch {
            state = .failed(message: "Update-Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func installUpdate(build: Int, from downloadURL: URL) async {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeWorkAppUpdate-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workDirectory) }

            let dmgURL = workDirectory.appendingPathComponent("HomeWorkApp-\(build).dmg")
            try await download(from: downloadURL, to: dmgURL) { [weak self] progress in
                self?.state = .downloading(build: build, progress: progress)
            }

            state = .installing(build: build)
            let mountPoint = workDirectory.appendingPathComponent("mount")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try mount(dmg: dmgURL, at: mountPoint)
            let stagedAppURL: URL
            do {
                let sourceAppURL = try locateApp(in: mountPoint)
                let stagingURL = workDirectory.appendingPathComponent(sourceAppURL.lastPathComponent)
                try FileManager.default.copyItem(at: sourceAppURL, to: stagingURL)
                stagedAppURL = stagingURL
            } catch {
                try? unmount(mountPoint)
                throw error
            }
            try unmount(mountPoint)

            let runningAppURL = Bundle.main.bundleURL
            try replace(runningAppURL, withStagedAppAt: stagedAppURL)

            state = .relaunching
            relaunch(at: runningAppURL)
        } catch {
            state = .failed(message: "Installation fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    // MARK: - Download

    private func download(from url: URL, to destination: URL, progress: @escaping (Double) -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw UpdateError.downloadFailed
        }
        let expectedLength = response.expectedContentLength

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw UpdateError.downloadFailed
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReportedProgress = -1.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                handle.write(buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expectedLength > 0 {
                    let value = Double(received) / Double(expectedLength)
                    // Coalesce to whole percentage points so @Published doesn't flood the UI.
                    if value - lastReportedProgress > 0.01 {
                        lastReportedProgress = value
                        progress(min(value, 1))
                    }
                }
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
        }
        progress(1)
    }

    // MARK: - Disk image handling

    private func mount(dmg: URL, at mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", dmg.path, "-nobrowse", "-noautoopen", "-mountpoint", mountPoint.path, "-quiet"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.mountFailed }
    }

    private func unmount(_ mountPoint: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", mountPoint.path, "-quiet"]
        try process.run()
        process.waitUntilExit()
    }

    private func locateApp(in mountPoint: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.appNotFoundInImage
        }
        return appURL
    }

    // MARK: - Swap and relaunch

    /// Swaps the running app's bundle for the staged one. macOS allows renaming/removing a
    /// directory that a process is currently executing from - only the directory entry changes,
    /// the already-open executable image keeps running off its inode - so this is safe to do
    /// without quitting first.
    private func replace(_ runningAppURL: URL, withStagedAppAt stagedAppURL: URL) throws {
        let fileManager = FileManager.default
        let backupURL = runningAppURL.deletingLastPathComponent()
            .appendingPathComponent(".\(runningAppURL.lastPathComponent).bak-\(UUID().uuidString)")

        try fileManager.moveItem(at: runningAppURL, to: backupURL)
        do {
            try fileManager.moveItem(at: stagedAppURL, to: runningAppURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            try? fileManager.removeItem(at: runningAppURL)
            try? fileManager.moveItem(at: backupURL, to: runningAppURL)
            throw error
        }
    }

    private func relaunch(at appURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", appURL.path]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApplication.shared.terminate(nil)
        }
    }

    /// Extracts the trailing run number from tags like "release-42".
    private static func buildNumber(fromTag tag: String) -> Int? {
        guard let range = tag.range(of: #"[0-9]+$"#, options: .regularExpression) else { return nil }
        return Int(tag[range])
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

private enum UpdateError: LocalizedError {
    case downloadFailed
    case mountFailed
    case appNotFoundInImage

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "Der Download ist fehlgeschlagen."
        case .mountFailed:
            return "Das Disk-Image konnte nicht geöffnet werden."
        case .appNotFoundInImage:
            return "Im heruntergeladenen Image wurde keine App gefunden."
        }
    }
}
