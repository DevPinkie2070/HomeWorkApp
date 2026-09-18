import Foundation
import WidgetKit

struct SubjectAlias: Codable, Identifiable, Hashable {
    let name: String
    var alias: String

    var id: String { name }
}

enum SubjectCatalog {
    static func load() -> [SubjectAlias] {
        if let data = UserDefaults.standard.data(forKey: Keys.subjectAliases),
           let subjects = try? JSONDecoder().decode([SubjectAlias].self, from: data) {
            return sortedAndFiltered(subjects)
        }

        guard let url = Bundle.main.url(forResource: "subject_aliases", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let subjects = try? JSONDecoder().decode([SubjectAlias].self, from: data) else {
            return []
        }
        return sortedAndFiltered(subjects)
    }

    static func save(_ subjects: [SubjectAlias]) throws {
        let data = try JSONEncoder().encode(subjects)
        UserDefaults.standard.set(data, forKey: Keys.subjectAliases)
    }

    private static func sortedAndFiltered(_ subjects: [SubjectAlias]) -> [SubjectAlias] {
        subjects
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private enum Keys {
        static let subjectAliases = "subjectAliases"
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

struct DailyScheduleLesson: Codable, Identifiable, Equatable {
    let period: Int
    let title: String
    let date: Date

    var id: String { "\(date.timeIntervalSince1970)-\(period)" }
}

enum SharedScheduleCache {
    static let appGroup = "group.devpinkie.homeworkapp"
    private static let key = "todaySchedule"

    static func save(_ lessons: [DailyScheduleLesson]) {
        guard let data = try? JSONEncoder().encode(lessons) else { return }
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        defaults.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: "TodayScheduleWidget")
    }

    static func load() -> [DailyScheduleLesson] {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let lessons = try? JSONDecoder().decode([DailyScheduleLesson].self, from: data) else {
            return []
        }
        return lessons
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

    /// Optional ClickUp user ID to assign new tasks to. Left empty, tasks are created unassigned.
    var clickUpAssigneeID: String {
        get { UserDefaults.standard.string(forKey: Keys.clickUpAssigneeID) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.clickUpAssigneeID) }
    }

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let schoolManagerAccessEnabled = "schoolManagerAccessEnabled"
        static let clickUpListID = "clickUpListID"
        static let clickUpAssigneeID = "clickUpAssigneeID"
    }
}
