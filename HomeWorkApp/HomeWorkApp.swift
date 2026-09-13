import SwiftUI

@main
struct HomeWorkApp: App {
    @StateObject private var homeworkStore = HomeworkStore()

    var body: some Scene {
        MenuBarExtra("Hausaufgaben", systemImage: "checklist") {
            HomeworkComposerView(store: homeworkStore)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: homeworkStore)
        }
    }
}
