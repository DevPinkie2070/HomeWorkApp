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
            DailyScheduleLesson(period: 2, title: "Englisch", date: .now),
            DailyScheduleLesson(period: 3, title: "Sport", date: .now)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        completion(ScheduleEntry(date: .now, lessons: SharedScheduleCache.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let entry = ScheduleEntry(date: .now, lessons: SharedScheduleCache.load())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now.addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

struct TodayScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ScheduleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if entry.lessons.isEmpty {
                emptyState
            } else {
                lessonList
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
                .font(.headline)
            Text(scheduleTitle)
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                Text("Kein Stundenplan verfügbar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Öffne die App, um den Stundenplan zu laden.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
        }
    }

    private var lessonList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.lessons.prefix(maxLessonCount)) { lesson in
                HStack(spacing: 8) {
                    Text("\(lesson.period)")
                        .font(.caption2.monospacedDigit().bold())
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.tint))
                    Text(lesson.title)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var maxLessonCount: Int {
        switch family {
        case .systemSmall: return 4
        case .systemMedium: return 5
        default: return 10
        }
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
