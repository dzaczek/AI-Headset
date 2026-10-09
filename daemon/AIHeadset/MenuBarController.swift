import AppKit
import CoreAudio
import Speech

/// Faza 4 (plan): the menu bar UI. AGENT mode now actually starts an
/// AgentSession (Faza 3) using the agent ID/API key from Settings.
/// Owns the transcription lifecycle too: the session follows the audio
/// router, the transcript store outlives both.
final class MenuBarController: NSObject, NSMenuDelegate, TranscriptionControlling {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let aggregate = AggregateDevice()
    private let hotkey = HotkeyMonitor()

    private var router: AudioRouter?
    private var outputDeviceUID: String
    private var inputDeviceUID: String?
    private var status: Status = .starting
    private var agentSession: AgentSession?
    private var agentState: AgentConnectionState = .disconnected
    private var settingsWindowController: SettingsWindowController?
    private var agentPanel: HintWindowController?
    /// Transkrypt żyje tyle co aplikacja: przebudowa audio wymienia sesję,
    /// nie magazyn, więc okno nie traci rozmowy.
    private let transcriptStore = TranscriptStore()
    private var transcriptionSession: TranscriptionSession?
    private var transcriptJournal: Transcript?
    private var transcriptWindow: TranscriptWindowController?
    private(set) var transcriptionStatus: TranscriptionStatus = .paused {
        didSet { transcriptWindow?.statusDidChange() }
    }
    private var availableAgents: [AgentConfigClient.AgentSummary] = []
    private var agentsLoading = false
    private var agentListError: String?
    private var uplinkMeterItem: NSMenuItem?
    private var downlinkMeterItem: NSMenuItem?
    private var headphonesMeterItem: NSMenuItem?
    private var micMeterItem: NSMenuItem?
    private var meterTimer: Timer?

    private var deadMansSwitch: DeadMansSwitch?
    private var clockWatchdog: ClockWatchdog?
    /// Drives the status-bar "agent is speaking" indicator and feeds
    /// the dead man's switch its turn state. Runs whenever the app is
    /// up, unlike the meter timer.
    private var supervisionTimer: Timer?
    private var lastTurnLatency: TimeInterval?
    private var agentIsSpeaking = false
    private var healthFindings: [ConfigHealthCheck.Finding] = []
    private var micPermission: MicrophonePermission.State = .notDetermined

    private enum Status {
        case starting, active, error

        var glyphColor: NSColor {
            switch self {
            case .starting: return .systemYellow
            case .active: return .systemGreen
            case .error: return .systemRed
            }
        }

        var label: String {
            switch self {
            case .starting: return L("status.starting")
            case .active: return L("status.active")
            case .error: return L("status.error")
            }
        }
    }

    override init() {
        // Najpierw to, co użytkownik sam wybrał ostatnio (jeśli jest
        // podłączone), potem domyślne systemu. Nigdy nie bierzemy
        // własnego urządzenia jako "fizycznego" punktu monitorowania --
        // patrz AudioDeviceUtil.isOwnDevice.
        let defaults = UserDefaults.standard
        outputDeviceUID = defaults.string(forKey: Self.outputDeviceKey)
            .flatMap { AudioDeviceUtil.isAvailablePhysicalDevice($0) ? $0 : nil }
            ?? AudioDeviceUtil.physicalDefaultOutputUID() ?? ""
        inputDeviceUID = defaults.string(forKey: Self.inputDeviceKey)
            .flatMap { AudioDeviceUtil.isAvailablePhysicalDevice($0) ? $0 : nil }
            ?? AudioDeviceUtil.physicalDefaultInputUID()
        super.init()

        buildStatusItem()
        rebuildAudio(outputUID: outputDeviceUID, inputUID: inputDeviceUID, mode: .pass)
        setupHotkey()
        refreshAgentList()
        requestMicrophonePermission()
        startSupervision()
        startClockWatchdog()
        runConfigHealthCheck()
    }

    /// Bez zgody TCC mikrofon podaje ciszę, a objaw jest identyczny
    /// jak zepsuty routing -- dlatego pytamy jawnie przy starcie i
    /// pokazujemy stan w menu, zamiast liczyć na to, że system zapyta
    /// sam we właściwym momencie.
    private func requestMicrophonePermission() {
        MicrophonePermission.requestIfNeeded { [weak self] state in
            self?.micPermission = state
            self?.rebuildMenu()
        }
    }

