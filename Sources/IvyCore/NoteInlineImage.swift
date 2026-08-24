import Foundation

/// Markdown-style inline image markers embedded in a note's plain text
/// (`![name](url)`). The macOS editor renders them as inline pictures at the
/// position they occupy; any other client sees a readable markdown reference.
/// While an image is still uploading, its marker carries an
/// `ivy-upload://<id>` URL that is replaced with the real URL on completion.
public enum NoteInlineImage {
    public struct Marker: Equatable {
        public let name: String
        public let url: String
        public let range: Range<String.Index>

        public init(name: String, url: String, range: Range<String.Index>) {
            self.name = name
            self.url = url
            self.range = range
        }
    }

    public static let pendingScheme = "ivy-upload"

    private static let markerRegex = try! NSRegularExpression(
        pattern: "!\\[([^\\]\\n]*)\\]\\(([^)\\s]+)\\)"
    )

    public static func pendingURL(id: String) -> String {
        "\(pendingScheme)://\(id)"
    }

    public static func marker(name: String, url: String) -> String {
        "![\(sanitizedName(name))](\(url))"
    }

    /// Strips the characters that would break the marker syntax out of a
    /// filename before it is embedded.
    public static func sanitizedName(_ name: String) -> String {
        String(name.map { "[]()\n".contains($0) ? "-" : $0 })
    }

    public static func markers(in text: String) -> [Marker] {
        let ns = text as NSString
        let matches = markerRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Marker(
                name: ns.substring(with: match.range(at: 1)),
                url: ns.substring(with: match.range(at: 2)),
                range: range
            )
        }
    }

    public static func referencedURLs(in text: String) -> Set<String> {
        Set(markers(in: text).map(\.url))
    }

    /// Swaps an upload placeholder for the real URL the server returned.
    public static func replacingPendingURL(id: String, with url: String, in text: String) -> String {
        text.replacingOccurrences(of: pendingURL(id: id), with: url)
    }

    /// Removes a failed upload's marker entirely, swallowing one trailing
    /// newline so the image's line does not survive as a blank line.
    public static func removingPendingMarker(id: String, from text: String) -> String {
        let pendingURL = pendingURL(id: id)
        guard let marker = markers(in: text).first(where: { $0.url == pendingURL }) else {
            return text
        }
        var range = marker.range
        if range.upperBound < text.endIndex, text[range.upperBound] == "\n" {
            range = range.lowerBound..<text.index(after: range.upperBound)
        }
        var result = text
        result.removeSubrange(range)
        return result
    }
}
