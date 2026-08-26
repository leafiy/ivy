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

    /// Wraps pasteboard bytes as an upload, so a pasted picture or file
    /// travels the same route a dropped one does. Concrete image flavors keep
    /// their original bytes and type; anything else the pasteboard carries as
    /// a file's data (a PDF, an archive) uploads as an ordinary file. Only
    /// pasteboards that carry text are refused, leaving ordinary copy/paste
    /// to the editor.
    init?(pasteboard: NSPasteboard) {
        guard let attachment = Self.imageAttachment(pasteboard: pasteboard)
            ?? Self.fileAttachment(pasteboard: pasteboard)
        else { return nil }
        self = attachment
    }

    /// Image flavors whose bytes upload verbatim, best first. TIFF is absent
    /// on purpose: it is the screenshot flavor, and its uncompressed bytes
    /// would eat the account's attachment quota.
    private static let losslessImageFlavors: [(type: NSPasteboard.PasteboardType, contentType: String, fileExtension: String)] = [
        (.png, "image/png", "png"),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), "image/jpeg", "jpg"),
        (NSPasteboard.PasteboardType(UTType.gif.identifier), "image/gif", "gif"),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), "image/heic", "heic"),
        (NSPasteboard.PasteboardType(UTType.webP.identifier), "image/webp", "webp"),
    ]

    private static func imageAttachment(pasteboard: NSPasteboard) -> PendingNoteAttachment? {
        for flavor in losslessImageFlavors {
            guard let data = pasteboard.data(forType: flavor.type), !data.isEmpty else { continue }
            return PendingNoteAttachment(
                filename: generatedImageName(fileExtension: flavor.fileExtension),
                contentType: flavor.contentType,
                data: data
            )
        }

        // A copied screenshot and every other flavor AppKit can decode becomes
        // PNG. Text pasteboards are excluded first: rich text from a word
        // processor also carries a PDF rendering, and pasting it must stay
        // text.
        guard
            !carriesText(pasteboard),
            let image = NSImage(pasteboard: pasteboard),
            let tiff = image.tiffRepresentation,
            let representation = NSBitmapImageRep(data: tiff),
            let png = representation.representation(using: .png, properties: [:])
        else { return nil }
        return PendingNoteAttachment(
            filename: generatedImageName(fileExtension: "png"),
            contentType: "image/png",
            data: png
        )
    }

    /// Any remaining pasteboard that holds one file's bytes and no text at
    /// all — a PDF page, an archive, a document dragged out of an app that
    /// never wrote it to disk.
    private static func fileAttachment(pasteboard: NSPasteboard) -> PendingNoteAttachment? {
        guard !carriesText(pasteboard) else { return nil }
        for pasteboardType in pasteboard.types ?? [] {
            guard
                let type = UTType(pasteboardType.rawValue),
                type.conforms(to: .data),
                !type.conforms(to: .text),
                !type.conforms(to: .url),
                let data = pasteboard.data(forType: pasteboardType),
                !data.isEmpty
            else { continue }
            return PendingNoteAttachment(
                filename: generatedFileName(
                    fileExtension: type.preferredFilenameExtension ?? "dat"
                ),
                contentType: type.preferredMIMEType ?? "application/octet-stream",
                data: data
            )
        }
        return nil
    }

    private static func carriesText(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: [.string, .rtf, .rtfd, .html]) != nil
    }

    var uploadFile: AttachmentUploadFile {
        AttachmentUploadFile(filename: filename, contentType: contentType, data: data)
    }

    static func generatedImageName(fileExtension: String, now: Date = Date()) -> String {
        generatedName(prefix: "Image", fileExtension: fileExtension, now: now)
    }

    static func generatedFileName(fileExtension: String, now: Date = Date()) -> String {
        generatedName(prefix: "File", fileExtension: fileExtension, now: now)
    }

    /// Pasteboard bytes arrive nameless; the timestamp keeps one note's
    /// pasted files apart from each other.
    private static func generatedName(
        prefix: String,
        fileExtension: String,
        now: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(prefix)-\(formatter.string(from: now)).\(fileExtension)"
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
