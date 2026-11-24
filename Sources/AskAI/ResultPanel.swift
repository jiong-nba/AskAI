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
final class ResultPanel: NSPanel, NSTextFieldDelegate {
    typealias Send = (QueryInput, PromptMode, ConnectionSettings, [ChatTurn], ((String) async -> Void)?, ((String) async -> Void)?) async throws -> String
    typealias Save = (String, String, String, Int?, String?) throws -> Void

    /// 追问时最多带上的最近轮数：请求体不随对话无限增长
    static let contextLimit = 8

    private let source: String
    private let total: Int
    private let send: Send
    private let save: Save
    private let pasteboard: NSPasteboard
    private let historyNotice: HistoryNotice   // 写历史时产生的提示从这里取；测试传自己的实例
    private let modePicker = NSPopUpButton()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let fullButton = NSButton()
    private let textView = NSTextView()
    private let questionField = NSTextField()
    private let sendButton = NSButton()
    private let stopOrRetryButton = NSButton()
    private let speaker = AVSpeechSynthesizer()
    private var sentCharacters = 0
    private var running: Task<Void, Never>?
    private var requestID = UUID()
    private var turns: [ChatTurn] = []                 // 这段对话里已完成的轮次，追问时作为上下文
    private var awaiting = false                       // 有请求在途（哪怕还没收到第一个字）
    private var streaming = ""                         // 在途那一轮已收到的正文（Markdown 原文）
    private var pendingQuestion: String?               // 在途那一轮是追问时的问题；对原文提问时为 nil
    private var lastRequest: (mode: PromptMode, full: Bool, question: String?)?
    private var failure: String?                       // 最近一轮出错或被停止后的状态行；有它就可以重试
    private var answerText = ""                        // 浮窗内容的 Markdown 原文（不含思考过程与状态行）：复制与朗读只用它
    private var latestReasoning = ""                   // 推理模型本次请求的思考过程（仅浮窗展示用）
    private var notice = ""                            // 正文下方的状态说明（如 history.json 被挪开重建），仅显示用

    /// 浮窗的内容区尺寸：默认 550×310；拖拽调整后记住（panelWidth/panelHeight）。
    /// 记住的尺寸放不进当前屏幕的可见区时收回来，免得整块跑到屏幕外
    static func panelSize(visible: NSRect?, defaults: UserDefaults = .standard) -> NSSize {
        panelSize(visibleWidth: visible?.width, visibleHeight: visible?.height, defaults: defaults)
    }

    static func panelSize(visibleWidth: CGFloat?, visibleHeight: CGFloat?,
                          defaults: UserDefaults = .standard) -> NSSize {
        var width = max(420, CGFloat(defaults.object(forKey: "panelWidth") as? Int ?? 550))
        var height = max(220, CGFloat(defaults.object(forKey: "panelHeight") as? Int ?? 310))
        if let visibleWidth, visibleWidth > 436 { width = min(width, visibleWidth - 16) }
        if let visibleHeight, visibleHeight > 240 { height = min(height, visibleHeight - 20) }
        return NSSize(width: width, height: height)
    }

    /// 记住用户拖出来的尺寸。存的是内容区大小，和 panelSize() 取用的口径一致：
    /// 存整窗 frame 的话，每拖一次、下次打开就多出一个标题栏的高度。
    static func rememberSize(of window: NSWindow, defaults: UserDefaults = .standard) {
        let size = window.contentRect(forFrameRect: window.frame).size
        defaults.set(Int(size.width), forKey: "panelWidth")
        defaults.set(Int(size.height), forKey: "panelHeight")
    }

    /// 窗口标题：原文前 40 字，换行换成空格（OCR 出来的多行文本会把标题撑成好几行）
    static func title(for source: String) -> String {
        let flat = source.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        return String(flat.prefix(40))
    }

    /// defaults 只用来读记住的窗口尺寸；测试传内存实现，免得碰进程的真实域。
    init(source: String, pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard,
         notice: HistoryNotice = .shared,
         send: @escaping Send = { try await askLLM($0, mode: $1, connection: $2, context: $3, onDelta: $4, onReasoning: $5) },
         save: @escaping Save = appendHistory) {
        self.source = source
        self.total = source.count
        self.send = send
        self.save = save
        self.pasteboard = pasteboard
        self.historyNotice = notice
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize(visible: NSScreen.main?.visibleFrame, defaults: defaults)),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        becomesKeyOnlyIfNeeded = false
        styleMask.insert(.resizable)   // 可拖拽调整；尺寸在 windowDidEndLiveResize 里记住
        minSize = NSSize(width: 420, height: 220)
        title = Self.title(for: source)
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

