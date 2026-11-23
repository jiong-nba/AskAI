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
    typealias Send = (QueryInput, PromptMode, ConnectionSettings, ((String) async -> Void)?, ((String) async -> Void)?) async throws -> String
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
    private var spokenText = ""   // 未渲染的纯文本，供 TTS 使用（避免朗读 markdown 符号）
    private var latestReasoning = ""   // 推理模型本次请求的思考过程（仅浮窗展示用）

    /// 浮窗尺寸：默认 550×310；拖拽调整后记住（panelWidth/panelHeight），换小屏时按可见高度兜底
    static func panelSize(screenHeight: CGFloat? = NSScreen.main?.visibleFrame.height,
                          defaults: UserDefaults = .standard) -> NSSize {
        let width = max(420, CGFloat(defaults.object(forKey: "panelWidth") as? Int ?? 550))
        var height = max(220, CGFloat(defaults.object(forKey: "panelHeight") as? Int ?? 310))
        if let screenHeight, screenHeight > 240 { height = min(height, screenHeight - 20) }
        return NSSize(width: width, height: height)
    }

    init(source: String, send: @escaping Send = { try await askLLM($0, mode: $1, connection: $2, onDelta: $3, onReasoning: $4) }, save: @escaping Save = appendHistory) {
        self.source = source
        self.total = source.count
        self.send = send
        self.save = save
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize()),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        becomesKeyOnlyIfNeeded = false
        styleMask.insert(.resizable)   // 可拖拽调整；尺寸在 windowDidEndLiveResize 里记住
        minSize = NSSize(width: 420, height: 220)
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
        textView.textColor = .textColor        // 同样是动态色，避免深色模式下黑字黑底
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
        setAnswer(entry.answer)
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
            setAnswer(error.localizedDescription)
            return nil
        }
        let id = requestID
        title = "\(mode.title) · \(source.prefix(40))"
        updateControls(mode: mode, sent: input.sent, limit: connection.summaryLimit)
        setAnswer(L("思考中…", "Thinking…"))
        latestReasoning = ""
        running = Task {
            var partial = ""
            do {
                let answer = try await send(input, mode, connection,
                                            { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    partial = text
                    self.setAnswer(self.displayed(text))
                }, { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    self.latestReasoning = text
                    self.setAnswer(self.displayed(partial))
                })
                guard requestID == id else { return }
                setAnswer(displayed(answer))
                // Accept completion on the main actor before handing persistence to the file lock.
                let (save, source) = (self.save, self.source)
                await Task.detached {
                    do { try save(mode.key, source, answer, input.sent) }
                    catch { NSLog("AskAI: failed to save history: \(error.localizedDescription)") }
                }.value
            } catch {
                guard requestID == id else { return }
                setAnswer(partial.isEmpty ? "❌ \(error.localizedDescription)"
                    : displayed(partial) + "\n\n⚠️ " + L("回答中断", "Answer interrupted") + " — " + error.localizedDescription)
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

    /// 思考过程只影响浮窗显示（拼在正文上方）；历史保存与命令行输出仍只用正文
    private func displayed(_ content: String) -> String {
        guard !latestReasoning.isEmpty else { return content }
        return L("💭 思考过程", "💭 Reasoning") + "\n" + latestReasoning + "\n\n————\n\n" + content
    }

    /// 行内 Markdown 渲染：粗体 / 斜体 / 行内代码 / 链接，保留原有换行——
    /// 聊天式回答不适合块级语法的段落重排；解析失败回落纯文本。
    static func renderedAnswer(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text,
                                      attributes: [.font: baseFont,
                                                   .foregroundColor: NSColor.textColor])
        }
        // 解析结果不带字体（转 NSAttributedString 也不会自动把 .strong 变粗体），
        // 按行内语义逐 run 套字体；无语义的片段拿基础字体，避免掉回系统默认字号
        let runs = parsed.runs.map { (range: $0.range, intent: $0.inlinePresentationIntent ?? []) }
        for (range, intent) in runs {
            var font = baseFont
            if intent.contains(.stronglyEmphasized) {   // **粗体**
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {           // *斜体*
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            }
            parsed[range].font = font
            // 富文本缺省不带前景色时 NSTextView 会按黑色渲染，深色模式下变成黑字黑底；
            // 显式给系统动态文字色，随明暗外观自动切换
            parsed[range].foregroundColor = .textColor
        }
        return NSAttributedString(parsed)
    }

    /// 更新答案文本。用户停在底部（或还没滚过）时跟随新内容滚动；
    /// 翻上去看前文时不再强行拉回。
    private func setAnswer(_ text: String) {
        let atBottom = textView.visibleRect.maxY >= textView.bounds.height - 48
        spokenText = text
        textView.textStorage?.setAttributedString(
            Self.renderedAnswer(text, baseFont: textView.font ?? .systemFont(ofSize: 14)))
        if atBottom { textView.scrollToEndOfDocument(nil) }
    }

    /// 面板出现在鼠标附近时的原点，clamp 在所在屏幕可见区内（纯函数，便于测试）
    static func nearMouseOrigin(mouse: NSPoint, panelSize: NSSize, visible: NSRect) -> NSPoint {
        // 偏右下方，不挡住光标；贴边时收回可见区内
        var origin = NSPoint(x: mouse.x + 20, y: mouse.y - panelSize.height * 0.4)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        return origin
    }

    /// 划词的结果应靠近触发点弹出，而不是每次都回到屏幕正中
    func showNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { center(); return }
        setFrameOrigin(Self.nearMouseOrigin(mouse: mouse, panelSize: frame.size, visible: visible))
    }

    override func close() { cancelRequest(); super.close() }
    override func cancelOperation(_ sender: Any?) { close() }

    /// ⌘C 复制回答：窗口显示时即成为 key window，无需先点按钮。
    /// 若用户已用鼠标选中了部分文字，则放行给系统，复制的是选区。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           textView.selectedRange().length == 0 {
            copyAnswer()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc private func copyAnswer() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
        NSSound.beep()
    }

    @objc private func speakAnswer() {
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate); return }
        let utterance = AVSpeechUtterance(string: spokenText)
        let hasCJK = spokenText.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
        utterance.rate = 0.5
        speaker.speak(utterance)
    }
}
