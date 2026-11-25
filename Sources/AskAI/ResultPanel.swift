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
final class ResultPanel: NSPanel, NSTextFieldDelegate, NSTextViewDelegate, AVSpeechSynthesizerDelegate {
    typealias Send = (QueryInput, PromptMode, ConnectionSettings, [ChatTurn], StreamCallback?, StreamCallback?) async throws -> String
    /// 保存历史要等文件锁，放在后台任务里执行，所以必须是 Sendable 闭包。
    typealias Save = @Sendable (String, String, String, Int?, String?) throws -> Void

    /// 追问时最多带上的最近轮数：请求体不随对话无限增长
    static let contextLimit = 8
    static let defaultFontSize: CGFloat = 14
    static let minFontSize: CGFloat = 11
    static let maxFontSize: CGFloat = 22
    private static let toggleReasoningURL = URL(string: "askai://toggle-reasoning")!

    static func storedFontSize(defaults: UserDefaults = .standard) -> CGFloat {
        guard let raw = defaults.object(forKey: "panelFontSize") as? NSNumber else { return defaultFontSize }
        return min(max(CGFloat(raw.doubleValue), minFontSize), maxFontSize)
    }

    private let source: String
    private let total: Int
    private let send: Send
    private let save: Save
    private let pasteboard: NSPasteboard
    private let historyNotice: HistoryNotice   // 写历史时产生的提示从这里取；测试传自己的实例
    private let defaults: UserDefaults         // 读自定义模式；和上面几个一样是为了测试可注入
    private let modePicker = NSPopUpButton()
    private let rangeLabel = NSTextField(labelWithString: "")
    private let fullButton = NSButton()
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let questionField = NSTextField()
    private let sendButton = NSButton()
    private let copyButton = NSButton()
    private let speakButton = NSButton()
    private let stopOrRetryButton = NSButton()
    private let speaker = AVSpeechSynthesizer()
    private var sentCharacters = 0
    private var running: Task<Void, Never>?
    private var renderScheduled: Task<Void, Never>?
    private var copyFeedback: Task<Void, Never>?
    private var lastStreamRender: ContinuousClock.Instant?
    private var requestID = UUID()
    private var turns: [ChatTurn] = []                 // 这段对话里已完成的轮次，追问时作为上下文
    private var cachedTurns: [ChatTurn] = []
    private var cachedTurnsFontSize: CGFloat = 0
    private var cachedTurnsRendered = NSAttributedString()
    private var awaiting = false                       // 有请求在途（哪怕还没收到第一个字）
    private var streaming = ""                         // 在途那一轮已收到的正文（Markdown 原文）
    private var pendingQuestion: String?               // 在途那一轮是追问时的问题；对原文提问时为 nil
    private var lastRequest: (mode: PromptMode, full: Bool, question: String?)?
    private var failure: String?                       // 最近一轮出错或被停止后的状态行；有它就可以重试
    private var answerText = ""                        // 浮窗内容的 Markdown 原文（不含思考过程与状态行）：复制与朗读只用它
    private var latestReasoning = ""                   // 推理模型本次请求的思考过程（仅浮窗展示用）
    private(set) var isReasoningCollapsed = false
    private var fontSize: CGFloat
    private var effectiveSource: String
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

    /// 窗口标题最大长度（不含省略号）：兼顾中英文宽度，避免顶到标题栏边缘或生硬断在半个词上
    static let titleLimit = 28

    /// 窗口标题：原文摘要（压平换行、去首尾空白），超出上限时截断并加省略号
    static func title(for source: String) -> String {
        let flat = source.flattenedLine
        guard flat.count > titleLimit else { return flat }
        return String(flat.prefix(titleLimit)) + "…"
    }

