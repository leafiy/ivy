import XCTest
@testable import IvyCore

final class NoteInlineStyleTests: XCTestCase {
    // MARK: - Parsing

    func testPlainTextIsSingleSpan() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "hello world"),
            [NoteInlineStyle.Span(text: "hello world")]
        )
    }

    func testBoldSpan() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "a **b** c"),
            [
                NoteInlineStyle.Span(text: "a "),
                NoteInlineStyle.Span(text: "b", isBold: true),
                NoteInlineStyle.Span(text: " c"),
            ]
        )
    }

    func testUnderlineSpan() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "<u>b</u>"),
            [NoteInlineStyle.Span(text: "b", isUnderline: true)]
        )
    }

    func testHighlightSpan() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "==b=="),
            [NoteInlineStyle.Span(text: "b", isHighlight: true)]
        )
    }

    func testCanonicalNestingParsesAllFlags() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "**<u>==x==</u>**"),
            [NoteInlineStyle.Span(text: "x", isBold: true, isUnderline: true, isHighlight: true)]
        )
    }

    func testReversedNestingParsesTheSameFlags() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "==**a**=="),
            [NoteInlineStyle.Span(text: "a", isBold: true, isHighlight: true)]
        )
    }

    func testUnmatchedDelimiterStaysLiteral() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "a ** b"),
            [NoteInlineStyle.Span(text: "a ** b")]
        )
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "half <u>open"),
            [NoteInlineStyle.Span(text: "half <u>open")]
        )
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "stray</u> close"),
            [NoteInlineStyle.Span(text: "stray</u> close")]
        )
    }

    func testDelimitersDoNotCrossLines() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "**a\nb**"),
            [
                NoteInlineStyle.Span(text: "**a"),
                NoteInlineStyle.Span(text: "\n"),
                NoteInlineStyle.Span(text: "b**"),
            ]
        )
    }

    func testStyledSpansPerLine() {
        XCTAssertEqual(
            NoteInlineStyle.spans(in: "**a**\n==b=="),
            [
                NoteInlineStyle.Span(text: "a", isBold: true),
                NoteInlineStyle.Span(text: "\n"),
                NoteInlineStyle.Span(text: "b", isHighlight: true),
            ]
        )
    }

    // MARK: - Serialization

    func testMarkupEmitsCanonicalNesting() {
        let span = NoteInlineStyle.Span(text: "x", isBold: true, isUnderline: true, isHighlight: true)
        XCTAssertEqual(NoteInlineStyle.markup(from: [span]), "**<u>==x==</u>**")
    }

    func testMarkupMergesAdjacentEqualSpans() {
        let spans = [
            NoteInlineStyle.Span(text: "a", isBold: true),
            NoteInlineStyle.Span(text: "b", isBold: true),
        ]
        XCTAssertEqual(NoteInlineStyle.markup(from: spans), "**ab**")
    }

    func testMarkupSplitsStyledRunsAtNewlines() {
        let spans = [NoteInlineStyle.Span(text: "a\nb", isBold: true)]
        XCTAssertEqual(NoteInlineStyle.markup(from: spans), "**a**\n**b**")
    }

    func testMarkupSkipsEmptySpans() {
        let spans = [
            NoteInlineStyle.Span(text: ""),
            NoteInlineStyle.Span(text: "a"),
        ]
        XCTAssertEqual(NoteInlineStyle.markup(from: spans), "a")
    }

    func testRoundTripIsStable() {
        let sources = [
            "plain",
            "**bold** and ==mark== and <u>line</u>",
            "**<u>==everything==</u>**",
            "todo **a**\nplain\n==b==",
        ]
        for source in sources {
            let once = NoteInlineStyle.markup(from: NoteInlineStyle.spans(in: source))
            let twice = NoteInlineStyle.markup(from: NoteInlineStyle.spans(in: once))
            XCTAssertEqual(once, twice, "canonical form must be a fixed point for \(source)")
            XCTAssertEqual(
                NoteInlineStyle.spans(in: source),
                NoteInlineStyle.spans(in: once),
                "re-serializing must not change the styles for \(source)"
            )
        }
    }
}

final class NoteTodoItemTests: XCTestCase {
    func testParsesUncheckedPrefix() {
        XCTAssertEqual(
            NoteTodoItem.prefix(ofLine: "- [ ] buy milk"),
            NoteTodoItem.Prefix(isChecked: false, length: 6)
        )
    }

    func testParsesCheckedPrefixBothCases() {
        XCTAssertEqual(
            NoteTodoItem.prefix(ofLine: "- [x] done"),
            NoteTodoItem.Prefix(isChecked: true, length: 6)
        )
        XCTAssertEqual(
            NoteTodoItem.prefix(ofLine: "- [X] done"),
            NoteTodoItem.Prefix(isChecked: true, length: 6)
        )
    }

    func testTrailingSpaceIsOptionalOnlyAtLineEnd() {
        XCTAssertEqual(
            NoteTodoItem.prefix(ofLine: "- [ ]"),
            NoteTodoItem.Prefix(isChecked: false, length: 5)
        )
        XCTAssertNil(NoteTodoItem.prefix(ofLine: "- [x]done"))
    }

    func testRejectsNonTodoLines() {
        XCTAssertNil(NoteTodoItem.prefix(ofLine: "-[ ] a"))
        XCTAssertNil(NoteTodoItem.prefix(ofLine: "* [ ] a"))
        XCTAssertNil(NoteTodoItem.prefix(ofLine: "text - [ ] a"))
        XCTAssertNil(NoteTodoItem.prefix(ofLine: ""))
    }

    func testMarkerRoundTrip() {
        for checked in [true, false] {
            let line = NoteTodoItem.marker(checked: checked) + "task"
            XCTAssertEqual(
                NoteTodoItem.prefix(ofLine: line[...]),
                NoteTodoItem.Prefix(isChecked: checked, length: 6)
            )
        }
    }
}
