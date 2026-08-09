import AppKit

/// Faza 4 "Ustawienia" window: agent ID + ElevenLabs API key, plus a
/// system-prompt editor that reads/writes the agent's behavior
/// directly via ElevenLabs' REST API (AgentConfigClient) -- requested
/// explicitly so agent behavior can be tweaked from this app instead
/// of only from the ElevenLabs dashboard. Plain programmatic AppKit
/// layout -- no Storyboard/XIB, consistent with the rest of this
/// project's no-Xcode-project build.
final class SettingsWindowController: NSWindowController {
    private let agentPopUp = NSPopUpButton()
    private let agentIDField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private var availableAgents: [AgentConfigClient.AgentSummary] = []
    private let promptTextView = NSTextView()
    private let promptStatusLabel = NSTextField(labelWithString: "")
    private var onSave: (() -> Void)?

    convenience init(onSave: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered,
                               defer: false)
        window.title = L("settings.title")
        window.center()
        self.init(window: window)
        self.onSave = onSave
        buildUI()
        refreshAgents()
        loadPromptIfConfigured()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let apiKeyLabel = NSTextField(labelWithString: L("settings.apiKey"))
        let hintLabel = NSTextField(wrappingLabelWithString:
            L("settings.keyHint"))
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor

        let agentLabel = NSTextField(labelWithString: L("settings.agent"))
        agentPopUp.target = self
        agentPopUp.action = #selector(agentPopUpChanged)
        agentPopUp.translatesAutoresizingMaskIntoConstraints = false
        agentPopUp.widthAnchor.constraint(equalToConstant: 400).isActive = true

        // Manual entry stays available: public agents can be used
        // without an API key, and without a key there is no way to
        // list anything.
        let manualLabel = NSTextField(labelWithString: L("settings.agentManual"))
        manualLabel.font = .systemFont(ofSize: 11)
        manualLabel.textColor = .secondaryLabelColor
        agentIDField.placeholderString = "agent_..."
        agentIDField.stringValue = AgentSettings.agentID ?? ""
        apiKeyField.stringValue = AgentSettings.apiKey ?? ""

        let promptLabel = NSTextField(labelWithString: L("settings.prompt"))
        let promptHint = NSTextField(wrappingLabelWithString:
            L("settings.promptHint"))
        promptHint.font = .systemFont(ofSize: 11)
        promptHint.textColor = .secondaryLabelColor

        promptTextView.isRichText = false
        promptTextView.font = .systemFont(ofSize: 12)
        promptTextView.isEditable = true
        promptTextView.textContainerInset = NSSize(width: 4, height: 4)
        let promptScroll = NSScrollView()
        promptScroll.hasVerticalScroller = true
        promptScroll.documentView = promptTextView
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.borderType = .bezelBorder
        promptScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true

        promptStatusLabel.font = .systemFont(ofSize: 11)
        promptStatusLabel.textColor = .secondaryLabelColor

        let reloadButton = NSButton(title: L("settings.reload"), target: self, action: #selector(reloadPrompt))
        let saveButton = NSButton(title: L("settings.save"), target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: L("settings.close"), target: self, action: #selector(cancel))
        let buttonRow = NSStackView(views: [reloadButton, NSView(), cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        for field in [agentIDField, apiKeyField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 400).isActive = true
        }
        promptScroll.widthAnchor.constraint(equalToConstant: 400).isActive = true

        let stack = NSStackView(views: [
            apiKeyLabel, apiKeyField, hintLabel,
            agentLabel, agentPopUp, manualLabel, agentIDField,
            promptLabel, promptScroll, promptHint, promptStatusLabel,
            buttonRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
        buttonRow.widthAnchor.constraint(equalToConstant: 400).isActive = true
    }

    private func loadPromptIfConfigured() {
        guard AgentSettings.isConfigured, AgentSettings.apiKey != nil else { return }
        reloadPrompt()
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
                if agents.isEmpty {
                    self.renderAgentPopUp(placeholder: L("agent.none"))
                } else {
                    self.renderAgentPopUp(placeholder: nil)
                }
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
        // Reflect whichever agent is currently configured.
        if let current = AgentSettings.agentID,
           let index = availableAgents.firstIndex(where: { $0.id == current }) {
            agentPopUp.selectItem(at: index)
        }
    }

    @objc private func agentPopUpChanged() {
        guard let id = agentPopUp.selectedItem?.representedObject as? String else { return }
        agentIDField.stringValue = id
        persistCredentials()
        onSave?()
        reloadPrompt() // show the newly selected agent's prompt
    }

    /// Commits whatever is currently typed in the credential fields to
    /// AgentSettings. Both Save *and* Reload go through this first:
    /// AgentConfigClient reads credentials from the Keychain, so
    /// fetching without persisting first would silently use stale (or
    /// absent) credentials and fail with a confusing 401.
    private func persistCredentials() {
        let agentID = agentIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        AgentSettings.agentID = agentID.isEmpty ? nil : agentID
        AgentSettings.apiKey = apiKey.isEmpty ? nil : apiKey
    }

    @objc private func reloadPrompt() {
        persistCredentials()
        onSave?()
        promptStatusLabel.stringValue = L("settings.loading")
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await AgentConfigClient.fetchSystemPrompt()
                await MainActor.run {
                    self.promptTextView.string = text
                    self.promptStatusLabel.stringValue = L("settings.loaded")
                }
            } catch {
                await MainActor.run {
                    self.promptStatusLabel.stringValue = L("settings.loadError", String(describing: error))
                }
            }
        }
    }

    @objc private func save() {
        persistCredentials()
        onSave?()
        // A newly entered/changed API key means a different (or newly
        // reachable) set of agents.
        refreshAgents()

        let promptText = promptTextView.string
        guard !promptText.isEmpty else { return }
        promptStatusLabel.stringValue = L("settings.saving")
        Task { [weak self] in
            guard let self else { return }
            do {
                try await AgentConfigClient.updateSystemPrompt(promptText)
                await MainActor.run {
                    self.promptStatusLabel.stringValue = L("settings.saved")
                }
            } catch {
                await MainActor.run {
                    self.promptStatusLabel.stringValue = L("settings.saveError", String(describing: error))
                }
            }
        }
    }

    @objc private func cancel() {
        window?.close()
    }
}