    /// defaults 只用来读记住的窗口尺寸；测试传内存实现，免得碰进程的真实域。
    init(source: String, pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard,
         notice: HistoryNotice = .shared,
         send: @escaping Send = { try await askLLM($0, mode: $1, connection: $2, context: $3, onDelta: $4, onReasoning: $5) },
         save: @escaping Save = { try appendHistory(mode: $0, source: $1, answer: $2, sentCharacters: $3, question: $4) }) {
        self.source = source
        self.total = source.count
        self.send = send
        self.save = save
        self.pasteboard = pasteboard
        self.historyNotice = notice
        self.defaults = defaults
        self.fontSize = Self.storedFontSize(defaults: defaults)
        self.effectiveSource = source
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize(visible: NSScreen.main?.visibleFrame, defaults: defaults)),
                   styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        becomesKeyOnlyIfNeeded = false
        styleMask.insert(.resizable)   // 可拖拽调整；尺寸在 windowDidEndLiveResize 里记住
        standardWindowButton(.zoomButton)?.isEnabled = false   // 浮窗不需要全屏/最大化按钮
        minSize = NSSize(width: 420, height: 220)
        title = Self.title(for: source)
        speaker.delegate = self
        refreshModes()
        modePicker.target = self
        modePicker.action = #selector(choosePanelMode)
        modePicker.setAccessibilityLabel(L("本次提问模式", "Mode for this selection"))
        fullButton.title = L("总结全文", "Summarize All")
        fullButton.controlSize = .small
        fullButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        fullButton.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)
        fullButton.imagePosition = .imageLeading
        fullButton.target = self
        fullButton.action = #selector(summarizeAll)
        fullButton.bezelStyle = .rounded
        rangeLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        rangeLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [modePicker, rangeLabel, spacer, fullButton])
        header.alignment = .centerY
        header.spacing = 8

        let topSeparator = NSBox()
        topSeparator.boxType = .separator

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        textView.textContainer?.replaceLayoutManager(CodeBlockLayoutManager())
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 14, height: 10)
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.textColor = .textColor        // 同样是动态色，避免深色模式下黑字黑底
        scroll.documentView = textView

        let bottomSeparator = NSBox()
        bottomSeparator.boxType = .separator

        questionField.placeholderString = L("追问…（回车发送）", "Ask a follow-up… (Return to send)")
        questionField.bezelStyle = .roundedBezel
        questionField.font = .systemFont(ofSize: 13)
        questionField.delegate = self
        questionField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        questionField.setAccessibilityLabel(L("追问", "Follow-up question"))
        sendButton.title = L("发送", "Send")
        sendButton.image = NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)
        sendButton.imagePosition = .imageOnly
        sendButton.bezelStyle = .rounded
        sendButton.toolTip = L("发送（回车）", "Send (Return)")
        sendButton.target = self
        sendButton.action = #selector(sendFollowUp)
        let prompt = NSStackView(views: [questionField, sendButton])
        prompt.spacing = 6

        for button in [speakButton, copyButton, stopOrRetryButton] {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.imagePosition = .imageLeading
            button.bezelStyle = .recessed
        }
        setCopyButton(copied: false)
        copyButton.target = self
        copyButton.action = #selector(copyAnswer)
        setSpeakButton(speaking: false)
        speakButton.target = self
        speakButton.action = #selector(speakAnswer)
        stopOrRetryButton.target = self
        stopOrRetryButton.action = #selector(stopOrRetry)
        stopOrRetryButton.isHidden = true
        let trailing = NSView()
        trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [speakButton, copyButton, trailing, stopOrRetryButton])

        let view = NSView()
        contentView = view
        for child in [header, topSeparator, scroll, bottomSeparator, prompt, actions] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            topSeparator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            topSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomSeparator.topAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            prompt.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor, constant: 8),
            prompt.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            prompt.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            actions.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 6),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            actions.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }

    /// 重建模式下拉列表（自定义模式增删改后同步），尽量保持之前选中的模式 key。
    func refreshModes(selecting key: String? = nil) {
        let targetKey = key ?? (modePicker.selectedItem?.representedObject as? String)
        modePicker.removeAllItems()
        for mode in PromptMode.all(defaults: defaults) {
            modePicker.addItem(withTitle: mode.title)
            modePicker.lastItem?.representedObject = mode.key
        }
        if let targetKey { selectMode(key: targetKey) }
    }

    private func selectMode(key: String) {
        if let index = modePicker.itemArray.firstIndex(where: { ($0.representedObject as? String) == key }) {
            modePicker.selectItem(at: index)
        }
    }

    private func updateControls(mode: PromptMode, sent: Int, limit: Int) {
        selectMode(key: mode.key)
        sentCharacters = sent
        refreshSummaryLimit(limit)
    }

    func refreshSummaryLimit(_ limit: Int? = nil) {
        if source.isEmpty {
            rangeLabel.isHidden = true
            fullButton.isHidden = true
            return
        }
        rangeLabel.isHidden = false
        let effectiveLimit = limit ?? ConnectionSettings.current(defaults: defaults).summaryLimit
        let sent = sentCharacters
        let mode = modePicker.selectedItem?.representedObject as? String
        rangeLabel.stringValue = L("原文 \(sent) / \(total) 字", "Source: \(sent) / \(total) characters")
        fullButton.isHidden = total <= QueryInput.previewLimit || (mode == "summarize" && sent == total)
        fullButton.isEnabled = total <= effectiveLimit
        if !fullButton.isHidden && !fullButton.isEnabled {
            rangeLabel.stringValue += L("（上限 \(effectiveLimit)）", " (limit \(effectiveLimit))")
        }
    }

    func prepareForDirectQuestion(mode: PromptMode) {
        cancelRequest()
        selectMode(key: mode.key)
        effectiveSource = ""
        title = L("直接提问", "Ask Directly")
        turns = []
        streaming = ""
        latestReasoning = ""
        isReasoningCollapsed = false
        pendingQuestion = nil
        failure = nil
        notice = ""
        awaiting = false
        lastRequest = (mode, false, nil)
        refreshSummaryLimit()
        render()
        focusQuestionField()
    }

    /// 回看一条历史。它是对话的起点：接着追问时模型能看到它；
    /// 条目本身是追问的话，换模式重问的是同一个问题。
    func show(_ entry: HistoryEntry) {
        cancelRequest()
        let mode = historyMode(entry.mode, defaults: defaults)
        title = L("历史：", "History: ") + Self.title(for: source)
        let opening = QueryInput(preview: source + (entry.question.map { "\n\n" + $0 } ?? ""))
        updateControls(mode: mode, sent: entry.sentCharacters ?? opening.sent,
                       limit: ConnectionSettings.current(defaults: defaults).summaryLimit)
        turns = [ChatTurn(question: entry.question ?? opening.message, answer: entry.answer,
                          message: opening.message, isFollowUp: entry.question != nil)]
        lastRequest = (mode, entry.sentCharacters == total, entry.question)
        isReasoningCollapsed = false
        awaiting = false
        streaming = ""
        pendingQuestion = nil
        failure = nil
        notice = ""
        render()
        focusQuestionField()
    }

    @objc private func choosePanelMode() {
        guard let key = modePicker.selectedItem?.representedObject as? String,
              let mode = PromptMode.all(defaults: defaults).first(where: { $0.key == key }) else { return }
        if source.isEmpty, turns.isEmpty, lastRequest?.question == nil {
            lastRequest = (mode, false, nil)
            focusQuestionField()
            return
        }
        // 换模式是重新问开头那一个问题：接着之前的追问往下聊没有意义
        let initialQuestion = source.isEmpty ? (turns.first?.question ?? lastRequest?.question) : lastRequest?.question
        if source.isEmpty { turns = [] }
        request(mode: mode, full: lastRequest?.full ?? false, question: initialQuestion)
    }

    @objc private func summarizeAll() {
        if let mode = PromptMode.builtin.first(where: { $0.key == "summarize" }) { request(mode: mode, full: true) }
    }

    /// question 为 nil：对原文提问，从头开始一段对话。否则是追问，之前的轮次作为上下文；
    /// 唯一的例外是回看带追问的历史条目时换模式重问——那时没有前文，把原文和问题合成一条消息。
    @discardableResult
    func request(connection: ConnectionSettings = .current(), mode: PromptMode, full: Bool = false,
                 question: String? = nil) -> Task<Void, Never>? {
        cancelRequest()
        failure = nil
        let input: QueryInput
        let startedEmptyDirect = source.isEmpty && turns.isEmpty
        if let question {
            let promptText = (turns.isEmpty && !source.isEmpty) ? source + "\n\n" + question : question
            input = QueryInput(preview: promptText)
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
        if source.isEmpty, let question {
            if startedEmptyDirect { effectiveSource = question }
            title = Self.title(for: effectiveSource)
        } else {
            title = Self.title(for: source)
        }
        if question == nil {
            updateControls(mode: mode, sent: input.sent, limit: connection.summaryLimit)
        } else {
            // 追问不改「原文 N / M 字」：那是在说原文，不是在说这个问题
            selectMode(key: mode.key)
        }
        awaiting = true
        streaming = ""
        latestReasoning = ""
        isReasoningCollapsed = false
        notice = ""
        lastStreamRender = nil
        let context = Array(turns.suffix(Self.contextLimit))
        render()
        running = Task {
            do {
                let answer = try await send(input, mode, connection, context,
                                            { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    self.streaming = text
                    self.scheduleStreamRender()
                }, { [weak self] text in
                    guard let self, self.requestID == id else { return }
                    self.latestReasoning = text
                    self.scheduleStreamRender()
                })
                guard requestID == id else { return }
                turns.append(ChatTurn(question: question ?? input.message, answer: answer,
                                      message: input.message, isFollowUp: question != nil && !startedEmptyDirect))
                awaiting = false
                streaming = ""
                pendingQuestion = nil
                render()
                focusQuestionField()
                // Accept completion on the main actor before handing persistence to the file lock.
                let (save, savedSource, notices) = (self.save, self.effectiveSource, historyNotice)
                let savedQuestion: String? = startedEmptyDirect ? nil : question
                let savedSent: Int? = (savedQuestion == nil) ? input.sent : nil
                await Task.detached {
                    do { try save(mode.key, savedSource, answer, savedSent, savedQuestion) }
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
                focusQuestionField()
            }
        }
        return running
    }

    private func cancelRequest() {
        requestID = UUID()
        running?.cancel()
        running = nil
        renderScheduled?.cancel()
        renderScheduled = nil
        lastStreamRender = nil
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
            setSpeakButton(speaking: false)
        }
    }

    /// 流式输出合帧渲染（约 30fps）：高速模型每秒推送几十上百个分片，逐片重解析整段 Markdown
    /// 会把主线程打满；首片立即画，结束/停止/出错由 render() 直接刷新并取消挂起任务。
    private static let streamRenderInterval: Duration = .milliseconds(33)

    private func scheduleStreamRender() {
        let now = ContinuousClock.now
        if let last = lastStreamRender, now - last < Self.streamRenderInterval {
            guard renderScheduled == nil else { return }
            let id = requestID
            renderScheduled = Task { [weak self] in
                try? await Task.sleep(for: Self.streamRenderInterval)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.renderScheduled = nil
                self.lastStreamRender = .now
                self.render()
            }
            return
        }
        lastStreamRender = now
        render()
    }

    /// 停止生成：已经收到的正文留在屏幕上，可以重试。
    func stopStreaming() {
        guard awaiting else { return }
        cancelRequest()   // requestID 换新之后，后台任务的收尾不会再碰界面
        awaiting = false
        render(status: "⏹ " + L("已停止生成", "Generation stopped"))
        focusQuestionField()
    }

    /// 在途（或被停止）的那一轮；没有就是 nil。
    private var pendingTurn: ChatTurn? {
        guard awaiting || !streaming.isEmpty else { return nil }
        return ChatTurn(question: pendingQuestion ?? "", answer: streaming, message: "", isFollowUp: pendingQuestion != nil)
    }

    /// 浮窗正文的 Markdown 原文：已完成的轮次加上在途的那一轮，用分隔线隔开；
    /// 追问的轮次先列出问题。status 是最后一轮下方的一行说明（出错、被停止）。
    nonisolated static func transcript(turns: [ChatTurn], pending: ChatTurn?, status: String?) -> String {
        var parts = turns.map { body(of: $0) }
        if let pending { parts.append(body(of: pending, whileEmpty: L("思考中…", "Thinking…"))) }
        if let status {
            if parts.isEmpty { parts = [status] } else { parts[parts.count - 1] += "\n\n" + status }
        }
        return parts.joined(separator: "\n\n————\n\n")
    }

    nonisolated static func body(of turn: ChatTurn, whileEmpty: String = "") -> String {
        let text = turn.answer.isEmpty ? whileEmpty : turn.answer
        return turn.isFollowUp ? "❓ " + turn.question + "\n\n" + text : text
    }

    /// 把当前对话画到正文里，思考过程拼在最上方、状态行拼在最下方（都只在屏幕上，不进复制与朗读）。
    /// 用户停在底部（或还没滚过）时跟随新内容滚动；翻上去看前文时不再强行拉回。
    private func render(status: String? = nil) {
        renderScheduled?.cancel()
        renderScheduled = nil
        if let status { failure = status }
        answerText = Self.transcript(turns: turns, pending: pendingTurn, status: nil)

        let base = NSFont.systemFont(ofSize: fontSize)
        let smallFont = NSFont.systemFont(ofSize: max(10, base.pointSize - 1))
        let out = NSMutableAttributedString()

        if !latestReasoning.isEmpty {
            let headerFont = NSFont.systemFont(ofSize: max(10, base.pointSize - 1), weight: .semibold)
            let headerStyle = NSMutableParagraphStyle()
            headerStyle.lineSpacing = 3
            let headerTitle = isReasoningCollapsed
                ? L("💭 思考过程（\(latestReasoning.count) 字）", "💭 Reasoning (\(latestReasoning.count) chars)")
                : L("💭 思考过程", "💭 Reasoning")
            out.append(NSAttributedString(string: headerTitle + "  ", attributes: [
                .font: headerFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: headerStyle,
            ]))
            out.append(NSAttributedString(string: isReasoningCollapsed ? L("展开", "Show") : L("收起", "Hide"), attributes: [
                .font: smallFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .link: Self.toggleReasoningURL,
                .paragraphStyle: headerStyle,
            ]))
            if isReasoningCollapsed {
                out.append(Self.renderedAnswer("\n\n————\n\n", baseFont: base))
            } else {
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: smallFont,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: headerStyle,
                ]))
                let body = NSMutableAttributedString(attributedString: Self.renderedAnswer(latestReasoning, baseFont: smallFont))
                body.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: body.length))
                out.append(body)
                out.append(Self.renderedAnswer("\n\n————\n\n", baseFont: base))
            }
        }

        if turns != cachedTurns || base.pointSize != cachedTurnsFontSize {
            cachedTurns = turns
            cachedTurnsFontSize = base.pointSize
            let turnsMarkdown = Self.transcript(turns: turns, pending: nil, status: nil)
            cachedTurnsRendered = turnsMarkdown.isEmpty ? NSAttributedString() : Self.renderedAnswer(turnsMarkdown, baseFont: base)
        }
        out.append(cachedTurnsRendered)
        if let pending = pendingTurn {
            if !turns.isEmpty {
                out.append(Self.renderedAnswer("\n\n————\n\n", baseFont: base))
            }
            let pendingMarkdown = Self.body(of: pending, whileEmpty: L("思考中…", "Thinking…"))
            out.append(Self.renderedAnswer(pendingMarkdown, baseFont: base))
        }

        if let failure {
            let prefix = answerText.isEmpty ? "" : "\n\n"
            let color: NSColor = failure.hasPrefix("❌") ? .systemRed : .secondaryLabelColor
            out.append(NSAttributedString(string: prefix + failure, attributes: [
                .font: smallFont,
                .foregroundColor: color,
            ]))
        }
        if !notice.isEmpty {
            out.append(NSAttributedString(string: "\n\n⚠️ " + notice, attributes: [
                .font: smallFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        let atBottom = textView.visibleRect.maxY >= textView.bounds.height - 48
        textView.textStorage?.setAttributedString(out)
        if atBottom { textView.scrollToEndOfDocument(nil) }

        stopOrRetryButton.isHidden = !awaiting && failure == nil
        stopOrRetryButton.title = awaiting ? L("停止", "Stop") : L("重试", "Retry")
        stopOrRetryButton.image = NSImage(
            systemSymbolName: awaiting ? "stop.fill" : "arrow.clockwise",
            accessibilityDescription: nil
        )
        questionField.isEnabled = !awaiting
        sendButton.isEnabled = !awaiting
    }

    /// 朗读用的纯文本：围栏代码块的围栏行整行跳过，其余去掉行内 Markdown 符号（链接只保留文字）；
    /// 解析失败就按原文朗读。
    nonisolated static func speechText(_ markdown: String) -> String {
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
        setContentSize(Self.panelSize(visible: visible, defaults: defaults))
        setFrameOrigin(Self.nearMouseOrigin(mouse: mouse, panelSize: frame.size, visible: visible))
    }

    override func close() {
        copyFeedback?.cancel()
        copyFeedback = nil
        setCopyButton(copied: false)
        cancelRequest()
        super.close()
    }
    override func cancelOperation(_ sender: Any?) { close() }

    func toggleReasoning() {
        isReasoningCollapsed.toggle()
        render()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if (link as? URL) == Self.toggleReasoningURL || (link as? String) == Self.toggleReasoningURL.absoluteString {
            toggleReasoning()
            return true
        }
        return false
    }

    func adjustFontSize(delta: CGFloat) {
        let next = min(max(fontSize + delta, Self.minFontSize), Self.maxFontSize)
        guard next != fontSize else { return }
        fontSize = next
        defaults.set(Double(fontSize), forKey: "panelFontSize")
        render()
    }

    func resetFontSize() {
        guard fontSize != Self.defaultFontSize else { return }
        fontSize = Self.defaultFontSize
        defaults.set(Double(fontSize), forKey: "panelFontSize")
        render()
    }

    /// ⌘C 复制回答、⌘⇧C 复制最后一个代码块、⌘+/⌘-/⌘0 缩放正文。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = event.charactersIgnoringModifiers
        if flags == [.command, .shift], chars?.lowercased() == "c" {
            if copyLastCodeBlock() { return true }
        }
        if (flags == .command || flags == [.command, .shift]), chars == "+" || chars == "=" {
            adjustFontSize(delta: 1)
            return true
        }
        if flags == .command, chars == "-" {
            adjustFontSize(delta: -1)
            return true
        }
        if flags == .command, chars == "0" {
            resetFontSize()
            return true
        }
        if Self.commandCCopiesTheAnswer(modifiers: event.modifierFlags, characters: chars,
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

    /// 回答结束后把键盘焦点交给追问框，接着输入就行，不用再点一下。
    /// 浮窗是非激活面板，成为 key window 也不会把别的应用切到前台；若焦点此刻在别的应用手里，
    /// 这只是在浮窗内预设 first responder，不会抢走那边正在输入的内容。
    private func focusQuestionField() {
        guard isVisible else { return }
        makeFirstResponder(questionField)
    }

    /// 追问输入框里的回车就是发送；Esc 在这里也会被文本系统以 cancelOperation: 送进来，
    /// 统一成一个规则：浮窗获得键盘焦点后，按 Esc 就关闭——焦点在追问框里也不例外。
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            close()
            return true
        }
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

    private func setCopyButton(copied: Bool) {
        copyButton.title = copied ? L("已复制 ✓", "Copied ✓") : L("复制", "Copy")
        copyButton.image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc",
                                   accessibilityDescription: nil)
    }

    private func setSpeakButton(speaking: Bool) {
        speakButton.title = speaking ? L("停止朗读", "Stop Speaking") : L("朗读", "Speak")
        speakButton.image = NSImage(systemSymbolName: speaking ? "stop.fill" : "speaker.wave.2",
                                    accessibilityDescription: nil)
    }

    /// 复制整段对话的 Markdown 原文：粘贴到别处保留语法，不带思考过程和状态行。
    /// 用按钮文字变化给出安静的视觉反馈，不响系统错误提示音。
    private func showCopyFeedback(title: String) {
        copyFeedback?.cancel()
        copyButton.title = title
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyFeedback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self, !Task.isCancelled else { return }
            self.setCopyButton(copied: false)
            self.copyFeedback = nil
        }
    }

    @discardableResult
    func copyLastCodeBlock() -> Bool {
        guard let code = Self.lastCodeBlock(in: answerText) else { return false }
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        showCopyFeedback(title: L("已复制代码 ✓", "Code Copied ✓"))
        return true
    }

    @objc private func copyAnswer() {
        pasteboard.clearContents()
        pasteboard.setString(answerText, forType: .string)
        showCopyFeedback(title: L("已复制 ✓", "Copied ✓"))
    }

    /// 朗读各轮回答（不读问题和分隔线），去掉行内 Markdown 符号。
    @objc private func speakAnswer() {
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
            setSpeakButton(speaking: false)
            return
        }
        let answers = (turns + [pendingTurn].compactMap { $0 }).map(\.answer).filter { !$0.isEmpty }
        let text = Self.speechText(answers.joined(separator: "\n\n"))
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        let hasCJK = text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(language: hasCJK ? "zh-CN" : "en-US")
        utterance.rate = 0.5
        setSpeakButton(speaking: true)
        speaker.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.setSpeakButton(speaking: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.setSpeakButton(speaking: false) }
    }
}
