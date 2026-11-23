import AppKit
import AVFoundation

struct QueryInput {
    static let previewLimit = 2_000
    let message: String
    let sent: Int

    init(preview source: String) {
        let prefix = source.prefix(Self.previewLimit)
        sent = prefix.count
        message = String(prefix) + (prefix.endIndex == source.endIndex ? "" : L("\n…（后文已截断）", "\n…(truncated)"))
    }

    init(fullSummary source: String, limit: Int) throws {
        sent = source.count
        guard sent <= limit else {
            throw AskError(L("全文超过已设置的 \(limit) 字上限。", "Full text exceeds the configured limit of \(limit) characters."))
        }
        message = source
    }
}

@MainActor
final class ResultPanel: NSPanel {
    typealias Send = (QueryInput, PromptMode, ConnectionSettings, ((String) async -> Void)?) async throws -> String
    typealias Save = (String, String, String, Int?) throws -> Void

    private let source: String
    private let total: Int
    private let send: Send
    private let save: Save
    private let modePicker = NSPopUpButton()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let fullButton = NSButton()
    private let textView = NSTextView()
    private let speaker = AVSpeechSynthesizer()
    private var sentCharacters = 0
    private var running: Task<Void, Never>?
    private var requestID = UUID()

    init(source: String, send: @escaping Send = { try await askLLM($0, mode: $1, connection: $2, onDelta: $3) }, save: @escaping Save = appendHistory) {
        self.source = source
        self.total = source.count
        self.send = send
        self.save = save
        super.init(contentRect: NSRect(x: 0, y: 0, width: 550, height: 310),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        becomesKeyOnlyIfNeeded = false
        title = String(source.prefix(40))
        for mode in PromptMode.all {
            modePicker.addItem(withTitle: mode.title)
            modePicker.lastItem?.representedObject = mode.key
        }
        modePicker.target = self
        modePicker.action = #selector(choosePanelMode)
        modePicker.setAccessibilityLabel(L("本次提问模式", "Mode for this selection"))
        fullButton.title = L("总结全文", "Summarize All")
        fullButton.target = self
        fullButton.action = #selector(summarizeAll)
        fullButton.bezelStyle = .rounded
        rangeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rangeLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [modePicker, rangeLabel, spacer, fullButton])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.font = .systemFont(ofSize: 14)
        scroll.documentView = textView
        let copy = NSButton(title: L("复制", "Copy"), target: self, action: #selector(copyAnswer))
        let speak = NSButton(title: L("朗读", "Speak"), target: self, action: #selector(speakAnswer))
        let actions = NSStackView(views: [speak, copy])
        let view = NSView()
        contentView = view
        for child in [header, scroll, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -4),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)
        ])
    }

    private func updateControls(mode: PromptMode, sent: Int, limit: Int) {
        modePicker.selectItem(withTitle: mode.title)
        sentCharacters = sent
        refreshSummaryLimit(limit)
    }

    func refreshSummaryLimit(_ limit: Int = ConnectionSettings.current().summaryLimit) {
        let sent = sentCharacters
        let mode = modePicker.selectedItem?.representedObject as? String
        rangeLabel.stringValue = L("原文 \(sent) / \(total) 字", "Source: \(sent) / \(total) characters")
        fullButton.isHidden = total <= QueryInput.previewLimit || (mode == "summarize" && sent == total)
        fullButton.isEnabled = total <= limit
        if !fullButton.isHidden && !fullButton.isEnabled {
            rangeLabel.stringValue += L("（上限 \(limit)）", " (limit \(limit))")
        }
    }

    func show(_ entry: HistoryEntry) {
        cancelRequest()
        let mode = historyMode(entry.mode)
        title = L("历史：", "History: ") + String(source.prefix(40))
        updateControls(mode: mode, sent: entry.sentCharacters ?? min(total, QueryInput.previewLimit),
                       limit: ConnectionSettings.current().summaryLimit)
        textView.string = entry.answer
    }

    @objc private func choosePanelMode() {
        guard let key = modePicker.selectedItem?.representedObject as? String,
              let mode = PromptMode.all.first(where: { $0.key == key }) else { return }
        request(mode: mode)
    }

    @objc private func summarizeAll() {
        if let mode = PromptMode.all.first(where: { $0.key == "summarize" }) { request(mode: mode, full: true) }
    }

    @discardableResult
    func request(mode: PromptMode, full: Bool = false, connection: ConnectionSettings = .current()) -> Task<Void, Never>? {
        cancelRequest()
        let input: QueryInput
        do {
            input = full ? try QueryInput(fullSummary: source, limit: connection.summaryLimit) : QueryInput(preview: source)
        } catch {
            textView.string = error.localizedDescription
            return nil
        }
        let id = requestID
        title = "\(mode.title) · \(source.prefix(40))"
        updateControls(mode: mode, sent: input.sent, limit: connection.summaryLimit)
        textView.string = L("思考中…", "Thinking…")
        running = Task {
            var partial = ""
            do {
                let answer = try await send(input, mode, connection) { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    partial = text
                    self.textView.string = text
                }
                guard requestID == id else { return }
                textView.string = answer
                // Accept completion on the main actor before handing persistence to the file lock.
                let (save, source) = (self.save, self.source)
                await Task.detached {
                    do { try save(mode.key, source, answer, input.sent) }
                    catch { NSLog("AskAI: failed to save history: \(error.localizedDescription)") }
                }.value
            } catch {
                guard requestID == id else { return }
                textView.string = partial.isEmpty ? "❌ \(error.localizedDescription)"
                    : partial + "\n\n⚠️ " + L("回答中断", "Answer interrupted") + " — " + error.localizedDescription
            }
        }
        return running
    }

    private func cancelRequest() {
        requestID = UUID()
        running?.cancel()
        running = nil
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate) }
    }

    override func close() { cancelRequest(); super.close() }
    override func cancelOperation(_ sender: Any?) { close() }

    @objc private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        NSSound.beep()
    }

    @objc private func speakAnswer() {
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate); return }
        let utterance = AVSpeechUtterance(string: textView.string)
        let hasCJK = textView.string.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
        utterance.rate = 0.5
        speaker.speak(utterance)
    }
}
