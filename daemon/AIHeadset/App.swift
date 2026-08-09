import AppKit

/// LSUIElement app (also set in Info.plist, belt-and-suspenders via
/// `.accessory` activation policy): no dock icon, no main window,
/// lives entirely in the menu bar (plan section 4).
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarController = MenuBarController()
    }
}
