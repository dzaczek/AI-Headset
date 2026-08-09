import AVFoundation

/// Plan section 6.5: announces to the rozmówca (not to the user --
/// this goes out Bridge.out, the channel the other side of the call
/// hears) that the conversation may be recorded/processed by AI,
/// before AGENT mode or transcription starts. Uses the system's local
/// speech synthesizer -- no network call, no API key, works fully
/// offline. Plan 6.1's *dead-man's-switch* fallback message is
/// different: that one specifically wants a pre-recorded file because
/// TTS itself might be the thing that's broken. This announcer's
/// trigger is a normal, expected event, so local TTS is appropriate.
final class ConsentAnnouncer {
    private let router: AudioRouter
    private let synthesizer = AVSpeechSynthesizer()

    /// Set by the caller right before invoking `announce`, read back
    /// afterward for session metadata (plan 6.5: "Fakt odtworzenia +
    /// timestamp zapisany w metadanych sesji").
    private(set) var lastAnnouncement: (text: String, playedAt: Date)?

    init(router: AudioRouter) {
        self.router = router
    }

    func announce(text: String = "Ta rozmowa może być nagrywana i przetwarzana przez asystenta AI.",
                  completion: @escaping () -> Void) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "pl-PL") ?? AVSpeechSynthesisVoice(language: "en-US")

        var resampler: Resampler?
        var finished = false
        func finishOnce() {
            guard !finished else { return }
            finished = true
            lastAnnouncement = (text, Date())
            completion()
        }

        synthesizer.write(utterance) { [weak self] buffer in
            guard let self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer, pcmBuffer.frameLength > 0 else {
                finishOnce()
                return
            }
            if resampler == nil {
                guard let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: AIHeadsetConfig.sampleRate,
                                                        channels: AVAudioChannelCount(AIHeadsetConfig.channelCount)) else { return }
                resampler = try? Resampler(from: pcmBuffer.format, to: deviceFormat)
            }
            guard let resampler,
                  let resampled = try? resampler.convert(pcmBuffer),
                  let floatData = resampled.floatChannelData else { return }
            let frames = Int(resampled.frameLength)
            guard frames > 0 else { return }
            var interleaved = [Float](repeating: 0, count: frames * AIHeadsetConfig.channelCount)
            for ch in 0..<Int(resampled.format.channelCount) {
                for i in 0..<frames {
                    interleaved[i * AIHeadsetConfig.channelCount + ch] = floatData[ch][i]
                }
            }
            interleaved.withUnsafeBufferPointer { buf in
                self.router.announcementBuffer.write(buf.baseAddress!, frameCount: frames)
            }
        }
    }
}
