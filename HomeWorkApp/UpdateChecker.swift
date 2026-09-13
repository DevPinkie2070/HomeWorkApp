import Foundation

@MainActor
final class UpdateChecker: ObservableObject {
    struct ReleaseInfo: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    enum State {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, downloadURL: URL)
        case failed(message: String)
    }

    @Published private(set) var state: State = .idle

    private let owner = "DevPinkie2070"
    private let repo = "HomeWorkApp"

    func checkForUpdates() async {
        state = .checking

        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            state = .failed(message: "Update-URL ist ungültig.")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                state = .failed(message: "Update-Informationen konnten nicht geladen werden.")
                return
            }

            let release = try JSONDecoder().decode(ReleaseInfo.self, from: data)
            let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let currentVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"

            guard latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending else {
                state = .upToDate
                return
            }

            if let dmgAsset = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) {
                state = .updateAvailable(version: latestVersion, downloadURL: dmgAsset.browserDownloadURL)
            } else {
                state = .updateAvailable(version: latestVersion, downloadURL: release.htmlURL)
            }
        } catch {
            state = .failed(message: "Update-Prüfung fehlgeschlagen: \(error.localizedDescription)")
        }
    }
}
