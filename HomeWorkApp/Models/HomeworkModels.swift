import Foundation

struct SubjectAlias: Codable, Identifiable, Hashable {
    let name: String
    let alias: String

    var id: String { name }
}

enum SubjectCatalog {
    static func load() -> [SubjectAlias] {
        guard let url = Bundle.main.url(forResource: "subject_aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let subjects = try? JSONDecoder().decode([SubjectAlias].self, from: data) else {
            return []
        }
        return subjects
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum DueSelection: String, CaseIterable, Identifiable {
    case nextLesson = "Nächste Stunde"
    case date = "Datum"

    var id: Self { self }
}

struct Lesson: Identifiable, Equatable {
    let id: String
    let subject: String
    let startDate: Date

    var formattedStart: String {
        startDate.formatted(date: .abbreviated, time: .omitted)
    }
}

struct SchoolSettings {
    var launchAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.launchAtLogin) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.launchAtLogin) }
    }

    var schoolManagerAccessEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.schoolManagerAccessEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.schoolManagerAccessEnabled) }
    }

    var clickUpListID: String {
        get { UserDefaults.standard.string(forKey: Keys.clickUpListID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.clickUpListID) }
    }

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let schoolManagerAccessEnabled = "schoolManagerAccessEnabled"
        static let clickUpListID = "clickUpListID"
    }
}
