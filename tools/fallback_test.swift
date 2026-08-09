// Standalone smoke test: FallbackPlayer should fail gracefully (no
// crash, returns false, logs) when no fallback.caf is bundled -- this
// is the expected state until a real recording is added. Not part of
// the daemon.
import Foundation

let router = AudioRouter(aggregateDeviceID: 0)
let player = FallbackPlayer(router: router)
let result = player.playBundledFallback()
print("playBundledFallback() returned \(result) (expected false -- no resource bundle for this CLI binary)")
print(result == false ? "PASS" : "FAIL: expected false without a real .app bundle")
exit(result == false ? 0 : 1)
