import AppKit
import Testing
@testable import AskAI

@Suite(.serialized)
struct PanelFeaturesTests {
    @MainActor
    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    @MainActor
    private func answerView(in panel: ResultPanel) throws -> NSTextView {
        let content = try #require(panel.contentView)
        return try #require(descendants(content).compactMap { $0 as? NSTextView }.first)
    }

    @Test @MainActor func fontZoomAdjustsClampsAndPersists() async throws {
        _ = NSApplication.shared
        let defaults = InMemoryDefaults()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let panel = ResultPanel(source: "zoom test", pasteboard: board, defaults: defaults) { _, _, _, _, delta, _ in
            await delta?("hello")
            return "hello"
        } save: { _, _, _, _, _ in }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        let plusEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24))
        #expect(panel.performKeyEquivalent(with: plusEvent))
        #expect(ResultPanel.storedFontSize(defaults: defaults) == 15)

        let tv = try answerView(in: panel)
        let fontAfterZoom = try #require(tv.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(fontAfterZoom.pointSize == 15)

        let minusEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 27))
        for _ in 0..<10 { #expect(panel.performKeyEquivalent(with: minusEvent)) }
        #expect(ResultPanel.storedFontSize(defaults: defaults) == ResultPanel.minFontSize)

        let zeroEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "0", charactersIgnoringModifiers: "0", isARepeat: false, keyCode: 29))
        #expect(panel.performKeyEquivalent(with: zeroEvent))
        #expect(ResultPanel.storedFontSize(defaults: defaults) == ResultPanel.defaultFontSize)
    }

    @Test @MainActor func reasoningCanCollapseAndExpandWithoutEnteringClipboard() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let panel = ResultPanel(source: "reasoning", pasteboard: board, defaults: InMemoryDefaults()) { _, _, _, _, delta, reasoning in
            await reasoning?("hidden scratchpad")
            await delta?("final answer")
            return "final answer"
        } save: { _, _, _, _, _ in }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        let tv = try answerView(in: panel)
        #expect(!panel.isReasoningCollapsed)
        #expect(tv.string.contains("hidden scratchpad"))

        #expect(panel.textView(tv, clickedOnLink: URL(string: "askai://toggle-reasoning")!, at: 0))
        #expect(panel.isReasoningCollapsed)
        #expect(!tv.string.contains("hidden scratchpad"))
        #expect(tv.string.contains("final answer"))

        #expect(panel.textView(tv, clickedOnLink: URL(string: "askai://toggle-reasoning")!, at: 0))
        #expect(!panel.isReasoningCollapsed)
        #expect(tv.string.contains("hidden scratchpad"))

        let copyEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(panel.performKeyEquivalent(with: copyEvent))
        #expect(board.string(forType: .string) == "final answer")
    }

    @Test @MainActor func commandShiftCCopiesLastCodeBlock() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let answer = """
        First:
        ```swift
        let first = 1
        ```
        Second:
        ```python
        print("second")
        ```
        """
        #expect(ResultPanel.lastCodeBlock(in: answer) == "print(\"second\")")
        #expect(ResultPanel.lastCodeBlock(in: "no code here") == nil)

        let panel = ResultPanel(source: "code", pasteboard: board, defaults: InMemoryDefaults()) { _, _, _, _, delta, _ in
            await delta?(answer)
            return answer
        } save: { _, _, _, _, _ in }
        defer { panel.close() }
        await panel.request(connection: fixtureConnection, mode: historyMode("explain"))?.value

        let copyCodeEvent = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil,
            characters: "C", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(panel.performKeyEquivalent(with: copyCodeEvent))
        #expect(board.string(forType: .string) == "print(\"second\")")
    }

    @Test @MainActor func directQuestionModeSendsQuestionWithoutLeadingNewlines() async throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var sent: [String] = []
        let savedEntries = Recorder<(source: String, question: String?)>()
        let panel = ResultPanel(source: "", pasteboard: board, defaults: InMemoryDefaults()) { input, _, _, _, delta, _ in
            sent.append(input.message)
            await delta?("direct answer")
            return "direct answer"
        } save: { _, source, _, _, question in
            savedEntries.append((source, question))
        }
        defer { panel.close() }

        panel.prepareForDirectQuestion(mode: historyMode("explain"))
        let content = try #require(panel.contentView)
        let field = try #require(descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = "  What is MVCC?  "
        #expect(panel.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))

        var waited = 0
        while savedEntries.values.isEmpty, waited < 1_000 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sent == ["What is MVCC?"])
        #expect(savedEntries.values.first?.source == "What is MVCC?")
        #expect(savedEntries.values.first?.question == nil)
        #expect(try answerView(in: panel).string == "direct answer")
    }
}
