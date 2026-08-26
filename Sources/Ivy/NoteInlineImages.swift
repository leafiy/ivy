import AppKit
import IvyCore

/// Image bytes for inline note images. Freshly dropped images register their
/// local data here (keyed by the pending marker URL, later aliased to the
/// uploaded URL) so they render instantly; markers synced from other devices
/// fetch their bytes once and cache them. Posts `imageLoadedNotification`
/// when bytes arrive so open editors can relayout the waiting cell.
@MainActor
final class NoteInlineImageStore {
    static let shared = NoteInlineImageStore()
    static let imageLoadedNotification = Notification.Name("NoteInlineImageStore.imageLoaded")

    private var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func registerLocal(data: Data, for key: String) {
        guard let image = NSImage(data: data) else { return }
        images[key] = image
        NotificationCenter.default.post(name: Self.imageLoadedNotification, object: nil)
    }

    /// Returns the cached image, kicking off a one-shot fetch of `fetchURL`
    /// on a miss. The caller redraws when the notification fires.
    func image(for key: String, fetchingFrom fetchURL: String) -> NSImage? {
        if let image = images[key] { return image }
        guard
            !inFlight.contains(key),
            let url = URL(string: fetchURL),
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        inFlight.insert(key)
        Task {
            defer { inFlight.remove(key) }
            guard
                let (data, response) = try? await URLSession.shared.data(from: url),
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let image = NSImage(data: data)
            else { return }
            images[key] = image
            NotificationCenter.default.post(name: Self.imageLoadedNotification, object: nil)
        }
        return nil
    }
}

/// The editor's current wrap width, shared with every inline image cell it
/// hosts. Cells size like CSS `max-width: 100%` against this value, which
/// the text view keeps in sync with its actual frame — TextKit's own
/// callbacks (a proposed line fragment, or the container-less `cellSize()`
/// fallback) do not reliably carry the real wrap width.
final class NoteInlineImageLayoutMetrics {
    var wrapWidth: CGFloat = 0
}

/// One inline image in the editor. Carries the marker identity so the display
/// text can be serialized back to the note's plain-text form.
final class NoteInlineImageAttachment: NSTextAttachment {
    let markerURL: String
    let markerName: String

    init(
        markerURL: String,
        markerName: String,
        layoutMetrics: NoteInlineImageLayoutMetrics?
    ) {
        self.markerURL = markerURL
        self.markerName = markerName
        super.init(data: nil, ofType: nil)
        attachmentCell = NoteInlineImageCell(
            markerURL: markerURL,
            markerName: markerName,
            layoutMetrics: layoutMetrics
        )
    }

    required init?(coder: NSCoder) {
        fatalError("NoteInlineImageAttachment is code-only")
    }
}

/// TextKit cell that draws the image scaled to the editor's wrap width,
/// capped at 600pt, keeping its aspect ratio. Until bytes arrive it draws a
/// quiet rounded placeholder of fixed height. Clicking the picture reveals its
/// download and delete controls in the top-right corner.
final class NoteInlineImageCell: NSTextAttachmentCell {
    private enum Metrics {
        static let maxWidth: CGFloat = 600
        static let minWidth: CGFloat = 40
        static let placeholderHeight: CGFloat = 96
        static let cornerRadius: CGFloat = 8
        static let controlDiameter: CGFloat = 24
        static let controlInset: CGFloat = 8
        static let controlGap: CGFloat = 6
        static let controlIconSize: CGFloat = 12
    }

    /// The two controls a picture offers, right to left from its corner.
    private enum Control {
        case delete
        case download

        var icon: IvyIcon {
            switch self {
            case .delete: return .trash
            case .download: return .download
            }
        }
    }

    private let markerURL: String
    private let markerName: String
    private let layoutMetrics: NoteInlineImageLayoutMetrics?

    /// Set by the editor while this picture is the one the user tapped.
    var isShowingControls = false

    init(
        markerURL: String,
        markerName: String,
        layoutMetrics: NoteInlineImageLayoutMetrics?
    ) {
        self.markerURL = markerURL
        self.markerName = markerName
        self.layoutMetrics = layoutMetrics
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("NoteInlineImageCell is code-only")
    }

    private var resolvedImage: NSImage? {
        MainActor.assumeIsolated {
            NoteInlineImageStore.shared.image(for: markerURL, fetchingFrom: markerURL)
        }
    }

    /// An image still uploading has no server URL to save from; it can only
    /// be deleted.
    private var isDownloadable: Bool {
        !markerURL.hasPrefix("\(NoteInlineImage.pendingScheme)://")
    }

