import AppKit
import Speech

/// Panel „Transkrypcja”: silnik (przyciski radiowe -- 3 wzajemnie
/// wykluczające się opcje, HIG toggles.md › Radio buttons), język, adres
/// serwera Whisper (tylko dla Whisper), notka prywatności i stan zgody
/// na rozpoznawanie mowy (tylko dla Apple). Zmiany obowiązują od razu.
final class TranscriptionSettingsPane: NSViewController {
    private let settings = TranscriptionSettings()
    private let onChange: () -> Void
    private var engineButtons: [TranscriberEngine: NSButton] = [:]
    private let languagePopUp = NSPopUpButton()
    private let whisperField = NSTextField()
    private let privacyLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")
    private let permissionButton = NSButton()
    private var whisperRow: NSGridRow?
    private var permissionRow: NSGridRow?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(nibName: nil, bundle: nil)
        title = L("settings.pane.transcription")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))

        let engineStack = NSStackView()
        engineStack.orientation = .vertical
        engineStack.alignment = .leading
        engineStack.spacing = 6
        for engine in TranscriberEngine.allCases {
            let button = NSButton(radioButtonWithTitle: engine.title, target: self, action: #selector(engineChanged(_:)))
            button.tag = TranscriberEngine.allCases.firstIndex(of: engine)!
            engineButtons[engine] = button
            engineStack.addArrangedSubview(button)
        }

        for code in TranscriptionSettings.languages {
            languagePopUp.addItem(withTitle: L("transcription.language.\(code)"))
            languagePopUp.lastItem?.representedObject = code
        }
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged)

        whisperField.placeholderString = "http://127.0.0.1:8080"
        whisperField.target = self
        whisperField.action = #selector(whisperCommitted)
        whisperField.cell?.sendsActionOnEndEditing = true
        whisperField.widthAnchor.constraint(equalToConstant: 320).isActive = true

        for label in [privacyLabel, permissionLabel] {
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 320
        }
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(permissionClicked)
        let permissionStack = NSStackView(views: [permissionLabel, permissionButton])
        permissionStack.orientation = .vertical
        permissionStack.alignment = .leading

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: L("settings.transcription.engine")), engineStack],
            [NSGridCell.emptyContentView, privacyLabel],
            [NSTextField(labelWithString: L("settings.transcription.language")), languagePopUp],
            [NSTextField(labelWithString: L("settings.transcription.whisperURL")), whisperField],
            [NSTextField(labelWithString: L("settings.transcription.permission")), permissionStack],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        grid.row(at: 1).topPadding = -4
        whisperRow = grid.row(at: 3)
        permissionRow = grid.row(at: 4)

        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        render() // stan zgody mógł się zmienić w Ustawieniach systemowych
    }

    private func render() {
        let engine = settings.engine
        for (candidate, button) in engineButtons { button.state = candidate == engine ? .on : .off }
        if let index = TranscriptionSettings.languages.firstIndex(of: settings.language) {
            languagePopUp.selectItem(at: index)
        }
        whisperField.stringValue = settings.whisperURL.absoluteString
        privacyLabel.stringValue = engine.privacyNote
        whisperRow?.isHidden = engine != .whisper
        permissionRow?.isHidden = engine != .apple
        (parent as? SettingsTabs)?.fitSelectedPane()

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            permissionLabel.stringValue = L("settings.transcription.permissionOK")
            permissionButton.isHidden = true
        case .notDetermined:
            permissionLabel.stringValue = L("settings.transcription.permissionAsk")
            permissionButton.title = L("settings.transcription.permissionRequest")
            permissionButton.isHidden = false
        default:
            permissionLabel.stringValue = L("transcription.error.speechDenied")
            permissionButton.title = L("settings.transcription.permissionOpen")
            permissionButton.isHidden = false
        }
    }

    @objc private func engineChanged(_ sender: NSButton) {
        settings.engine = TranscriberEngine.allCases[sender.tag]
        render()
        onChange()
    }

    @objc private func languageChanged() {
        guard let code = languagePopUp.selectedItem?.representedObject as? String else { return }
        settings.language = code
        onChange()
    }

    @objc private func whisperCommitted() {
        let text = whisperField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else {
            whisperField.stringValue = settings.whisperURL.absoluteString // zły adres -> wróć do poprzedniego
            NSSound.beep()
            return
        }
        guard url != settings.whisperURL else { return }
        settings.whisperURL = url
        onChange()
    }

    @objc private func permissionClicked() {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            AppleSpeechTranscriber.requestAuthorization { [weak self] _ in
                self?.render()
                self?.onChange()
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }
}
