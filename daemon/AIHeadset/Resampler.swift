import AVFoundation

/// Plan section 3: resamples between the device's native format
/// (48kHz Float32, stereo) and the ElevenLabs agent's wire format
/// (16kHz PCM16 mono), in both directions. One instance per direction,
/// reused across the whole session -- AVAudioConverter keeps internal
/// filter state across calls, which is what makes chunk-to-chunk
/// resampling continuous instead of clicking at every boundary.
final class Resampler {
    enum ResamplerError: Error {
        case converterCreationFailed
        case conversionFailed(String)
    }

    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ResamplerError.converterCreationFailed
        }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    /// Converts one buffer of `input` to `outputFormat`. Not safe to
    /// call concurrently on the same instance -- callers own their own
    /// serialization (this runs on the non-realtime worker thread per
    /// plan 1.6/2.2, never on the IOProc itself).
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw ResamplerError.converterCreationFailed
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error else {
            throw ResamplerError.conversionFailed(conversionError?.localizedDescription ?? "unknown AVAudioConverter error")
        }
        return outputBuffer
    }
}

extension Resampler {
    /// Device-native (48kHz Float32 stereo) -> agent upload format
    /// (16kHz PCM16 mono). Plan 3.2: "ustaw pcm_16000 na wejściu ...
    /// żeby uniknąć dekodowania mp3 w kliencie."
    static func deviceToAgent(deviceSampleRate: Double = AIHeadsetConfig.sampleRate) throws -> Resampler {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSampleRate,
                                               channels: AVAudioChannelCount(AIHeadsetConfig.channelCount)),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                channels: 1, interleaved: true) else {
            throw ResamplerError.converterCreationFailed
        }
        return try Resampler(from: inputFormat, to: outputFormat)
    }

    /// Bufor transkrypcji (Float32 mono, częstotliwość urządzenia) ->
    /// format silników rozpoznawania (PCM16 mono 16 kHz).
    static func monoDeviceToSpeech(deviceSampleRate: Double) throws -> Resampler {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSampleRate, channels: 1),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                channels: 1, interleaved: true) else {
            throw ResamplerError.converterCreationFailed
        }
        return try Resampler(from: inputFormat, to: outputFormat)
    }

    /// Agent TTS format (16kHz PCM16 mono) -> device-native (48kHz
    /// Float32 stereo) for the AGENT-mode playback buffer.
    static func agentToDevice(deviceSampleRate: Double = AIHeadsetConfig.sampleRate) throws -> Resampler {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                               channels: 1, interleaved: true),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: deviceSampleRate,
                                                channels: AVAudioChannelCount(AIHeadsetConfig.channelCount)) else {
            throw ResamplerError.converterCreationFailed
        }
        return try Resampler(from: inputFormat, to: outputFormat)
    }
}
