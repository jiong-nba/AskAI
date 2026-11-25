import AppKit
import Testing
@testable import AskAI

struct MarkdownBlockTests {
    private let base = NSFont.systemFont(ofSize: 14)

    @Test @MainActor func headingsStripHashesAndScaleBoldFont() throws {
        let rich = ResultPanel.renderedAnswer("## Title **x**", baseFont: base)
        #expect(rich.string == "Title x")
        let titleRange = try #require(rich.string.range(of: "Title"))
        let xRange = try #require(rich.string.range(of: "x"))

        let titleFont = try #require(rich.attribute(.font, at: NSRange(titleRange, in: rich.string).location, effectiveRange: nil) as? NSFont)
        let xFont = try #require(rich.attribute(.font, at: NSRange(xRange, in: rich.string).location, effectiveRange: nil) as? NSFont)
        #expect(titleFont.pointSize > base.pointSize)
        #expect(titleFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(xFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test @MainActor func bulletsUseHangingIndentAndRenderInlineMarkdown() throws {
        let rich = ResultPanel.renderedAnswer("- **a** item\n  - b sub", baseFont: base)
        #expect(rich.string == "• a item\n• b sub")

        let aRange = try #require(rich.string.range(of: "a"))
        let aFont = try #require(rich.attribute(.font, at: NSRange(aRange, in: rich.string).location, effectiveRange: nil) as? NSFont)
        #expect(aFont.fontDescriptor.symbolicTraits.contains(.bold))

        let firstLineLoc = 0
        let secondLineLoc = NSRange(try #require(rich.string.range(of: "• b")), in: rich.string).location
        let firstStyle = try #require(rich.attribute(.paragraphStyle, at: firstLineLoc, effectiveRange: nil) as? NSParagraphStyle)
        let secondStyle = try #require(rich.attribute(.paragraphStyle, at: secondLineLoc, effectiveRange: nil) as? NSParagraphStyle)
        #expect(firstStyle.headIndent > firstStyle.firstLineHeadIndent)
        #expect(secondStyle.firstLineHeadIndent > firstStyle.firstLineHeadIndent)
        #expect(secondStyle.headIndent > firstStyle.headIndent)
    }

    @Test @MainActor func orderedListKeepsTextAndSetsHangingIndent() throws {
        let rich = ResultPanel.renderedAnswer("1. one **two**", baseFont: base)
        #expect(rich.string == "1. one two")
        let style = try #require(rich.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent > style.firstLineHeadIndent)
        #expect(style.headIndent > 0)
    }

    @Test @MainActor func blockquoteStripsMarkerAndUsesSecondaryColor() throws {
        let rich = ResultPanel.renderedAnswer("> q", baseFont: base)
        #expect(rich.string == "q")
        let color = try #require(rich.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(color == NSColor.secondaryLabelColor)
        let style = try #require(rich.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.headIndent > 0)
    }

    @Test @MainActor func horizontalRuleRendersAsLineAndTranscriptKeepsSeparator() {
        let rich = ResultPanel.renderedAnswer("---", baseFont: base)
        #expect(rich.string == "————")

        let t = ResultPanel.transcript(
            turns: [
                ChatTurn(question: "q1", answer: "a1", message: "m1", isFollowUp: false),
                ChatTurn(question: "q2", answer: "a2", message: "m2", isFollowUp: true),
            ],
            pending: nil,
            status: nil
        )
        #expect(t == "a1\n\n————\n\n❓ q2\n\na2")
    }

    @Test @MainActor func codeBlockMarksAttributeWithoutBackgroundColorOrTrailingNewline() throws {
        let rich = ResultPanel.renderedAnswer("before\n```swift\nlet x = 1\n```\nafter", baseFont: base)
        #expect(rich.string == "before\nlet x = 1\nafter")
        let codeRange = NSRange(try #require(rich.string.range(of: "let x = 1")), in: rich.string)
        for i in codeRange.location..<NSMaxRange(codeRange) {
            #expect(rich.attribute(.askAICodeBlock, at: i, effectiveRange: nil) as? Bool == true)
            #expect(rich.attribute(.backgroundColor, at: i, effectiveRange: nil) == nil)
        }
        // Trailing newline right after code block must not carry .askAICodeBlock.
        let newlineIdx = NSMaxRange(codeRange)
        #expect(rich.attribute(.askAICodeBlock, at: newlineIdx, effectiveRange: nil) == nil)
    }

    @Test @MainActor func everyCharacterInMixedSampleHasFontAndForegroundColor() {
        let sample = """
        # Heading 1
        Paragraph with **bold**, *italic*, `code`, and [link](https://example.com).

        - bullet 1
          - sub bullet
        1. ordered item

        > quote text

        ---

        ```swift
        let a = 1
        ```

        | col1 | col2 |
        """
        let rich = ResultPanel.renderedAnswer(sample, baseFont: base)
        #expect(rich.length > 0)
        var missingFont = 0
        var missingColor = 0
        rich.enumerateAttribute(.font, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            if value == nil { missingFont += range.length }
        }
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            if value == nil { missingColor += range.length }
        }
        #expect(missingFont == 0)
        #expect(missingColor == 0)
    }

    @Test @MainActor func mixedSampleRendersWithCodeBlockLayoutManager() throws {
        _ = NSApplication.shared
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        textView.textContainer?.replaceLayoutManager(CodeBlockLayoutManager())
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 14, height: 10)

        let sample = "# Title\n\n- item\n\n```swift\nlet x = 42\n```\n\n> note"
        textView.textStorage?.setAttributedString(ResultPanel.renderedAnswer(sample, baseFont: base))
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
    }
}
