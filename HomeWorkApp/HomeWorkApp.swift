import SwiftUI

@main
struct HomeWorkApp: App {
    @StateObject private var homeworkStore = HomeworkStore()
    @StateObject private var updateService = AppUpdateService()

    var body: some Scene {
        MenuBarExtra("Hausaufgaben", systemImage: "backpack.fill") {
            HomeworkComposerView(store: homeworkStore, updateService: updateService)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: homeworkStore, updateService: updateService)
        }
    }
}
