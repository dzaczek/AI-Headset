import AVFoundation
import Speech

/// Rozpoznawanie mowy Apple, wyłącznie na urządzeniu (dźwięk nie
/// opuszcza Maca). Jedno zadanie rozpoznawania = jedna wypowiedź:
/// po ciszy (SilenceSegmenter) albo po 45 s zadanie jest kończone i
/// startuje następne -- dzięki temu segmenty mają rozmiar zdań, a nie
/// minut, i nie trafiamy w limit długości zadania.
final class AppleSpeechTranscriber: SpeechTranscriber {
    enum AppleSpeechError: Error, CustomStringConvertible {
        case notAuthorized, unsupportedLanguage, onDeviceUnavailable
        var description: String {
            switch self {
            case .notAuthorized: return L("transcription.error.speechDenied")
            case .unsupportedLanguage: return L("transcription.error.language")
            case .onDeviceUnavailable: return L("transcription.error.onDevice")
            }
        }
    }

    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?

    private let language: String
    private let speaker: TranscriptSpeaker
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmenter = SilenceSegmenter(maxChunk: 45)
    private var stopped = true
    /// Zadanie, do którego trafia bieżący dźwięk. Handler rozpoznawania
    /// działa na wątku Speech, `feed` na kolejce transkrypcji -- stąd zamek.
    private var currentTaskID = UUID()
    private let lock = NSLock()

    init(language: String, speaker: TranscriptSpeaker) {
        self.language = language
        self.speaker = speaker
    }

    static func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    static func makeBuffer(_ pcm16: Data) -> AVAudioPCMBuffer? {
        let frames = pcm16.count / 2
        guard frames > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            if let src = raw.bindMemory(to: Int16.self).baseAddress { dst.update(from: src, count: frames) }
        }
        return buffer
    }

    func start() throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { throw AppleSpeechError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            throw AppleSpeechError.unsupportedLanguage
        }
        guard recognizer.supportsOnDeviceRecognition else { throw AppleSpeechError.onDeviceUnavailable }
        self.recognizer = recognizer
        lock.lock(); stopped = false; lock.unlock()
        beginTask()
    }

    func feed(pcm16Mono16k: Data) {
        guard let buffer = Self.makeBuffer(pcm16Mono16k) else { return }
        lock.lock()
        let request = stopped ? nil : self.request
        lock.unlock()
        guard let request else { return }
        request.append(buffer)
        if !segmenter.append(pcm16Mono16k).isEmpty {
            // Koniec wypowiedzi: zamknij zadanie (przyjdzie wynik final)
            // i od razu otwórz następne na dalszy dźwięk.
            request.endAudio()
            beginTask()
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let request = self.request
        self.request = nil
        task = nil
        lock.unlock()
        request?.endAudio() // wynik final dotrze mimo stop -- callbacki są skopiowane w beginTask
    }

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        let id = UUID()
        let speaker = self.speaker
        // Kopie callbacków: wynik final po stop() (endAudio) przychodzi,
        // gdy tego obiektu może już nie być.
        let emit = onSegment
        let report = onError
        // Początek wypowiedzi = pierwszy rozpoznany fragment, nie otwarcie
        // zadania (to następuje zaraz po poprzedniej wypowiedzi i sklejało
        // akapity oraz przesuwało godziny).
        var speechStart: Date?
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let start = speechStart ?? Date()
                speechStart = start
                emit?(TranscriptSegment(id: id, speaker: speaker, text: result.bestTranscription.formattedString,
                                        start: start, end: Date(), isFinal: result.isFinal))
                if result.isFinal { self?.replaceTaskIfCurrent(id) }
            } else if let error = error as NSError? {
                // 1110 = „nie wykryto mowy”, 301 = zadanie anulowane -- to nie są awarie.
                if ![1110, 301].contains(error.code) { report?(error) }
                self?.replaceTaskIfCurrent(id)
            }
        }
        lock.lock()
        currentTaskID = id
        self.request = request
        self.task = task
        lock.unlock()
    }

    /// Zadanie skończyło się samo (np. długa cisza na linii), a dźwięk
    /// nadal do niego trafia -- otwórz następne, inaczej kolejna
    /// wypowiedź by przepadła.
    private func replaceTaskIfCurrent(_ id: UUID) {
        lock.lock()
        let shouldReplace = !stopped && currentTaskID == id
        lock.unlock()
        if shouldReplace { beginTask() }
    }
}