    /// Plan 6.3: drift builds up slowly and only shows itself as
    /// clicking after ~20 minutes, so it has to be watched rather than
    /// waited for.
    private func startClockWatchdog() {
        let watchdog = ClockWatchdog(
            aggregateDeviceID: { [weak self] in self?.aggregate.deviceID },
            onRebuildNeeded: { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    Log.info("clock drift over threshold -- rebuilding aggregate")
                    self.rebuildAudio(outputUID: self.outputDeviceUID,
                                       inputUID: self.inputDeviceUID,
                                       mode: self.router?.mode ?? .pass)
                }
            })
        watchdog.start()
        clockWatchdog = watchdog
    }

    func shutdown() {
        hotkey.unregisterAll()
        agentSession?.stop()
        stopTranscription()
        transcriptJournal?.close()
        router?.stop()
        try? aggregate.destroy()
    }

    // MARK: - Status item / icon

    private func buildStatusItem() {
        updateIcon()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    /// Plan 4: the AGENT icon must be unmistakably different from
    /// PASS/MUTE -- "coś mówi twoim głosem" -- not just a color swap.
    private func updateIcon() {
        let (symbol, description): (String, String)
        switch router?.mode ?? .pass {
        case .pass:
            (symbol, description) = ("waveform", "AI Headset: PASS")
        case .agent:
            (symbol, description) = ("brain.head.profile", "AI Headset: AGENT")
        case .mute:
            (symbol, description) = ("mic.slash", "AI Headset: MUTE")
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        statusItem.button?.image = image

        // Error beats everything; otherwise light up while the agent is
        // actually speaking on your channel, so it's visible without
        // opening the menu.
        if status == .error {
            statusItem.button?.contentTintColor = .systemRed
        } else if agentIsSpeaking {
            statusItem.button?.contentTintColor = .systemPurple
        } else {
            statusItem.button?.contentTintColor = nil
        }
    }

    // MARK: - Menu construction

    /// Układ wg HIG (menus.md › Organization): na górze to, czego
    /// dotyka się w trakcie rozmowy (tryb, okno podpowiedzi), potem
    /// wybory z bieżącą wartością w tytule, a diagnostyka -- mierniki,
    /// statusy, test dźwięku, wersja -- w jednym podmenu, żeby nie
    /// wydłużała menu. Na wierzch wychodzi tylko to, co wymaga reakcji.
    private func rebuildMenu() {
        menu.removeAllItems()

        let currentMode = router?.mode ?? .pass
        let header = NSMenuItem(title: L("menu.header", modeTitle(currentMode)), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        for mode in [RouterMode.pass, .agent, .mute] {
            let item = NSMenuItem(title: modeTitle(mode), action: #selector(selectMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = currentMode == mode ? .on : .off
            menu.addItem(item)
        }

        // Okno używane W TRAKCIE rozmowy, więc tuż pod trybami. Skrót
        // NIE ⌘⇧A -- tamten jest globalnym przełącznikiem PASS↔AGENT i
        // przechwytuje zdarzenie, zanim dojdzie do menu.
        menu.addItem(.separator())
        let transcriptItem = NSMenuItem(title: L("menu.transcript"), action: #selector(openTranscriptWindow), keyEquivalent: "t")
        transcriptItem.keyEquivalentModifierMask = [.command, .shift]
        transcriptItem.target = self
        menu.addItem(transcriptItem)
        let panelItem = NSMenuItem(title: L("menu.agentPanel"), action: #selector(openAgentPanel), keyEquivalent: "h")
        panelItem.keyEquivalentModifierMask = [.command, .shift]
        panelItem.target = self
        menu.addItem(panelItem)

        menu.addItem(.separator())
        menu.addItem(buildAgentPickerItem())
        menu.addItem(buildDevicePickerItem(titleKey: "device.output", scope: kAudioObjectPropertyScopeOutput,
                                            current: outputDeviceUID, action: #selector(selectOutputDevice(_:))))
        menu.addItem(buildDevicePickerItem(titleKey: "device.input", scope: kAudioObjectPropertyScopeInput,
                                            current: inputDeviceUID, action: #selector(selectInputDevice(_:))))

        // Problemy wymagające reakcji -- widoczne bez otwierania podmenu.
        let attention = attentionItems()
        if !attention.isEmpty {
            menu.addItem(.separator())
            attention.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        menu.addItem(buildDiagnosticsItem())

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("menu.settings"), action: #selector(openSettingsMenuAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: L("menu.quit"), action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = item.target ?? self
        }
    }

    private func modeTitle(_ mode: RouterMode) -> String {
        switch mode {
        case .pass: return L("mode.pass")
        case .agent: return L("mode.agent")
        case .mute: return L("mode.mute")
        }
    }

    /// Błąd audio, zablokowany mikrofon i ostrzeżenia konfiguracji
    /// agenta. Wszystko, co tu trafia, jest tekstem, nie samym kolorem.
    private func attentionItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if status == .error {
            items.append(statusLine(title: L("status.audio", status.label), color: status.glyphColor))
        }
        if micPermission == .denied {
            let warning = statusLine(title: L("mic.denied"), color: .systemRed)
            warning.action = #selector(openMicrophoneSettings)
            warning.target = self
            warning.isEnabled = true
            items.append(warning)
        }
        if healthFindings.contains(where: { $0.severity == .warning }) {
            items.append(buildHealthItem())
        }
        return items
    }

    private func buildHealthItem() -> NSMenuItem {
        let parent = NSMenuItem(title: healthSummaryTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for finding in healthFindings {
            submenu.addItem(statusLine(title: finding.message,
                                        color: finding.severity == .ok ? .systemGreen : .systemOrange))
        }
        let recheck = NSMenuItem(title: L("health.recheck"), action: #selector(recheckConfig), keyEquivalent: "")
        recheck.target = self
        submenu.addItem(.separator())
        submenu.addItem(recheck)
        parent.submenu = submenu
        return parent
    }

    private func buildDiagnosticsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L("menu.diagnostics"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        submenu.addItem(statusLine(title: L("status.audio", status.label), color: status.glyphColor))
        submenu.addItem(statusLine(title: L("status.agent", agentStateLabel), color: agentStateColor))
        if let latency = lastTurnLatency {
            // Plan's Faza 3 acceptance target is under 1s.
            let color: NSColor = latency < 1.0 ? .systemGreen : (latency < 2.5 ? .systemYellow : .systemRed)
            submenu.addItem(statusLine(title: L("status.latency", latency), color: color))
        }

        submenu.addItem(.separator())
        uplinkMeterItem = statusLine(title: meterTitle(L("meter.toAgent"), router?.uplinkLevel ?? 0), color: .systemBlue)
        downlinkMeterItem = statusLine(title: meterTitle(L("meter.fromAgent"), router?.downlinkLevel ?? 0), color: .systemPurple)
        headphonesMeterItem = statusLine(title: meterTitle(L("meter.toHeadphones"), router?.physicalOutLevel ?? 0), color: .systemTeal)
        micMeterItem = statusLine(title: meterTitle(L("meter.mic"), router?.micLevel ?? 0), color: .systemGreen)
        submenu.addItem(uplinkMeterItem!)
        submenu.addItem(downlinkMeterItem!)
        submenu.addItem(headphonesMeterItem!)
        submenu.addItem(micMeterItem!)

        submenu.addItem(.separator())
        let toneItem = NSMenuItem(title: L("menu.testTone"), action: #selector(playTestTone), keyEquivalent: "")
        toneItem.target = self
        submenu.addItem(toneItem)
        // Gdy konfiguracja jest w porządku, jej podsumowanie nie musi
        // wisieć w głównym menu -- ale ma być gdzie je sprawdzić.
        if !healthFindings.isEmpty && !healthFindings.contains(where: { $0.severity == .warning }) {
            submenu.addItem(buildHealthItem())
        }

        submenu.addItem(.separator())
        // Version + build stamp, so "which build is actually running"
        // is never a guess from file timestamps.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let versionItem = NSMenuItem(title: L("menu.version", version, build), action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        submenu.addItem(versionItem)

        parent.submenu = submenu
        return parent
    }

    private var agentStateLabel: String {
        switch agentState {
        case .disconnected: return L("agent.state.disconnected")
        case .connecting: return L("agent.state.connecting")
        case .connected: return L("agent.state.connected")
        case .reconnecting: return L("agent.state.reconnecting")
        }
    }

    private var healthSummaryTitle: String {
        let warnings = healthFindings.filter { $0.severity == .warning }.count
        return warnings == 0 ? L("health.allOK") : L("health.warnings", warnings)
    }

    @objc private func recheckConfig() {
        runConfigHealthCheck()
    }

    private var agentStateColor: NSColor {
        switch agentState {
        case .disconnected: return .systemGray
        case .connecting, .reconnecting: return .systemYellow
        case .connected: return .systemGreen
        }
    }

    /// Renders a level as a block-character bar. Log-ish scaling, since
    /// speech RMS spends most of its time well below 1.0 and a linear
    /// bar would barely twitch.
    private func meterTitle(_ label: String, _ level: Float) -> String {
        let blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let scaled = min(1.0, sqrt(max(0, level)) * 1.6)
        let filled = Int(scaled * 12)
        var bar = ""
        for i in 0..<12 {
            bar += i < filled ? blocks[min(blocks.count - 1, Int(scaled * Float(blocks.count)))] : "▁"
        }
        return "\(label) \(bar)"
    }

    /// Meters only tick while the menu is actually on screen -- no
    /// point burning a timer (and forcing menu redraws) when nobody is
    /// looking at it.
    @objc private func retryAgentList() {
        refreshAgentList()
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Samonaprawa: jeśli listy nie ma (np. API Key wpisano już po
        // starcie aplikacji), spróbuj ponownie w momencie, gdy
        // użytkownik faktycznie po nią sięga. Brak listy nie powinien
        // wymagać restartu aplikacji.
        if availableAgents.isEmpty && !agentsLoading && AgentSettings.apiKey != nil {
            refreshAgentList()
        }

        // Lista urządzeń jest odczytywana z CoreAudio dopiero w
        // rebuildMenu(), a to działo się wyłącznie przy zmianach stanu
        // aplikacji. Słuchawki podłączone w międzyczasie nie miały jak
        // się pojawić. Odbudowa przy otwarciu menu daje zawsze aktualny
        // obraz sprzętu.
        rebuildMenu()

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let router = self.router else { return }
            self.uplinkMeterItem?.title = self.meterTitle(L("meter.toAgent"), router.uplinkLevel)
            self.downlinkMeterItem?.title = self.meterTitle(L("meter.fromAgent"), router.downlinkLevel)
            self.headphonesMeterItem?.title = self.meterTitle(L("meter.toHeadphones"), router.physicalOutLevel)
            self.micMeterItem?.title = self.meterTitle(L("meter.mic"), router.micLevel)
        }
        RunLoop.current.add(meterTimer!, forMode: .common) // .common so it keeps firing while the menu tracks
    }

    func menuDidClose(_ menu: NSMenu) {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func statusLine(title: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let dot = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) {
            dot.isTemplate = false
            let tinted = dot.copy() as! NSImage
            tinted.lockFocus()
            color.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            item.image = tinted
        }
        return item
    }

    /// Agent list is fetched lazily and cached: the menu is rebuilt on
    /// every state change, so hitting the network each time would be
    /// wasteful and would make the menu pop open empty. Refreshed when
    /// the menu is first built with credentials present, and after
    /// Settings changes.
    private func buildAgentPickerItem() -> NSMenuItem {
        // Bieżący wybór w tytule, żeby nie trzeba było otwierać podmenu.
        let currentID = AgentSettings.agentID
        let currentName = availableAgents.first(where: { $0.id == currentID })?.name
            ?? currentID.flatMap { $0.isEmpty ? nil : $0 }
            ?? L("agent.noneSelected")
        let parent = NSMenuItem(title: L("agent.picker", currentName), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        if availableAgents.isEmpty {
            let title: String
            if agentsLoading {
                title = L("agent.loading")
            } else if let agentListError {
                // Pokazujemy konkretny powód (401, brak sieci...), bo
                // samo "brak agentów" nie pozwala nic z tym zrobić.
                title = agentListError
            } else {
                title = L("agent.none")
            }
            let placeholder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)

            let retry = NSMenuItem(title: L("agent.retry"), action: #selector(retryAgentList), keyEquivalent: "")
            retry.target = self
            submenu.addItem(.separator())
            submenu.addItem(retry)
        } else {
            for agent in availableAgents {
                let item = NSMenuItem(title: agent.name, action: #selector(selectAgent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = agent.id
                item.state = agent.id == AgentSettings.agentID ? .on : .off
                submenu.addItem(item)
            }
        }

        // Połączenie dotyczy wybranego agenta, więc mieszka obok wyboru.
        submenu.addItem(.separator())
        let toggleTitle = agentSession == nil ? L("agent.connect") : L("agent.disconnect")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleAgentConnection), keyEquivalent: "")
        toggleItem.target = self
        submenu.addItem(toggleItem)

        parent.submenu = submenu
        return parent
    }

    private func runConfigHealthCheck() {
        Task { [weak self] in
            let findings = await ConfigHealthCheck.run()
            await MainActor.run { [weak self] in
                self?.healthFindings = findings
                self?.rebuildMenu()
            }
        }
    }

    private func refreshAgentList() {
        guard !agentsLoading else { return }
        guard AgentSettings.apiKey != nil else {
            Log.info("nie pobieram listy agentów -- brak API Key")
            availableAgents = []
            agentListError = L("agent.none")
            return
        }
        agentsLoading = true
        agentListError = nil
        Task { [weak self] in
            let result: (agents: [AgentConfigClient.AgentSummary], error: String?)
            do {
                let agents = try await AgentConfigClient.listAgents()
                Log.info("pobrano listę agentów: \(agents.count)")
                result = (agents, nil)
            } catch {
                // Milczące `try?` sprawiało, że pusta lista wyglądała
                // identycznie jak brak agentów -- bez śladu w logu nie
                // dało się tego zdiagnozować zdalnie.
                let description = String(describing: error)
                Log.error("błąd pobierania listy agentów: \(description)")
                result = ([], description)
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.availableAgents = result.agents
                self.agentListError = result.error
                self.agentsLoading = false
                self.rebuildMenu()
            }
        }
    }

    @objc private func selectAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, id != AgentSettings.agentID else { return }
        AgentSettings.agentID = id

        // Switching agents mid-session means the old WebSocket is
        // pointed at the wrong agent -- reconnect, but only if we were
        // connected to begin with.
        if agentSession != nil {
            stopAgentSession()
            startAgentSessionIfNeeded()
        }
        rebuildMenu()
    }

    private func buildDevicePickerItem(titleKey: String, scope: AudioObjectPropertyScope, current: String?,
                                        action: Selector) -> NSMenuItem {
        let currentName = current
            .flatMap(AudioDeviceUtil.translateUIDToDevice)
            .flatMap(AudioDeviceUtil.deviceName(for:))
            ?? L("device.none")
        let parent = NSMenuItem(title: L(titleKey, currentName), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for deviceID in AudioDeviceUtil.allDeviceIDs() {
            guard let uid = AudioDeviceUtil.deviceUID(for: deviceID),
                  uid != AIHeadsetConfig.deviceUID, uid != AIHeadsetConfig.bridgeUID, uid != AIHeadsetConfig.aggregateUID
            else { continue }
            guard AudioDeviceUtil.channelCount(for: deviceID, scope: scope) > 0 else { continue }
            let name = AudioDeviceUtil.deviceName(for: deviceID) ?? uid
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = uid
            item.state = uid == current ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? RouterMode else { return }
        applyMode(mode)
    }

    private func applyMode(_ mode: RouterMode) {
        if mode == .agent && !AgentSettings.isConfigured {
            showSettingsRequiredAlert()
            return
        }

        router?.mode = mode
        if mode == .agent {
            startAgentSessionIfNeeded()
        } else {
            stopAgentSession()
        }
        updateIcon()
        rebuildMenu()
    }

    private func startAgentSessionIfNeeded() {
        guard agentSession == nil, let router else { return }
        do {
            let session = try AgentSession(router: router, signedURLProvider: AgentSettings.signedURLProvider)
            session.onStateChange = { [weak self] state in
                self?.agentState = state
                self?.deadMansSwitch?.isConnected = (state == .connected)
                self?.rebuildMenu()
            }
            session.onTurnLatency = { [weak self] latency in
                self?.lastTurnLatency = latency
                self?.rebuildMenu()
            }
            session.start()
            agentSession = session
            agentState = .connecting

            // Plan 6.1: the safety net only needs to watch while an
            // agent session actually exists.
            let switchInstance = DeadMansSwitch(router: router)
            switchInstance.start()
            deadMansSwitch = switchInstance
        } catch {
            Log.error("nie udało się uruchomić sesji agenta: \(error)")
            agentState = .disconnected
        }
    }

    private func stopAgentSession() {
        agentSession?.stop()
        agentSession = nil
        agentState = .disconnected
        deadMansSwitch?.stop()
        deadMansSwitch = nil
        agentIsSpeaking = false
        lastTurnLatency = nil
    }

    /// One timer feeds everything that has to keep watching while the
    /// app runs: turn state into the dead man's switch, and the
    /// "agent is speaking" indicator in the status bar.
    private func startSupervision() {
        supervisionTimer?.invalidate()
        supervisionTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.superviseTick()
        }
    }

    private func superviseTick() {
        guard let router else { return }

        // End-of-turn detection: the agent's reply has drained.
        if let session = agentSession, session.expectingAgentSpeech,
           router.agentPlaybackBuffer.framesAvailable == 0,
           Date().timeIntervalSince(session.lastAudioActivity) > 0.6 {
            session.noteAgentFinishedSpeaking()
        }

        if let session = agentSession, let dms = deadMansSwitch {
            dms.expectingAgentSpeech = session.expectingAgentSpeech
            dms.lastAudioActivity = session.lastAudioActivity
        }

        // Plan 4: seeing at a glance that something is speaking in your
        // voice matters more than any other status here.
        let speaking = router.mode == .agent && router.downlinkLevel > 0.01
        if speaking != agentIsSpeaking {
            agentIsSpeaking = speaking
            updateIcon()
        }
    }

    /// Explicit manual control, independent of the mode radio: lets you
    /// drop the WebSocket without leaving AGENT mode (and reconnect
    /// without toggling modes back and forth).
    @objc private func toggleAgentConnection() {
        if agentSession == nil {
            guard AgentSettings.isConfigured else {
                showSettingsRequiredAlert()
                return
            }
            startAgentSessionIfNeeded()
        } else {
            stopAgentSession()
        }
        rebuildMenu()
    }

    private func showSettingsRequiredAlert() {
        let alert = NSAlert()
        alert.messageText = L("alert.configure.title")
        alert.informativeText = L("alert.configure.body")
        alert.addButton(withTitle: L("alert.configure.open"))
        alert.addButton(withTitle: L("alert.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSettings()
        }
    }

    /// Wtryskuje ton prosto na fizyczne wyjście. Jeśli go nie słychać,
    /// wina leży po naszej stronie albo w urządzeniu -- co ucina całą
    /// resztę łańcucha (Teams, sterownik, Bridge) z podejrzanych.
    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func playTestTone() {
        guard let router else { return }
        router.playTestTone()
        Log.info("test dźwięku: 2 s tonu 440 Hz prosto na wyjście \(outputDeviceUID)")
    }

    /// Podręczny panel agenta: charakter + podpowiedzi na żywo.
    /// Osobno od Ustawień, bo tego dotyka się w trakcie pracy, a
    /// poświadczeń raz.
    @objc private func openAgentPanel() {
        if agentPanel == nil {
            agentPanel = HintWindowController(sessionProvider: { [weak self] in self?.agentSession })
        }
        agentPanel?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsMenuAction() {
        openSettings()
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(onSave: { [weak self] in
                // Credentials may have changed -- AGENT mode may now be
                // available, and the agent list may now be fetchable.
                self?.refreshAgentList()
                self?.rebuildMenu()
            }, onTranscriptionChange: { [weak self] in
                self?.restartTranscription()
            })
        }
        settingsWindowController?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Transkrypcja

    private func startTranscription() {
        let settings = TranscriptionSettings()
        guard settings.isEnabled else {
            transcriptionStatus = .paused
            return
        }
        guard let router else { return }
        if settings.engine == .apple, SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            // Pytamy w kontekście: dopiero gdy transkrypcja Apple ma ruszyć.
            AppleSpeechTranscriber.requestAuthorization { [weak self] _ in self?.restartTranscription() }
            return
        }
        do {
            if transcriptJournal == nil { transcriptJournal = try? Transcript() }
            let session = try TranscriptionSession(router: router, store: transcriptStore, journal: transcriptJournal) { speaker in
                try TranscriberFactory.make(speaker, settings: settings, elevenLabsKey: AgentSettings.apiKey)
            }
            session.onError = { [weak self] _, error in
                self?.transcriptionStatus = .unavailable(String(describing: error))
            }
            // Błąd bywa chwilowy (jedno zapytanie do Whispera, zerwane i
            // odnowione połączenie Scribe) -- kolejny segment znaczy, że
            // silnik znowu działa.
            session.onSegment = { [weak self] _ in
                guard let self, case .unavailable = self.transcriptionStatus else { return }
                self.transcriptionStatus = .running(settings.engine)
            }
            try session.start()
            transcriptionSession = session
            transcriptionStatus = .running(settings.engine)
        } catch {
            Log.error("transkrypcja nie wystartowała: \(error)")
            transcriptionStatus = .unavailable(String(describing: error))
        }
    }

    private func stopTranscription() {
        transcriptionSession?.stop()
        transcriptionSession = nil
    }

    private func restartTranscription() {
        stopTranscription()
        startTranscription()
    }

    func setTranscriptionPaused(_ paused: Bool) {
        TranscriptionSettings().isEnabled = !paused
        restartTranscription()
    }

    func openTranscriptionSettings() {
        openSettings()
        settingsWindowController?.show(pane: .transcription)
    }

    @objc private func openTranscriptWindow() {
        if transcriptWindow == nil {
            transcriptWindow = TranscriptWindowController(store: transcriptStore, controller: self)
        }
        transcriptWindow?.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Zapamiętywane tylko przy jawnym wyborze z menu -- domyślne
    /// systemu mają się dalej zmieniać razem z systemem.
    private static let outputDeviceKey = "outputDeviceUID"
    private static let inputDeviceKey = "inputDeviceUID"

    @objc private func selectOutputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: Self.outputDeviceKey)
        rebuildAudio(outputUID: uid, inputUID: inputDeviceUID, mode: router?.mode ?? .pass)
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        UserDefaults.standard.set(uid, forKey: Self.inputDeviceKey)
        rebuildAudio(outputUID: outputDeviceUID, inputUID: uid, mode: router?.mode ?? .pass)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Audio lifecycle

    /// Plan 2.1: changing physical devices means tearing down and
    /// recreating the aggregate (100-200ms of silence expected) --
    /// mute first so this never lands mid-sentence.
    private func rebuildAudio(outputUID: String, inputUID: String?, mode: RouterMode) {
        stopTranscription()
        router?.mode = .mute
        stopAgentSession()
        router?.stop()

        do {
            let aggID = try aggregate.create(outputDeviceUID: outputUID, inputDeviceUID: inputUID)
            let newRouter = AudioRouter(aggregateDeviceID: aggID, sampleRate: aggregate.actualSampleRate)
            newRouter.mode = mode
            try newRouter.start()
            router = newRouter
            outputDeviceUID = outputUID
            inputDeviceUID = inputUID
            status = .active
            startTranscription()
            if mode == .agent {
                startAgentSessionIfNeeded()
            }
        } catch {
            status = .error
            Log.error("nie udało się zbudować aggregate/routera: \(error)")
        }

        updateIcon()
        rebuildMenu()
    }

    private func setupHotkey() {
        guard HotkeyMonitor.hasAccessibilityPermission() else {
            HotkeyMonitor.requestAccessibilityPermission()
            return // user needs to grant it and relaunch; menu still works without the hotkey.
        }
        // Cmd+Shift+A: toggle PASS <-> AGENT (plan 6.4: must work even
        // if the WS thread is stuck -- this is a synchronous enum flip,
        // nothing here can block).
        let toggleHotkey = HotkeyMonitor.Hotkey(keyCode: 0 /* A */, modifiers: [.command, .shift])
        hotkey.register(toggleHotkey) { [weak self] in
            guard let self, let current = self.router?.mode else { return }
            let newMode: RouterMode = (current == .agent) ? .pass : .agent
            // Immediate, synchronous, non-blocking flip first (plan 6.4:
            // handback must work even if the WS thread is stuck).
            // AgentSession lifecycle + UI happen after, off this path.
            self.router?.mode = newMode
            DispatchQueue.main.async {
                if newMode == .agent {
                    self.startAgentSessionIfNeeded()
                } else {
                    self.stopAgentSession()
                }
                self.updateIcon()
                self.rebuildMenu()
            }
        }
    }
}
