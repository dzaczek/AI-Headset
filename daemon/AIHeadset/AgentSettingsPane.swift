import AppKit

/// Panel Ustawień „Agent głosowy” -- poświadczenia i wybór agenta
/// ElevenLabs. Zmiany obowiązują od razu, bez przycisku „Zapisz” (HIG
/// settings.md).
///
/// Charakter agenta (system prompt) celowo NIE jest tutaj: to ustawienie
/// zmieniane pod konkretną rozmowę, więc żyje w oknie podpowiedzi
/// (settings.md › Task-specific options).
///
/// Plain programmatic AppKit layout -- no Storyboard/XIB, consistent
/// with the rest of this project's no-Xcode-project build.
final class AgentSettingsPane: NSViewController {
    private let apiKeyField = NSSecureTextField()
    private let agentPopUp = NSPopUpButton()
    private let agentIDField = NSTextField()
    private let healthLabel = NSTextField(wrappingLabelWithString: "")
    private let recheckButton = NSButton()
    private var availableAgents: [AgentConfigClient.AgentSummary] = []
    private let onSave: () -> Void

    private static let fieldWidth: CGFloat = 320

    init(onSave: @escaping () -> Void) {
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = L("settings.pane.voiceAgent")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        buildUI()
        refreshAgents()
        runHealthCheck()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        view.window?.makeFirstResponder(nil) // zapis pola w trakcie edycji
    }

    private func buildUI() {
        let contentView = view

        apiKeyField.stringValue = AgentSettings.apiKey ?? ""
        configureCommitOnEndEditing(apiKeyField, action: #selector(apiKeyCommitted))

        agentPopUp.target = self
        agentPopUp.action = #selector(agentPopUpChanged)
        let refreshButton = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise",
                                                     accessibilityDescription: L("settings.refreshAgents"))!,
                                     target: self, action: #selector(refreshAgentsClicked))
        refreshButton.bezelStyle = .rounded
        refreshButton.toolTip = L("settings.refreshAgents")
        let agentRow = NSStackView(views: [agentPopUp, refreshButton])
        agentRow.spacing = 6
        agentPopUp.widthAnchor.constraint(equalToConstant: Self.fieldWidth - 38).isActive = true

        // Ręczne ID zostaje: agenci publiczni działają bez klucza API,
        // a bez klucza nie da się niczego wylistować.
        agentIDField.stringValue = AgentSettings.agentID ?? ""
        agentIDField.placeholderString = "agent_…"
        configureCommitOnEndEditing(agentIDField, action: #selector(agentIDCommitted))

        recheckButton.title = L("health.recheck")
        recheckButton.target = self
        recheckButton.action = #selector(runHealthCheck)
        recheckButton.bezelStyle = .rounded
        healthLabel.preferredMaxLayoutWidth = Self.fieldWidth

        let grid = NSGridView(views: [
            [label("settings.apiKey"), apiKeyField],
            [NSGridCell.emptyContentView, footnote("settings.keyHint")],
            [label("settings.agent"), agentRow],
            [label("settings.agentID"), agentIDField],
            [NSGridCell.emptyContentView, footnote("settings.agentManual")],
            [label("settings.health"), healthLabel],
            [NSGridCell.emptyContentView, recheckButton],
        ])
        // Układ formularza macOS: etykiety do prawej, pola do lewej.
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 8
        grid.rowSpacing = 8
        for row in [1, 4] { grid.row(at: row).topPadding = -4 }
        grid.row(at: 2).topPadding = 8
        grid.row(at: 5).topPadding = 8
        for field in [apiKeyField, agentIDField] {
            field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        }

        grid.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func label(_ key: String) -> NSTextField {
        NSTextField(labelWithString: L(key))
    }

    private func footnote(_ key: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: L(key))
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = Self.fieldWidth
        return field
    }

    /// Zmiana obowiązuje po wyjściu z pola (Tab, klik gdzie indziej,
    /// Enter) -- bez osobnego przycisku zapisu.
    private func configureCommitOnEndEditing(_ field: NSTextField, action: Selector) {
        field.target = self
        field.action = action
        field.cell?.sendsActionOnEndEditing = true
    }

    // MARK: - Commit

    /// AgentConfigClient reads credentials from the Keychain, so
    /// everything that talks to ElevenLabs must persist first --
    /// otherwise it would silently use stale (or absent) credentials
    /// and fail with a confusing 401.
    private func persistCredentials() {
        let agentID = agentIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AgentSettings.agentID = agentID.isEmpty ? nil : agentID
        AgentSettings.apiKey = apiKey.isEmpty ? nil : apiKey
        onSave()
    }

    @objc private func apiKeyCommitted() {
        guard apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != (AgentSettings.apiKey ?? "")
        else { return }
        persistCredentials()
        // Inny klucz = inny (albo dopiero dostępny) zestaw agentów.
        refreshAgents()
        runHealthCheck()
    }

    @objc private func agentIDCommitted() {
        guard agentIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != (AgentSettings.agentID ?? "")
        else { return }
        persistCredentials()
        selectCurrentAgentInPopUp()
        runHealthCheck()
    }

    @objc private func agentPopUpChanged() {
        guard let id = agentPopUp.selectedItem?.representedObject as? String else { return }
        agentIDField.stringValue = id
        persistCredentials()
        runHealthCheck()
    }

    // MARK: - Agent list

    @objc private func refreshAgentsClicked() {
        persistCredentials()
        refreshAgents()
    }

    /// Populates the agent dropdown from the ElevenLabs account. Needs
    /// an API key; without one the dropdown just says so and the
    /// manual ID field below is the way in.
    private func refreshAgents() {
        guard AgentSettings.apiKey != nil else {
            renderAgentPopUp(placeholder: L("agent.none"))
            return
        }
        renderAgentPopUp(placeholder: L("agent.loading"))
        Task { [weak self] in
            let agents = (try? await AgentConfigClient.listAgents()) ?? []
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.availableAgents = agents
                self.renderAgentPopUp(placeholder: agents.isEmpty ? L("agent.none") : nil)
            }
        }
    }

