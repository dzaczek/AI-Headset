// Cięcie PCM16 na wypowiedzi: mowa + cisza, sama cisza, długi monolog.
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

func pcm(tone seconds: Double, amplitude: Double = 0.3) -> Data {
    let samples = (0..<Int(seconds * 16000)).map { Int16(sin(Double($0) * 2 * .pi * 300 / 16000) * amplitude * 32767) }
    return samples.withUnsafeBytes { Data($0) }
}
func pcm(silence seconds: Double) -> Data { Data(count: Int(seconds * 16000) * 2) }

/// Podaje dane porcjami po 50 ms, jak pompa transkrypcji.
func feed(_ segmenter: inout SilenceSegmenter, _ data: Data) -> [Data] {
    var chunks: [Data] = []
    var offset = 0
    while offset < data.count {
        let end = min(offset + 1600, data.count)
        chunks += segmenter.append(data.subdata(in: offset..<end))
        offset = end
    }
    return chunks
}

// 1 s mowy + 0,6 s ciszy -> jeden fragment ~1,5 s (mowa + 0,5 s ciszy).
do {
    var s = SilenceSegmenter()
    let chunks = feed(&s, pcm(tone: 1.0) + pcm(silence: 0.6))
    check(chunks.count == 1, "jeden fragment, jest \(chunks.count)")
    let seconds = Double(chunks.first?.count ?? 0) / 32000
    check(abs(seconds - 1.5) < 0.05, "długość \(seconds) s")
}

// Sama cisza -> nic, i bufor nie rośnie (flush pusty).
do {
    var s = SilenceSegmenter()
    check(feed(&s, pcm(silence: 3)).isEmpty, "cisza nie daje fragmentów")
    check(s.flush() == nil, "flush po ciszy pusty")
}

// 12 s monologu -> fragmenty po 5 s, reszta przez flush.
do {
    var s = SilenceSegmenter()
    let chunks = feed(&s, pcm(tone: 12))
    check(chunks.count == 2, "dwa pełne fragmenty, jest \(chunks.count)")
    check(chunks.allSatisfy { abs(Double($0.count) / 32000 - 5) < 0.02 }, "po 5 s")
    let rest = s.flush()
    check(abs(Double(rest?.count ?? 0) / 32000 - 2) < 0.02, "reszta 2 s przez flush")
}

// Trzask krótszy niż 0,3 s -> nie jest mową.
do {
    var s = SilenceSegmenter()
    check(feed(&s, pcm(tone: 0.1) + pcm(silence: 1)).isEmpty, "krótki trzask odrzucony")
}

if failures > 0 { exit(1) }
print("PASS silence_segmenter_test")
