import SwiftUI

struct SettingsView: View {
    @AppStorage("memberID") private var memberID = ""
    @StateObject private var updateChecker = UpdateChecker()

    var body: some View {
        Form {
            Section("AStA") {
                TextField("Member-ID", text: $memberID)
                    .textFieldStyle(.roundedBorder)

                Text("Die Member-ID wird lokal gespeichert und kann jederzeit geändert werden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Button("Nach Updates suchen") {
                    Task {
                        await updateChecker.checkForUpdates()
                    }
                }

                statusView
            }
        }
        .padding()
        .frame(minWidth: 420, minHeight: 230)
    }

    @ViewBuilder
    private var statusView: some View {
        switch updateChecker.state {
        case .idle:
            Text("Noch keine Update-Prüfung durchgeführt.")
                .foregroundStyle(.secondary)
        case .checking:
            ProgressView("Suche nach Updates …")
        case .upToDate:
            Text("Du nutzt bereits die aktuelle Version.")
                .foregroundStyle(.green)
        case let .updateAvailable(version, downloadURL):
            VStack(alignment: .leading, spacing: 8) {
                Text("Neue Version verfügbar: \(version)")
                    .foregroundStyle(.orange)
                Link("Update herunterladen", destination: downloadURL)
            }
        case let .failed(message):
            Text(message)
                .foregroundStyle(.red)
        }
    }
}
