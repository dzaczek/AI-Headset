// Pompa: bufor rozmówców -> resampling -> właściwy silnik; segment -> magazyn.
import AVFoundation
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

final class FakeTranscriber: SpeechTranscriber {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onError: ((Error) -> Void)?
    var started = false, stopped = false
    var bytes = 0
    func start() throws { started = true }
    func feed(pcm16Mono16k: Data) { bytes += pcm16Mono16k.count }
    func stop() { stopped = true }
}

let router = AudioRouter(aggregateDeviceID: 0, sampleRate: 48000)
let store = TranscriptStore()
var fakes: [TranscriptSpeaker: FakeTranscriber] = [:]
let session = try TranscriptionSession(router: router, store: store, journal: nil) { speaker in
    let fake = FakeTranscriber()
    fakes[speaker] = fake
    return fake
}
try session.start()
check(fakes[.caller]?.started == true && fakes[.me]?.started == true, "oba silniki wystartowały")

// 300 ms tonu 440 Hz po stronie rozmówców, w trzech porcjach jak z wątku IO.
var tone = (0..<4800).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000)) * 0.3 }
for _ in 0..<3 {
    tone.withUnsafeBufferPointer { router.callerTranscriptTap.write($0.baseAddress!, frameCount: 4800) }
    session.pumpOnce()
}
let callerBytes = fakes[.caller]?.bytes ?? 0
// 14400 ramek @ 48 kHz = 4800 ramek @ 16 kHz = 9600 B; konwerter trzyma
// kilka ms na filtr, więc dopuszczamy niedomiar.
check(callerBytes > 8000 && callerBytes <= 9600, "rozmówcy: \(callerBytes) B PCM16 16 kHz")
check(callerBytes % 2 == 0, "pełne próbki Int16")
check(fakes[.me]?.bytes == 0, "mikrofon cichy -> nic do silnika 'me'")

// Segment z silnika trafia do magazynu na głównym wątku.
fakes[.caller]?.onSegment?(TranscriptSegment(id: UUID(), speaker: .caller, text: "Dzień dobry",
                                             start: Date(), end: Date(), isFinal: true))
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
check(store.paragraphs.count == 1, "segment w magazynie")

// Przebudowa audio: stop starej sesji, nowa na nowym routerze, magazyn zostaje.
session.stop()
check(fakes[.caller]?.stopped == true && fakes[.me]?.stopped == true, "oba silniki zatrzymane")
let router2 = AudioRouter(aggregateDeviceID: 0, sampleRate: 44100)
let session2 = try TranscriptionSession(router: router2, store: store, journal: nil) { _ in FakeTranscriber() }
try session2.start()
check(store.paragraphs.count == 1, "transkrypt przeżył przebudowę")
session2.stop()

if failures > 0 { exit(1) }
print("PASS transcription_session_test")
