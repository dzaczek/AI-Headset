import AppKit

/// Okno Ustawień (⌘,) z panelami w pasku narzędzi (HIG settings.md):
/// pasek nieedytowalny, aktywny panel zaznaczony, tytuł okna = nazwa
/// panelu, otwiera się na ostatnio używanym panelu, bez minimalizacji
/// i powiększania. Kolejne panele (Modele, Narzędzia, Agenci, Notatki)
/// dochodzą razem ze swoimi funkcjami.
final class SettingsWindowController: NSWindowController {
    enum Pane: Int { case voiceAgent, transcription }

    private let tabs = SettingsTabs()
    private static let lastPaneKey = "settings.lastPane"

    /// `onSave` -- zmiana poświadczeń agenta głosowego.
    /// `onTranscriptionChange` -- zmiana ustawień transkrypcji.
    convenience init(onSave: @escaping () -> Void, onTranscriptionChange: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        self.init(window: window)

        tabs.tabStyle = .toolbar
        let voice = NSTabViewItem(viewController: AgentSettingsPane(onSave: onSave))
        voice.image = NSImage(systemSymbolName: "person.wave.2", accessibilityDescription: nil)
        let transcription = NSTabViewItem(viewController: TranscriptionSettingsPane(onChange: onTranscriptionChange))
        transcription.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
        tabs.addTabViewItem(voice)
        tabs.addTabViewItem(transcription)
        tabs.selectedTabViewItemIndex = UserDefaults.standard.integer(forKey: Self.lastPaneKey)
        window.contentViewController = tabs
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            UserDefaults.standard.set(self.tabs.selectedTabViewItemIndex, forKey: Self.lastPaneKey)
        }
    }

    func show(pane: Pane? = nil) {
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        showWindow(nil)
        tabs.fitSelectedPane()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Tytuł okna = nazwa panelu, a wysokość okna dopasowana do zawartości
/// panelu (panele mają różne wysokości, a Transkrypcja zmienia swoją,
/// gdy pokazuje/ukrywa wiersze). Sam NSTabViewController w tej
/// konfiguracji nie robi ani jednego, ani drugiego.
final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitSelectedPane()
    }

    func fitSelectedPane() {
        guard let window = view.window,
              let item = tabView.selectedTabViewItem,
              let pane = item.viewController else { return }
        window.title = item.label
        pane.view.layoutSubtreeIfNeeded()
        // Wspólna minimalna szerokość: okno nie skacze w bok przy zmianie panelu.
        let size = NSSize(width: max(pane.view.fittingSize.width, 520), height: pane.view.fittingSize.height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // Lewy górny róg stoi w miejscu, okno rośnie/maleje w dół.
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}
