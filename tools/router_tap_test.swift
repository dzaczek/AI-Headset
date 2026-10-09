// Bufory transkrypcji: stereo i mono trafiają jako mono, uplink agenta nietknięty.
import AudioToolbox
import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

let router = AudioRouter(aggregateDeviceID: 0)

// Rozmówcy: stereo, lewy = rampa, prawy = 0 -> mono = rampa / 2.
var stereo = [Float](repeating: 0, count: 512)
for i in 0..<256 { stereo[i * 2] = Float(i) / 256 }
// Mikrofon: mono (MacBook, Bluetooth HFP).
var mono = (0..<128).map { Float($0) / 128 }

stereo.withUnsafeMutableBytes { s in
    mono.withUnsafeMutableBytes { m in
        let caller = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(s.count), mData: s.baseAddress)
        let mic = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(m.count), mData: m.baseAddress)
        router.feedTranscriptTaps(caller: caller, mic: mic)
    }
}

check(router.callerTranscriptTap.framesAvailable == 256, "256 ramek rozmówców")
var callerOut = [Float](repeating: 0, count: 256)
callerOut.withUnsafeMutableBufferPointer { router.callerTranscriptTap.read($0.baseAddress!, frameCount: 256) }
check(abs(callerOut[100] - Float(100) / 256 / 2) < 1e-6, "stereo uśrednione do mono: \(callerOut[100])")

check(router.micTranscriptTap.framesAvailable == 128, "128 ramek mikrofonu")
var micOut = [Float](repeating: 0, count: 128)
micOut.withUnsafeMutableBufferPointer { router.micTranscriptTap.read($0.baseAddress!, frameCount: 128) }
check(abs(micOut[64] - 0.5) < 1e-6, "mono bez zmian: \(micOut[64])")

check(router.uplinkBuffer.framesAvailable == 0, "uplink agenta nie dostał nic z tej ścieżki")

// Brak mikrofonu w aggregate -> nil, bez awarii.
router.feedTranscriptTaps(caller: nil, mic: nil)

if failures > 0 { exit(1) }
print("PASS router_tap_test")
