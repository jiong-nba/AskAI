import AppKit

extension NSAttributedString.Key {
    /// 标记围栏代码块范围，由 `CodeBlockLayoutManager` 统一绘制圆角底色，避免行尾参差不齐。
    static let askAICodeBlock = NSAttributedString.Key("AskAICodeBlock")
}

/// 为 TextKit 1 的代码块段落绘制圆角背景卡片。
/// 不用字符级 `.backgroundColor`，因为那只会紧贴每行文字绘制、右侧参差不齐，且换行处没有内边距。
final class CodeBlockLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let visibleChars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let fullLength = storage.length
        let containerWidth = container.size.width
        var drawnEnd = 0

        storage.enumerateAttribute(.askAICodeBlock, in: visibleChars, options: []) { value, runRange, _ in
            guard value != nil, runRange.location >= drawnEnd else { return }
            var effectiveRange = NSRange()
            _ = storage.attribute(.askAICodeBlock, at: runRange.location, longestEffectiveRange: &effectiveRange,
                                  in: NSRange(location: 0, length: fullLength))
            drawnEnd = NSMaxRange(effectiveRange)

            let glyphRange = self.glyphRange(forCharacterRange: effectiveRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            var blockRect = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, _, _ in
                blockRect = blockRect.union(rect)
            }
            guard !blockRect.isNull else { return }

            let width = containerWidth > 0 ? containerWidth : blockRect.width
            let box = NSRect(x: origin.x, y: origin.y + blockRect.minY, width: width, height: blockRect.height)
                .insetBy(dx: 4, dy: -3)
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }
    }
}

extension ResultPanel {
    private nonisolated static let inlineSyntaxChars = CharacterSet(charactersIn: "*_`[<\\&~!")

