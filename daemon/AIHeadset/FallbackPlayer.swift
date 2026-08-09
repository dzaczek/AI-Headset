import AVFoundation

/// Plan 6.1 point 1: plays a pre-recorded local fallback message
/// (never TTS -- TTS might be the thing that's broken) into
/// Bridge.out via the same override buffer ConsentAnnouncer uses.
///
/// NEEDS AN ACTUAL AUDIO FILE, not included: record a short message
/// (plan's example: "moment, mam problem z łączem") and add it to the
/// app bundle's Resources as `fallback.caf` (or pass a different
/// name/extension to `playBundledFallback`). Without it this safely
/// no-ops and logs -- see the dead man's switch note in project memory.
final class FallbackPlayer {
    private let router: AudioRouter

    init(router: AudioRouter) {
        self.router = router
    }

    @discardableResult
    func playBundledFallback(resourceName: String = "fallback", withExtension: String = "caf") -> Bool {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: withExtension) else {
            Log.info("brak nagrania awaryjnego \(resourceName).\(withExtension) w Resources -- dodaj je")
            return false
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                return false
            }
            try file.read(into: raw)

            guard let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: AIHeadsetConfig.sampleRate,
                                                    channels: AVAudioChannelCount(AIHeadsetConfig.channelCount)) else {
                return false
            }
            let resampler = try Resampler(from: file.processingFormat, to: deviceFormat)
            let resampled = try resampler.convert(raw)
            guard let floatData = resampled.floatChannelData else { return false }

            let frames = Int(resampled.frameLength)
            var interleaved = [Float](repeating: 0, count: frames * AIHeadsetConfig.channelCount)
            for ch in 0..<Int(resampled.format.channelCount) {
                for i in 0..<frames {
                    interleaved[i * AIHeadsetConfig.channelCount + ch] = floatData[ch][i]
                }
            }
            interleaved.withUnsafeBufferPointer { buf in
                router.announcementBuffer.write(buf.baseAddress!, frameCount: frames)
            }
            return true
        } catch {
            Log.error("nie udało się wczytać nagrania awaryjnego: \(error)")
            return false
        }
    }
}
