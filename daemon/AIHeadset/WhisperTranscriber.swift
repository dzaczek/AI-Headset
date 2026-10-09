import Foundation

/// PCM16 mono 16 kHz w kontenerze WAV -- tego oczekuje whisper-server.
enum WAV {
    static func encode(pcm16Mono16k pcm: Data) -> Data {
        var data = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); le32(16)
        le16(1)            // PCM
        le16(1)            // mono
        le32(16000)        // częstotliwość
        le32(16000 * 2)    // bajty na sekundę
        le16(2)            // bajty na ramkę
        le16(16)           // bity na próbkę
        data.append(contentsOf: Array("data".utf8)); le32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}

/// whisper.cpp `whisper-server`: POST /inference, multipart z plikiem
/// audio, odpowiedź `{"text": "..."}`. Język ustawia się przy starcie
/// serwera (`-l pl`).
enum WhisperServerAPI {
    enum APIError: Error, CustomStringConvertible {
        case http(Int)
        case invalidResponse
        var description: String {
            switch self {
            case .http(let code): return "whisper-server HTTP \(code)"
            case .invalidResponse: return "whisper-server: nieoczekiwana odpowiedź"
            }
        }
    }

    static func request(baseURL: URL, wav: Data, boundary: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("response_format", "json")
        field("temperature", "0.0")
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    static func parseText(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw APIError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lokalny Whisper: tnie dźwięk po ciszy i wysyła każdą wypowiedź do
/// whisper-server. Tylko segmenty final (Whisper nie daje partiali).
/// Zapytania idą po kolei, żeby wypowiedzi nie przestawiały się.
final class WhisperTranscriber: SpeechTranscriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?

    private let baseURL: URL
    private let speaker: TranscriptSpeaker
    private let session: URLSession
    private var segmenter = SilenceSegmenter()
    private var chain: Task<Void, Never>?
    private var stopped = true

    init(baseURL: URL, speaker: TranscriptSpeaker, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.speaker = speaker
        self.session = session
    }

    func start() throws {
        stopped = false
    }

    func feed(pcm16Mono16k: Data) {
        guard !stopped else { return }
        for chunk in segmenter.append(pcm16Mono16k) { send(chunk) }
    }

    func stop() {
        if let rest = segmenter.flush() { send(rest) }
        stopped = true
    }

    private func send(_ chunk: Data) {
        let end = Date()
        let start = end.addingTimeInterval(-Double(chunk.count) / 32000)
        let request = WhisperServerAPI.request(baseURL: baseURL, wav: WAV.encode(pcm16Mono16k: chunk),
                                               boundary: UUID().uuidString)
        let previous = chain
        chain = Task { [weak self, session, speaker] in
            await previous?.value
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw WhisperServerAPI.APIError.http(http.statusCode)
                }
                let text = try WhisperServerAPI.parseText(data)
                guard !text.isEmpty else { return }
                self?.onSegment?(TranscriptSegment(id: UUID(), speaker: speaker, text: text,
                                                   start: start, end: end, isFinal: true))
            } catch {
                self?.onError?(error)
            }
        }
    }
}
