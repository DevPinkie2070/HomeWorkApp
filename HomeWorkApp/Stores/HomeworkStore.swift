import Combine
import Foundation

@MainActor
final class HomeworkStore: ObservableObject {
    let subjects = SubjectCatalog.load()
    @Published var selectedSubject: SubjectAlias?
    @Published var homework = ""
    @Published var dueSelection: DueSelection = .nextLesson
    @Published var chosenDate = Date()
    @Published private(set) var nextLesson: Lesson?
    @Published private(set) var isLoadingLesson = false
    @Published private(set) var isSubmitting = false
    @Published var successMessage: String?
    @Published var errorMessage: String?

    private let schoolManager = SchoolManagerCalendarService()
    private let clickUp = ClickUpService()

    var subject: String {
        selectedSubject?.name ?? ""
    }

    private var subjectAlias: String {
        selectedSubject?.alias ?? ""
    }

    func lookupNextLesson() async {
        guard !subjectAlias.isEmpty else {
            nextLesson = nil
            return
        }
        successMessage = nil
        isLoadingLesson = true
        defer { isLoadingLesson = false }
        do {
            nextLesson = try await schoolManager.nextLesson(for: subjectAlias)
            errorMessage = nil
        } catch {
            nextLesson = nil
            errorMessage = error.localizedDescription
        }
    }

    func submit() async {
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
                let lesson = try await schoolManager.nextLesson(for: subjectAlias)
                nextLesson = lesson
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
