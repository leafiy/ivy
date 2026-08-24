import XCTest
@testable import IvyCore

final class NoteInlineImageTests: XCTestCase {
    func testMarkerRoundTripsThroughParsing(){
        let text = "before\n" + NoteInlineImage.marker(name: "Shot 1.png", url: "https://oss.example/a.png") + "\nafter"
        let markers = NoteInlineImage.markers(in: text)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers.first?.name, "Shot 1.png")
        XCTAssertEqual(markers.first?.url, "https://oss.example/a.png")
    }

    func testSanitizedNameStripsSyntaxCharacters() {
        XCTAssertEqual(NoteInlineImage.sanitizedName("a[b](c).png"), "a-b--c-.png")
    }

    func testMarkersFindsMultipleAndIgnoresPlainText() {
        let text = """
        note text ![one](https://x/1.png) middle
        ![two](ivy-upload://abc)
        no marker ![broken](url with space)
        """
        let urls = NoteInlineImage.markers(in: text).map(\.url)
        XCTAssertEqual(urls, ["https://x/1.png", "ivy-upload://abc"])
    }

    func testReplacingPendingURLSwapsOnlyThatMarker() {
        let text = "![a](\(NoteInlineImage.pendingURL(id: "one")))\n![b](\(NoteInlineImage.pendingURL(id: "two")))"
        let replaced = NoteInlineImage.replacingPendingURL(id: "one", with: "https://x/a.png", in: text)
        XCTAssertTrue(replaced.contains("![a](https://x/a.png)"))
        XCTAssertTrue(replaced.contains("![b](\(NoteInlineImage.pendingURL(id: "two")))"))
    }

    func testRemovingPendingMarkerAlsoRemovesItsLine() {
        let marker = NoteInlineImage.marker(name: "x", url: NoteInlineImage.pendingURL(id: "gone"))
        let text = "line one\n\(marker)\nline two"
        XCTAssertEqual(
            NoteInlineImage.removingPendingMarker(id: "gone", from: text),
            "line one\nline two"
        )
    }

    func testRemovingUnknownMarkerLeavesTextUntouched() {
        let text = "plain text"
        XCTAssertEqual(NoteInlineImage.removingPendingMarker(id: "missing", from: text), text)
    }

    func testReferencedURLs() {
        let text = "![a](https://x/1.png) and ![b](https://x/2.png)"
        XCTAssertEqual(
            NoteInlineImage.referencedURLs(in: text),
            ["https://x/1.png", "https://x/2.png"]
        )
    }
}
