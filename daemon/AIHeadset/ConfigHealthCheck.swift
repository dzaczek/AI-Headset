import Foundation

/// Reads the agent's configuration from ElevenLabs and flags settings
/// that conflict with how *this app* works.
///
/// Deliberately read-only, and deliberately not a config editor: the
/// ElevenLabs dashboard already edits these well and stays current
/// with their API, whereas a duplicated editor here would drift and
/// multiply the unverified-field-shape risk documented in
/// AgentConfigClient. What this app knows and the dashboard cannot is
/// the surrounding context -- that there is a virtual audio driver,
/// fixed PCM expectations, a mid-call entry point, and a dead man's
/// switch with its own thresholds. Those are the only things checked
/// here.
enum ConfigHealthCheck {
    enum Severity {
        case ok
        case warning
    }

    struct Finding {
        let severity: Severity
        let message: String
    }

    static func run() async -> [Finding] {
        guard let agentID = AgentSettings.agentID, !agentID.isEmpty,
              let apiKey = AgentSettings.apiKey, !apiKey.isEmpty,
              let url = URL(string: "https://api.elevenlabs.io/v1/convai/agents/\(agentID)") else {
            return []
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["conversation_config"] as? [String: Any] else {
            return []
        }
        return evaluate(conversationConfig: config)
    }

    /// Split out from `run()` so the rules can be exercised against a
    /// captured config without network or Keychain access -- reading
    /// the app's Keychain item from a separate test binary triggers an
    /// interactive authorization prompt and hangs.
    static func evaluate(conversationConfig config: [String: Any]) -> [Finding] {
        var findings: [Finding] = []

        // Audio formats: hard requirement. Resampler assumes 16k PCM in
        // both directions; anything else (notably mp3 output) simply
        // will not decode.
        let asr = config["asr"] as? [String: Any]
        let tts = config["tts"] as? [String: Any]
        let inputFormat = asr?["user_input_audio_format"] as? String
        let outputFormat = tts?["agent_output_audio_format"] as? String
        if inputFormat == "pcm_16000" && outputFormat == "pcm_16000" {
            findings.append(Finding(severity: .ok, message: L("health.formatsOK")))
        } else {
            findings.append(Finding(severity: .warning,
                                     message: L("health.formatsBad", inputFormat ?? "?", outputFormat ?? "?")))
        }

        let conversation = config["conversation"] as? [String: Any]
        // Plan's success criterion is an hour-long call.
        if let maxDuration = conversation?["max_duration_seconds"] as? Int, maxDuration < 3600 {
            findings.append(Finding(severity: .warning,
                                     message: L("health.maxDuration", maxDuration / 60)))
        }

        // This app joins a conversation that is already in progress, so
        // a greeting fires in the middle of someone else's sentence.
        let agent = config["agent"] as? [String: Any]
        if let firstMessage = agent?["first_message"] as? String,
           !firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            findings.append(Finding(severity: .warning,
                                     message: L("health.firstMessage", firstMessage)))
        }

        // Filler audio must land before the dead man's switch trips, or
        // a perfectly healthy pause gets treated as a fault.
        let turn = config["turn"] as? [String: Any]
        if let soft = turn?["soft_timeout_config"] as? [String: Any],
           let timeout = soft["timeout_seconds"] as? Double {
            if timeout < 2.5 {
                findings.append(Finding(severity: .ok, message: L("health.softTimeoutOK", timeout)))
            } else {
                findings.append(Finding(severity: .warning, message: L("health.softTimeoutLate", timeout)))
            }
        }

        return findings
    }
}
