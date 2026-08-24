import Foundation

/// Lightweight inline styling embedded in a note's plain text, mirroring the
/// inline image markers: bold `**text**`, underline `<u>text</u>`, and
/// highlight `==text==`. The macOS editor renders the styles and hides the
/// delimiters; any other client sees readable markdown-ish text. Delimiters
/// never span lines, and an opener without a closer on the same line stays
/// literal text.
public enum NoteInlineStyle {
    /// A run of text sharing one combination of inline styles.
    public struct Span: Equatable {
        public var text: String
        public var isBold: Bool
        public var isUnderline: Bool
        public var isHighlight: Bool

        public init(
            text: String,
            isBold: Bool = false,
            isUnderline: Bool = false,
            isHighlight: Bool = false
        ) {
            self.text = text
            self.isBold = isBold
            self.isUnderline = isUnderline
            self.isHighlight = isHighlight
        }

        var hasStyle: Bool { isBold || isUnderline || isHighlight }

        var sameStyle: (Bool, Bool, Bool) { (isBold, isUnderline, isHighlight) }
    }

    /// Tokenizes marked-up text into styled spans. A toggle-scanner rather
    /// than nested patterns, so any delimiter order (`**==a==**` or
    /// `==**a**==`) resolves to the same flags.
    public static func spans(in text: String) -> [Span] {
        var result: [Span] = []
        var buffer = ""
        var bold = false
        var underline = false
        var highlight = false

        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(Span(
                text: buffer,
                isBold: bold,
                isUnderline: underline,
                isHighlight: highlight
            ))
            buffer = ""
        }

        /// Whether `token` occurs at or after `start` before the next
        /// newline — i.e. the delimiter that is about to open can close.
        func closes(_ token: String, from start: String.Index) -> Bool {
            var index = start
            while index < text.endIndex, text[index] != "\n" {
                if text[index...].hasPrefix(token) { return true }
                index = text.index(after: index)
            }
            return false
        }

        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if text[index] == "\n" {
                flush()
                bold = false
                underline = false
                highlight = false
                result.append(Span(text: "\n"))
                index = text.index(after: index)
            } else if rest.hasPrefix("**") {
                let after = text.index(index, offsetBy: 2)
                if bold || closes("**", from: after) {
                    flush()
                    bold.toggle()
                } else {
                    buffer += "**"
                }
                index = after
            } else if rest.hasPrefix("==") {
                let after = text.index(index, offsetBy: 2)
                if highlight || closes("==", from: after) {
                    flush()
                    highlight.toggle()
                } else {
                    buffer += "=="
                }
                index = after
            } else if rest.hasPrefix("<u>") {
                let after = text.index(index, offsetBy: 3)
                if !underline, closes("</u>", from: after) {
                    flush()
                    underline = true
                } else {
                    buffer += "<u>"
                }
                index = after
            } else if rest.hasPrefix("</u>") {
                let after = text.index(index, offsetBy: 4)
                if underline {
                    flush()
                    underline = false
                } else {
                    buffer += "</u>"
                }
                index = after
            } else {
                buffer.append(text[index])
                index = text.index(after: index)
            }
        }
        flush()
        return result
    }

    /// Serializes spans back to marked-up text. Delimiters wrap maximal runs
    /// and never cross newlines; the emitted nesting order is canonical
    /// (`**<u>==text==</u>**`) no matter how the source was written.
    public static func markup(from spans: [Span]) -> String {
        var merged: [Span] = []
        for span in spans where !span.text.isEmpty {
            if let last = merged.last, last.sameStyle == span.sameStyle {
                merged[merged.count - 1].text += span.text
            } else {
                merged.append(span)
            }
        }

        var output = ""
        for span in merged {
            guard span.hasStyle else {
                output += span.text
                continue
            }
            let segments = span.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, segment) in segments.enumerated() {
                if index > 0 { output += "\n" }
                guard !segment.isEmpty else { continue }
                var piece = String(segment)
                if span.isHighlight { piece = "==\(piece)==" }
                if span.isUnderline { piece = "<u>\(piece)</u>" }
                if span.isBold { piece = "**\(piece)**" }
                output += piece
            }
        }
        return output
    }
}

/// Markdown task-list prefixes (`- [ ] ` / `- [x] `) at the start of a note
/// line. The macOS editor renders them as clickable checkboxes; any other
/// client sees a standard markdown todo item.
public enum NoteTodoItem {
    public struct Prefix: Equatable {
        public let isChecked: Bool
        /// Characters the marker occupies, including the trailing space when
        /// present.
        public let length: Int

        public init(isChecked: Bool, length: Int) {
            self.isChecked = isChecked
            self.length = length
        }
    }

    public static func marker(checked: Bool) -> String {
        checked ? "- [x] " : "- [ ] "
    }

    /// Parses a task marker at the start of `line` (one line, no newlines).
    /// The trailing space is required except at the end of the line.
    public static func prefix(ofLine line: Substring) -> Prefix? {
        let isChecked: Bool
        if line.hasPrefix("- [ ]") {
            isChecked = false
        } else if line.hasPrefix("- [x]") || line.hasPrefix("- [X]") {
            isChecked = true
        } else {
            return nil
        }
        let rest = line.dropFirst(5)
        if rest.isEmpty { return Prefix(isChecked: isChecked, length: 5) }
        guard rest.first == " " else { return nil }
        return Prefix(isChecked: isChecked, length: 6)
    }

    public static func prefix(ofLine line: String) -> Prefix? {
        prefix(ofLine: line[...])
    }
}