    /// CSS-like `max-width`: never wider than 600pt, the editor's wrap
    /// width, or whatever sane extra limit the caller passes in.
    private func availableWidth(extraLimit: CGFloat?) -> CGFloat {
        var limit = Metrics.maxWidth
        if let wrapWidth = layoutMetrics?.wrapWidth, wrapWidth > 0 {
            limit = min(limit, wrapWidth)
        }
        if let extraLimit, extraLimit > 0, extraLimit < 100_000 {
            limit = min(limit, extraLimit)
        }
        return max(limit, Metrics.minWidth)
    }

    private func displaySize(extraLimit: CGFloat?) -> NSSize {
        let available = availableWidth(extraLimit: extraLimit)
        guard
            let image = resolvedImage,
            image.size.width > 0,
            image.size.height > 0
        else {
            return NSSize(width: available, height: Metrics.placeholderHeight)
        }
        let width = min(image.size.width, available)
        let height = (width * image.size.height / image.size.width).rounded()
        return NSSize(width: width, height: max(height, 1))
    }

    override func cellSize() -> NSSize {
        displaySize(extraLimit: nil)
    }

    override func cellFrame(
        for textContainer: NSTextContainer,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(origin: .zero, size: displaySize(extraLimit: lineFrag.width))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(
            roundedRect: cellFrame,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        ).addClip()

        if let image = resolvedImage {
            image.draw(
                in: cellFrame,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue]
            )
        } else {
            NSColor.black.withAlphaComponent(0.05).setFill()
            cellFrame.fill()
            let image = IvyIcon.image.nsImage(size: 18)
            let size = image.size
            let origin = NSPoint(
                x: cellFrame.midX - size.width / 2,
                y: cellFrame.midY - size.height / 2
            )
            image.draw(
                in: NSRect(origin: origin, size: size),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.25,
                respectFlipped: true,
                hints: nil
            )
        }

