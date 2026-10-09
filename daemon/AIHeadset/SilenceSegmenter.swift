import Foundation

/// Tnie strumień PCM16 mono na wypowiedzi: fragment zamyka się po
/// `minSilence` ciszy następującej po co najmniej `minSpeech` mowy, albo
/// po `maxChunk` niezależnie od wszystkiego. Sama cisza (i krótkie
/// trzaski) jest odrzucana, żeby nie płacić za transkrypcję niczego.
///
/// Prosty próg RMS w ramkach 10 ms -- wystarcza na mikrofon i dźwięk z
/// komunikatora, które i tak mają już tłumienie szumu.
struct SilenceSegmenter {
    private let sampleRate: Double
    private let threshold: Float
    private let minSilenceSamples: Int
    private let maxChunkSamples: Int
    private let minSpeechSamples: Int
    private let frameBytes: Int

    private var pending = Data()
    private var current = Data()
    private var speechSamples = 0
    private var trailingSilenceSamples = 0

    init(sampleRate: Double = 16000, threshold: Float = 0.015, minSilence: TimeInterval = 0.5,
         maxChunk: TimeInterval = 5, minSpeech: TimeInterval = 0.3) {
        self.sampleRate = sampleRate
        self.threshold = threshold
        self.minSilenceSamples = Int(minSilence * sampleRate)
        self.maxChunkSamples = Int(maxChunk * sampleRate)
        self.minSpeechSamples = Int(minSpeech * sampleRate)
        self.frameBytes = Int(sampleRate / 100) * 2
    }

    mutating func append(_ pcm16: Data) -> [Data] {
        pending.append(pcm16)
        var chunks: [Data] = []
        while pending.count >= frameBytes {
            let frame = Data(pending.prefix(frameBytes))
            pending = Data(pending.dropFirst(frameBytes))
            let frameSamples = frameBytes / 2
            current.append(frame)
            if Self.rms(frame) >= threshold {
                speechSamples += frameSamples
                trailingSilenceSamples = 0
            } else {
                trailingSilenceSamples += frameSamples
            }

            let hasSpeech = speechSamples >= minSpeechSamples
            if (hasSpeech && trailingSilenceSamples >= minSilenceSamples) || current.count / 2 >= maxChunkSamples {
                if hasSpeech { chunks.append(current) }
                reset()
            } else if !hasSpeech && trailingSilenceSamples >= minSilenceSamples {
                reset() // sama cisza albo trzask -- nie trzymamy
            }
        }
        return chunks
    }

    mutating func flush() -> Data? {
        defer { reset(); pending = Data() }
        return speechSamples >= minSpeechSamples ? current : nil
    }

    private mutating func reset() {
        current = Data()
        speechSamples = 0
        trailingSilenceSamples = 0
    }

    private static func rms(_ frame: Data) -> Float {
        frame.withUnsafeBytes { raw -> Float in
            let samples = raw.bindMemory(to: Int16.self)
            guard !samples.isEmpty else { return 0 }
            var sum: Float = 0
            for sample in samples {
                let value = Float(sample) / 32768
                sum += value * value
            }
            return (sum / Float(samples.count)).squareRoot()
        }
    }
}
