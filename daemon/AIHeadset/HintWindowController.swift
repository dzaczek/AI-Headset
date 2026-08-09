import AppKit

/// Podręczne okno agenta: charakter na górze, podpowiedzi na dole.
///
/// Osobne od Ustawień celowo. W Ustawieniach siedzą poświadczenia,
/// które wpisuje się raz. Tu są dwie rzeczy dotykane w trakcie pracy:
///  * charakter agenta -- zapisywany na koncie ElevenLabs,
///  * podpowiedź na żywo (`contextual_update`) -- wchodzi jako
///    informacja w tle, nie przerywając bieżącej wypowiedzi.
///
/// Okno jest pływające (zostaje nad Teamsem), żeby dało się z niego
/// korzystać nie przerywając rozmowy.
final class HintWindowController: NSWindowController, NSTextFieldDelegate {
    private let personaView = NSTextView()
    private let personaStatus = NSTextField(labelWithString: "")
    private let hintField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let historyLabel = NSTextField(wrappingLabelWithString: "")
    private var recentHints: [String] = []

    /// Zwraca sesję agenta albo nil, gdy nie ma połączenia.
    private let sessionProvider: () -> AgentSession?

    init(sessionProvider: @escaping () -> AgentSession?) {
        self.sessionProvider = sessionProvider
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                             styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                             backing: .buffered,
                             defer: false)
        window.title = L("hint.title")
        window.isFloatingPanel = true
        window.level = .floating // ma być widoczne nad Teamsem w trakcie rozmowy
        window.hidesOnDeactivate = false
        window.center()
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // --- charakter agenta ---
        let personaLabel = NSTextField(labelWithString: L("hint.persona"))
        personaView.isRichText = false
        personaView.font = .systemFont(ofSize: 12)
        personaView.isEditable = true
        personaView.textContainerInset = NSSize(width: 4, height: 4)
        let personaScroll = NSScrollView()
        personaScroll.hasVerticalScroller = true
        personaScroll.documentView = personaView
        personaScroll.borderType = .bezelBorder
        personaScroll.translatesAutoresizingMaskIntoConstraints = false
        personaScroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        personaScroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        personaStatus.font = .systemFont(ofSize: 11)
        personaStatus.textColor = .secondaryLabelColor
        let personaButtons = NSStackView(views: [
            NSButton(title: L("hint.personaLoad"), target: self, action: #selector(loadPersona)),
            NSButton(title: L("hint.personaSave"), target: self, action: #selector(savePersona)),
        ])
        personaButtons.orientation = .horizontal
        personaButtons.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 420).isActive = true

        // --- podpowiedz na zywo ---
        let label = NSTextField(labelWithString: L("hint.prompt"))
        let hint = NSTextField(wrappingLabelWithString: L("hint.explain"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        hintField.placeholderString = L("hint.placeholder")
        hintField.delegate = self
        hintField.target = self
        hintField.action = #selector(send)
        hintField.translatesAutoresizingMaskIntoConstraints = false
        hintField.widthAnchor.constraint(equalToConstant: 380).isActive = true

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        historyLabel.font = .systemFont(ofSize: 11)
        historyLabel.textColor = .tertiaryLabelColor

        let sendButton = NSButton(title: L("hint.send"), target: self, action: #selector(send))
        sendButton.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            personaLabel, personaScroll, personaButtons, personaStatus,
            separator,
            label, hintField, hint, sendButton, statusLabel, historyLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ])
    }

    @objc private func loadPersona() {
        personaStatus.stringValue = L("settings.loading")
        Task { [weak self] in
            do {
                let text = try await AgentConfigClient.fetchSystemPrompt()
                await MainActor.run { [weak self] in
                    self?.personaView.string = text
                    self?.personaStatus.stringValue = L("settings.loaded")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.personaStatus.stringValue = L("settings.loadError", String(describing: error))
                }
            }
        }
    }

    @objc private func savePersona() {
        let text = personaView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        personaStatus.stringValue = L("settings.saving")
        Task { [weak self] in
            do {
                try await AgentConfigClient.updateSystemPrompt(text)
                await MainActor.run { [weak self] in
                    self?.personaStatus.stringValue = L("hint.personaSaved")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.personaStatus.stringValue = L("settings.saveError", String(describing: error))
                }
            }
        }
    }

    func show() {
        if personaView.string.isEmpty, AgentSettings.isConfigured, AgentSettings.apiKey != nil {
            loadPersona()
        }
        refreshStatus()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(hintField)
    }

    private func refreshStatus() {
        if let session = sessionProvider(), session.isConnected {
            statusLabel.stringValue = L("hint.ready")
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = L("hint.notConnected")
            statusLabel.textColor = .systemOrange
        }
    }

    @objc private func send() {
        let text = hintField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard let session = sessionProvider(), session.isConnected else {
            // Bez połączenia podpowiedź nie ma dokąd pójść -- mówimy o
            // tym wprost, zamiast udawać, że wysłano.
            statusLabel.stringValue = L("hint.notConnected")
            statusLabel.textColor = .systemOrange
            return
        }

        session.sendHint(text)
        hintField.stringValue = ""

        recentHints.insert(text, at: 0)
        if recentHints.count > 3 { recentHints.removeLast() }
        historyLabel.stringValue = recentHints.map { "• \($0)" }.joined(separator: "\n")

        statusLabel.stringValue = L("hint.sent")
        statusLabel.textColor = .systemGreen
    }
}
