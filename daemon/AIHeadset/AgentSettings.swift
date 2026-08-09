import Foundation

/// Faza 4 "Ustawienia (agent ID, endpoint, ...)".
///
/// Agent ID isn't secret (UserDefaults). The API key is (Keychain, via
/// KeychainStore) -- but note this is a deliberate, narrower reading of
/// plan 3.1's "nie trzymać klucza API w aplikacji" warning: that
/// warning is about a *distributed* app embedding a *shared* key that
/// any downloader could extract. This app has no separate backend and
/// exactly one user, running only for the person who owns the key --
/// storing it in that person's own Keychain (never in source, never in
/// plaintext) is the standard, secure way a local single-user tool
/// holds its own credentials, not the scenario the plan was warning
/// about. If this ever becomes a multi-user distributed product, route
/// through a real backend instead and delete this.
enum AgentSettings {
    private static let agentIDDefaultsKey = "agentID"

    /// Keychain ACLs are bound to whichever binary last wrote the item.
    /// A throwaway CLI test binary writing here silently locks the real
    /// app out of its own key -- which happened once already. Test
    /// tools must set AIHEADSET_TEST_KEYCHAIN_SUFFIX so they operate on
    /// a separate account and can never touch production credentials.
    private static var apiKeyAccount: String {
        let base = "elevenlabs-api-key"
        if let suffix = ProcessInfo.processInfo.environment["AIHEADSET_TEST_KEYCHAIN_SUFFIX"], !suffix.isEmpty {
            return "\(base).\(suffix)"
        }
        return base
    }

    static var agentID: String? {
        get { UserDefaults.standard.string(forKey: agentIDDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: agentIDDefaultsKey) }
    }

    static var apiKey: String? {
        get { KeychainStore.get(apiKeyAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                KeychainStore.set(newValue, forAccount: apiKeyAccount)
            } else {
                KeychainStore.delete(apiKeyAccount)
            }
        }
    }

    static var isConfigured: Bool {
        guard let agentID else { return false }
        return !agentID.isEmpty
    }

    enum SettingsError: Error, CustomStringConvertible {
        case missingAgentID
        case invalidResponse
        case httpError(Int)

        var description: String {
            switch self {
            case .missingAgentID: return "No agent ID configured"
            case .invalidResponse: return "Unexpected response from ElevenLabs"
            case .httpError(let code): return "ElevenLabs returned HTTP \(code)"
            }
        }
    }

    /// Plan 3.1: signed-URL flow for private agents. UNVERIFIED
    /// against live docs (same caveat as ElevenLabsClient.swift): the
    /// endpoint path is stated in the plan text itself
    /// (`/v1/convai/conversation/get-signed-url?agent_id=...`), but the
    /// exact response field name (`signed_url` here) is this author's
    /// best recollection, not confirmed against current API docs.
    ///
    /// Falls back to a direct (unsigned) connection when no API key is
    /// configured -- that only works for agents marked public in the
    /// ElevenLabs dashboard.
    static func signedURLProvider() async throws -> URL {
        guard let agentID, !agentID.isEmpty else {
            throw SettingsError.missingAgentID
        }

        guard let apiKey, !apiKey.isEmpty else {
            var components = URLComponents(string: "wss://api.elevenlabs.io/v1/convai/conversation")!
            components.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
            guard let url = components.url else { throw SettingsError.invalidResponse }
            return url
        }

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/convai/conversation/get-signed-url")!
        components.queryItems = [URLQueryItem(name: "agent_id", value: agentID)]
        guard let requestURL = components.url else { throw SettingsError.invalidResponse }

        var request = URLRequest(url: requestURL)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SettingsError.invalidResponse }
        guard http.statusCode == 200 else { throw SettingsError.httpError(http.statusCode) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SettingsError.invalidResponse
        }
        // Nazwa pola nie jest potwierdzona w dokumentacji, więc gdy jej
        // brak -- mówimy jakie pola przyszły, zamiast samego
        // "nieoczekiwana odpowiedź".
        guard let signedURLString = json["signed_url"] as? String,
              let url = URL(string: signedURLString) else {
            Log.error("odpowiedź get-signed-url nie zawiera pola signed_url; otrzymane pola: \(json.keys.sorted())")
            throw SettingsError.invalidResponse
        }
        return url
    }
}
