import AppKit
import Testing
@testable import AskAI

@MainActor
private func descendants(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants)
}

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
        let panel = ResultPanel(source: source) { input, mode, _, delta, _ in
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
        } save: { mode, original, answer, count in
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
        let name = "AskAI.panelSize.tests"
        let suite = try #require(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        defer { suite.removePersistentDomain(forName: name) }
        // 无记录 → 默认尺寸
        #expect(ResultPanel.panelSize(screenHeight: 900, defaults: suite) == NSSize(width: 550, height: 310))
        // 记住用户拖拽结果
        suite.set(800, forKey: "panelWidth")
        suite.set(600, forKey: "panelHeight")
        #expect(ResultPanel.panelSize(screenHeight: 900, defaults: suite) == NSSize(width: 800, height: 600))
        // 换小屏：高度按可见区兜底，宽度不变
        #expect(ResultPanel.panelSize(screenHeight: 500, defaults: suite) == NSSize(width: 800, height: 480))
        // 脏数据不低于 minSize
        suite.set(100, forKey: "panelWidth")
        suite.set(50, forKey: "panelHeight")
        #expect(ResultPanel.panelSize(screenHeight: 900, defaults: suite) == NSSize(width: 420, height: 220))
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
        let panel = ResultPanel(source: "idempotency") { _, _, _, _, _ in "答案文本" }
        defer { panel.close() }
        panel.show(HistoryEntry(time: Date(), mode: "explain", source: "idempotency", answer: "答案文本"))
        let content = try #require(panel.contentView)
        let view = try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
        view.setSelectedRange(NSRange(location: 0, length: 0))

        let copy = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))

        NSPasteboard.general.clearContents()
        #expect(panel.performKeyEquivalent(with: copy))
        #expect(NSPasteboard.general.string(forType: .string) == "答案文本")
    }

    @Test @MainActor func commandCLeavesSelectionToSystem() throws {
        _ = NSApplication.shared
        let panel = ResultPanel(source: "idempotency") { _, _, _, _, _ in "答案文本" }
        defer { panel.close() }
        panel.show(HistoryEntry(time: Date(), mode: "explain", source: "idempotency", answer: "答案文本"))
        let content = try #require(panel.contentView)
        let view = try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
        view.setSelectedRange(NSRange(location: 0, length: 2))

        let copy = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))

        // 有选区时不拦截，交给系统复制选区
        #expect(panel.performKeyEquivalent(with: copy) == false)
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
