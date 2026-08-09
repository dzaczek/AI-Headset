import AppKit
import ApplicationServices

/// Plan section 2.3 / 6.4: a global hotkey to flip modes, wired
/// independently of the network/WS thread so handback (AGENT -> PASS)
/// still works even if the WebSocket is hung. The handler fires
/// synchronously on the delivering thread (AppKit's event-monitor
/// callback) and must stay a fast, non-blocking state flip -- no
/// network calls, no waiting on anything -- to honor that guarantee.
final class HotkeyMonitor {
    struct Hotkey {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Registers a single global hotkey. Requires Accessibility
    /// permission (see `hasAccessibilityPermission`/
    /// `requestAccessibilityPermission`) or the global monitor simply
    /// never fires -- macOS gives no error for this, it's silent.
    func register(_ hotkey: Hotkey, handler: @escaping () -> Void) {
        unregisterAll()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if Self.matches(event, hotkey) {
                handler()
            }
        }
        // Global monitors only see events destined for *other* apps;
        // catch our own app's frontmost case too.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Self.matches(event, hotkey) {
                handler()
                return nil // swallow so it doesn't also trigger menu/text input
            }
            return event
        }
    }

    func unregisterAll() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    private static func matches(_ event: NSEvent, _ hotkey: Hotkey) -> Bool {
        event.keyCode == hotkey.keyCode
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == hotkey.modifiers
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "AIHeadset would like to control this
    /// computer" prompt if permission hasn't been granted yet. Call
    /// once at startup, before `register`.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: true]
        return AXIsProcessTrustedWithOptions(options)
    }

    deinit {
        unregisterAll()
    }
}
