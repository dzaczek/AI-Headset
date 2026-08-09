// Standalone smoke test for Faza 2.2 (plan): starts AudioRouter in
// PASS mode on the private aggregate, then separately drives the
// app-facing "AI Headset" device with a tone (simulating rozmówca)
// and checks the monitoring leg (Bridge.in -> physical out) copies
// correctly. Not part of the daemon; a throwaway dev diagnostic.
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
print("Physical UID: \(physicalUID)")
let physicalInputUID = AudioDeviceUtil.defaultInputDeviceUID()
print("Physical input UID: \(physicalInputUID ?? "none")")

let aggregate = AggregateDevice()
let aggID: AudioDeviceID
do {
    aggID = try aggregate.create(outputDeviceUID: physicalUID, inputDeviceUID: physicalInputUID)
    print("Aggregate created: \(aggID)")
} catch {
    print("FAIL: \(error)")
    exit(1)
}

let router = AudioRouter(aggregateDeviceID: aggID)
router.mode = .pass

final class Stats: @unchecked Sendable {
    var maxBridgeIn: Float = 0
    var maxPhysicalOut: Float = 0
    var maxDelta: Float = 0
    var samples = 0
}
let stats = Stats()
router.onDebugSample = { bridgeIn, physicalOut in
    stats.samples += 1
    stats.maxBridgeIn = max(stats.maxBridgeIn, bridgeIn)
    stats.maxPhysicalOut = max(stats.maxPhysicalOut, physicalOut)
    stats.maxDelta = max(stats.maxDelta, abs(bridgeIn - physicalOut))
}

do {
    try router.start()
    print("Router started (PASS mode).")
} catch {
    print("FAIL: router.start() \(error)")
    exit(1)
}

// Drive "AI Headset" app-side: play a tone (simulating rozmówca) and
// record whatever comes back on its input. PASS mode relays the
// physical mic to that input -- expect silence here, since this
// test's physical device (default output) has no mic channels at all.
let sampleRate: Double = 48000
let toneFreq = 440.0
var phase = 0.0
var headsetIOProcID: AudioDeviceIOProcID?
var capturedFrames = 0
var captureSumSquares: Double = 0

let headsetStatus = AudioDeviceCreateIOProcIDWithBlock(&headsetIOProcID, headsetID, nil) { _, inInputData, _, outOutputData, _ in
    let output = UnsafeMutableAudioBufferListPointer(outOutputData)
    let phaseStep = 2.0 * Double.pi * toneFreq / sampleRate
    for buffer in output {
        guard let data = buffer.mData else { continue }
        let channels = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        var p = phase
        for i in 0..<frames {
            let s = Float(0.5 * sin(p))
            for ch in 0..<channels { samples[i * channels + ch] = s }
            p += phaseStep
        }
        phase = (phase + phaseStep * Double(frames)).truncatingRemainder(dividingBy: 2 * .pi)
    }

    let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    for buffer in input {
        guard let data = buffer.mData else { continue }
        let channels = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        let samples = data.assumingMemoryBound(to: Float.self)
        for i in 0..<(frames * channels) {
            captureSumSquares += Double(samples[i] * samples[i])
        }
        capturedFrames += frames
    }
}
guard headsetStatus == noErr, let headsetProcID = headsetIOProcID else {
    print("FAIL: could not create IOProc on AI Headset")
    exit(1)
}
AudioDeviceStart(headsetID, headsetProcID)

print("Running for 2s...")
Thread.sleep(forTimeInterval: 2.0)

AudioDeviceStop(headsetID, headsetProcID)
AudioDeviceDestroyIOProcID(headsetID, headsetProcID)
router.stop()
try? aggregate.destroy()

print("Debug samples: \(stats.samples), maxBridgeInRMS=\(stats.maxBridgeIn), maxPhysicalOutRMS=\(stats.maxPhysicalOut), maxDelta=\(stats.maxDelta)")

var ok = true
if stats.samples == 0 {
    print("FAIL: router never processed an IO cycle")
    ok = false
}
if stats.maxBridgeIn < 0.2 {
    print("FAIL: Bridge.in never saw the tone written to AI Headset.out (maxBridgeInRMS=\(stats.maxBridgeIn))")
    ok = false
}
if stats.maxDelta > 0.01 {
    print("FAIL: monitoring leg diverged -- physical out did not match Bridge.in (maxDelta=\(stats.maxDelta))")
    ok = false
}

let headsetInRMS = capturedFrames > 0 ? Float((captureSumSquares / Double(capturedFrames)).squareRoot()) : 0
if physicalInputUID != nil {
    // A real mic is in the aggregate -- PASS mode should be relaying
    // it live. Can't assert a specific RMS (it's whatever the room's
    // ambient sound is), just that IO ran and produced *some* reading
    // without crashing.
    print("AI Headset.in RMS = \(headsetInRMS) (live mic relay via PASS mode -- informational, no fixed expectation)")
} else {
    print("AI Headset.in RMS = \(headsetInRMS) (expected ~0: no physical input device available, so PASS mode's mic->Bridge.out leg has nothing to relay)")
    if headsetInRMS > 0.01 {
        print("FAIL: AI Headset.in has unexpected signal with no physical mic in the aggregate")
        ok = false
    }
}

print(ok ? "PASS" : "SOME FAILED")
exit(ok ? 0 : 1)
