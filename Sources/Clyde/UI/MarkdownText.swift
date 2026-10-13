import SwiftUI

/// Renders chat/summary text with real formatting instead of showing raw markdown syntax.
///
/// Deliberately not a full CommonMark renderer (no nesting, tables, blockquotes, headings) —
/// LLM chat replies are almost entirely paragraphs, bullet/numbered lists, inline emphasis, and
/// occasional fenced code blocks, so this covers exactly that with no third-party dependency:
/// block-splits the text into paragraphs / list items / code fences itself, then hands each
/// paragraph and list item to Foundation's built-in `AttributedString(markdown:)` for inline
/// styling (bold, italic, inline code, links).
struct MarkdownText: View {
    let text: String

    private enum Block {
        case paragraph(String)
        case listItem(String, marker: String)
        case codeBlock(String, language: String?)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(Self.parseBlocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let content):
                    inlineText(content)
                case .listItem(let content, let marker):
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        inlineText(content)
                    }
                case .codeBlock(let code, let language):
                    CodeBlockView(code: code, language: language)
                }
            }
        }
    }

    private func inlineText(_ content: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: content, options: options) {
            return Text(attributed)
        }
        return Text(content)
    }

    // MARK: - Block parsing

    private static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var orderedCounter = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll()
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                orderedCounter = 0
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(codeLines.joined(separator: "\n"), language: language.isEmpty ? nil : language))
                i += 1 // skip the closing fence
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                orderedCounter = 0
                blocks.append(.listItem(String(trimmed.dropFirst(2)), marker: "•"))
                i += 1
                continue
            }

            if let (number, rest) = orderedListItem(trimmed) {
                flushParagraph()
                orderedCounter = number
                blocks.append(.listItem(rest, marker: "\(orderedCounter)."))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                orderedCounter = 0
                i += 1
                continue
            }

            paragraphLines.append(rawLine)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// Matches "1. rest", "12. rest" — returns the number and the remaining text.
    private static func orderedListItem(_ line: String) -> (Int, String)? {
        guard let dotIndex = line.firstIndex(of: ".") else { return nil }
        let digits = line[line.startIndex..<dotIndex]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) else { return nil }
        let afterDot = line[line.index(after: dotIndex)...]
        guard afterDot.hasPrefix(" ") else { return nil }
        return (number, String(afterDot.dropFirst()))
    }
}

private struct CodeBlockView: View {
    let code: String
    let language: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .padding(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.25)))
    }
}
