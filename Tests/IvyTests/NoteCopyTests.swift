import AppKit
import XCTest
import IvyCore
@testable import Ivy

/// Copying a selection that holds inline pictures puts the pictures' real
/// bytes on the pasteboard — never their `![name](url)` markers or URLs.
@MainActor
final class NoteCopyTests: XCTestCase {
    private let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
    ]

    private func editorString(for text: String) -> NSAttributedString {
        NoteRichTextFormat.attributedString(
            from: text,
            attributes: attributes,
            layoutMetrics: nil
        )
    }

    private func pngData(side: Int = 4) -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return representation.representation(using: .png, properties: [:])!
    }

    func testSelectionWithoutPicturesUsesOrdinaryCopy() {
        XCTAssertNil(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(for: "just words")
        ))
    }

    func testSelectionWithUnloadedPictureUsesOrdinaryCopy() {
        // loadedImage(for:) never fetches, so an unregistered URL stays empty.
        XCTAssertNil(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(for: "![shot.png](https://example.com/never-loaded.png)")
        ))
    }

    func testPictureOnlySelectionCopiesBytesAndNothingElse() throws {
        let png = pngData()
        let url = "https://example.com/\(UUID().uuidString).png"
        NoteInlineImageStore.shared.registerLocal(data: png, for: url)

        let items = try XCTUnwrap(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(for: "![shot.png](\(url))")
        ))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].data(forType: .png), png)
        XCTAssertNotNil(items[0].data(forType: .tiff))
        XCTAssertNil(items[0].string(forType: .string))
    }

    /// Raw image flavors alone paste one picture — readers take the first
    /// item — so a picture-only copy also exports each picture to a file and
    /// carries its URL, the multi-file form every reader takes whole.
    func testMultiPictureCopyCarriesEveryPictureAsAFile() throws {
        let first = pngData(side: 4)
        let second = pngData(side: 8)
        let firstURL = "https://example.com/\(UUID().uuidString).png"
        let secondURL = "https://example.com/\(UUID().uuidString).png"
        NoteInlineImageStore.shared.registerLocal(data: first, for: firstURL)
        NoteInlineImageStore.shared.registerLocal(data: second, for: secondURL)

        let items = try XCTUnwrap(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(
                for: "![shot.png](\(firstURL))\n![shot.png](\(secondURL))"
            )
        ))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].data(forType: .png), first)
        XCTAssertEqual(items[1].data(forType: .png), second)

        let fileURLs = try items.map { item in
            try XCTUnwrap(URL(string: XCTUnwrap(item.string(forType: .fileURL))))
        }
        XCTAssertEqual(try Data(contentsOf: fileURLs[0]), first)
        XCTAssertEqual(try Data(contentsOf: fileURLs[1]), second)
        // Same marker name, two files: the export dedupes the path.
        XCTAssertEqual(fileURLs[0].lastPathComponent, "shot.png")
        XCTAssertEqual(fileURLs[1].lastPathComponent, "shot-2.png")
    }

    /// A copy that carries words must not carry file URLs: ivy's own paste
    /// prefers them, and would trade the words for attachments.
    func testMixedCopyCarriesNoFileURLs() throws {
        let png = pngData()
        let url = "https://example.com/\(UUID().uuidString).png"
        NoteInlineImageStore.shared.registerLocal(data: png, for: url)

        let items = try XCTUnwrap(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(for: "words\n![shot.png](\(url))")
        ))
        XCTAssertEqual(items.count, 2)
        XCTAssertNil(items[1].string(forType: .fileURL))
    }

    /// The paste side of the same story: a multi-picture pasteboard is one
    /// picture per item, and reading it whole would see only the first.
    func testPasteReadsEveryImageItem() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        let first = pngData(side: 4)
        let second = pngData(side: 8)
        let items = [first, second].map { data in
            let item = NSPasteboardItem()
            item.setData(data, forType: .png)
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))

        let pending = PendingNoteAttachment.attachments(pasteboard: pasteboard)
        XCTAssertEqual(pending.map(\.data), [first, second])
        XCTAssertEqual(pending.map(\.contentType), ["image/png", "image/png"])
    }

    func testMixedSelectionCopiesWordsWithoutTheURLAndThePictureBytes() throws {
        let png = pngData()
        let url = "https://example.com/\(UUID().uuidString).png"
        NoteInlineImageStore.shared.registerLocal(data: png, for: url)

        let items = try XCTUnwrap(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(for: "- [ ] hello ==world==\n![shot.png](\(url))")
        ))
        XCTAssertEqual(items.count, 2)

        let plain = try XCTUnwrap(items[0].string(forType: .string))
        XCTAssertEqual(plain, "- [ ] hello world\n")
        XCTAssertFalse(plain.contains(url))
        XCTAssertNotNil(items[0].data(forType: .rtfd))

        XCTAssertEqual(items[1].data(forType: .png), png)
    }

    func testRTFDEmbedsThePictureBytes() throws {
        let png = pngData()
        let url = "https://example.com/\(UUID().uuidString).png"
        NoteInlineImageStore.shared.registerLocal(data: png, for: url)

        let items = try XCTUnwrap(NoteRichTextFormat.pasteboardItems(
            forSelection: editorString(for: "words\n![shot.png](\(url))")
        ))
        let rtfd = try XCTUnwrap(items[0].data(forType: .rtfd))
        let decoded = try XCTUnwrap(NSAttributedString(
            rtfd: rtfd,
            documentAttributes: nil
        ))
        var embedded: Data?
        decoded.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: decoded.length)
        ) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            embedded = attachment.fileWrapper?.regularFileContents
        }
        XCTAssertEqual(embedded, png)
    }
}