        if isShowingControls {
            for placed in controls(in: cellFrame) {
                drawControl(placed.control, in: placed.rect)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Controls sit in the picture's top-right corner, delete outermost. A
    /// picture too small to seat them keeps its own surface: backspace
    /// remains the way to remove it.
    private func controls(in cellFrame: NSRect) -> [(control: Control, rect: NSRect)] {
        let diameter = Metrics.controlDiameter
        let span = diameter + Metrics.controlInset * 2
        guard cellFrame.width >= span, cellFrame.height >= span else { return [] }

        // A flipped text view puts the picture's top edge at minY.
        let y = cellFrame.minY + Metrics.controlInset
        var x = cellFrame.maxX - Metrics.controlInset - diameter
        var placed: [(control: Control, rect: NSRect)] = [
            (.delete, NSRect(x: x, y: y, width: diameter, height: diameter))
        ]
        x -= diameter + Metrics.controlGap
        if isDownloadable, x >= cellFrame.minX + Metrics.controlInset {
            placed.append((.download, NSRect(x: x, y: y, width: diameter, height: diameter)))
        }
        return placed
    }

    private func drawControl(_ control: Control, in rect: NSRect) {
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()

        let icon = control.icon.nsImage(size: Metrics.controlIconSize)
        let size = icon.size
        icon.draw(
            in: NSRect(
                origin: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                size: size
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 0.72,
            respectFlipped: true,
            hints: nil
        )
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func trackMouse(
        with theEvent: NSEvent,
        in cellFrame: NSRect,
        of controlView: NSView?,
        atCharacterIndex charIndex: Int,
        untilMouseUp flag: Bool
    ) -> Bool {
        guard let view = controlView as? NoteRichTextView else { return false }
        MainActor.assumeIsolated {
            let point = view.convert(theEvent.locationInWindow, from: nil)
            if isShowingControls,
               let hit = controls(in: cellFrame).first(where: { $0.rect.contains(point) }) {
                switch hit.control {
                case .download:
                    view.downloadInlineImage(url: markerURL, name: markerName)
                case .delete:
                    view.removeInlineImage(at: charIndex)
                }
                return
            }
            view.activateImageControls(self, at: charIndex)
        }
        return true
    }
}

/// Converts between the note's stored plain text (with `![name](url)` image
/// markers, `- [ ] ` todo prefixes, and `**`/`<u>`/`==` inline style
/// delimiters) and the attributed string the editor displays (attachment
/// cells and real text attributes at the marker positions).
enum NoteRichTextFormat {
    /// Background for `==highlight==` runs; translucent so it reads on every
    /// note color.
    static let highlightColor = NSColor(srgbRed: 1.0, green: 0.83, blue: 0.30, alpha: 0.45)

    static func attributedString(
        from text: String,
        attributes: [NSAttributedString.Key: Any],
        layoutMetrics: NoteInlineImageLayoutMetrics?
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let textColor = attributes[.foregroundColor] as? NSColor ?? .labelColor
        for (lineIndex, line) in text.components(separatedBy: "\n").enumerated() {
            if lineIndex > 0 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            var content = Substring(line)
            var todo: NoteTodoItem.Prefix?
            if let prefix = NoteTodoItem.prefix(ofLine: content) {
                todo = prefix
                content = content.dropFirst(prefix.length)
                result.append(todoAttachmentString(
                    checked: prefix.isChecked,
                    attributes: attributes,
                    textColor: textColor
                ))
            }
            let contentStart = result.length
            appendInlineContent(
                String(content),
                to: result,
                attributes: attributes,
                layoutMetrics: layoutMetrics
            )
            if todo?.isChecked == true, result.length > contentStart {
                result.addAttributes(
                    doneStyling(textColor: textColor),
                    range: NSRange(location: contentStart, length: result.length - contentStart)
                )
            }
        }
        return result
    }

    static func storedText(from attributed: NSAttributedString) -> String {
        var output = ""
        var spans: [NoteInlineStyle.Span] = []
        func flushSpans() {
            guard !spans.isEmpty else { return }
            output += NoteInlineStyle.markup(from: spans)
            spans = []
        }
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
            if let image = attrs[.attachment] as? NoteInlineImageAttachment {
                flushSpans()
                output += NoteInlineImage.marker(name: image.markerName, url: image.markerURL)
            } else if let todo = attrs[.attachment] as? NoteTodoCheckboxAttachment {
                flushSpans()
                output += NoteTodoItem.marker(checked: todo.isChecked)
            } else if attrs[.attachment] != nil {
                // Foreign attachments can never corrupt the stored text.
                flushSpans()
            } else {
                // Strip stray object-replacement characters for the same
                // reason. The done styling of checked todos (strikethrough,
                // dimmed color) intentionally stays display-only.
                let piece = (attributed.string as NSString)
                    .substring(with: range)
                    .replacingOccurrences(of: "\u{FFFC}", with: "")
                guard !piece.isEmpty else { return }
                let font = attrs[.font] as? NSFont
                spans.append(NoteInlineStyle.Span(
                    text: piece,
                    isBold: font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
                    isUnderline: (attrs[.underlineStyle] as? Int ?? 0) != 0,
                    isHighlight: attrs[.backgroundColor] != nil
                ))
            }
        }
        flushSpans()
        return output
    }

    /// One checkbox attachment character, ready for insertion at a line start.
    static func todoAttachmentString(
        checked: Bool,
        attributes: [NSAttributedString.Key: Any],
        textColor: NSColor
    ) -> NSAttributedString {
        let attachment = NoteTodoCheckboxAttachment(checked: checked, color: textColor)
        let piece = NSMutableAttributedString(attachment: attachment)
        var attrs = attributes
        attrs[.cursor] = NSCursor.pointingHand
        attrs.removeValue(forKey: .strikethroughStyle)
        piece.addAttributes(attrs, range: NSRange(location: 0, length: piece.length))
        return piece
    }

    /// Display-only styling for a completed todo's text; never serialized.
    static func doneStyling(textColor: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: textColor.withAlphaComponent(0.45),
        ]
    }

    private static func appendInlineContent(
        _ text: String,
        to result: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any],
        layoutMetrics: NoteInlineImageLayoutMetrics?
    ) {
        var cursor = text.startIndex
        for marker in NoteInlineImage.markers(in: text) {
            if cursor < marker.range.lowerBound {
                appendStyledText(
                    String(text[cursor..<marker.range.lowerBound]),
                    to: result,
                    attributes: attributes
                )
            }
            let attachment = NoteInlineImageAttachment(
                markerURL: marker.url,
                markerName: marker.name,
                layoutMetrics: layoutMetrics
            )
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes(attributes, range: NSRange(location: 0, length: piece.length))
            result.append(piece)
            cursor = marker.range.upperBound
        }
        if cursor < text.endIndex {
            appendStyledText(String(text[cursor...]), to: result, attributes: attributes)
        }
    }

    /// Renders `**bold**`, `<u>underline</u>` and `==highlight==` delimiters
    /// as real attributes, hiding the delimiter characters.
    private static func appendStyledText(
        _ text: String,
        to result: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        for span in NoteInlineStyle.spans(in: text) {
            var attrs = attributes
            if span.isBold, let font = attrs[.font] as? NSFont {
                attrs[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if span.isUnderline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if span.isHighlight {
                attrs[.backgroundColor] = highlightColor
            }
            result.append(NSAttributedString(string: span.text, attributes: attrs))
        }
    }
}
