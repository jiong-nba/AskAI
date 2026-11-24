import AppKit
import Testing
@testable import AskAI

struct CodeBlockRenderingTests {
    private let base = NSFont.systemFont(ofSize: 14)

    @MainActor
    private func fontTraits(of text: String, in rich: NSAttributedString) throws -> [Bool] {
        // true where the run is monospaced, for each line of `text`
        let range = try #require(rich.string.range(of: text))
        var monospaced: [Bool] = []
        rich.enumerateAttribute(.font, in: NSRange(range, in: rich.string)) { font, _, _ in
            monospaced.append((font as? NSFont)?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        }
        return monospaced
    }

    // Fenced code is monospaced and left alone by Markdown; the fence lines are not shown, and the
    // lines around them stay where they were.
    @Test @MainActor func fencedCodeIsMonospacedAndFencesAreHidden() throws {
        let rich = ResultPanel.renderedAnswer("before\n```swift\nlet x = *1*\n```\nafter", baseFont: base)
        #expect(rich.string == "before\nlet x = *1*\nafter")
        #expect(try fontTraits(of: "before", in: rich) == [false])
        #expect(try fontTraits(of: "let x = *1*", in: rich) == [true])
        #expect(try fontTraits(of: "after", in: rich) == [false])
        // Every character keeps the dynamic text colour (dark mode).
        var missing = 0
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { color, range, _ in
            if color == nil { missing += NSMaxRange(range) - range.location }
        }
        #expect(missing == 0)
    }

    // While the answer streams, the closing fence has not arrived yet: the rest counts as code.
    @Test @MainActor func anUnclosedFenceRunsToEndOfText() {
        let streaming = ResultPanel.renderedAnswer("text\n```\nlet y = **1**", baseFont: base)
        #expect(streaming.string == "text\nlet y = **1**")
        let segments = ResultPanel.splitCodeBlocks("a\n```\nb\nc")
        #expect(segments.map(\.text) == ["a\n", "b\nc"] && segments.map(\.isCode) == [false, true])
    }

    @Test @MainActor func splittingKeepsLinePositions() {
        let text = "one\n\n```js\nconst a = 1\n\nconst b = 2\n```\n\ntwo\n"
        let segments = ResultPanel.splitCodeBlocks(text)
        #expect(segments.map(\.isCode) == [false, true, false])
        #expect(segments.map(\.text) == ["one\n\n", "const a = 1\n\nconst b = 2\n", "\ntwo\n"])
        #expect(segments.map(\.text).joined() == text.replacingOccurrences(of: "```js\n", with: "").replacingOccurrences(of: "```\n", with: ""))
        // A line that merely mentions backticks is not a fence.
        #expect(ResultPanel.splitCodeBlocks("use ``` to open\n").map(\.isCode) == [false])
        #expect(ResultPanel.splitCodeBlocks("").isEmpty)
    }

    // Speech skips the fence lines and still reads the code itself.
    @Test @MainActor func speechSkipsFencesButReadsTheCode() {
        #expect(ResultPanel.speechText("before\n```swift\nlet x = 1\n```\nafter") == "before\nlet x = 1\nafter")
        #expect(ResultPanel.speechText("**bold** and `code`") == "bold and code")
    }
}
