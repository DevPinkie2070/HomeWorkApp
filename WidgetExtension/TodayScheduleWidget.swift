import SwiftUI
import WidgetKit

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let lessons: [DailyScheduleLesson]
}

struct TodayScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry {
        ScheduleEntry(date: .now, lessons: [
            DailyScheduleLesson(period: 1, title: "Mathematik", date: .now),
            DailyScheduleLesson(period: 2, title: "Englisch", date: .now)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        completion(ScheduleEntry(date: .now, lessons: SharedScheduleCache.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let entry = ScheduleEntry(date: .now, lessons: SharedScheduleCache.load())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct TodayScheduleWidgetView: View {
    let entry: ScheduleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scheduleTitle)
                .font(.headline)
            if entry.lessons.isEmpty {
                Text("Kein Stundenplan verfügbar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entry.lessons.prefix(6)) { lesson in
                    HStack(spacing: 8) {
                        Text("\(lesson.period).")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(lesson.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }

    private var scheduleTitle: String {
        guard let date = entry.lessons.first?.date else { return "Heute" }
        if Calendar.current.isDateInToday(date) {
            return "Heute"
        }
        return date.formatted(.dateTime.weekday(.wide))
    }
}

@main
struct TodayScheduleWidget: Widget {
    let kind = "TodayScheduleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayScheduleProvider()) { entry in
            TodayScheduleWidgetView(entry: entry)
        }
        .configurationDisplayName("Stundenplan")
        .description("Zeigt deinen heutigen Stundenplan.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct DailyScheduleLesson: Codable, Identifiable {
    let period: Int
    let title: String
    let date: Date

    var id: String { "\(date.timeIntervalSince1970)-\(period)" }
}

enum SharedScheduleCache {
    static let appGroup = "group.devpinkie.homeworkapp"
    private static let key = "todaySchedule"

    static func load() -> [DailyScheduleLesson] {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let lessons = try? JSONDecoder().decode([DailyScheduleLesson].self, from: data) else {
            return []
        }
        return lessons
    }
}
