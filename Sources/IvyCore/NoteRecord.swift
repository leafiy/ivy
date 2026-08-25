import Foundation

/// Device-local placement of a note panel in global screen coordinates.
/// Never part of the sync payload: frames are meaningless across devices.
public struct NoteWindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One uploaded file referenced by a note. The API stores the binary on OSS;
/// notes only carry the returned URLs plus display metadata, and the whole
/// array syncs inside the notes database snapshot.
public struct NoteAttachment: Codable, Equatable, Identifiable, Sendable {
    public var url: String
    /// Server-generated compressed preview (≤600px wide) for image uploads.
    public var thumbnailURL: String?
    public var name: String
    public var sizeBytes: Int64
    public var contentType: String

    public var id: String { url }

    public var isImage: Bool {
        contentType.lowercased().hasPrefix("image/")
    }

    /// The URL the UI should render for a thumbnail; images without a
    /// server thumbnail fall back to the original.
    public var displayImageURL: String {
        thumbnailURL ?? url
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case thumbnailURL = "thumbnailUrl"
        case name
        case sizeBytes
        case contentType
    }

    public init(
        url: String,
        thumbnailURL: String? = nil,
        name: String,
        sizeBytes: Int64,
        contentType: String
    ) {
        self.url = url
        self.thumbnailURL = thumbnailURL
        self.name = name
        self.sizeBytes = sizeBytes
        self.contentType = contentType
    }
}

public struct NoteRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var color: String
    public var images: [String]
    public var attachments: [NoteAttachment]
    public var type: String
    public var updatedAt: Date
    public var deletedAt: Date?
    public var dirty: Bool
    public static let defaultFontSize: Double = 14
    public static let minimumFontSize: Double = 10
    public static let maximumFontSize: Double = 24

    /// Geometry, opacity, font size, and visibility are device-local.
    public var windowFrame: NoteWindowFrame?
    /// Pin state travels with note color and content in database snapshots.
    public var windowLevel: NoteWindowLevel
    public var windowOpacity: Double
    public var fontSize: Double
    public var closed: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        text: String,
        color: String = NoteColor.white.rawValue,
        images: [String] = [],
        attachments: [NoteAttachment] = [],
        type: String = "text",
        updatedAt: Date = Date(),
        deletedAt: Date? = nil,
        dirty: Bool = true,
        windowFrame: NoteWindowFrame? = nil,
        windowLevel: NoteWindowLevel = .normal,
        windowOpacity: Double = 1,
        fontSize: Double = NoteRecord.defaultFontSize,
        closed: Bool = false
    ) {
        self.id = id
        self.text = text
        self.color = color
        self.images = images
        self.attachments = attachments
        self.type = type
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.dirty = dirty
        self.windowFrame = windowFrame
        self.windowLevel = windowLevel
        self.windowOpacity = windowOpacity
        self.fontSize = fontSize
        self.closed = closed
    }
}
