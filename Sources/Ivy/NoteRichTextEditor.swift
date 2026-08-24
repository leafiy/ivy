import AppKit
import SwiftUI
import IvyCore

/// Lets SwiftUI-side code (tap-to-focus, drop handling) reach the AppKit
/// editor that a representable created.
final class NoteEditorHandle {
    weak var textView: NoteRichTextView?
}

/// The note body editor: an AppKit text view that renders inline image
/// markers as pictures (max 600pt wide, each on its own line) and reports
/// its laid-out height so it can grow inside the surrounding document
/// scroll instead of scrolling internally.
struct NoteRichTextEditor: NSViewRepresentable {
    @Binding var text: String
    let textColor: NSColor
    let fontSize: Double
    let handle: NoteEditorHandle
    /// Bumped when an async image finishes loading, so SwiftUI re-queries
    /// sizeThatFits even though the text itself is unchanged.
    let layoutTick: Int
    let onLayoutChange: () -> Void
    let displayURLProvider: (String) -> String

    private var font: NSFont { NSFont.systemFont(ofSize: CGFloat(fontSize)) }
    private static let lineSpacing: CGFloat = 6

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onLayoutChange: onLayoutChange)
    }

    func makeNSView(context: Context) -> NoteRichTextView {
        // Attachment cells require the TextKit 1 stack; build it explicitly
        // instead of relying on NSTextView's default.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let view = NoteRichTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize.zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false

        let attributes = makeAttributes()
        view.font = font
        view.renderedFontSize = font.pointSize
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.typingAttributes = attributes
        view.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        view.textStorage?.setAttributedString(
            NoteRichTextFormat.attributedString(
                from: text,
                attributes: attributes,
                displayURLProvider: displayURLProvider,
                layoutMetrics: view.layoutMetrics
            )
        )

        context.coordinator.textView = view
        // TextKit's back-references are weak; someone must own the storage
        // for the manually assembled stack, and the coordinator outlives
        // the view.
        context.coordinator.retainedStorage = storage
        handle.textView = view
        return view
    }

    func updateNSView(_ nsView: NoteRichTextView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onLayoutChange = onLayoutChange
        handle.textView = nsView
        let fontChanged = nsView.renderedFontSize != font.pointSize

        // Never rebuild while an input method holds marked text.
        guard !nsView.hasMarkedText() else { return }
        let current = NoteRichTextFormat.storedText(from: nsView.attributedString())
        guard current != text || fontChanged else { return }

        let selection = nsView.selectedRange()
        let attributes = makeAttributes()
        nsView.font = font
        nsView.renderedFontSize = font.pointSize
        nsView.textStorage?.setAttributedString(
            NoteRichTextFormat.attributedString(
                from: text,
                attributes: attributes,
                displayURLProvider: displayURLProvider,
                layoutMetrics: nsView.layoutMetrics
            )
        )
        nsView.typingAttributes = attributes
        // The swap bypassed the undo stack, so recorded ranges no longer
        // line up with the content.
        nsView.undoManager?.removeAllActions()
        let length = (nsView.string as NSString).length
        nsView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NoteRichTextView,
        context: Context
    ) -> CGSize? {
        _ = layoutTick
        guard
            let container = nsView.textContainer,
            let layoutManager = nsView.layoutManager
        else { return nil }
        var width = proposal.width ?? max(nsView.bounds.width, 240)
        if !width.isFinite { width = 600 }
        guard width > 0 else { return nil }
        nsView.layoutMetrics.wrapWidth = width
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height
        let minHeight = layoutManager.defaultLineHeight(for: font) + Self.lineSpacing
        return CGSize(width: width, height: max(usedHeight.rounded(.up), minHeight))
    }

    private func makeAttributes() -> [NSAttributedString.Key: Any] {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = Self.lineSpacing
        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle,
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onLayoutChange: () -> Void
        weak var textView: NoteRichTextView?
        var retainedStorage: NSTextStorage?
        private var imageObserver: NSObjectProtocol?

        init(text: Binding<String>, onLayoutChange: @escaping () -> Void) {
            self.text = text
            self.onLayoutChange = onLayoutChange
            super.init()
            imageObserver = NotificationCenter.default.addObserver(
                forName: NoteInlineImageStore.imageLoadedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.relayoutImages()
                }
            }
        }

        deinit {
            if let imageObserver {
                NotificationCenter.default.removeObserver(imageObserver)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            text.wrappedValue = NoteRichTextFormat.storedText(from: view.attributedString())
        }

        /// Keeps the insertion point behind a line's checkbox so typed text
        /// cannot slip in front of it and break the stored `- [ ]` marker.
        func textView(
            _ textView: NSTextView,
            willChangeSelectionFromCharacterRange oldRange: NSRange,
            toCharacterRange newRange: NSRange
        ) -> NSRange {
            guard
                newRange.length == 0,
                let storage = textView.textStorage,
                newRange.location < storage.length,
                storage.attribute(.attachment, at: newRange.location, effectiveRange: nil)
                    is NoteTodoCheckboxAttachment
            else { return newRange }
            let ns = textView.string as NSString
            let lineStart = ns.lineRange(for: NSRange(location: newRange.location, length: 0)).location
            guard newRange.location == lineStart else { return newRange }
            // Arrow-left from behind the checkbox continues to the previous
            // line instead of getting stuck.
            if oldRange.length == 0, oldRange.location == newRange.location + 1, lineStart > 0 {
                return NSRange(location: lineStart - 1, length: 0)
            }
            return NSRange(location: newRange.location + 1, length: 0)
        }

        /// A freshly loaded image changes its attachment cell's size, so
        /// TextKit must relayout and SwiftUI must re-query the height.
        private func relayoutImages() {
            guard
                let view = textView,
                let layoutManager = view.layoutManager,
                let storage = view.textStorage,
                storage.length > 0
            else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: fullRange)
            onLayoutChange()
        }
    }
}

