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
        let panel = ResultPanel(source: source) { input, mode, _, delta in
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
}
