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
    @State private var clickUpAssigneeID = ""
    @State private var subjects: [SubjectAlias] = []
    @State private var savedMessage: String?
    @State private var settingsLoaded = false
    @State private var isTestingClickUp = false
    @State private var clickUpTestMessage: String?
    @State private var clickUpTestSucceeded = false

    var body: some View {
        Form {
            Section {
                Toggle("Beim Mac-Start öffnen", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, shouldLaunch in
                        updateLaunchAtLogin(shouldLaunch)
                    }
            } header: {
                Label("Allgemein", systemImage: "switch.2")
            }

            Section {
                Text("Passe die Kürzel an die Fachbezeichnungen in deinem Schulmanager-Stundenplan an.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach($subjects) { $subject in
                    HStack {
                        Text(subject.name)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        TextField("Alias", text: $subject.alias)
                            .frame(width: 120)
                    }
                }
            } header: {
                Label("Fächer-Aliase", systemImage: "books.vertical.fill")
            }

            Section {
                Toggle("Schulmanager-Abgleich aktivieren", isOn: $schoolManagerAccessEnabled)
                TextField("E-Mail-Adresse", text: $schoolManagerUsername)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                SecureField("Passwort", text: $schoolManagerPassword)
                Text("Für den Abgleich wird die lokale Drittanbieter-Bibliothek Schulmanager-API mit Chrome/Selenium verwendet. Sie liest ausschließlich deinen Stundenplan; deine Zugangsdaten bleiben im macOS-Schlüsselbund. Bitte nutze sie nur, wenn deine Schule bzw. Schulmanager Online dies erlaubt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Schulmanager", systemImage: "calendar")
            }

            Section {
                TextField("Listen-ID", text: $clickUpListID)
                SecureField("Persönlicher API-Token", text: $clickUpToken)
                TextField("Zugewiesene Person (ClickUp-Nutzer-ID, optional)", text: $clickUpAssigneeID)
                Text("Token und Listen-ID findest du in ClickUp unter Einstellungen → Apps beziehungsweise in der Listen-URL. Der Token wird im macOS-Schlüsselbund gespeichert. Bleibt die Nutzer-ID leer, werden Aufgaben ohne Zuweisung angelegt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button("Verbindung testen") {
                        Task { await testClickUpConnection() }
                    }
                    .disabled(isTestingClickUp)
                    if isTestingClickUp {
                        ProgressView()
                            .controlSize(.small)
                    } else if let clickUpTestMessage {
                        Label(clickUpTestMessage, systemImage: clickUpTestSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(clickUpTestSucceeded ? .green : .red)
                            .lineLimit(2)
                    }
                }
            } header: {
                Label("ClickUp", systemImage: "checklist")
            }

            Section {
                HStack {
                    Button {
                        save()
                    } label: {
                        Label("Einstellungen sichern", systemImage: "checkmark.circle.fill")
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
        clickUpAssigneeID = SchoolSettings().clickUpAssigneeID
        subjects = SubjectCatalog.load()
        schoolManagerUsername = KeychainStore.value(for: "schoolManagerUsername") ?? ""
        schoolManagerPassword = KeychainStore.value(for: "schoolManagerPassword") ?? ""
        clickUpToken = KeychainStore.value(for: "clickUpToken") ?? ""
    }

    private func testClickUpConnection() async {
        isTestingClickUp = true
        clickUpTestMessage = nil
        defer { isTestingClickUp = false }
        do {
            let listName = try await ClickUpService().verifyConnection(
                token: clickUpToken.trimmingCharacters(in: .whitespacesAndNewlines),
                listID: clickUpListID
            )
            clickUpTestSucceeded = true
            clickUpTestMessage = "Verbunden mit Liste „\(listName)“."
        } catch {
            clickUpTestSucceeded = false
            clickUpTestMessage = error.localizedDescription
        }
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
        settings.clickUpAssigneeID = clickUpAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let cleanedSubjects = subjects.map {
                SubjectAlias(name: $0.name, alias: $0.alias.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard cleanedSubjects.allSatisfy({ !$0.alias.isEmpty }) else {
                throw SettingsValidationError.emptySubjectAlias
            }
            try SubjectCatalog.save(cleanedSubjects)
            subjects = cleanedSubjects
            store.updateSubjects(cleanedSubjects)
            try saveOrClearKeychain(schoolManagerUsername.trimmingCharacters(in: .whitespacesAndNewlines), for: "schoolManagerUsername")
            try saveOrClearKeychain(schoolManagerPassword, for: "schoolManagerPassword")
            try saveOrClearKeychain(clickUpToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "clickUpToken")
            savedMessage = "Gespeichert"
            store.successMessage = nil
            store.errorMessage = nil
        } catch {
            savedMessage = nil
            store.errorMessage = error.localizedDescription
        }
    }

    /// Clears the keychain entry instead of leaving a blank secret behind when a field is emptied.
    private func saveOrClearKeychain(_ value: String, for account: String) throws {
        if value.isEmpty {
            KeychainStore.delete(for: account)
        } else {
            try KeychainStore.save(value, for: account)
        }
    }

    private enum SettingsValidationError: LocalizedError {
        case emptySubjectAlias

        var errorDescription: String? {
            "Bitte gib für jedes Fach einen Alias ein."
        }
    }
}
