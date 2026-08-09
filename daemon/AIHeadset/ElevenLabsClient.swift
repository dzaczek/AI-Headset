import Foundation

/// ============================================================
/// UNTESTED against a real ElevenLabs agent -- no credentials were
/// available while writing this (see project memory). Written to
/// match plan section 3's description of the protocol as closely as
/// possible, but the plan itself warns:
///
///   "Protokół ElevenLabs się zmienia. Przed implementacją zweryfikuj
///   nazwy pól w aktualnej dokumentacji Agents Platform WebSocket API."
///
/// Specifically UNVERIFIED against live docs: the nested field paths
/// for user_transcript / agent_response / vad_score / ping
/// (`user_transcription_event.user_transcript`,
/// `agent_response_event.agent_response`, `vad_score_event.vad_score`,
/// `ping_event.event_id`). `audio_event.audio_base_64` for the `audio`
/// message is the one field path the plan states explicitly. Confirm
/// all of these against the current Agents Platform WebSocket API
/// docs before wiring this to a real agent_id.
/// ============================================================

enum AgentConnectionState: String, CustomStringConvertible {
    case disconnected
    case connecting
    case connected
    case reconnecting

    var description: String { rawValue }
}

protocol ElevenLabsClientDelegate: AnyObject {
    func elevenLabsClient(_ client: ElevenLabsClient, didChangeState state: AgentConnectionState)
    /// pcm16Mono16k: raw PCM16 LE mono @ 16kHz, already base64-decoded.
    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveAudio pcm16Mono16k: Data)
    func elevenLabsClientDidReceiveInterruption(_ client: ElevenLabsClient)
    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveUserTranscript text: String)
    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveAgentResponse text: String)
    func elevenLabsClient(_ client: ElevenLabsClient, didReceiveVADScore score: Double)
}

/// Plan section 3: WebSocket client for the ElevenLabs Conversational
/// AI agent. Sends `user_audio_chunk` (plan 3.4: every 40-60ms),
/// dispatches received events to the delegate, auto-reconnects with
/// exponential backoff, and answers `ping` with `pong` (plan 3.2:
/// "brak pongu zrywa sesję").
final class ElevenLabsClient: NSObject {
    weak var delegate: ElevenLabsClientDelegate?

    private(set) var state: AgentConnectionState = .disconnected {
        didSet {
            guard oldValue != state else { return }
            Log.info("stan agenta: \(state)")
            delegate?.elevenLabsClient(self, didChangeState: state)
        }
    }

    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    /// Plan 3.1: "pobierz podpisany URL po stronie własnego backendu
    /// ... żeby nie trzymać klucza API w aplikacji." This closure is
    /// how the caller supplies that -- the client itself never sees
    /// or stores an API key.
    private let signedURLProvider: () async throws -> URL
    private var shouldReconnect = false
    private var reconnectAttempt = 0

    init(signedURLProvider: @escaping () async throws -> URL) {
        self.signedURLProvider = signedURLProvider
        self.session = URLSession(configuration: .default)
        super.init()
    }

    func connect() {
        guard state == .disconnected else { return }
        shouldReconnect = true
        reconnectAttempt = 0
        Task { await connectInternal() }
    }

    func disconnect() {
        shouldReconnect = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    private func connectInternal() async {
        state = reconnectAttempt == 0 ? .connecting : .reconnecting
        do {
            let url = try await signedURLProvider()
            // Host bez części poufnej -- podpisany URL zawiera token,
            // którego nie wolno wypisywać do logu systemowego.
            Log.info("łączę z agentem: \(url.host ?? "?")\(url.path)")
            let task = session.webSocketTask(with: url)
            webSocketTask = task
            task.resume()
            state = .connected
            reconnectAttempt = 0
            receiveNext()
        } catch {
            // Najczęstsza przyczyna: nie udało się pobrać podpisanego
            // URL-a (zły klucz, brak uprawnień do agenta, brak sieci).
            // Bez tego wpisu awaria była niewidoczna -- kod po cichu
            // przechodził do ponawiania.
            Log.error("nie udało się połączyć z agentem: \(error)")
            await scheduleReconnect()
        }
    }

    private func scheduleReconnect() async {
        guard shouldReconnect else { return }
        webSocketTask = nil
        state = .reconnecting
        reconnectAttempt += 1
        // Capped exponential backoff: 2, 4, 8, 16, 30, 30, ... seconds.
        let delaySeconds = min(30.0, pow(2.0, Double(reconnectAttempt)))
        Log.info("ponawiam połączenie za \(Int(delaySeconds)) s (próba \(reconnectAttempt))")
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        guard shouldReconnect else { return }
        await connectInternal()
    }

    private func receiveNext() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Log.error("WebSocket zerwany: \(error)")
                self.state = .disconnected
                Task { await self.scheduleReconnect() }
            case .success(let message):
                self.handle(message)
                self.receiveNext()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "conversation_initiation_metadata":
            Log.info("agent potwierdził start rozmowy")

        case "audio":
            guard let audioEvent = json["audio_event"] as? [String: Any],
                  let base64 = audioEvent["audio_base_64"] as? String,
                  let decoded = Data(base64Encoded: base64) else { return }
            delegate?.elevenLabsClient(self, didReceiveAudio: decoded)

        case "user_transcript":
            // UNVERIFIED field path -- see header comment.
            guard let event = json["user_transcription_event"] as? [String: Any],
                  let text = event["user_transcript"] as? String else { return }
            delegate?.elevenLabsClient(self, didReceiveUserTranscript: text)

        case "agent_response":
            // UNVERIFIED field path -- see header comment.
            guard let event = json["agent_response_event"] as? [String: Any],
                  let text = event["agent_response"] as? String else { return }
            delegate?.elevenLabsClient(self, didReceiveAgentResponse: text)

        case "interruption":
            delegate?.elevenLabsClientDidReceiveInterruption(self)

        case "vad_score":
            // UNVERIFIED field path -- see header comment.
            guard let event = json["vad_score_event"] as? [String: Any],
                  let score = event["vad_score"] as? Double else { return }
            delegate?.elevenLabsClient(self, didReceiveVADScore: score)

        case "ping":
            // UNVERIFIED field path -- see header comment. Missing a
            // pong is documented to kill the session, so this matters.
            guard let event = json["ping_event"] as? [String: Any],
                  let eventID = event["event_id"] as? Int else { return }
            sendPong(eventID: eventID)

        default:
            break
        }
    }

    private func sendPong(eventID: Int) {
        sendJSON(["type": "pong", "event_id": eventID])
    }

    /// Wstrzykuje kontekst do trwającej rozmowy. W przeciwieństwie do
    /// pozostałych pól tego protokołu ten kształt jest ZWERYFIKOWANY
    /// wprost w dokumentacji ElevenLabs (Advanced → Events → Client to
    /// server events): `{"type":"contextual_update","text":"..."}`.
    ///
    /// Nie przerywa wypowiedzi i nie wymusza odpowiedzi -- treść wchodzi
    /// jako informacja w tle, którą agent uwzględni przy kolejnej turze.
    func sendContextualUpdate(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendJSON(["type": "contextual_update", "text": trimmed])
    }

    /// Plan 3.2/3.4: PCM16 LE mono 16kHz, base64, sent every 40-60ms.
    func sendAudioChunk(_ pcm16Mono16k: Data) {
        sendJSON(["user_audio_chunk": pcm16Mono16k.base64EncodedString()])
    }

    private func sendJSON(_ payload: [String: Any]) {
        guard state == .connected,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }
}
