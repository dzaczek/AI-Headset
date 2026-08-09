// Standalone smoke test for Faza 2.3 (plan): AGENT mode playback and
// the always-on uplink tap. Not part of the daemon; a throwaway dev
// diagnostic.
import AudioToolbox
import CoreAudio
import Foundation

guard let physicalUID = AudioDeviceUtil.defaultOutputDeviceUID() else {
    print("FAIL: no default output device")
    exit(1)
}
guard let headsetID = AudioDeviceUtil.translateUIDToDevice(AIHeadsetConfig.deviceUID) else {
    print("FAIL: AI Headset device not found -- is the driver installed?")
    exit(1)
}

let aggregate = AggregateDevice()
let aggID: AudioDeviceID
do {
    aggID = try aggregate.create(outputDeviceUID: physicalUID, inputDeviceUID: nil)
} catch {
    print("FAIL: \(error)")
    exit(1)
}

let router = AudioRouter(aggregateDeviceID: aggID)

// Pre-fill the agent playback buffer with a 300Hz tone, as if
// ElevenLabsClient had already decoded some `audio` events (plan 3.3).
let channels = AIHeadsetConfig.channelCount
let sampleRate = AIHeadsetConfig.sampleRate
func makeTone(seconds: Double, freq: Double) -> [Float] {
    let frames = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: frames * channels)
    let phaseStep = 2.0 * Double.pi * freq / sampleRate
    var phase = 0.0
    for i in 0..<frames {
        let s = Float(0.5 * sin(phase))
        for ch in 0..<channels { out[i * channels + ch] = s }
        phase += phaseStep
    }
    return out
}

let agentTone = makeTone(seconds: 1.0, freq: 300)
agentTone.withUnsafeBufferPointer { buf in
    router.agentPlaybackBuffer.write(buf.baseAddress!, frameCount: agentTone.count / channels)
}
print("Pre-filled agentPlaybackBuffer with \(agentTone.count / channels) frames of 300Hz tone.")

router.mode = .agent
do {
    try router.start()
} catch {
    print("FAIL: router.start() \(error)")
    exit(1)
}

// Drive "AI Headset" app-side: capture its input (should be the
// agent's tone, relayed via Bridge.out) and simultaneously play a
// 600Hz tone on its output (simulating rozmówca, feeding Bridge.in ->
// uplinkBuffer).
var headsetIOProcID: AudioDeviceIOProcID?
var capturedSumSquares: Double = 0
var capturedFrames = 0
var playPhase = 0.0
let playPhaseStep = 2.0 * Double.pi * 600.0 / sampleRate

let status = AudioDeviceCreateIOProcIDWithBlock(&headsetIOProcID, headsetID, nil) { _, inInputData, _, outOutputData, _ in
    let output = UnsafeMutableAudioBufferListPointer(outOutputData)
    for buffer in output {
        guard let data = buffer.mData else { continue }
        let ch = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (ch * MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        var p = playPhase
        for i in 0..<frames {
            let s = Float(0.5 * sin(p))
            for c in 0..<ch { samples[i * ch + c] = s }
            p += playPhaseStep
        }
        playPhase = (playPhase + playPhaseStep * Double(frames)).truncatingRemainder(dividingBy: 2 * .pi)
    }

    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    for buffer in input {
        guard let data = buffer.mData else { continue }
        let ch = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (ch * MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<(frames * ch) {
            capturedSumSquares += Double(samples[i] * samples[i])
        }
        capturedFrames += frames
    }
}
guard status == noErr, let headsetProcID = headsetIOProcID else {
    print("FAIL: could not create IOProc on AI Headset")
    exit(1)
}
AudioDeviceStart(headsetID, headsetProcID)

print("Running AGENT mode for 1s...")
Thread.sleep(forTimeInterval: 1.0)

// Zlapane jeszcze w trybie AGENT -- po przelaczeniu na PASS miernik
// celowo opada, wiec pozniej bylby juz bliski zeru.
let downlinkDuringAgent = router.downlinkLevel

let agentInRMS = capturedFrames > 0 ? Float((capturedSumSquares / Double(capturedFrames * channels)).squareRoot()) : 0
let expectedRMS: Float = 0.5 / Float(2.0.squareRoot())
print("AI Headset.in RMS during AGENT mode = \(agentInRMS) (expected ~\(expectedRMS))")

var ok = true
if agentInRMS < expectedRMS * 0.5 || agentInRMS > expectedRMS * 1.5 {
    print("FAIL: AGENT playback did not reach AI Headset.in as expected")
    ok = false
}

// Now switch to PASS and confirm the ramp doesn't crash and things go
// quiet afterward (physical has no mic, so post-ramp should be silent).
router.mode = .pass
Thread.sleep(forTimeInterval: 0.5)

capturedSumSquares = 0
capturedFrames = 0
Thread.sleep(forTimeInterval: 0.5)
let postRampRMS = capturedFrames > 0 ? Float((capturedSumSquares / Double(capturedFrames * channels)).squareRoot()) : 0
print("AI Headset.in RMS well after AGENT->PASS transition = \(postRampRMS) (expected ~0)")
if postRampRMS > 0.02 {
    print("FAIL: still hearing agent audio well after the 5ms ramp should have finished")
    ok = false
}

// Uplink tap: the 600Hz tone we've been writing to AI Headset.out the
// whole time should have flowed through Bridge.in into uplinkBuffer.
let uplinkFrames = router.uplinkBuffer.framesAvailable
print("uplinkBuffer.framesAvailable = \(uplinkFrames)")
if uplinkFrames > 0 {
    var scratch = [Float](repeating: 0, count: uplinkFrames * channels)
    scratch.withUnsafeMutableBufferPointer { buf in
        router.uplinkBuffer.read(buf.baseAddress!, frameCount: uplinkFrames)
    }
    let uplinkRMS = (scratch.reduce(0) { $0 + $1 * $1 } / Float(scratch.count)).squareRoot()
    print("uplinkBuffer RMS = \(uplinkRMS) (expected ~\(expectedRMS), the rozmówca tone written to AI Headset.out)")
    if uplinkRMS < expectedRMS * 0.5 {
        print("FAIL: uplinkBuffer does not contain the expected rozmówca signal")
        ok = false
    }
} else {
    print("FAIL: uplinkBuffer is empty")
    ok = false
}

// Mierniki poziomu dla UI: musza reagowac na realny sygnal, inaczej
// wskaznik w menu bylby zawsze pusty.
print("uplinkLevel (rozmowca -> agent)          = \(router.uplinkLevel)")
print("downlinkLevel w trybie AGENT             = \(downlinkDuringAgent)")
print("downlinkLevel po przelaczeniu na PASS    = \(router.downlinkLevel) (ma opasc)")
if router.uplinkLevel < 0.05 {
    print("FAIL: uplinkLevel nie zareagowal na sygnal")
    ok = false
}
if downlinkDuringAgent < 0.05 {
    print("FAIL: downlinkLevel nie zareagowal na odtwarzanie agenta")
    ok = false
}
if router.downlinkLevel > downlinkDuringAgent * 0.5 {
    print("FAIL: downlinkLevel nie opadl po wyjsciu z trybu AGENT")
    ok = false
}

AudioDeviceStop(headsetID, headsetProcID)
AudioDeviceDestroyIOProcID(headsetID, headsetProcID)
router.stop()
try? aggregate.destroy()

print(ok ? "PASS" : "SOME FAILED")
exit(ok ? 0 : 1)
