import AppKit

/// One todo checkbox in the editor. Carries the checked state so the display
/// text can be serialized back to the note's `- [ ] ` / `- [x] ` form.
final class NoteTodoCheckboxAttachment: NSTextAttachment {
    var isChecked: Bool {
        get { (attachmentCell as? NoteTodoCheckboxCell)?.isChecked ?? false }
        set { (attachmentCell as? NoteTodoCheckboxCell)?.isChecked = newValue }
    }

    init(checked: Bool, color: NSColor) {
        super.init(data: nil, ofType: nil)
        attachmentCell = NoteTodoCheckboxCell(checked: checked, color: color)
    }

    required init?(coder: NSCoder) {
        fatalError("NoteTodoCheckboxAttachment is code-only")
    }
}

/// TextKit cell that draws the checkbox and flips it on click; NSTextView
/// routes attachment clicks here through the cell mouse-tracking API.
final class NoteTodoCheckboxCell: NSTextAttachmentCell {
    private enum Metrics {
        static let boxSize: CGFloat = 14
        static let trailingGap: CGFloat = 7
        static let baselineDrop: CGFloat = 2.5
        static let symbolPointSize: CGFloat = 12.5
    }

    var isChecked: Bool
    private let color: NSColor

    init(checked: Bool, color: NSColor) {
        self.isChecked = checked
        self.color = color
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        fatalError("NoteTodoCheckboxCell is code-only")
    }

    override func cellSize() -> NSSize {
        NSSize(width: Metrics.boxSize + Metrics.trailingGap, height: Metrics.boxSize)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -Metrics.baselineDrop)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let icon: IvyIcon = isChecked ? .todoChecked : .todoUnchecked
        let image = icon.nsImage(size: Metrics.symbolPointSize)
        let size = image.size
        let origin = NSPoint(
            x: cellFrame.minX + (Metrics.boxSize - size.width) / 2,
            y: cellFrame.midY - size.height / 2
        )
        image.draw(
            in: NSRect(origin: origin, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: color.alphaComponent * (isChecked ? 0.55 : 0.45),
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
            view.toggleTodo(at: charIndex)
        }
        return true
    }
}