    private nonisolated static func bodyParagraphStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return style
    }

    /// 回答的富文本：围栏代码块用等宽字体并标出背景区间，其余部分按块级与行内 Markdown 渲染。
    nonisolated static func renderedAnswer(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in splitCodeBlocks(text) {
            if segment.isCode {
                result.append(codeBlock(segment.text, baseFont: baseFont))
            } else {
                result.append(renderedBlocks(segment.text, baseFont: baseFont))
            }
        }
        return result
    }

    /// 把回答切成「普通段落」和「围栏代码块」。围栏行本身不显示，它占的那一处换行保留，
    /// 所以其余各行的位置不变。流式输出时代码块常常还没闭合：从开头的围栏到文末都算代码；
    /// 每次都按全文重新切分，闭合之后自然恢复。
    nonisolated static func splitCodeBlocks(_ text: String) -> [(text: String, isCode: Bool)] {
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
    /// 结尾的换行不带 `.askAICodeBlock`，免得代码块下面多出一条空的背景带。
    private nonisolated static func codeBlock(_ text: String, baseFont: NSFont) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1), weight: .regular)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 10
        style.headIndent = 10
        style.tailIndent = -10
        style.lineSpacing = 2

        let highlighted: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: style,
            .askAICodeBlock: true,
        ]
        let result = NSMutableAttributedString()
        if text.hasSuffix("\n") {
            result.append(NSAttributedString(string: String(text.dropLast()), attributes: highlighted))
            result.append(NSAttributedString(string: "\n", attributes: [
                .font: font,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: style,
            ]))
        } else {
            result.append(NSAttributedString(string: text, attributes: highlighted))
        }
        return result
    }

    /// 按行解析轻量级块级 Markdown（标题、列表、引用、分隔线、表格、追问行与思考占位），
    /// 保持简单可控、零外部依赖，同时避免块级解析器对换行做不适合聊天的重排。
    private nonisolated static func renderedBlocks(_ text: String, baseFont: NSFont) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        let result = NSMutableAttributedString()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let newlineAttrs: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: bodyParagraphStyle(),
        ]

        for (index, rawSlice) in lines.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: newlineAttrs))
            }
            let raw = String(rawSlice)
            result.append(renderLine(raw, baseFont: baseFont))
        }
        return result
    }

    private nonisolated static func renderLine(_ raw: String, baseFont: NSFont) -> NSAttributedString {
        if raw.isEmpty {
            return NSAttributedString()
        }

        // 计算前导缩进，用于嵌套列表等缩进层级
        var idx = raw.startIndex
        var indentColumns = 0
        while idx < raw.endIndex {
            let ch = raw[idx]
            if ch == " " { indentColumns += 1 }
            else if ch == "\t" { indentColumns += 2 }
            else { break }
            idx = raw.index(after: idx)
        }
        let level = indentColumns / 2
        let afterIndent = raw[idx...]
        let trimmed = afterIndent.trimmingCharacters(in: .whitespaces)

        // 1. 分隔线（保留对话轮次分隔符 "————" 原串不变）
        if isHorizontalRule(trimmed) {
            let style = bodyParagraphStyle()
            style.alignment = .center
            return NSAttributedString(string: "————", attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: style,
            ])
        }

        // 2. 标题（# ~ ######）
        if let heading = parseHeading(afterIndent) {
            let delta: CGFloat = switch heading.level {
            case 1: 5
            case 2: 3
            case 3: 1
            default: 0
            }
            let headingFont = NSFont.systemFont(ofSize: baseFont.pointSize + delta, weight: .bold)
            let styled = NSMutableAttributedString(attributedString: renderedInline(heading.text, baseFont: headingFont))
            let style = bodyParagraphStyle()
            style.paragraphSpacingBefore = 4
            styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
            return styled
        }

        // 3. 无序列表（- / * / + 后跟空格）
        if afterIndent.hasPrefix("- ") || afterIndent.hasPrefix("* ") || afterIndent.hasPrefix("+ ") {
            let rest = String(afterIndent.dropFirst(2))
            let bullet = "• "
            let bulletWidth = (bullet as NSString).size(withAttributes: [.font: baseFont]).width
            let left = CGFloat(level) * 16
            let style = bodyParagraphStyle()
            style.firstLineHeadIndent = left
            style.headIndent = left + bulletWidth

            let line = NSMutableAttributedString(string: bullet, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            line.append(renderedInline(rest, baseFont: baseFont))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            return line
        }

        // 4. 有序列表（N. 或 N) 后跟空格）
        if let ordered = parseOrderedPrefix(afterIndent) {
            let prefixWidth = (ordered.prefix as NSString).size(withAttributes: [.font: baseFont]).width
            let left = CGFloat(level) * 16
            let style = bodyParagraphStyle()
            style.firstLineHeadIndent = left
            style.headIndent = left + prefixWidth

            let line = NSMutableAttributedString(string: ordered.prefix, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            line.append(renderedInline(ordered.rest, baseFont: baseFont))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            return line
        }

        // 5. 引用块（>）
        if afterIndent.hasPrefix(">") {
            let rest = afterIndent.hasPrefix("> ") ? String(afterIndent.dropFirst(2)) : String(afterIndent.dropFirst(1))
            let style = bodyParagraphStyle()
            let indent = CGFloat(level) * 16 + 12
            style.firstLineHeadIndent = indent
            style.headIndent = indent

            let line = NSMutableAttributedString(attributedString: renderedInline(rest, baseFont: baseFont))
            let range = NSRange(location: 0, length: line.length)
            line.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
            line.addAttribute(.paragraphStyle, value: style, range: range)
            return line
        }

        // 6. Markdown 表格行（等宽对齐）
        if trimmed.hasPrefix("|") {
            let mono = NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1), weight: .regular)
            return NSAttributedString(string: raw, attributes: [
                .font: mono,
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: bodyParagraphStyle(),
            ])
        }

        // 7. 追问问题行
        if raw.hasPrefix("❓ ") {
            let questionFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)
            let line = NSMutableAttributedString(attributedString: renderedInline(raw, baseFont: questionFont))
            line.addAttribute(.paragraphStyle, value: bodyParagraphStyle(), range: NSRange(location: 0, length: line.length))
            return line
        }

        // 8. 思考中占位符
        if raw == L("思考中…", "Thinking…") {
            return NSAttributedString(string: raw, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: bodyParagraphStyle(),
            ])
        }

        // 9. 普通正文行
        let line = NSMutableAttributedString(attributedString: renderedInline(raw, baseFont: baseFont))
        line.addAttribute(.paragraphStyle, value: bodyParagraphStyle(), range: NSRange(location: 0, length: line.length))
        return line
    }

    private nonisolated static func isHorizontalRule(_ trimmed: String) -> Bool {
        if trimmed == "————" { return true }
        guard trimmed.count >= 3, let first = trimmed.first,
              first == "-" || first == "*" || first == "_" else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private nonisolated static func parseHeading(_ line: Substring) -> (level: Int, text: String)? {
        var hashes = 0
        var cursor = line.startIndex
        while cursor < line.endIndex && line[cursor] == "#" && hashes < 6 {
            hashes += 1
            cursor = line.index(after: cursor)
        }
        guard hashes > 0, cursor < line.endIndex, line[cursor] == " " else { return nil }
        return (hashes, String(line[line.index(after: cursor)...]))
    }

    private nonisolated static func parseOrderedPrefix(_ line: Substring) -> (prefix: String, rest: String)? {
        var cursor = line.startIndex
        var digits = 0
        while cursor < line.endIndex && line[cursor].isASCII && line[cursor].isNumber {
            digits += 1
            cursor = line.index(after: cursor)
        }
        guard digits > 0, cursor < line.endIndex, line[cursor] == "." || line[cursor] == ")" else { return nil }
        let afterPunct = line.index(after: cursor)
        guard afterPunct < line.endIndex, line[afterPunct] == " " else { return nil }
        let contentStart = line.index(after: afterPunct)
        return (String(line[..<contentStart]), String(line[contentStart...]))
    }

    /// 行内 Markdown 渲染：粗体 / 斜体 / 行内代码 / 链接，保留原有换行——
    /// 聊天式回答不适合块级语法的段落重排；解析失败或无语法字符时直接走纯文本快路径。
    nonisolated static func renderedInline(_ text: String, baseFont: NSFont) -> NSAttributedString {
        guard !text.isEmpty else { return NSAttributedString() }
        if text.rangeOfCharacter(from: inlineSyntaxChars) == nil {
            return NSAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.textColor,
            ])
        }

        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.textColor,
            ])
        }
        // 解析结果不带字体（直接转 NSAttributedString 也不会自动把 .strong 变粗体），
        // 按行内语义逐 run 套字体再拼起来；无语义的片段拿基础字体，避免掉回系统默认字号。
        // 只读属性、不往 AttributedString 上回写：回写要经过 key path，严格并发检查不允许
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            // 用属性类型下标读取：点语法的访问器经由 key path 实现，严格并发检查不允许
            let intent = run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] ?? []
            var font = baseFont
            if intent.contains(.stronglyEmphasized) {   // **粗体**
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {           // *斜体*
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let isInlineCode = intent.contains(.code)
            if isInlineCode {
                font = NSFont.monospacedSystemFont(ofSize: max(10, baseFont.pointSize - 1), weight: .regular)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                // 富文本缺省不带前景色时 NSTextView 会按黑色渲染，深色模式下变成黑字黑底；
                // 显式给系统动态文字色，随明暗外观自动切换
                .foregroundColor: NSColor.textColor,
            ]
            if isInlineCode {
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor
            }
            // 链接要带上：浮窗里的链接靠它才能点开
            if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