        questionField.placeholderString = L("追问…（回车发送）", "Ask a follow-up… (Return to send)")
        questionField.font = .systemFont(ofSize: 13)
        questionField.delegate = self
        questionField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        questionField.setAccessibilityLabel(L("追问", "Follow-up question"))
        sendButton.title = L("发送", "Send")
        sendButton.target = self
        sendButton.action = #selector(sendFollowUp)
        let prompt = NSStackView(views: [questionField, sendButton])

        let copy = NSButton(title: L("复制", "Copy"), target: self, action: #selector(copyAnswer))
        let speak = NSButton(title: L("朗读", "Speak"), target: self, action: #selector(speakAnswer))
        stopOrRetryButton.target = self
        stopOrRetryButton.action = #selector(stopOrRetry)
        stopOrRetryButton.isHidden = true
        let trailing = NSView()
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [speak, copy, trailing, stopOrRetryButton])

        let view = NSView()
        contentView = view
        for child in [header, scroll, prompt, actions] {
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
            scroll.bottomAnchor.constraint(equalTo: prompt.topAnchor, constant: -4),
            prompt.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            prompt.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            prompt.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -2),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
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

    /// 回看一条历史。它是对话的起点：接着追问时模型能看到它；
    /// 条目本身是追问的话，换模式重问的是同一个问题。
    func show(_ entry: HistoryEntry) {
        cancelRequest()
        let mode = historyMode(entry.mode)
        title = L("历史：", "History: ") + Self.title(for: source)
        let opening = QueryInput(preview: source + (entry.question.map { "\n\n" + $0 } ?? ""))
        updateControls(mode: mode, sent: entry.sentCharacters ?? opening.sent,
                       limit: ConnectionSettings.current().summaryLimit)
        turns = [ChatTurn(question: entry.question ?? opening.message, answer: entry.answer,
                          message: opening.message, isFollowUp: entry.question != nil)]
        lastRequest = (mode, entry.sentCharacters == total, entry.question)
        awaiting = false
        streaming = ""
        pendingQuestion = nil
        failure = nil
        notice = ""
        render()
    }

    @objc private func choosePanelMode() {
        guard let key = modePicker.selectedItem?.representedObject as? String,
              let mode = PromptMode.all.first(where: { $0.key == key }) else { return }
        // 换模式是重新问开头那一个问题：接着之前的追问往下聊没有意义
        request(mode: mode, full: lastRequest?.full ?? false, question: lastRequest?.question)
    }

    @objc private func summarizeAll() {
        if let mode = PromptMode.all.first(where: { $0.key == "summarize" }) { request(mode: mode, full: true) }
    }

    /// question 为 nil：对原文提问，从头开始一段对话。否则是追问，之前的轮次作为上下文；
    /// 唯一的例外是回看带追问的历史条目时换模式重问——那时没有前文，把原文和问题合成一条消息。
    @discardableResult
    func request(connection: ConnectionSettings = .current(), mode: PromptMode, full: Bool = false,
                 question: String? = nil) -> Task<Void, Never>? {
        cancelRequest()
        failure = nil
        let input: QueryInput
        if let question {
            input = QueryInput(preview: turns.isEmpty ? source + "\n\n" + question : question)
        } else {
            do {
                input = full ? try QueryInput(fullSummary: source, limit: connection.summaryLimit) : QueryInput(preview: source)
            } catch {
                turns = []
                streaming = ""
                awaiting = false
                pendingQuestion = nil
                render(status: "❌ " + error.localizedDescription)
                return nil
            }
            turns = []
        }
        let id = requestID
        lastRequest = (mode, full, question)
        pendingQuestion = question
        title = "\(mode.title) · \(Self.title(for: source))"
        if question == nil {
            updateControls(mode: mode, sent: input.sent, limit: connection.summaryLimit)
        } else {
            // 追问不改「原文 N / M 字」：那是在说原文，不是在说这个问题
            modePicker.selectItem(withTitle: mode.title)
        }
        awaiting = true
        streaming = ""
        latestReasoning = ""
        notice = ""
        let context = Array(turns.suffix(Self.contextLimit))
        render()
        running = Task {
            do {
                let answer = try await send(input, mode, connection, context,
                                            { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    self.streaming = text
                    self.render()
                }, { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    self.latestReasoning = text
                    self.render()
                })
                guard requestID == id else { return }
                turns.append(ChatTurn(question: question ?? input.message, answer: answer,
                                      message: input.message, isFollowUp: question != nil))
                awaiting = false
                streaming = ""
                pendingQuestion = nil
                render()
                // Accept completion on the main actor before handing persistence to the file lock.
                let (save, source, notices) = (self.save, self.source, historyNotice)
                let savedQuestion = question
                await Task.detached {
                    do { try save(mode.key, source, answer, savedQuestion == nil ? input.sent : nil, savedQuestion) }
                    catch { NSLog("AskAI: failed to save history: \(error.localizedDescription)") }
                }.value
                // 写历史时发现 history.json 读不出来并已挪开重建：在正文下方说明
                guard requestID == id, let message = notices.take() else { return }
                notice = message
                render()
            } catch {
                guard requestID == id else { return }
                awaiting = false
                render(status: streaming.isEmpty ? "❌ \(error.localizedDescription)"
                    : "⚠️ " + L("回答中断", "Answer interrupted") + " — " + error.localizedDescription)
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

    /// 停止生成：已经收到的正文留在屏幕上，可以重试。
    func stopStreaming() {
        guard awaiting else { return }
        cancelRequest()   // requestID 换新之后，后台任务的收尾不会再碰界面
        awaiting = false
        render(status: "⏹ " + L("已停止生成", "Generation stopped"))
    }

    /// 在途（或被停止）的那一轮；没有就是 nil。
    private var pendingTurn: ChatTurn? {
        guard awaiting || !streaming.isEmpty else { return nil }
        return ChatTurn(question: pendingQuestion ?? "", answer: streaming, message: "", isFollowUp: pendingQuestion != nil)
    }

    /// 浮窗正文的 Markdown 原文：已完成的轮次加上在途的那一轮，用分隔线隔开；
    /// 追问的轮次先列出问题。status 是最后一轮下方的一行说明（出错、被停止）。
    static func transcript(turns: [ChatTurn], pending: ChatTurn?, status: String?) -> String {
        var parts = turns.map { body(of: $0) }
        if let pending { parts.append(body(of: pending, whileEmpty: L("思考中…", "Thinking…"))) }
        if let status {
            if parts.isEmpty { parts = [status] } else { parts[parts.count - 1] += "\n\n" + status }
        }
        return parts.joined(separator: "\n\n————\n\n")
    }

    private static func body(of turn: ChatTurn, whileEmpty: String = "") -> String {
        let text = turn.answer.isEmpty ? whileEmpty : turn.answer
        return turn.isFollowUp ? "❓ " + turn.question + "\n\n" + text : text
    }

    /// 把当前对话画到正文里，思考过程拼在最上方、状态行拼在最下方（都只在屏幕上，不进复制与朗读）。
    /// 用户停在底部（或还没滚过）时跟随新内容滚动；翻上去看前文时不再强行拉回。
    private func render(status: String? = nil) {
        if let status { failure = status }
        answerText = Self.transcript(turns: turns, pending: pendingTurn, status: nil)
        var shown = Self.transcript(turns: turns, pending: pendingTurn, status: failure)
        if !latestReasoning.isEmpty {
            shown = L("💭 思考过程", "💭 Reasoning") + "\n" + latestReasoning + "\n\n————\n\n" + shown
        }
        if !notice.isEmpty { shown += "\n\n⚠️ " + notice }
        let atBottom = textView.visibleRect.maxY >= textView.bounds.height - 48
        textView.textStorage?.setAttributedString(
            Self.renderedAnswer(shown, baseFont: textView.font ?? .systemFont(ofSize: 14)))
        if atBottom { textView.scrollToEndOfDocument(nil) }
        stopOrRetryButton.isHidden = !awaiting && failure == nil
        stopOrRetryButton.title = awaiting ? L("停止", "Stop") : L("重试", "Retry")
        questionField.isEnabled = !awaiting
        sendButton.isEnabled = !awaiting
    }

    /// 回答的富文本：围栏代码块用等宽字体和浅底色，其余部分按行内 Markdown 渲染。
    static func renderedAnswer(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in splitCodeBlocks(text) {
            if segment.isCode {
                result.append(codeBlock(segment.text, baseFont: baseFont))
            } else {
                result.append(renderedInline(segment.text, baseFont: baseFont))
            }
        }
        return result
    }

    /// 把回答切成「普通段落」和「围栏代码块」。围栏行本身不显示，它占的那一处换行保留，
    /// 所以其余各行的位置不变。流式输出时代码块常常还没闭合：从开头的围栏到文末都算代码；
    /// 每次都按全文重新切分，闭合之后自然恢复。
    static func splitCodeBlocks(_ text: String) -> [(text: String, isCode: Bool)] {
        guard !text.isEmpty else { return [] }
        var segments: [(text: String, isCode: Bool)] = []
        var lines: [String] = []
        var inCode = false
        func close() {
            guard !lines.isEmpty else { return }
            segments.append((lines.joined(separator: "\n"), inCode))
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                lines.append("")   // keep the line break the fence occupied
                close()
                inCode.toggle()
            } else {
                lines.append(String(line))
            }
        }
        close()
        return segments
    }

    /// 代码块：等宽字体、原样保留，不做 Markdown 解析（代码里的 * 和 _ 不该被当成语法）。
    /// 底色不画在结尾的换行上，免得代码块下面多出一条空的高亮带。
    private static func codeBlock(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        let highlighted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor,
                                                          .backgroundColor: NSColor.unemphasizedSelectedContentBackgroundColor]
        let result = NSMutableAttributedString()
        if text.hasSuffix("\n") {
            result.append(NSAttributedString(string: String(text.dropLast()), attributes: highlighted))
            result.append(NSAttributedString(string: "\n", attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        } else {
            result.append(NSAttributedString(string: text, attributes: highlighted))
        }
        return result
    }

    /// 行内 Markdown 渲染：粗体 / 斜体 / 行内代码 / 链接，保留原有换行——
    /// 聊天式回答不适合块级语法的段落重排；解析失败回落纯文本。
    static func renderedInline(_ text: String, baseFont: NSFont) -> NSAttributedString {
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
            if intent.contains(.emphasized) {           // *斜体**
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

    /// 朗读用的纯文本：围栏代码块的围栏行整行跳过，其余去掉行内 Markdown 符号（链接只保留文字）；
    /// 解析失败就按原文朗读。
    static func speechText(_ markdown: String) -> String {
        let spoken = markdown.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: spoken, options: options) else { return spoken }
        return String(parsed.characters)
    }

    /// 面板出现在鼠标附近时的原点，clamp 在所在屏幕可见区内（纯函数，便于测试）
    static func nearMouseOrigin(mouse: NSPoint, panelSize: NSSize, visible: NSRect) -> NSPoint {
        // 偏右下方，不挡住光标；贴边时收回可见区内
        var origin = NSPoint(x: mouse.x + 20, y: mouse.y - panelSize.height * 0.4)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panelSize.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - panelSize.height - 8)
        return origin
    }

    /// 划词的结果应靠近触发点弹出，而不是每次都回到屏幕正中。
    /// 鼠标位置和屏幕列表可以传入，测试不必依赖真实的鼠标在哪块屏上。
    func showNearMouse(at mouse: NSPoint = NSEvent.mouseLocation, screens: [NSScreen] = NSScreen.screens) {
        let screen = screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { center(); return }
        // 面板是按主屏尺寸创建的；鼠标在更小的那块屏上时，先把它收进那块屏的可见区
        setContentSize(Self.panelSize(visible: visible))
        setFrameOrigin(Self.nearMouseOrigin(mouse: mouse, panelSize: frame.size, visible: visible))
    }

    override func close() { cancelRequest(); super.close() }
    override func cancelOperation(_ sender: Any?) { close() }

    /// ⌘C 复制回答：窗口显示时即成为 key window，无需先点按钮。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if Self.commandCCopiesTheAnswer(modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers,
                                        answerSelection: textView.selectedRange().length,
                                        fieldSelection: questionField.currentEditor()?.selectedRange.length ?? 0) {
            copyAnswer()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘C 是否由浮窗接管（复制整段对话）。正文里或追问输入框里已经选中了文字的话，
    /// 放行给系统，复制的是选区。
    static func commandCCopiesTheAnswer(modifiers: NSEvent.ModifierFlags, characters: String?,
                                        answerSelection: Int, fieldSelection: Int) -> Bool {
        // 只看四个修饰键：Caps Lock、Fn 这类状态不该让 ⌘C 失效
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        return flags == .command && characters?.lowercased() == "c" && answerSelection == 0 && fieldSelection == 0
    }

    /// 追问输入框里的回车就是发送。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        sendFollowUp()
        return true
    }

    @objc private func sendFollowUp() {
        let question = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !awaiting, let last = lastRequest else { return }
        questionField.stringValue = ""
        request(mode: last.mode, full: false, question: question)
    }

    @objc private func stopOrRetry() {
        guard let last = lastRequest else { return }
        if awaiting {
            stopStreaming()
        } else {
            request(mode: last.mode, full: last.full, question: last.question)
        }
    }

    /// 复制整段对话的 Markdown 原文：粘贴到别处保留语法，不带思考过程和状态行。
    @objc private func copyAnswer() {
        pasteboard.clearContents()
        pasteboard.setString(answerText, forType: .string)
        NSSound.beep()
    }

    /// 朗读各轮回答（不读问题和分隔线），去掉行内 Markdown 符号。
    @objc private func speakAnswer() {
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate); return }
        let answers = (turns + [pendingTurn].compactMap { $0 }).map(\.answer).filter { !$0.isEmpty }
        let text = Self.speechText(answers.joined(separator: "\n\n"))
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
        utterance.rate = 0.5
        speaker.speak(utterance)
    }
}
