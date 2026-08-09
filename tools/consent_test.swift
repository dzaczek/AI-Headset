// Standalone smoke test for ConsentAnnouncer.swift: verifies local TTS
// gets resampled and written into AudioRouter.announcementBuffer.
// AudioRouter is constructed with a dummy device ID and never
// started, so this is pure plumbing (TTS -> resample -> ring buffer),
// no live device/driver involved. Not part of the daemon.
import Foundation

let router = AudioRouter(aggregateDeviceID: 0)
let announcer = ConsentAnnouncer(router: router)

// AVSpeechSynthesizer's callback delivery needs an active run loop --
// blocking the main thread on a semaphore deadlocks it. Pump the run
// loop in small increments instead.
var completed = false
announcer.announce(text: "To jest test.") {
    completed = true
}
let deadline = Date().addingTimeInterval(10)
while !completed && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

var ok = true
if !completed {
    print("FAIL: announce() never called completion within 10s")
    ok = false
}

let frames = router.announcementBuffer.framesAvailable
print("announcementBuffer.framesAvailable after announce = \(frames)")
if frames == 0 {
    print("FAIL: no audio was written to announcementBuffer")
    ok = false
}

if let last = announcer.lastAnnouncement {
    print("lastAnnouncement recorded: text=\"\(last.text)\" playedAt=\(last.playedAt)")
} else {
    print("FAIL: lastAnnouncement was never set")
    ok = false
}

print(ok ? "PASS" : "SOME FAILED")
exit(ok ? 0 : 1)
