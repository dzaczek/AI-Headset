import AVFoundation
import Foundation

/// Pompa transkrypcji: co ~50 ms opróżnia bufory routera, resampluje do
/// PCM16 16 kHz i karmi silnik każdego mówcy. Segmenty trafiają do
/// magazynu (główny wątek) i -- gotowe -- do dziennika JSONL.
///
/// Działa niezależnie od trybu i od agenta głosowego. Przy przebudowie
/// audio sesję się zatrzymuje i tworzy nową na nowym routerze; magazyn
/// (a więc i okno) zostaje.
final class TranscriptionSession {
    var onError: ((TranscriptSpeaker, Error) -> Void)?
    /// Każdy segment dostarczony do magazynu (główny wątek) -- znak, że
    /// silnik działa, nawet jeśli wcześniej zgłosił chwilowy błąd.
    var onSegment: ((TranscriptSegment) -> Void)?

    private struct Stream {
        let speaker: TranscriptSpeaker
        let tap: RingBuffer
        let resampler: Resampler
        let transcriber: SpeechTranscriber
    }

    private let store: TranscriptStore
    private let journal: Transcript?
    private let streams: [Stream]
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "cat.sysop.aiheadset.transcription")
    private var timer: DispatchSourceTimer?

    init(router: AudioRouter, store: TranscriptStore, journal: Transcript?,
         makeTranscriber: (TranscriptSpeaker) throws -> SpeechTranscriber) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: router.sampleRate, channels: 1) else {
            throw Resampler.ResamplerError.converterCreationFailed
        }
        self.format = format
        self.store = store
        self.journal = journal
        self.streams = try [(TranscriptSpeaker.caller, router.callerTranscriptTap),
                            (TranscriptSpeaker.me, router.micTranscriptTap)].map { speaker, tap in
            Stream(speaker: speaker, tap: tap,
                   resampler: try Resampler.monoDeviceToSpeech(deviceSampleRate: router.sampleRate),
                   transcriber: try makeTranscriber(speaker))
        }
        for stream in streams {
            let speaker = stream.speaker
            // Magazyn i dziennik trzymane wprost, nie przez sesję: wynik
            // final przychodzi też PO stop() (Apple po endAudio, Scribe po
            // commit, Whisper z zapytania w locie), gdy sesji już nie ma
            // -- a to zwykle ostatnie zdanie przed pauzą czy zmianą urządzenia.
            stream.transcriber.onSegment = { [weak self, store, journal] segment in
                DispatchQueue.main.async {
                    Self.deliver(segment, to: store, journal: journal)
                    self?.onSegment?(segment)
                }
            }
            stream.transcriber.onError = { [weak self] error in
                Log.error("transkrypcja (\(speaker.rawValue)): \(error)")
                DispatchQueue.main.async { self?.onError?(speaker, error) }
            }
        }
    }

    func start() throws {
        for stream in streams {
            stream.tap.clear() // nie transkrybujemy dźwięku sprzed startu
            try stream.transcriber.start()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pumpOnce() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {} // dokończ ewentualną porcję w locie
        streams.forEach { $0.transcriber.stop() }
    }

    /// Jedna porcja dla każdego mówcy. Publiczne dla testów; w działaniu
    /// woła je timer na `queue`.
    func pumpOnce() {
        for stream in streams {
            let frames = stream.tap.framesAvailable
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            stream.tap.read(channel, frameCount: frames)
            guard let converted = try? stream.resampler.convert(buffer),
                  let samples = converted.int16ChannelData?[0],
                  converted.frameLength > 0 else { continue }
            stream.transcriber.feed(pcm16Mono16k: Data(bytes: samples, count: Int(converted.frameLength) * 2))
        }
    }

    private static func deliver(_ segment: TranscriptSegment, to store: TranscriptStore, journal: Transcript?) {
        store.apply(segment)
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if segment.isFinal, !text.isEmpty {
            journal?.append(segment.speaker == .me ? .user : .caller, text)
        }
    }
}
