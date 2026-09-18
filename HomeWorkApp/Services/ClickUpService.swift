import Foundation

struct ClickUpService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func createHomeworkTask(subject: String, homework: String, dueDate: Date, includesTime: Bool) async throws -> String? {
        guard let token = KeychainStore.value(for: "clickUpToken"), !token.isEmpty else {
            throw HomeworkServiceError.missingClickUpToken
        }

        let listID = SchoolSettings().clickUpListID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !listID.isEmpty else {
            throw HomeworkServiceError.missingClickUpListID
        }

        guard let url = URL(string: "https://api.clickup.com/api/v2/list/\(listID)/task") else {
            throw HomeworkServiceError.invalidClickUpListID
        }

        let dueMilliseconds = Int64(dueDate.timeIntervalSince1970 * 1_000)
        let assigneeID = SchoolSettings().clickUpAssigneeID.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ClickUpTaskPayload(
            name: "[\(subject)] Hausaufgabe",
            markdownDescription: "## \(subject)\n\n\(homework)\n\n*Fällig: \(dueDate.formatted(date: .long, time: .shortened))*",
            dueDate: dueMilliseconds,
            dueDateTime: includesTime,
            assignees: Int(assigneeID).map { [$0] } ?? []
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HomeworkServiceError.invalidServerResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(ClickUpErrorResponse.self, from: data).err)
            throw HomeworkServiceError.clickUpRequestFailed(httpResponse.statusCode, message)
        }

        return try? JSONDecoder().decode(ClickUpTaskResponse.self, from: data).url
    }

    /// Verifies that a token/list ID pair can reach ClickUp and resolves to a real list.
    /// Pass explicit values to test unsaved settings-form input; omit them to test the saved configuration.
    func verifyConnection(token overrideToken: String? = nil, listID overrideListID: String? = nil) async throws -> String {
        let token = overrideToken ?? KeychainStore.value(for: "clickUpToken") ?? ""
        guard !token.isEmpty else {
            throw HomeworkServiceError.missingClickUpToken
        }

        let listID = (overrideListID ?? SchoolSettings().clickUpListID).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !listID.isEmpty else {
            throw HomeworkServiceError.missingClickUpListID
        }

        guard let url = URL(string: "https://api.clickup.com/api/v2/list/\(listID)") else {
            throw HomeworkServiceError.invalidClickUpListID
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HomeworkServiceError.invalidServerResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = try? JSONDecoder().decode(ClickUpErrorResponse.self, from: data).err
            throw HomeworkServiceError.clickUpConnectionFailed(httpResponse.statusCode, message)
        }

        return (try? JSONDecoder().decode(ClickUpListResponse.self, from: data).name) ?? listID
    }
}

private struct ClickUpTaskPayload: Encodable {
    let name: String
    let markdownDescription: String
    let dueDate: Int64
    let dueDateTime: Bool
    let assignees: [Int]

    enum CodingKeys: String, CodingKey {
        case name
        case markdownDescription = "markdown_description"
        case dueDate = "due_date"
        case dueDateTime = "due_date_time"
        case assignees
    }
}

private struct ClickUpTaskResponse: Decodable {
    let url: String?
}

private struct ClickUpErrorResponse: Decodable {
    let err: String?
}

private struct ClickUpListResponse: Decodable {
    let name: String?
}

enum HomeworkServiceError: LocalizedError {
    case missingClickUpToken
    case missingClickUpListID
    case invalidClickUpListID
    case invalidServerResponse
    case clickUpRequestFailed(Int, String?)
    case clickUpConnectionFailed(Int, String?)
    case schoolManagerAccessDisabled
    case missingSchoolManagerCredentials
    case invalidSchoolManagerEmail
    case schoolManagerAdapterMissing
    case schoolManagerLoginFailed
    case schoolManagerLoginTimeout
    case schoolManagerDiagnostic(String)
    case schoolManagerRequestFailed
    case schoolManagerTimedOut
    case noNextLesson(String)

    var errorDescription: String? {
        switch self {
        case .missingClickUpToken:
            return "Bitte hinterlege zuerst deinen ClickUp-API-Token in den Einstellungen."
        case .missingClickUpListID:
            return "Bitte hinterlege zuerst die ClickUp-Listen-ID in den Einstellungen."
        case .invalidClickUpListID:
            return "Die ClickUp-Listen-ID ist ungültig."
        case .invalidServerResponse:
            return "Der Server hat keine verwertbare Antwort geliefert."
        case let .clickUpRequestFailed(statusCode, message):
            return "ClickUp hat die Aufgabe nicht angelegt (HTTP \(statusCode))\(message.map { ": \($0)" } ?? "")."
        case let .clickUpConnectionFailed(statusCode, message):
            return "Verbindung zu ClickUp fehlgeschlagen (HTTP \(statusCode))\(message.map { ": \($0)" } ?? "")."
        case .schoolManagerAccessDisabled:
            return "Bitte aktiviere zuerst den Schulmanager-Abgleich in den Einstellungen."
        case .missingSchoolManagerCredentials:
            return "Bitte hinterlege zuerst deinen Schulmanager-Benutzernamen und dein Passwort in den Einstellungen."
        case .invalidSchoolManagerEmail:
            return "Bitte hinterlege die E-Mail-Adresse deines Schulmanager-Kontos."
        case .schoolManagerAdapterMissing:
            return "Die lokale Schulmanager-API wurde nicht gefunden. Führe script/setup_schulmanager_api.sh aus."
        case .schoolManagerLoginFailed:
            return "Die Anmeldung bei Schulmanager ist fehlgeschlagen. Prüfe Benutzername und Passwort."
        case .schoolManagerLoginTimeout:
            return "Die Schulmanager-Anmeldung hat keine verwertbare Antwort geliefert. Prüfe die Internetverbindung und ob die Login-Seite erreichbar ist."
        case let .schoolManagerDiagnostic(type):
            return "Der Schulmanager-Abgleich ist an einem technischen Schritt fehlgeschlagen (\(type)). Prüfe Chrome und die lokale API-Installation."
        case .schoolManagerRequestFailed:
            return "Der Schulmanager-Stundenplan konnte nicht abgeglichen werden. Prüfe deine Zugangsdaten, Chrome und die lokale API-Installation."
        case .schoolManagerTimedOut:
            return "Der Schulmanager-Abgleich hat zu lange gedauert und wurde abgebrochen. Prüfe deine Internetverbindung und versuche es erneut."
        case let .noNextLesson(subject):
            return "Im Stundenplan wurde keine kommende Stunde für \(subject) gefunden."
        }
    }
}
