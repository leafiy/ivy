import AppKit
import XCTest
@testable import Ivy

final class IvyIconTests: XCTestCase {
    func testPinnedButtonUsesAVisuallyDistinctIcon() {
        XCTAssertNotEqual(IvyIcon.pinState(false), IvyIcon.pinState(true))
    }

    func testEverySemanticIconLoadsFromLucideAsTemplateImage() {
        for icon in IvyIcon.allCases {
            let image = icon.nsImage

            XCTAssertTrue(image.isTemplate, "\(icon) must remain tintable")
            XCTAssertFalse(image.representations.isEmpty, "\(icon) did not load from Lucide")
        }
    }

    func testIvyUISourceDoesNotBypassSemanticIconLibrary() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = repositoryRoot.appendingPathComponent("Sources/Ivy", isDirectory: true)
        let forbiddenFragments = [
            "Image(systemName:",
            "systemImage:",
            "systemSymbolName:",
            "Path {",
            "Canvas {",
        ]
        let files = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: nil
            )
        )

        for case let fileURL as URL in files where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            for fragment in forbiddenFragments {
                XCTAssertFalse(
                    source.contains(fragment),
                    "\(fileURL.lastPathComponent) bypasses IvyIcon with '\(fragment)'"
                )
            }
        }
    }
}
