import AppKit
import SwiftUI

struct HomeworkComposerView: View {
    @ObservedObject var store: HomeworkStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hausaufgabe erfassen")
                        .font(.headline)
                    Text("Wird direkt in deine ClickUp-Liste gelegt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(.tint)
            }

            Picker("Fach", selection: $store.selectedSubject) {
                Text("Fach auswählen").tag(nil as SubjectAlias?)
                ForEach(store.subjects) { subject in
                    Text(subject.name).tag(subject as SubjectAlias?)
                }
            }
            .pickerStyle(.menu)

            TextEditor(text: $store.homework)
                .font(.body)
                .frame(minHeight: 96)
                .overlay(alignment: .topLeading) {
                    if store.homework.isEmpty {
                        Text("Hausaufgabe eingeben …")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                }

            Picker("Fällig", selection: $store.dueSelection) {
                ForEach(DueSelection.allCases) { selection in
                    Text(selection.rawValue).tag(selection)
                }
            }
            .pickerStyle(.segmented)

            switch store.dueSelection {
            case .date:
                DatePicker("Fällig am", selection: $store.chosenDate, displayedComponents: [.date, .hourAndMinute])
            case .nextLesson:
                LessonLookupRow(store: store)
            }

            if let message = store.successMessage {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            if let message = store.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Fehlermeldung kopieren")
                }
            }

            Divider()

            HStack {
                Button {
                    Task { await store.refreshTodaySchedule(force: true) }
                } label: {
                    if store.isRefreshingSchedule {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.isRefreshingSchedule)
                .help("Stundenplan aktualisieren")
                SettingsLink {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("Einstellungen")
                Spacer()
                Button("Beenden") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await store.submit() }
                } label: {
                    if store.isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("In ClickUp anlegen", systemImage: "plus.circle.fill")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(store.isSubmitting)
            }
        }
        .padding(20)
        .frame(width: 390)
        .task {
            await store.refreshTodaySchedule()
        }
    }
}

private struct LessonLookupRow: View {
    @ObservedObject var store: HomeworkStore

    var body: some View {
        HStack(spacing: 10) {
            if store.isLoadingLesson {
                ProgressView()
                    .controlSize(.small)
                Text("Stundenplan wird abgeglichen …")
                    .foregroundStyle(.secondary)
            } else if let lesson = store.nextLesson {
                Label("Nächste Stunde: \(lesson.formattedStart)", systemImage: "calendar")
                    .foregroundStyle(.secondary)
            } else {
                Text("Nächste Stunde wird beim Anlegen abgeglichen.")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Abgleichen") {
                Task { await store.lookupNextLesson() }
            }
            .disabled(store.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoadingLesson)
        }
        .font(.caption)
    }
}
