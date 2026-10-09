// Auto-przewijanie: podążaj za nowym tekstem tylko, gdy użytkownik jest na dole.
import AppKit

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { print("FAIL [\(line)]: \(message)"); failures += 1 }
}

check(AutoScrollPolicy.shouldFollow(visibleMaxY: 1000, documentHeight: 1000), "dokładnie na dole")
check(AutoScrollPolicy.shouldFollow(visibleMaxY: 980, documentHeight: 1000), "20 pt od dołu")
check(!AutoScrollPolicy.shouldFollow(visibleMaxY: 600, documentHeight: 1000), "przewinięty w górę -> nie skacz")
check(AutoScrollPolicy.shouldFollow(visibleMaxY: 400, documentHeight: 300), "treść krótsza niż okno")

if failures > 0 { exit(1) }
print("PASS autoscroll_test")