    private func renderAgentPopUp(placeholder: String?) {
        agentPopUp.removeAllItems()
        if let placeholder {
            agentPopUp.addItem(withTitle: placeholder)
            agentPopUp.isEnabled = false
            return
        }
        agentPopUp.isEnabled = true
        for agent in availableAgents {
            agentPopUp.addItem(withTitle: agent.name)
            agentPopUp.lastItem?.representedObject = agent.id
        }
        selectCurrentAgentInPopUp()
    }

    private func selectCurrentAgentInPopUp() {
        guard let current = AgentSettings.agentID,
              let index = availableAgents.firstIndex(where: { $0.id == current }) else { return }
        agentPopUp.selectItem(at: index)
    }

    // MARK: - Config health

    @objc private func runHealthCheck() {
        recheckButton.isEnabled = AgentSettings.isConfigured
        guard AgentSettings.isConfigured else {
            healthLabel.stringValue = L("settings.healthNotConfigured")
            healthLabel.textColor = .secondaryLabelColor
            return
        }
        healthLabel.stringValue = L("settings.healthChecking")
        healthLabel.textColor = .secondaryLabelColor
        Task { [weak self] in
            let findings = await ConfigHealthCheck.run()
            await MainActor.run { [weak self] in
                guard let self else { return }
                let warnings = findings.filter { $0.severity == .warning }
                // Znaczenie niesie symbol i tekst, nie kolor --
                // pomarańczowy tekst na jasnym tle nie trzyma 4,5:1.
                if warnings.isEmpty {
                    self.healthLabel.stringValue = L("settings.healthOK")
                    self.healthLabel.textColor = .secondaryLabelColor
                } else {
                    self.healthLabel.stringValue = warnings.map { "⚠︎ \($0.message)" }.joined(separator: "\n")
                    self.healthLabel.textColor = .labelColor
                }
            }
        }
    }
}
