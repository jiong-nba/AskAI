import AppKit
import Testing
@testable import AskAI

@MainActor
private func descendants(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants)
}

/// ⌘C 用例专用的剪贴板：测试不能清空并覆盖开发者的系统剪贴板。
@MainActor
private func isolatedPasteboard() -> NSPasteboard {
    NSPasteboard.withUniqueName()
}

@MainActor
private func answerView(of panel: ResultPanel) throws -> NSTextView {
    let content = try #require(panel.contentView)
    return try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
}

@MainActor
private func copyEvent(for panel: ResultPanel, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil,
        characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
}

// Serialized: these tests share NSApplication.
@Suite(.serialized)
struct ResultPanelTests {
    @Test @MainActor func settingsWindowOpensAtFormSize() throws {
        _ = NSApplication.shared
        let window = makeSettingsWindow {}
        defer { window.close() }
        let view = try #require(window.contentView)
        #expect(view.bounds.height > 0 && view.bounds.height >= view.fittingSize.height)
        #expect(view.bounds.width >= view.fittingSize.width)
    }

    @Test @MainActor func historyModeSwitchCancelsOldResultAndSummarizesOriginal() async throws {
        _ = NSApplication.shared
        let source = String(repeating: "甲", count: 2995) + "结论：乙。"
        let (started, signalStart) = AsyncStream<Void>.makeStream()
        let (stale, signalStale) = AsyncStream<Bool>.makeStream()
        let (saved, signalSave) = AsyncStream<HistoryEntry>.makeStream()
        let defaultMode = currentMode().key
        let panel = ResultPanel(source: source) { input, mode, _, _, delta, _ in
            if mode.key == "translate" {
                signalStart.yield(())
                do { try await Task.sleep(for: .seconds(10)) } catch {}
                // Even an upstream which delivers one last chunk must not replace the new result.
                await delta?("stale")
                signalStale.yield(Task.isCancelled)
                return "stale"
            }
            #expect(mode.key == "summarize")
            #expect(input.message == source)
            await delta?("new")
            return "new"
        } save: { mode, original, answer, count, _ in
            signalSave.yield(HistoryEntry(time: Date(), mode: mode, source: original, answer: answer, sentCharacters: count))
        }
        defer { panel.close(); signalStart.finish(); signalStale.finish(); signalSave.finish() }
        panel.show(HistoryEntry(time: Date(), mode: "解释名词", source: source, answer: "old"))
        let views = descendants(try #require(panel.contentView))
        let picker = try #require(views.compactMap { $0 as? NSPopUpButton }.first)
        let full = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == L("总结全文", "Summarize All") })
        let output = try #require(views.compactMap { $0 as? NSTextView }.first)
        let countLabel = try #require(views.compactMap { $0 as? NSTextField }.first { $0.stringValue.contains("2000 / 3000") })
        #expect(output.string == "old" && picker.selectedItem?.representedObject as? String == "explain")
        picker.selectItem(withTitle: historyMode("translate").title)
        try #require(picker.sendAction(picker.action, to: picker.target))
        var start = started.makeAsyncIterator()
        _ = await start.next()
        panel.refreshSummaryLimit(2000)
        #expect(!full.isEnabled && countLabel.stringValue.contains("2000"))
        panel.refreshSummaryLimit(16000)
        #expect(full.isEnabled && !full.isHidden)
        try #require(full.sendAction(full.action, to: full.target))
        var late = stale.makeAsyncIterator()
        #expect(await late.next() == true)
        var history = saved.makeAsyncIterator()
        let entry = try #require(await history.next())
        #expect(entry.source == source && entry.mode == "summarize" && entry.sentCharacters == 3000)
        #expect(output.string == "new" && currentMode().key == defaultMode)
        #expect(countLabel.stringValue.contains("3000 / 3000"))
        panel.show(entry)
        #expect(countLabel.stringValue.contains("3000 / 3000"))
        signalSave.finish()
        #expect(await history.next() == nil)
    }

    @Test @MainActor func nearMouseOriginClampsToVisibleFrame() {
        let size = NSSize(width: 550, height: 310)
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 鼠标在屏幕中部：面板偏右下方弹出，不挡光标
        let middle = ResultPanel.nearMouseOrigin(mouse: NSPoint(x: 700, y: 450), panelSize: size, visible: visible)
        #expect(middle.x == 720 && middle.y == 326)
        // 鼠标贴右缘：收回可见区内
        let right = ResultPanel.nearMouseOrigin(mouse: NSPoint(x: 1430, y: 450), panelSize: size, visible: visible)
        #expect(right.x <= visible.maxX - size.width - 8 + 0.5)
        // 鼠标在左下角：不越出可见区
        let corner = ResultPanel.nearMouseOrigin(mouse: NSPoint(x: 2, y: 3), panelSize: size, visible: visible)
        #expect(corner.x >= visible.minX + 8 - 0.5 && corner.y >= visible.minY + 8 - 0.5)
    }

    @Test @MainActor func panelSizeRemembersResizeAndClampsToScreen() throws {
        let suite = InMemoryDefaults()
        let wide = NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 无记录 → 默认尺寸
        #expect(ResultPanel.panelSize(visible: wide, defaults: suite) == NSSize(width: 550, height: 310))
        // 记住用户拖拽结果
        suite.set(800, forKey: "panelWidth")
        suite.set(600, forKey: "panelHeight")
        #expect(ResultPanel.panelSize(visible: wide, defaults: suite) == NSSize(width: 800, height: 600))
        // 换小屏：高度按可见区兜底，宽度放得下就不变
        let short = NSRect(x: 0, y: 0, width: 1440, height: 500)
        #expect(ResultPanel.panelSize(visible: short, defaults: suite) == NSSize(width: 800, height: 480))
        // 在外接大屏上拖宽了、回到窄屏：宽度也收进可见区，否则左侧的关闭按钮和模式下拉落到屏幕外
        suite.set(2400, forKey: "panelWidth")
        #expect(ResultPanel.panelSize(visible: wide, defaults: suite) == NSSize(width: 1424, height: 600))
        // 脏数据不低于 minSize
        suite.set(100, forKey: "panelWidth")
        suite.set(50, forKey: "panelHeight")
        #expect(ResultPanel.panelSize(visible: wide, defaults: suite) == NSSize(width: 420, height: 220))
    }

    // Regression: the frame height includes the title bar and the content height does not. Storing the
    // former and restoring it as the latter made the panel one title bar taller after every resize.
    @Test @MainActor func rememberedSizeIsTheContentSize() throws {
        _ = NSApplication.shared
        let suite = InMemoryDefaults()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board) { _, _, _, _, _, _ in "x" }
        defer { panel.close() }
        panel.setContentSize(NSSize(width: 700, height: 400))
        #expect(panel.frame.height > 400)   // a titled window is taller than its content
        ResultPanel.rememberSize(of: panel, defaults: suite)
        #expect(ResultPanel.panelSize(visible: nil, defaults: suite) == NSSize(width: 700, height: 400))
    }

    // A width left over from a wide external display must not push the panel's left edge off a smaller screen.
    @Test @MainActor func showNearMouseKeepsAnOversizedPanelOnScreen() throws {
        _ = NSApplication.shared
        guard let main = NSScreen.main else { return }
        let visible = main.visibleFrame
        let defaults = InMemoryDefaults()
        defaults.set(5_000, forKey: "panelWidth")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board, defaults: defaults) { _, _, _, _, _, _ in "x" }
        defer { panel.close() }

        // A pointer in the middle of the one screen there is; the real pointer may be on another display.
        panel.showNearMouse(at: NSPoint(x: visible.midX, y: visible.midY), screens: [main])

        #expect(panel.frame.width <= visible.width)
        #expect(panel.frame.minX >= visible.minX - 0.5 && panel.frame.maxX <= visible.maxX + 0.5)
        #expect(panel.frame.minY >= visible.minY - 0.5 && panel.frame.maxY <= visible.maxY + 0.5)
    }

    @Test @MainActor func titleFlattensLineBreaksAndEllipsizesLongSource() {
        #expect(ResultPanel.title(for: "  line one\nline two\r\nline three  ") == "line one line two line three")
        let truncated = ResultPanel.title(for: String(repeating: "字", count: 60))
        #expect(truncated == String(repeating: "字", count: ResultPanel.titleLimit) + "…")
    }

    // The mode picker already shows the active mode right below the title bar, so the title bar
    // should not repeat it; and a floating panel disables the green zoom button.
    @Test @MainActor func panelTitleDoesNotDuplicateModeAndDisablesZoomButton() async {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board, defaults: InMemoryDefaults(),
                                send: { _, _, _, _, _, _ in "answer" }, save: { _, _, _, _, _ in })
        defer { panel.close() }
        let mode = historyMode("explain")
        await panel.request(connection: fixtureConnection, mode: mode)?.value

        #expect(panel.title == "idempotency")
        #expect(!panel.title.contains(mode.title))
        #expect(panel.standardWindowButton(.zoomButton)?.isEnabled == false)
    }

    // Rapid streaming chunks coalesce instead of re-parsing Markdown per token, while the final
    // answer still renders immediately on completion with no trailing stale overwrite.
    @Test @MainActor func rapidStreamingChunksStillRenderFinalAnswerImmediately() async throws {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board, defaults: InMemoryDefaults(),
                                send: { _, _, _, _, delta, _ in
            var acc = ""
            for i in 1...50 {
                acc += "\(i) "
                await delta?(acc)
            }
            return acc + "done"
        }, save: { _, _, _, _, _ in })
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        let expected = (1...50).map { "\($0) " }.joined() + "done"
        #expect(try answerView(of: panel).string == expected)
    }

    // Caps Lock and Fn are state, not part of the shortcut: ⌘C must still copy while they are on.
    @Test @MainActor func commandCStillCopiesWithCapsLockOn() throws {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board) { _, _, _, _, _, _ in "answer" }
        defer { panel.close() }
        panel.show(HistoryEntry(time: Date(), mode: "explain", source: "idempotency", answer: "answer"))
        try answerView(of: panel).setSelectedRange(NSRange(location: 0, length: 0))

        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel, flags: [.command, .capsLock])))
        #expect(board.string(forType: .string) == "answer")
    }

    @Test @MainActor func answerMarkdownRendersInlineSyntax() throws {
        let base = NSFont.systemFont(ofSize: 14)
        let rich = ResultPanel.renderedAnswer("**加粗** 与 `code` 及普通文字\n第二行", baseFont: base)
        // 行内语法符号被吃掉，内容与换行保留
        #expect(!rich.string.contains("**") && !rich.string.contains("`"))
        #expect(rich.string.contains("加粗") && rich.string.contains("code") && rich.string.contains("第二行"))
        // 粗体片段真的带 bold trait，行内代码用等宽字体
        var hasBold = false
        var hasMono = false
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { font, _, _ in
            guard let font = font as? NSFont else { return }
            if font.fontDescriptor.symbolicTraits.contains(.bold) { hasBold = true }
            if font.fontDescriptor.symbolicTraits.contains(.monoSpace) { hasMono = true }
        }
        #expect(hasBold && hasMono)
    }

    @Test @MainActor func answerMarkdownKeepsPlainTextAndBaseFont() throws {
        let base = NSFont.systemFont(ofSize: 14)
        // 无语法文本：内容与换行原样保留，且全文都带基础字体（不会掉回默认字号）
        let plain = ResultPanel.renderedAnswer("第一行普通中文\nSecond line", baseFont: base)
        #expect(plain.string == "第一行普通中文\nSecond line")
        var unfixed: [NSRange] = []
        plain.enumerateAttribute(.font, in: NSRange(location: 0, length: plain.length)) { font, range, _ in
            if font == nil { unfixed.append(range) }
        }
        #expect(unfixed.isEmpty)
        // 未闭合语法不崩溃，仍有内容
        let broken = ResultPanel.renderedAnswer("**未闭合的加粗", baseFont: base)
        #expect(broken.length > 0)
    }

    @Test @MainActor func commandCCopiesWholeAnswerWhenNothingSelected() throws {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board) { _, _, _, _, _, _ in "答案文本" }
        defer { panel.close() }
        panel.show(HistoryEntry(time: Date(), mode: "explain", source: "idempotency", answer: "答案文本"))
        try answerView(of: panel).setSelectedRange(NSRange(location: 0, length: 0))

        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel)))
        #expect(board.string(forType: .string) == "答案文本")
    }

    @Test @MainActor func commandCLeavesSelectionToSystem() throws {
        _ = NSApplication.shared
        let panel = ResultPanel(source: "idempotency") { _, _, _, _, _, _ in "答案文本" }
        defer { panel.close() }
        panel.show(HistoryEntry(time: Date(), mode: "explain", source: "idempotency", answer: "答案文本"))
        try answerView(of: panel).setSelectedRange(NSRange(location: 0, length: 2))

        // 有选区时不拦截，交给系统复制选区
        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel)) == false)
    }

    // A reasoning model that only produced thinking before the stream failed keeps the trace on
    // screen, above the error. Nothing is saved or copied from it.
    @Test @MainActor func reasoningStaysVisibleWhenTheAnswerFails() async throws {
        struct StreamFailed: Error {}
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board) { _, _, _, _, delta, reasoning in
            await reasoning?("thinking about it")
            _ = delta
            throw StreamFailed()
        } save: { _, _, _, _, _ in
            Issue.record("A failed request must not be saved")
        }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        let shown = try answerView(of: panel).string
        #expect(shown.contains("thinking about it"))
        #expect(shown.contains("❌"))
        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel)))
        #expect(board.string(forType: .string)?.contains("thinking") == false)
    }

    // README: "history and copy keep the final answer"; issue #23: 思考过程仅供浏览。
    @Test @MainActor func copyKeepsOnlyTheFinalAnswerOfReasoningModels() async throws {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "idempotency", pasteboard: board) { _, _, _, _, delta, reasoning in
            await reasoning?("the model's scratchpad")
            await delta?("final answer")
            return "final answer"
        } save: { _, _, _, _, _ in }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        // 思考过程照常显示在正文上方，但不进入剪贴板
        #expect(try answerView(of: panel).string.contains("scratchpad"))
        #expect(board.string(forType: .string) == nil)
        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel)))
        #expect(board.string(forType: .string) == "final answer")
    }

    // Issue #21: 复制按钮仍复制原始 markdown 源文（粘贴到别处保留语法）。
    @Test @MainActor func copyKeepsMarkdownSourceWhileTheViewIsRendered() async throws {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        let answer = "**bold** `code` [text](https://example.com)"
        let panel = ResultPanel(source: "idempotency", pasteboard: board) { _, _, _, _, delta, _ in
            await delta?(answer)
            return answer
        } save: { _, _, _, _, _ in }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        #expect(try answerView(of: panel).string == "bold code text")
        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel)))
        #expect(board.string(forType: .string) == answer)
    }

    // Issue #21: 朗读不读 markdown 符号。
    @Test @MainActor func speechTextDropsInlineMarkdown() {
        #expect(ResultPanel.speechText("**bold** `code` [text](https://example.com)") == "bold code text")
        #expect(ResultPanel.speechText("第一行普通中文\nSecond line") == "第一行普通中文\nSecond line")
    }

    // A notice raised while history was saved (history.json unreadable and moved aside) is shown
    // below the answer, and stays out of the clipboard.
    @Test @MainActor func historyNoticeIsShownBelowTheAnswerButNotCopied() async throws {
        _ = NSApplication.shared
        let board = isolatedPasteboard()
        defer { board.releaseGlobally() }
        // Its own notice channel: the shared one races with the other suites, which run in parallel.
        let notices = HistoryNotice()
        let panel = ResultPanel(source: "idempotency", pasteboard: board, notice: notices) { _, _, _, _, delta, _ in
            await delta?("answer")
            return "answer"
        } save: { _, _, _, _, _ in
            notices.post("history.json was moved aside")
        }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        #expect(try answerView(of: panel).string == "answer\n\n⚠️ history.json was moved aside")
        #expect(panel.performKeyEquivalent(with: try copyEvent(for: panel)))
        #expect(board.string(forType: .string) == "answer")
        #expect(notices.take() == nil)   // shown once, then consumed
    }

    @Test @MainActor func answerUsesDynamicTextColorForDarkMode() throws {
        // 富文本若不带前景色，NSTextView 会按黑色渲染，深色模式下变成黑字黑底。
        // 要求每个片段都显式带上系统动态文字色（labelColor 随外观切换）。
        let base = NSFont.systemFont(ofSize: 14)
        let expected = NSColor.textColor
        for sample in ["**加粗** 与 `code` 及普通文字", "第一行普通中文\nSecond line", "**未闭合的加粗"] {
            let rich = ResultPanel.renderedAnswer(sample, baseFont: base)
            #expect(rich.length > 0)
            var missing: [NSRange] = []
            var mismatched: [NSRange] = []
            rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { color, range, _ in
                guard let color = color as? NSColor else { missing.append(range); return }
                if color != expected { mismatched.append(range) }
            }
            #expect(missing.isEmpty)
            #expect(mismatched.isEmpty)
        }
    }
}
