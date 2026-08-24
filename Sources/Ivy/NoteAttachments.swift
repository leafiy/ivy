import AppKit
import Foundation
import IvyCore
import UniformTypeIdentifiers

/// A file the user dropped or pasted onto a note, held in memory until the
/// API stores it on OSS and returns the URLs the note actually keeps.
struct PendingNoteAttachment {
    let filename: String
    let contentType: String
    let data: Data
    /// Set when this image already occupies a pending inline marker in the
    /// note text; upload completion swaps the marker for the real URL.
    var inlineMarkerID: String?

    init(filename: String, contentType: String, data: Data) {
        self.filename = filename
        self.contentType = contentType
        self.data = data
    }

    var isImage: Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    /// Reads a dropped or pasted file from disk. Folders are not attachable.
    init?(fileURL: URL) {
        var isDirectory: ObjCBool = false
        guard
            fileURL.isFileURL,
            FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let data = try? Data(contentsOf: fileURL)
        else { return nil }

        let type = UTType(filenameExtension: fileURL.pathExtension)
        self.init(
            filename: fileURL.lastPathComponent,
            contentType: type?.preferredMIMEType ?? "application/octet-stream",
            data: data
        )
    }

    /// Wraps raw image bytes from the pasteboard (a copied screenshot or an
    /// image copied out of another app) as a PNG upload.
    init?(pasteboard: NSPasteboard) {
        if let png = pasteboard.data(forType: .png) {
            self.init(
                filename: Self.generatedImageName(fileExtension: "png"),
                contentType: "image/png",
                data: png
            )
            return
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let representation = NSBitmapImageRep(data: tiff),
           let png = representation.representation(using: .png, properties: [:]) {
            self.init(
                filename: Self.generatedImageName(fileExtension: "png"),
                contentType: "image/png",
                data: png
            )
            return
        }
        // Any remaining image flavor (JPEG dragged out of a browser, etc.).
        guard
            let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiff),
            let png = representation.representation(using: .png, properties: [:])
        else { return nil }
        self.init(
            filename: Self.generatedImageName(fileExtension: "png"),
            contentType: "image/png",
            data: png
        )
    }

    var uploadFile: AttachmentUploadFile {
        AttachmentUploadFile(filename: filename, contentType: contentType, data: data)
    }

    static func generatedImageName(fileExtension: String, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Image-\(formatter.string(from: now)).\(fileExtension)"
    }
}

/// One row of minimal upload state shown in the note's file list while its
/// file sits in the background upload queue.
struct NoteUploadStatusItem: Identifiable, Equatable {
    let id: String
    let name: String
    let isImage: Bool
}

enum NoteAttachmentFormat {
    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func sizeText(_ bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }
}
