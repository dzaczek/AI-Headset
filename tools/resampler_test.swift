// Standalone smoke test for the Resampler (plan section 3): feeds a
// synthetic tone through in realistic small chunks (like plan 3.4's
// 40-60ms send chunks) and checks total frame counts and signal
// quality. Not part of the daemon; a throwaway dev diagnostic. No
// live device/driver involved.
//
// NOTE on methodology: a *single* one-shot convert() call does not
// drain AVAudioConverter's internal filter lookahead -- that's normal,
// expected behavior for a windowed resampler, not a bug. Streaming
// several chunks through the same instance (as production code will)
// is what actually exercises and validates real usage.
import AVFoundation
import Foundation

func makeDeviceBuffer(frames: Int, phaseStart: Double, freq: Double) -> (AVAudioPCMBuffer, Double) {
    let format = AVAudioFormat(standardFormatWithSampleRate: AIHeadsetConfig.sampleRate,
                                channels: AVAudioChannelCount(AIHeadsetConfig.channelCount))!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let phaseStep = 2.0 * Double.pi * freq / AIHeadsetConfig.sampleRate
    var phase = phaseStart
    for ch in 0..<Int(AIHeadsetConfig.channelCount) {
        let data = buffer.floatChannelData![ch]
        var p = phaseStart
        for i in 0..<frames {
            data[i] = Float(0.5 * sin(p))
            p += phaseStep
        }
    }
    phase += phaseStep * Double(frames)
    return (buffer, phase)
}

func makeAgentBuffer(frames: Int, phaseStart: Double, freq: Double) -> (AVAudioPCMBuffer, Double) {
    let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let phaseStep = 2.0 * Double.pi * freq / 16000.0
    var phase = phaseStart
    let data = buffer.int16ChannelData![0]
    for i in 0..<frames {
        data[i] = Int16(0.5 * 32767.0 * sin(phase))
        phase += phaseStep
    }
    return (buffer, phase)
}

var ok = true
let expectedRMS = 0.5 / 2.0.squareRoot()

// Device (48kHz stereo Float32) -> Agent (16kHz mono Int16), streamed
// in 50ms chunks like plan 3.4 calls for on the send side.
do {
    let resampler = try Resampler.deviceToAgent()
    let chunkFrames = Int(0.05 * AIHeadsetConfig.sampleRate) // 50ms @ 48kHz
    var phase = 0.0
    var totalOutFrames = 0
    var sumSquares = 0.0
    for _ in 0..<20 { // 1s total
        let (chunk, nextPhase) = makeDeviceBuffer(frames: chunkFrames, phaseStart: phase, freq: 440)
        phase = nextPhase
        let output = try resampler.convert(chunk)
        totalOutFrames += Int(output.frameLength)
        if let data = output.int16ChannelData?[0] {
            for i in 0..<Int(output.frameLength) {
                let s = Double(data[i]) / 32767.0
                sumSquares += s * s
            }
        }
    }
    let expectedFrames = Double(20 * chunkFrames) * 16000.0 / AIHeadsetConfig.sampleRate
    print("deviceToAgent (streamed): total output frames=\(totalOutFrames) (expected ~\(expectedFrames))")
    if abs(Double(totalOutFrames) - expectedFrames) > expectedFrames * 0.05 {
        print("FAIL: streamed output frame count off by more than 5%")
        ok = false
    }
    let rms = (sumSquares / Double(totalOutFrames)).squareRoot()
    print("streamed output RMS = \(rms) (expected ~\(expectedRMS))")
    if rms < expectedRMS * 0.5 || rms > expectedRMS * 1.5 {
        print("FAIL: resampled signal RMS out of expected range")
        ok = false
    }
} catch {
    print("FAIL: deviceToAgent \(error)")
    ok = false
}

// Agent (16kHz mono Int16) -> Device (48kHz stereo Float32), streamed.
do {
    let resampler = try Resampler.agentToDevice()
    let chunkFrames = Int(0.05 * 16000) // 50ms @ 16kHz
    var phase = 0.0
    var totalOutFrames = 0
    var sumSquares = 0.0
    var sampleCount = 0
    for _ in 0..<20 { // 1s total
        let (chunk, nextPhase) = makeAgentBuffer(frames: chunkFrames, phaseStart: phase, freq: 300)
        phase = nextPhase
        let output = try resampler.convert(chunk)
        totalOutFrames += Int(output.frameLength)
        if let data = output.floatChannelData {
            for ch in 0..<Int(output.format.channelCount) {
                for i in 0..<Int(output.frameLength) {
                    let s = Double(data[ch][i])
                    sumSquares += s * s
                    sampleCount += 1
                }
            }
        }
    }
    let expectedFrames = Double(20 * chunkFrames) * AIHeadsetConfig.sampleRate / 16000.0
    print("agentToDevice (streamed): total output frames=\(totalOutFrames) (expected ~\(expectedFrames))")
    if abs(Double(totalOutFrames) - expectedFrames) > expectedFrames * 0.05 {
        print("FAIL: streamed output frame count off by more than 5%")
        ok = false
    }
    let rms = (sumSquares / Double(sampleCount)).squareRoot()
    print("streamed output RMS = \(rms) (expected ~\(expectedRMS))")
    if rms < expectedRMS * 0.5 || rms > expectedRMS * 1.5 {
        print("FAIL: resampled signal RMS out of expected range")
        ok = false
    }
} catch {
    print("FAIL: agentToDevice \(error)")
    ok = false
}

print(ok ? "PASS" : "SOME FAILED")
exit(ok ? 0 : 1)
