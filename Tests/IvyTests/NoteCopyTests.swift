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

    private func pngData() -> Data {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
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