/// The inline formatting operations the slash popup and the keyboard
/// shortcuts share.
enum NoteInlineStyleCommand {
    case bold
    case underline
    case highlight
}

/// NSTextView subclass that keeps pasted content plain, lets the note insert
/// pending inline images at a drop point, and carries the note's quick
/// formatting: the "/" command popup, todo checkboxes, and inline styles.
final class NoteRichTextView: NSTextView {
    struct PendingImage {
        let markerID: String
        let name: String
    }

    /// Shared with every inline image cell; mirrors the view's real width so
    /// images size like CSS `max-width: 100%` no matter which TextKit path
    /// asks for their size.
    let layoutMetrics = NoteInlineImageLayoutMetrics()
    var renderedFontSize: CGFloat = CGFloat(NoteRecord.defaultFontSize)

    /// Where the "/" that opened the command popup sits, so choosing a
    /// command can remove it.
    private var slashLocation: Int?

    /// A note panel is non-activating, so the editor must explicitly accept
    /// the click that gives the panel key status instead of requiring a
    /// second click before AppKit sends it to NSTextView.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, layoutMetrics.wrapWidth != newSize.width else { return }
        layoutMetrics.wrapWidth = newSize.width
        if let layoutManager, let textStorage, textStorage.length > 0 {
            layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textStorage.length),
                actualCharacterRange: nil
            )
        }
    }

    /// Attachments render pictures, but typed and pasted content stays plain.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// Inserts one pending image per line at the drop point (window
    /// coordinates), or at the caret when the image was pasted.
    func insertPendingImages(_ items: [PendingImage], at windowPoint: NSPoint?) {
        guard let storage = textStorage, !items.isEmpty else { return }

        let length = (string as NSString).length
        var index: Int
        if let windowPoint {
            index = characterIndexForInsertion(at: convert(windowPoint, from: nil))
        } else {
            index = selectedRange().upperBound
        }
        index = max(0, min(index, length))

        let newline = NSAttributedString(string: "\n", attributes: typingAttributes)
        let insertion = NSMutableAttributedString()
        if index > 0, (string as NSString).character(at: index - 1) != 0x0A {
            insertion.append(newline)
        }
        for item in items {
            let markerURL = NoteInlineImage.pendingURL(id: item.markerID)
            let attachment = NoteInlineImageAttachment(
                markerURL: markerURL,
                markerName: NoteInlineImage.sanitizedName(item.name),
                displayURL: markerURL,
                layoutMetrics: layoutMetrics
            )
            let piece = NSMutableAttributedString(attachment: attachment)
            piece.addAttributes(typingAttributes, range: NSRange(location: 0, length: piece.length))
            insertion.append(piece)
            insertion.append(newline)
        }

        guard shouldChangeText(
            in: NSRange(location: index, length: 0),
            replacementString: insertion.string
        ) else { return }
        storage.insert(insertion, at: index)
        setSelectedRange(NSRange(location: index + insertion.length, length: 0))
        didChangeText()
    }

    // MARK: - Slash command popup

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        let inserted = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        guard inserted == "/" else { return }
        let location = selectedRange().location - 1
        guard location >= 0, isSlashTrigger(at: location) else { return }
        presentSlashMenu(for: location)
    }

    /// The popup only opens for a "/" typed at a line start or after
    /// whitespace (or a checkbox), so URLs and dates keep typing cleanly.
    private func isSlashTrigger(at location: Int) -> Bool {
        guard location > 0 else { return true }
        switch (string as NSString).character(at: location - 1) {
        case 0x0A, 0x20, 0x09, 0xFFFC:
            return true
        default:
            return false
        }
    }

    private func presentSlashMenu(for location: Int) {
        slashLocation = location
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(commandMenuItem(
            title: L("Todo List"),
            action: #selector(slashInsertTodo),
            keyEquivalent: "",
            modifiers: [],
            icon: .todo,
            state: false
        ))
        menu.addItem(.separator())
        menu.addItem(commandMenuItem(
            title: L("Bold"),
            action: #selector(slashToggleBold),
            keyEquivalent: "b",
            modifiers: [.command],
            icon: .bold,
            state: isStyleActive(in: typingAttributes, .bold)
        ))
        menu.addItem(commandMenuItem(
            title: L("Underline"),
            action: #selector(slashToggleUnderline),
            keyEquivalent: "u",
            modifiers: [.command],
            icon: .underline,
            state: isStyleActive(in: typingAttributes, .underline)
        ))
        menu.addItem(commandMenuItem(
            title: L("Highlight"),
            action: #selector(slashToggleHighlight),
            keyEquivalent: "h",
            modifiers: [.command, .shift],
            icon: .highlight,
            state: isStyleActive(in: typingAttributes, .highlight)
        ))

        let point = caretMenuPoint(for: location)
        // The "/" keystroke is still being processed; popping the tracking
        // loop must wait until the insertion has fully settled.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = menu.popUp(positioning: menu.items.first, at: point, in: self)
        }
    }

    private func commandMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        icon: IvyIcon,
        state: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        item.image = icon.nsImage(size: 16)
        item.state = state ? .on : .off
        return item
    }

    private func caretMenuPoint(for location: Int) -> NSPoint {
        guard let layoutManager, let textContainer else {
            return NSPoint(x: 0, y: bounds.maxY)
        }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return NSPoint(x: rect.minX, y: rect.maxY + 4)
    }

    @objc private func slashInsertTodo() {
        consumeSlash()
        toggleTodoOnSelectedLines()
    }

    @objc private func slashToggleBold() {
        consumeSlash()
        toggleInlineStyle(.bold)
    }

    @objc private func slashToggleUnderline() {
        consumeSlash()
        toggleInlineStyle(.underline)
    }

    @objc private func slashToggleHighlight() {
        consumeSlash()
        toggleInlineStyle(.highlight)
    }

    /// Removes the "/" that opened the popup. Dismissing the popup without
    /// choosing anything keeps the "/" as ordinary text.
    private func consumeSlash() {
        guard let location = slashLocation else { return }
        slashLocation = nil
        let ns = string as NSString
        guard
            location < ns.length,
            ns.substring(with: NSRange(location: location, length: 1)) == "/"
        else { return }
        insertText("", replacementRange: NSRange(location: location, length: 1))
    }

    // MARK: - Inline styles

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == .command, key == "b" {
            toggleInlineStyle(.bold)
            return true
        }
        if modifiers == .command, key == "u" {
            toggleInlineStyle(.underline)
            return true
        }
        if modifiers == [.command, .shift], key == "h" {
            toggleInlineStyle(.highlight)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Applies the style to the selection, or toggles it for text typed next
    /// when the selection is empty.
    func toggleInlineStyle(_ style: NoteInlineStyleCommand) {
        let range = selectedRange()
        if range.length == 0 {
            let active = isStyleActive(in: typingAttributes, style)
            typingAttributes = applying(style, to: typingAttributes, active: !active)
            return
        }
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else {
            return
        }
        let active = isStyleActive(throughout: range, in: storage, style)
        storage.beginEditing()
        storage.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            storage.setAttributes(applying(style, to: attrs, active: !active), range: subRange)
        }
        storage.endEditing()
        didChangeText()
    }

    private func isStyleActive(
        in attributes: [NSAttributedString.Key: Any],
        _ style: NoteInlineStyleCommand
    ) -> Bool {
        switch style {
        case .bold:
            return (attributes[.font] as? NSFont)?
                .fontDescriptor.symbolicTraits.contains(.bold) == true
        case .underline:
            return (attributes[.underlineStyle] as? Int ?? 0) != 0
        case .highlight:
            return attributes[.backgroundColor] != nil
        }
    }

    /// Whether every text run of the range already carries the style;
    /// attachment characters do not count.
    private func isStyleActive(
        throughout range: NSRange,
        in storage: NSTextStorage,
        _ style: NoteInlineStyleCommand
    ) -> Bool {
        var active = true
        storage.enumerateAttributes(in: range, options: []) { attrs, _, stop in
            if attrs[.attachment] == nil, !isStyleActive(in: attrs, style) {
                active = false
                stop.pointee = true
            }
        }
        return active
    }

    private func applying(
        _ style: NoteInlineStyleCommand,
        to attributes: [NSAttributedString.Key: Any],
        active: Bool
    ) -> [NSAttributedString.Key: Any] {
        var attrs = attributes
        switch style {
        case .bold:
            if let font = attrs[.font] as? NSFont {
                attrs[.font] = active
                    ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    : NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
            }
        case .underline:
            if active {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            } else {
                attrs.removeValue(forKey: .underlineStyle)
            }
        case .highlight:
            if active {
                attrs[.backgroundColor] = NoteRichTextFormat.highlightColor
            } else {
                attrs.removeValue(forKey: .backgroundColor)
            }
        }
        return attrs
    }

    // MARK: - Todos

    /// Adds an unchecked checkbox to every selected line, or removes the
    /// checkboxes when every selected line already has one.
    func toggleTodoOnSelectedLines() {
        guard let storage = textStorage else { return }
        let ns = string as NSString
        let linesRange = ns.lineRange(for: selectedRange())
        var lineStarts: [Int] = []
        var location = linesRange.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            lineStarts.append(line.location)
            if line.length == 0 { break }
            location = line.upperBound
        } while location < linesRange.upperBound

        let allTodo = lineStarts.allSatisfy { todoAttachment(at: $0) != nil }
        for start in lineStarts.reversed() {
            if allTodo {
                let range = NSRange(location: start, length: 1)
                guard shouldChangeText(in: range, replacementString: "") else { continue }
                storage.replaceCharacters(in: range, with: "")
                removeDoneStyling(inLineAt: start)
            } else if todoAttachment(at: start) == nil {
                let piece = NoteRichTextFormat.todoAttachmentString(
                    checked: false,
                    attributes: cleanTypingAttributes,
                    textColor: textColor ?? .labelColor
                )
                guard shouldChangeText(
                    in: NSRange(location: start, length: 0),
                    replacementString: piece.string
                ) else { continue }
                storage.insert(piece, at: start)
            }
        }
        didChangeText()
    }

    /// Flips one checkbox and restyles its line; the checkbox cell calls
    /// this when clicked. Rewrites the whole line in one text change so undo
    /// restores the checkbox and the line styling together.
    func toggleTodo(at index: Int) {
        guard let storage = textStorage, let attachment = todoAttachment(at: index) else { return }
        let checked = !attachment.isChecked
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
        let color = textColor ?? .labelColor

        var checkboxAttributes = storage.attributes(at: index, effectiveRange: nil)
        checkboxAttributes.removeValue(forKey: .attachment)
        let replacement = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: lineRange)
        )
        let local = index - lineRange.location
        replacement.replaceCharacters(
            in: NSRange(location: local, length: 1),
            with: NoteRichTextFormat.todoAttachmentString(
                checked: checked,
                attributes: checkboxAttributes,
                textColor: color
            )
        )
        var contentRange = NSRange(location: local + 1, length: replacement.length - local - 1)
        if contentRange.length > 0, replacement.string.hasSuffix("\n") {
            contentRange.length -= 1
        }
        if contentRange.length > 0 {
            if checked {
                replacement.addAttributes(
                    NoteRichTextFormat.doneStyling(textColor: color),
                    range: contentRange
                )
            } else {
                replacement.removeAttribute(.strikethroughStyle, range: contentRange)
                replacement.addAttribute(.foregroundColor, value: color, range: contentRange)
            }
        }

        let selection = selectedRange()
        guard shouldChangeText(in: lineRange, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: lineRange, with: replacement)
        setSelectedRange(selection)
        didChangeText()
    }

    /// Return inside a todo item continues the list with a fresh unchecked
    /// item; Return on an empty item removes its checkbox instead, leaving
    /// the list.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let ns = string as NSString
        guard selection.length == 0, selection.location <= ns.length else {
            super.insertNewline(sender)
            return
        }
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        guard todoAttachment(at: lineRange.location) != nil else {
            super.insertNewline(sender)
            return
        }

        var contentEnd = lineRange.upperBound
        if contentEnd > lineRange.location, ns.character(at: contentEnd - 1) == 0x0A {
            contentEnd -= 1
        }
        if contentEnd <= lineRange.location + 1 {
            let range = NSRange(location: lineRange.location, length: 1)
            guard shouldChangeText(in: range, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
            return
        }

        super.insertNewline(sender)
        let caret = selectedRange().location
        let attrs = cleanTypingAttributes
        let piece = NoteRichTextFormat.todoAttachmentString(
            checked: false,
            attributes: attrs,
            textColor: textColor ?? .labelColor
        )
        guard shouldChangeText(
            in: NSRange(location: caret, length: 0),
            replacementString: piece.string
        ) else { return }
        textStorage?.insert(piece, at: caret)
        setSelectedRange(NSRange(location: caret + 1, length: 0))
        typingAttributes = attrs
        // Splitting a completed item must not drag the done styling onto the
        // fresh line.
        removeDoneStyling(inLineAt: caret + 1)
        didChangeText()
    }

    private func todoAttachment(at index: Int) -> NoteTodoCheckboxAttachment? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        return storage.attribute(.attachment, at: index, effectiveRange: nil)
            as? NoteTodoCheckboxAttachment
    }

    private func removeDoneStyling(inLineAt index: Int) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let ns = string as NSString
        var lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0))
        if lineRange.length > 0, ns.character(at: lineRange.upperBound - 1) == 0x0A {
            lineRange.length -= 1
        }
        guard lineRange.length > 0 else { return }
        storage.removeAttribute(.strikethroughStyle, range: lineRange)
        storage.addAttribute(.foregroundColor, value: textColor ?? .labelColor, range: lineRange)
    }

    /// Typing attributes with the display-only done styling stripped, for
    /// text that starts a fresh (unchecked) todo item.
    private var cleanTypingAttributes: [NSAttributedString.Key: Any] {
        var attrs = typingAttributes
        attrs.removeValue(forKey: .strikethroughStyle)
        attrs.removeValue(forKey: .cursor)
        if let color = textColor {
            attrs[.foregroundColor] = color
        }
        return attrs
    }
}
