import AppKit

enum TranscriptionStatus: Equatable {
    case running(TranscriberEngine)
    case paused
    case unavailable(String)
}

protocol TranscriptionControlling: AnyObject {
    var transcriptionStatus: TranscriptionStatus { get }
    func setTranscriptionPaused(_ paused: Bool)
    func openTranscriptionSettings()
}

enum AutoScrollPolicy {
    static func shouldFollow(visibleMaxY: CGFloat, documentHeight: CGFloat, tolerance: CGFloat = 24) -> Bool {
        documentHeight - visibleMaxY <= tolerance
    }
}

/// Okno transkryptora: akapity rozmowy w tabeli (treść, bez szkła) i
/// szklany pasek sterowania nad nią. Pływa nad komunikatorem, działa w
/// każdym trybie. Notatki agentów i przełączniki dochodzą w podprojekcie 3.
final class TranscriptWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: TranscriptStore
    private weak var controller: TranscriptionControlling?
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let pauseButton = NSButton()
    private let emptyLabel = NSTextField(labelWithString: "")
    private static let barHeight: CGFloat = 44
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(store: TranscriptStore, controller: TranscriptionControlling) {
        self.store = store
        self.controller = controller
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = L("transcript.title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 360, height: 300)
        panel.setFrameAutosaveName("TranscriptWindow")
        super.init(window: panel)
        buildUI()
        store.onChange = { [weak self] change in self?.apply(change) }
        statusDidChange()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    func show() {
        tableView.reloadData()
        updateEmptyState()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        scrollToBottom()
    }

    // MARK: - Budowa

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let column = NSTableColumn(identifier: .init("paragraph"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.selectionHighlightStyle = .none
        tableView.intercellSpacing = NSSize(width: 0, height: 10)
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel(L("transcript.title"))

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        // Treść przewija się POD szklanym paskiem.
        scrollView.contentInsets = NSEdgeInsets(top: Self.barHeight + 36, left: 0, bottom: 12, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(emptyLabel)

        statusDot.symbolConfiguration = .init(pointSize: 9, weight: .regular)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        pauseButton.bezelStyle = .accessoryBarAction
        pauseButton.isBordered = false
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        let settingsButton = NSButton(image: NSImage(systemSymbolName: "slider.horizontal.3",
                                                     accessibilityDescription: L("transcript.settings"))!,
                                      target: self, action: #selector(openSettings))
        settingsButton.isBordered = false
        settingsButton.toolTip = L("transcript.settings")

        let barContent = NSStackView(views: [statusDot, statusLabel, NSView(), pauseButton, settingsButton])
        barContent.orientation = .horizontal
        barContent.spacing = 8
        barContent.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = makeGlass(around: barContent, cornerRadius: Self.barHeight / 2)
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
    }

    // MARK: - Stan

    func statusDidChange() {
        let status = controller?.transcriptionStatus ?? .paused
        let (symbol, color, text, paused): (String, NSColor, String, Bool)
        switch status {
        case .running(let engine):
            (symbol, color, text, paused) = ("circle.fill", .systemGreen, L("transcript.status.running", engine.privacyNote), false)
        case .paused:
            (symbol, color, text, paused) = ("pause.circle.fill", .secondaryLabelColor, L("transcript.status.paused"), true)
        case .unavailable(let reason):
            (symbol, color, text, paused) = ("exclamationmark.triangle.fill", .systemOrange, reason, false)
        }
        statusDot.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusDot.contentTintColor = color
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        let title = paused ? L("transcript.resume") : L("transcript.pause")
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill", accessibilityDescription: title)
        pauseButton.toolTip = title
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !store.paragraphs.isEmpty
        if case .paused = controller?.transcriptionStatus {
            emptyLabel.stringValue = L("transcript.empty.paused")
        } else {
            emptyLabel.stringValue = L("transcript.empty.listening")
        }
    }

    @objc private func togglePause() {
        let paused: Bool
        if case .paused = controller?.transcriptionStatus { paused = false } else { paused = true }
        controller?.setTranscriptionPaused(paused)
    }

    @objc private func openSettings() {
        controller?.openTranscriptionSettings()
    }

    // MARK: - Zmiany magazynu

    private func apply(_ change: TranscriptStore.Change) {
        guard window?.isVisible == true else { return } // odświeżamy przy show()
        let clip = scrollView.contentView
        let follow = AutoScrollPolicy.shouldFollow(visibleMaxY: clip.bounds.maxY,
                                                   documentHeight: tableView.frame.height)
        switch change {
        case .appended:
            tableView.insertRows(at: IndexSet(integer: store.paragraphs.count - 1), withAnimation: .effectFade)
        case .updated(let id):
            if let row = store.paragraphs.firstIndex(where: { $0.id == id }) {
                tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
            }
        case .removed(let ids):
            tableView.removeRows(at: IndexSet(integersIn: 0..<ids.count), withAnimation: [])
        }
        updateEmptyState()
        if follow { scrollToBottom() }
    }

    private func scrollToBottom() {
        guard !store.paragraphs.isEmpty else { return }
        tableView.scrollRowToVisible(store.paragraphs.count - 1)
    }

    // MARK: - Tabela

    func numberOfRows(in tableView: NSTableView) -> Int { store.paragraphs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let paragraph = store.paragraphs[row]
        let cell = (tableView.makeView(withIdentifier: ParagraphCell.identifier, owner: nil) as? ParagraphCell) ?? ParagraphCell()
        let speaker = paragraph.speaker == .me ? L("speaker.me") : L("speaker.caller")
        cell.configure(header: "\(timeFormatter.string(from: paragraph.start)) · \(speaker)",
                       text: store.text(of: paragraph.id),
                       isPartial: store.hasPartial(in: paragraph.id),
                       isMe: paragraph.speaker == .me)
        return cell
    }
}

/// Akapit: godzina i mówca małą czcionką, tekst w rozmiarze systemowym.
/// Tekst jeszcze rozpoznawany (partial) w kolorze drugorzędnym.
private final class ParagraphCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ParagraphCell")
    private let header = NSTextField(labelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        header.textColor = .secondaryLabelColor
        body.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) nieużywane") }

    func configure(header headerText: String, text: String, isPartial: Bool, isMe: Bool) {
        header.stringValue = headerText
        body.stringValue = text
        body.textColor = isPartial ? .secondaryLabelColor : .labelColor
        setAccessibilityLabel("\(headerText): \(text)")
    }
}
