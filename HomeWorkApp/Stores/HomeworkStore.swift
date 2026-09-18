import Combine
import Foundation

@MainActor
final class HomeworkStore: ObservableObject {
    @Published private(set) var subjects = SubjectCatalog.load()
    @Published var selectedSubject: SubjectAlias? {
        didSet {
            guard oldValue?.id != selectedSubject?.id else { return }
            // A stale "next lesson" from the previous subject would otherwise linger in the UI.
            nextLesson = nil
            nextLessonSubjectAlias = nil
            nextLessonFetchedAt = nil
        }
    }
    @Published var homework = ""
    @Published var dueSelection: DueSelection = .nextLesson
    @Published var chosenDate = Date()
    @Published private(set) var nextLesson: Lesson?
    @Published private(set) var isLoadingLesson = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var isRefreshingSchedule = false
    @Published var successMessage: String?
    @Published var errorMessage: String?

    private let schoolManager = SchoolManagerCalendarService()
    private let clickUp = ClickUpService()

    /// Each Schulmanager lookup spins up a headless Chrome session and logs in, which takes
    /// several seconds. These caches avoid repeating that work needlessly.
    private var nextLessonSubjectAlias: String?
    private var nextLessonFetchedAt: Date?
    private let nextLessonCacheInterval: TimeInterval = 120
    private var lastScheduleRefreshAt: Date?
    private let scheduleRefreshInterval: TimeInterval = 600

    var subject: String {
        selectedSubject?.name ?? ""
    }

    private var subjectAlias: String {
        selectedSubject?.alias ?? ""
    }

    func updateSubjects(_ subjects: [SubjectAlias]) {
        self.subjects = subjects
        if let selectedSubject,
           let updatedSubject = subjects.first(where: { $0.id == selectedSubject.id }) {
            self.selectedSubject = updatedSubject
        }
    }

    func lookupNextLesson() async {
        guard !subjectAlias.isEmpty else {
            nextLesson = nil
            return
        }
        guard !isLoadingLesson else { return }
        successMessage = nil
        isLoadingLesson = true
        defer { isLoadingLesson = false }
        do {
            let lesson = try await schoolManager.nextLesson(for: subjectAlias)
            nextLesson = lesson
            nextLessonSubjectAlias = subjectAlias
            nextLessonFetchedAt = .now
            errorMessage = nil
        } catch {
            nextLesson = nil
            nextLessonSubjectAlias = nil
            nextLessonFetchedAt = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes the widget's schedule cache. Automatic callers (e.g. the menu opening) should
    /// leave `force` false so a fresh Chrome/Selenium session isn't launched on every open;
    /// pass `force: true` for an explicit user-triggered refresh.
    func refreshTodaySchedule(force: Bool = false) async {
        guard SchoolSettings().schoolManagerAccessEnabled else {
            errorMessage = HomeworkServiceError.schoolManagerAccessDisabled.localizedDescription
            return
        }
        guard !isRefreshingSchedule else { return }
        if !force, let lastScheduleRefreshAt, Date.now.timeIntervalSince(lastScheduleRefreshAt) < scheduleRefreshInterval {
            return
        }
        isRefreshingSchedule = true
        defer { isRefreshingSchedule = false }
        do {
            let calendar = Calendar.current
            let weekday = calendar.component(.weekday, from: .now)
            let scheduleDate: Date
            if weekday == 7 {
                scheduleDate = calendar.date(byAdding: .day, value: 2, to: .now) ?? .now
            } else if weekday == 1 {
                scheduleDate = calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
            } else {
                scheduleDate = .now
            }
            let lessons = try await schoolManager.todaySchedule(after: scheduleDate)
            SharedScheduleCache.save(lessons)
            lastScheduleRefreshAt = .now
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submit() async {
        guard !isSubmitting else { return }
        let cleanedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedHomework = homework.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subjectAlias.isEmpty, !cleanedHomework.isEmpty else {
            errorMessage = "Bitte gib Fach und Hausaufgabe ein."
            return
        }

        successMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let dueDate: Date
            switch dueSelection {
            case .date:
                dueDate = chosenDate
            case .nextLesson:
                let lesson: Lesson
                if let cached = nextLesson,
                   nextLessonSubjectAlias == subjectAlias,
                   let fetchedAt = nextLessonFetchedAt,
                   Date.now.timeIntervalSince(fetchedAt) < nextLessonCacheInterval {
                    // Reuse the lesson from a recent "Abgleichen" tap instead of logging in again.
                    lesson = cached
                } else {
                    lesson = try await schoolManager.nextLesson(for: subjectAlias)
                    nextLesson = lesson
                    nextLessonSubjectAlias = subjectAlias
                    nextLessonFetchedAt = .now
                }
                dueDate = lesson.startDate
            }
            let includesTime = dueSelection == .date
            let taskURL = try await clickUp.createHomeworkTask(subject: cleanedSubject, homework: cleanedHomework, dueDate: dueDate, includesTime: includesTime)
            successMessage = taskURL.map { "In ClickUp angelegt. \($0)" } ?? "In ClickUp angelegt."
            errorMessage = nil
            homework = ""
        } catch {
            successMessage = nil
            errorMessage = error.localizedDescription
        }
    }
}
