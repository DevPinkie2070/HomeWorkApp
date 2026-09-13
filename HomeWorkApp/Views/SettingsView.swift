import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: HomeworkStore
    @State private var launchAtLogin = SchoolSettings().launchAtLogin
    @State private var schoolManagerAccessEnabled = false
    @State private var schoolManagerUsername = ""
    @State private var schoolManagerPassword = ""
    @State private var clickUpListID = ""
    @State private var clickUpToken = ""
    @State private var savedMessage: String?
    @State private var settingsLoaded = false

    var body: some View {
        Form {
            Section("Allgemein") {
                Toggle("Beim Mac-Start öffnen", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, shouldLaunch in
                        updateLaunchAtLogin(shouldLaunch)
                    }
            }

            Section("Schulmanager") {
                Toggle("Schulmanager-Abgleich aktivieren", isOn: $schoolManagerAccessEnabled)
                TextField("E-Mail-Adresse", text: $schoolManagerUsername)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Passwort", text: $schoolManagerPassword)
                Text("Für den Abgleich wird die lokale Drittanbieter-Bibliothek Schulmanager-API mit Chrome/Selenium verwendet. Sie liest ausschließlich deinen Stundenplan; deine Zugangsdaten bleiben im macOS-Schlüsselbund. Bitte nutze sie nur, wenn deine Schule bzw. Schulmanager Online dies erlaubt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ClickUp") {
                TextField("Listen-ID", text: $clickUpListID)
                SecureField("Persönlicher API-Token", text: $clickUpToken)
                Text("Token und Listen-ID findest du in ClickUp unter Einstellungen → Apps beziehungsweise in der Listen-URL. Der Token wird im macOS-Schlüsselbund gespeichert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Einstellungen sichern") {
                        save()
                    }
                    .buttonStyle(.borderedProminent)
                    if let savedMessage {
                        Text(savedMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 560)
        .task {
            guard !settingsLoaded else { return }
            settingsLoaded = true
            loadSettings()
        }
    }

    private func loadSettings() {
        launchAtLogin = SchoolSettings().launchAtLogin
        schoolManagerAccessEnabled = SchoolSettings().schoolManagerAccessEnabled
        clickUpListID = SchoolSettings().clickUpListID
        schoolManagerUsername = KeychainStore.value(for: "schoolManagerUsername") ?? ""
        schoolManagerPassword = KeychainStore.value(for: "schoolManagerPassword") ?? ""
        clickUpToken = KeychainStore.value(for: "clickUpToken") ?? ""
    }

    private func updateLaunchAtLogin(_ shouldLaunch: Bool) {
        do {
            if shouldLaunch {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            var settings = SchoolSettings()
            settings.launchAtLogin = shouldLaunch
            savedMessage = "Gespeichert"
        } catch {
            launchAtLogin = SchoolSettings().launchAtLogin
            store.errorMessage = "Startoption konnte nicht geändert werden: \(error.localizedDescription)"
        }
    }

    private func save() {
        var settings = SchoolSettings()
        settings.schoolManagerAccessEnabled = schoolManagerAccessEnabled
        settings.clickUpListID = clickUpListID.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.save(schoolManagerUsername.trimmingCharacters(in: .whitespacesAndNewlines), for: "schoolManagerUsername")
            try KeychainStore.save(schoolManagerPassword, for: "schoolManagerPassword")
            try KeychainStore.save(clickUpToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "clickUpToken")
            savedMessage = "Gespeichert"
            store.successMessage = nil
            store.errorMessage = nil
        } catch {
            savedMessage = nil
            store.errorMessage = error.localizedDescription
        }
    }
}
