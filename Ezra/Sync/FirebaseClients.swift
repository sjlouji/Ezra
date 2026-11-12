import Foundation
import Security

typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// Which Firebase project to talk to, read from the GoogleService-Info.plist bundled with the app.
struct FirebaseConfig: Sendable, Equatable {
    let apiKey: String
    let projectID: String

    static func load(from bundle: Bundle = .main) -> FirebaseConfig? {
        guard let url = bundle.url(forResource: "GoogleService-Info", withExtension: "plist"),
              let values = NSDictionary(contentsOf: url),
              let apiKey = values["API_KEY"] as? String, let projectID = values["PROJECT_ID"] as? String
        else { return nil }
        return FirebaseConfig(apiKey: apiKey, projectID: projectID)
    }
}

enum SyncError: LocalizedError, Equatable {
    case notConfigured
    case notSignedIn
    case server(status: Int, code: String)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Sync is not set up: GoogleService-Info.plist is missing from the app."
        case .notSignedIn:
            "Sign in to sync."
        case .server(_, "INVALID_LOGIN_CREDENTIALS"), .server(_, "INVALID_PASSWORD"), .server(_, "EMAIL_NOT_FOUND"):
            "That email and password do not match an account in your Firebase project."
        case .server(_, "PASSWORD_LOGIN_DISABLED"), .server(_, "OPERATION_NOT_ALLOWED"):
            "Email and password sign-in is switched off in your Firebase project. In the Firebase console, open Authentication › Sign-in method and enable Email/Password."
        case .server(_, "TOO_MANY_ATTEMPTS_TRY_LATER"):
            "Firebase has paused sign-in after too many attempts. Wait a few minutes and try again."
        case .server(_, "PERMISSION_DENIED"):
            "Firebase refused access. Check that the Firestore rules allow your account its own data."
        case .server(_, "TOKEN_EXPIRED"), .server(_, "INVALID_REFRESH_TOKEN"), .server(_, "USER_DISABLED"), .server(_, "USER_NOT_FOUND"):
            "Your sign-in is no longer valid. Sign in again."
        case .server(let status, let code):
            "Firebase answered \(status): \(code)."
        case .unreadableResponse:
            "Firebase sent a response that could not be read."
        }
    }
}

enum HTTP {
    static let live: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncError.unreadableResponse }
        return (data, http)
    }

    /// The JSON of a 2xx response. Anything else is thrown with Google's own error code.
    static func json(_ request: URLRequest, via transport: Transport) async throws -> Any {
        let (data, response) = try await transport(request)
        let body = try? JSONSerialization.jsonObject(with: data) // an error page may not be JSON; the status is reported either way
        guard (200..<300).contains(response.statusCode) else {
            // Errors arrive as {"error": {...}}, or wrapped in a one-element array from runQuery.
            let wrapper = (body as? [String: Any]) ?? (body as? [[String: Any]])?.first
            let error = wrapper?["error"] as? [String: Any]
            let message = (error?["message"] as? String)?.split(separator: " ").first.map(String.init)
            throw SyncError.server(status: response.statusCode, code: error?["status"] as? String ?? message ?? "unknown")
        }
        guard let body else { throw SyncError.unreadableResponse }
        return body
    }

    static func post(_ url: String, json: Any, headers: [String: String]) throws -> URLRequest {
        guard let address = URL(string: url) else { throw SyncError.unreadableResponse }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return request
    }
}

/// A signed-in account: who it is, and the tokens that prove it.
struct AuthSession: Codable, Equatable, Sendable {
    var email: String
    var uid: String
    var refreshToken: String
    var idToken: String
    var expiresAt: Date
}

/// Firebase Authentication with an email and password.
struct FirebaseAuthClient: Sendable {
    let config: FirebaseConfig
    let transport: Transport

    func signIn(email: String, password: String, now: Date = .now) async throws -> AuthSession {
        let request = try HTTP.post(
            "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword",
            json: ["email": email, "password": password, "returnSecureToken": true],
            headers: ["X-Goog-Api-Key": config.apiKey]
        )
        guard let reply = try await HTTP.json(request, via: transport) as? [String: Any],
              let idToken = reply["idToken"] as? String, let refreshToken = reply["refreshToken"] as? String,
              let uid = reply["localId"] as? String
        else { throw SyncError.unreadableResponse }
        return AuthSession(
            email: email, uid: uid, refreshToken: refreshToken, idToken: idToken,
            expiresAt: now.addingTimeInterval(Double(reply["expiresIn"] as? String ?? "") ?? 3600)
        )
    }

    /// A session whose token is good for at least the next five minutes.
    func current(_ session: AuthSession, now: Date = .now) async throws -> AuthSession {
        guard session.expiresAt < now.addingTimeInterval(300) else { return session }
        let request = try HTTP.post(
            "https://securetoken.googleapis.com/v1/token",
            json: ["grant_type": "refresh_token", "refresh_token": session.refreshToken],
            headers: ["X-Goog-Api-Key": config.apiKey]
        )
        guard let reply = try await HTTP.json(request, via: transport) as? [String: Any],
              let idToken = reply["id_token"] as? String, let refreshToken = reply["refresh_token"] as? String
        else { throw SyncError.unreadableResponse }
        var renewed = session
        (renewed.idToken, renewed.refreshToken) = (idToken, refreshToken)
        renewed.expiresAt = now.addingTimeInterval(Double(reply["expires_in"] as? String ?? "") ?? 3600)
        return renewed
    }
}

/// The sign-in, kept in the login Keychain rather than in the app's data.
enum Keychain {
    static let syncSession = "sync.session"
    static let claudeKey = "claude.key"
    /// What Claude must send to use Ezra's tools (Settings › Claude).
    static let mcpToken = "mcp.token"

    private static func query(_ account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.ezra.Ezra",
        kSecAttrAccount as String: account,
    ] }

    static func read(_ account: String) throws -> Data? {
        var lookup = query(account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else { throw KeychainError(status: status) }
        return data
    }

    /// Stores the entry, or removes it when `data` is nil.
    static func write(_ data: Data?, _ account: String) throws {
        let query = query(account)
        let removed = SecItemDelete(query as CFDictionary)
        guard removed == errSecSuccess || removed == errSecItemNotFound else { throw KeychainError(status: removed) }
        guard let data else { return }
        var entry = query
        entry[kSecValueData as String] = data
        let added = SecItemAdd(entry as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        "The Keychain refused: \(SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)")."
    }
}
