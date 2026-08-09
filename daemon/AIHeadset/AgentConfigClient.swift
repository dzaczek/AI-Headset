import Foundation

/// Lets the Settings window read/write the agent's system prompt
/// directly via ElevenLabs' REST API (not the WebSocket -- this is
/// agent *configuration*, done once per edit, not per conversation),
/// using the same API key already stored for the WS connection.
///
/// UNVERIFIED against live docs -- same caveat as ElevenLabsClient
/// .swift's WS field names: this is the author's best recollection of
/// the Conversational AI agent-config API shape
/// (`conversation_config.agent.prompt.prompt`), not confirmed against
/// current ElevenLabs documentation. If it's wrong, a GET simply fails
/// with a decode error (visible in the UI, nothing silently corrupted)
/// and a PATCH fails loudly with an HTTP/decode error rather than
/// silently no-op'ing. Confirm the actual shape against current docs
/// before trusting this for anything important.
enum AgentConfigClient {
    enum ConfigError: Error, CustomStringConvertible {
        case notConfigured
        case httpError(Int, String)
        case invalidResponse

        var description: String {
            switch self {
            case .notConfigured: return L("error.notConfigured")
            case .httpError(let code, let body): return L("error.http", code, String(body.prefix(200)))
            case .invalidResponse: return L("error.invalidResponse")
            }
        }
    }

    struct AgentSummary {
        let id: String
        let name: String
    }

    /// Lists the workspace's agents so the UI can offer a picker
    /// instead of making the user paste raw IDs. Response shape
    /// (`{"agents":[{"agent_id":..,"name":..}], "has_more":..}`) was
    /// verified against the live API, unlike the prompt-config shapes
    /// above.
    static func listAgents() async throws -> [AgentSummary] {
        guard let apiKey = AgentSettings.apiKey, !apiKey.isEmpty else {
            throw ConfigError.notConfigured
        }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents") else {
            throw ConfigError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConfigError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ConfigError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let agents = json["agents"] as? [[String: Any]] else {
            throw ConfigError.invalidResponse
        }
        return agents.compactMap { entry in
            guard let id = entry["agent_id"] as? String else { return nil }
            let name = entry["name"] as? String ?? id
            return AgentSummary(id: id, name: name)
        }
    }

    static func fetchSystemPrompt() async throws -> String {
        guard let agentID = AgentSettings.agentID, !agentID.isEmpty,
              let apiKey = AgentSettings.apiKey, !apiKey.isEmpty else {
            throw ConfigError.notConfigured
        }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentID)") else {
            throw ConfigError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConfigError.invalidResponse }
        guard http.statusCode == 200 else {
            throw ConfigError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let conversationConfig = json["conversation_config"] as? [String: Any],
              let agent = conversationConfig["agent"] as? [String: Any],
              let prompt = agent["prompt"] as? [String: Any],
              let promptText = prompt["prompt"] as? String else {
            throw ConfigError.invalidResponse
        }
        return promptText
    }

    static func updateSystemPrompt(_ text: String) async throws {
        guard let agentID = AgentSettings.agentID, !agentID.isEmpty,
              let apiKey = AgentSettings.apiKey, !apiKey.isEmpty else {
            throw ConfigError.notConfigured
        }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentID)") else {
            throw ConfigError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "conversation_config": [
                "agent": [
                    "prompt": [
                        "prompt": text
                    ]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ConfigError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ConfigError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
