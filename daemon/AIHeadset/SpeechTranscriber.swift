import Foundation

/// Silnik rozpoznawania mowy dla JEDNEGO mówcy. `feed` jest wołane z
/// kolejki sesji transkrypcji (szeregowo); `onSegment`/`onError` mogą
/// przyjść z dowolnego wątku -- sesja przekazuje je na główny.
protocol SpeechTranscriber: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start() throws
    /// PCM16 LE, mono, 16 kHz.
    func feed(pcm16Mono16k: Data)
    func stop()
}
