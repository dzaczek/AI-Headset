import Foundation

/// ElevenLabs Scribe realtime -- kształt wiadomości zweryfikowany w
/// dokumentacji „Server-side streaming” (2026-10-09).
enum ScribeProtocol {
    static let endpoint = URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime")!

    enum Event: Equatable {
        case sessionStarted
        case partial(String)
        case committed(String)
        case error(String)
    }

    static func audioMessage(_ pcm16: Data, commit: Bool) -> String {
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm16.base64EncodedString(),
            "commit": commit,
            "sample_rate": 16000,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ text: String) -> Event? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["message_type"] as? String else { return nil }
        switch type {
        case "session_started": return .sessionStarted
        case "partial_transcript": return .partial(json["text"] as? String ?? "")
        case "committed_transcript": return .committed(json["text"] as? String ?? "")
        default:
            if type.contains("error") {
                return .error((json["error"] as? String) ?? (json["message"] as? String) ?? type)
            }
            return nil
        }
    }
}

/// Strumień do Scribe: dźwięk leci na bieżąco, a koniec wypowiedzi
/// (cisza wg SilenceSegmenter) wysyła commit -- wtedy serwer zwraca
/// `committed_transcript`. Partiale aktualizują bieżący segment.
final class ScribeTranscriber: SpeechTranscriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?

    private let apiKey: String
    private let speaker: TranscriptSpeaker
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var segmenter = SilenceSegmenter()
    private let lock = NSLock()
    private var currentID: UUID?
    private var currentStart = Date()
    private var stopped = true

    init(apiKey: String, speaker: TranscriptSpeaker) {
        self.apiKey = apiKey
        self.speaker = speaker
    }

    func start() throws {
        stopped = false
        connect()
    }

    func feed(pcm16Mono16k: Data) {
        guard let task, !stopped else { return }
        task.send(.string(ScribeProtocol.audioMessage(pcm16Mono16k, commit: false))) { _ in }
        if !segmenter.append(pcm16Mono16k).isEmpty {
            task.send(.string(ScribeProtocol.audioMessage(Data(), commit: true))) { _ in }
        }
    }

    func stop() {
        stopped = true
        task?.send(.string(ScribeProtocol.audioMessage(Data(), commit: true))) { _ in }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func connect() {
        var request = URLRequest(url: ScribeProtocol.endpoint)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                guard !self.stopped else { return }
                self.onError?(error)
                // Jedna próba ponownego połączenia po 2 s -- zerwane
                // połączenie w trakcie rozmowy nie może zakończyć transkrypcji.
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.connect()
                }
            case .success(let message):
                if case .string(let text) = message, let event = ScribeProtocol.parse(text) {
                    self.handle(event)
                }
                self.receive(on: task)
            }
        }
    }

    private func handle(_ event: ScribeProtocol.Event) {
        switch event {
        case .sessionStarted:
            Log.info("Scribe: sesja rozpoczęta (\(speaker.rawValue))")
        case .partial(let text):
            guard !text.isEmpty else { return }
            emit(text, isFinal: false)
        case .committed(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { emit(text, isFinal: true) }
            lock.lock(); currentID = nil; lock.unlock()
        case .error(let message):
            onError?(NSError(domain: "Scribe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }

    private func emit(_ text: String, isFinal: Bool) {
        lock.lock()
        if currentID == nil { currentID = UUID(); currentStart = Date() }
        let id = currentID!
        let start = currentStart
        lock.unlock()
        onSegment?(TranscriptSegment(id: id, speaker: speaker, text: text, start: start, end: Date(), isFinal: isFinal))
    }
}
