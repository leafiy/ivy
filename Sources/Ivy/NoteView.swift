import AppKit
import SwiftUI
import IvyCore
import LeafiyUI
import UniformTypeIdentifiers

struct NoteView: View {
    private enum Layout {
        /// The editor draws with zero text inset, so the wrapper carries the
        /// full margin that puts the text edge on the controls' 24pt axis.
        static let bodyHorizontalPadding: CGFloat = 24
        static let bodyTopPadding: CGFloat = 52
        static let bodyBottomPadding: CGFloat = 18
        static let topControlHorizontalPadding: CGFloat = 10
        static let topControlTopPadding: CGFloat = 10
        static let actionHitSize: CGFloat = 28
        static let operationPanelWidth: CGFloat = 244
        static let attachmentControlSize: CGFloat = 20
        static let fileRowHeight: CGFloat = 28
        static let fileListMaxHeight: CGFloat = 92
    }

    let note: NoteRecord
    let uploadingFiles: [NoteUploadStatusItem]
    let onTextChange: (String, String) -> Void
    let onColorChange: (String, String) -> Void
    let onTogglePin: (String) -> Void
    let onOpacityChange: (String, Double) -> Void
    let onFontSizeChange: (String, Double) -> Void
    let onClose: (String) -> Void
    let onDelete: (String) -> Void
    let onAddAttachments: (String, [PendingNoteAttachment]) -> Void
    let onDeleteAttachment: (String, NoteAttachment) -> Void
    let onDownloadAttachment: (NoteAttachment) -> Void

    @State private var text: String
    @State private var isNoteFocused = false
    @State private var isMorePresented = false
    @State private var opacityPercent: Double
    @State private var fontSize: Double
    @State private var isDropTargeted = false
    @State private var editorHandle = NoteEditorHandle()
    @State private var editorLayoutTick = 0

    init(
        note: NoteRecord,
        uploadingFiles: [NoteUploadStatusItem],
        onTextChange: @escaping (String, String) -> Void,
        onColorChange: @escaping (String, String) -> Void,
        onTogglePin: @escaping (String) -> Void,
        onOpacityChange: @escaping (String, Double) -> Void,
        onFontSizeChange: @escaping (String, Double) -> Void,
        onClose: @escaping (String) -> Void,
        onDelete: @escaping (String) -> Void,
        onAddAttachments: @escaping (String, [PendingNoteAttachment]) -> Void,
        onDeleteAttachment: @escaping (String, NoteAttachment) -> Void,
        onDownloadAttachment: @escaping (NoteAttachment) -> Void
    ) {
        self.note = note
        self.uploadingFiles = uploadingFiles
        self.onTextChange = onTextChange
        self.onColorChange = onColorChange
        self.onTogglePin = onTogglePin
        self.onOpacityChange = onOpacityChange
        self.onFontSizeChange = onFontSizeChange
        self.onClose = onClose
        self.onDelete = onDelete
        self.onAddAttachments = onAddAttachments
        self.onDeleteAttachment = onDeleteAttachment
        self.onDownloadAttachment = onDownloadAttachment
        _text = State(initialValue: note.text)
        _opacityPercent = State(initialValue: note.windowOpacity * 100)
        _fontSize = State(initialValue: note.fontSize)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NoteWindowDragArea(
                onFocusChange: { isNoteFocused = $0 },
                onFocusEditor: focusEditor,
                onPasteAttachments: handlePasteAttachments,
                onIncreaseFontSize: { adjustFontSize(by: 1) },
                onDecreaseFontSize: { adjustFontSize(by: -1) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 0) {
                documentEditor

                if isFileSectionVisible {
                    fileSection
                        .padding(.horizontal, Layout.bodyHorizontalPadding)
                        .padding(.top, LeafiyDesign.Spacing.xs)
                        .padding(.bottom, Layout.bodyBottomPadding)
                }
            }

            topControls


            // Frontmost layer: the editor's NSTextView registers for file
            // drags itself and would otherwise insert file paths as text.
            // This catcher claims those drags while ignoring clicks.
            NoteDropCatcher(
                onTargeted: { isDropTargeted = $0 },
                onDrop: { pasteboard, point in
                    handleAttachmentPasteboard(pasteboard, dropPoint: point)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(noteBackgroundColor.opacity(effectiveSurfaceOpacity))
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(noteAccentColor, lineWidth: 2)
            }
        }
        .onAppear(perform: migrateLegacyImageAttachments)
        .onChange(of: text) { _, newValue in
            onTextChange(note.id, newValue)
            deleteOrphanedImageAttachments(text: newValue)
        }
        // Panel refreshes update this view in place, so local state survives
        // them; adopt outside text edits (a pending upload marker swapped for
        // its real URL, a failed one removed) or later edits would write the
        // stale marker back over them.
        .onChange(of: note.text) { _, newValue in
            if newValue != text {
                text = newValue
            }
        }
        .onChange(of: note.fontSize) { _, newValue in
            if newValue != fontSize {
                fontSize = newValue
                editorLayoutTick += 1
            }
        }
    }

    /// The note body is one scrolling document: the rich editor lays text
    /// and dropped images out together, so a picture lives exactly where it
    /// was dropped instead of in a thumbnail strip.
    private var documentEditor: some View {
        ScrollView(.vertical) {
            NoteRichTextEditor(
                text: $text,
                textColor: Self.nsSRGB(41, 37, 43),
                fontSize: fontSize,
                handle: editorHandle,
                layoutTick: editorLayoutTick,
                onLayoutChange: { editorLayoutTick += 1 },
                displayURLProvider: displayURL(forImageURL:)
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        // Margins stay outside the scroll view: its AppKit backing consumes
        // clicks, and the strips above and beside it are where the window
        // drag area must keep receiving them.
        .padding(.horizontal, Layout.bodyHorizontalPadding)
        .padding(.top, Layout.bodyTopPadding)
        .padding(.bottom, isFileSectionVisible ? LeafiyDesign.Spacing.s : Layout.bodyBottomPadding)
    }

    private var topControls: some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            moreButton

            Spacer(minLength: LeafiyDesign.Spacing.s)

            pinButton
        }
        .padding(.horizontal, Layout.topControlHorizontalPadding)
        .padding(.top, Layout.topControlTopPadding)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .opacity(areControlsVisible ? 1 : 0)
        .allowsHitTesting(areControlsVisible)
        .accessibilityHidden(!areControlsVisible)
        .animation(.easeOut(duration: 0.14), value: areControlsVisible)
    }

    private var moreButton: some View {
        Button {
            isMorePresented.toggle()
        } label: {
            IvyIconView(.more, size: 15)
                .foregroundStyle(strongContentColor.opacity(0.68))
                .frame(width: Layout.actionHitSize, height: Layout.actionHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("More Note Actions"))
        .accessibilityLabel(L("More Note Actions"))
        .popover(isPresented: $isMorePresented, arrowEdge: .top) {
            operationPanel
        }
    }

    private var pinButton: some View {
        Button {
            onTogglePin(note.id)
        } label: {
            IvyIconView(.pinState(isPinned), size: 14)
                .foregroundStyle(isPinned ? noteAccentColor : strongContentColor.opacity(0.68))
                .frame(width: Layout.actionHitSize, height: Layout.actionHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(isPinned ? "Unpin Note" : "Pin Note"))
        .accessibilityLabel(L(isPinned ? "Unpin Note" : "Pin Note"))
    }

    private var operationPanel: some View {
        VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.m) {
            VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.s) {
                Text(L("Note Color"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: LeafiyDesign.Spacing.xs) {
                    ForEach(NoteColor.allCases, id: \.rawValue) { color in
                        Button {
                            isMorePresented = false
                            onColorChange(note.id, color.rawValue)
                        } label: {
                            colorSwatch(color, diameter: 16)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L(color.localizationKey))
                        .accessibilityLabel(L(color.localizationKey))
                    }
                }
            }

            if isPinned {
                Divider()

                VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.s) {
                    HStack {
                        Text(L("Pinned Note Opacity"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("\(Int(opacityPercent.rounded()))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                    }

                    NoteOpacitySlider(value: $opacityPercent)
                        .onChange(of: opacityPercent) { _, newValue in
                            onOpacityChange(note.id, newValue / 100)
                        }
                        .accessibilityLabel(L("Pinned Note Opacity"))
                }
            }

            Divider()

            operationButton(
                title: L("Close Note"),
                icon: .close,
                role: nil
            ) {
                isMorePresented = false
                onClose(note.id)
            }

            operationButton(
                title: L("Delete Note"),
                icon: .trash,
                role: .destructive
            ) {
                isMorePresented = false
                onDelete(note.id)
            }
        }
        .padding(LeafiyDesign.Spacing.m)
        .frame(width: Layout.operationPanelWidth)
    }

    private func operationButton(
        title: String,
        icon: IvyIcon,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            IvyIconLabel(title, icon: icon, iconSize: 13)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 24)
    }

    // MARK: - Attachments

    private var imageAttachments: [NoteAttachment] {
        note.attachments.filter(\.isImage)
    }

    private var fileAttachments: [NoteAttachment] {
        note.attachments.filter { !$0.isImage }
    }

    private var uploadingFileRows: [NoteUploadStatusItem] {
        uploadingFiles.filter { !$0.isImage }
    }

    private var isFileSectionVisible: Bool {
        !fileAttachments.isEmpty || !uploadingFileRows.isEmpty
    }

    /// Inline markers store the original URL; rendering prefers the server's
    /// compressed thumbnail when the attachment metadata is present.
    private func displayURL(forImageURL url: String) -> String {
        note.attachments.first { $0.url == url }?.displayImageURL ?? url
    }

    private func focusEditor() {
        guard let textView = editorHandle.textView, let window = textView.window else { return }
        let needsInitialCaret = window.firstResponder !== textView
        window.makeKey()
        guard window.makeFirstResponder(textView), needsInitialCaret else { return }
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    private func adjustFontSize(by delta: Double) {
        let nextSize = min(
            max(fontSize + delta, NoteRecord.minimumFontSize),
            NoteRecord.maximumFontSize
        )
        guard nextSize != fontSize else { return }
        fontSize = nextSize
        editorLayoutTick += 1
        onFontSizeChange(note.id, nextSize)
    }

    /// Notes written before inline images existed carry image attachments
    /// that no marker references; append their markers once so those images
    /// stay visible in the new body layout.
    private func migrateLegacyImageAttachments() {
        let referenced = NoteInlineImage.referencedURLs(in: text)
        let missing = imageAttachments.filter { !referenced.contains($0.url) }
        guard !missing.isEmpty else { return }
        var migrated = text
        if !migrated.isEmpty, !migrated.hasSuffix("\n") {
            migrated += "\n"
        }
        for attachment in missing {
            migrated += NoteInlineImage.marker(name: attachment.name, url: attachment.url) + "\n"
        }
        text = migrated
    }

    /// Backspacing an inline image is its delete gesture: an image
    /// attachment whose marker left the text leaves the note too, freeing
    /// its server quota.
    private func deleteOrphanedImageAttachments(text: String) {
        let referenced = NoteInlineImage.referencedURLs(in: text)
        for attachment in imageAttachments where !referenced.contains(attachment.url) {
            onDeleteAttachment(note.id, attachment)
        }
    }

    /// Non-image attachments stay out of the body: a fixed list at the
    /// bottom with one readable row per file, plus a minimal spinner row per
    /// file still uploading.
    private var fileSection: some View {
        VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xs) {
            Rectangle()
                .fill(strongContentColor.opacity(0.08))
                .frame(height: 1)

            fileList
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fileList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: LeafiyDesign.Spacing.xxs) {
                ForEach(fileAttachments) { attachment in
                    fileRow(attachment)
                }
                ForEach(uploadingFileRows) { item in
                    uploadingRow(item)
                }
            }
        }
        .frame(height: fileListHeight)
    }

    private var fileListHeight: CGFloat {
        let rows = CGFloat(fileAttachments.count + uploadingFileRows.count)
        let height = rows * Layout.fileRowHeight + max(rows - 1, 0) * LeafiyDesign.Spacing.xxs
        return min(height, Layout.fileListMaxHeight)
    }

    private func fileRow(_ attachment: NoteAttachment) -> some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            IvyIconView(.file, size: 14)
                .foregroundStyle(noteAccentColor)

            Text(attachment.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primaryContentColor)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(NoteAttachmentFormat.sizeText(attachment.sizeBytes))
                .font(.system(size: 11))
                .foregroundStyle(strongContentColor.opacity(0.5))
                .layoutPriority(1)

            Spacer(minLength: LeafiyDesign.Spacing.xs)

            attachmentControl(
                icon: .download,
                help: L("Download Attachment"),
                tint: strongContentColor.opacity(0.6)
            ) {
                onDownloadAttachment(attachment)
            }

            attachmentControl(
                icon: .trash,
                help: L("Delete Attachment"),
                tint: strongContentColor.opacity(0.6)
            ) {
                onDeleteAttachment(note.id, attachment)
            }
        }
        .padding(.horizontal, LeafiyDesign.Spacing.s)
        .frame(height: Layout.fileRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            strongContentColor.opacity(0.05),
            in: .rect(cornerRadius: LeafiyDesign.Radius.control)
        )
    }

    /// Uploads run silently in the background queue; this spinner row is the
    /// only trace a file upload leaves while in flight.
    private func uploadingRow(_ item: NoteUploadStatusItem) -> some View {
        HStack(spacing: LeafiyDesign.Spacing.s) {
            IvyIconView(.file, size: 14)
                .foregroundStyle(strongContentColor.opacity(0.35))

            Text(item.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primaryContentColor.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: LeafiyDesign.Spacing.xs)

            ProgressView()
                .controlSize(.small)
        }
        .padding(.horizontal, LeafiyDesign.Spacing.s)
        .frame(height: Layout.fileRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            strongContentColor.opacity(0.03),
            in: .rect(cornerRadius: LeafiyDesign.Radius.control)
        )
    }

    private func attachmentControl(
        icon: IvyIcon,
        help: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            IvyIconView(icon, size: 13)
                .foregroundStyle(tint)
                .frame(width: Layout.attachmentControlSize, height: Layout.attachmentControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Consumes Cmd+V when the pasteboard carries files or raw image data;
    /// plain text keeps flowing to the editor.
    private func handlePasteAttachments() -> Bool {
        handleAttachmentPasteboard(NSPasteboard.general, dropPoint: nil)
    }

    /// Shared by paste and drop: file URLs win, then any image flavor.
    /// Images enter the note body right at the drop point (or the caret for
    /// pastes) as pending inline markers backed by their local bytes, so
    /// they render before the upload finishes; everything else queues for
    /// the file list. Returns false for anything unattachable so text
    /// handling stays native.
    private func handleAttachmentPasteboard(_ pasteboard: NSPasteboard, dropPoint: NSPoint?) -> Bool {
        var pending: [PendingNoteAttachment] = []
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            pending = urls.compactMap { PendingNoteAttachment(fileURL: $0) }
            guard !pending.isEmpty else { return false }
        } else if let item = PendingNoteAttachment(pasteboard: pasteboard) {
            pending = [item]
        } else {
            return false
        }

        var queued: [PendingNoteAttachment] = []
        var inlineImages: [NoteRichTextView.PendingImage] = []
        for var file in pending {
            if file.isImage {
                let markerID = UUID().uuidString.lowercased()
                file.inlineMarkerID = markerID
                NoteInlineImageStore.shared.registerLocal(
                    data: file.data,
                    for: NoteInlineImage.pendingURL(id: markerID)
                )
                inlineImages.append(.init(markerID: markerID, name: file.filename))
            }
            queued.append(file)
        }
        if !inlineImages.isEmpty {
            editorHandle.textView?.insertPendingImages(inlineImages, at: dropPoint)
        }
        onAddAttachments(note.id, queued)
        return true
    }

    private var areControlsVisible: Bool {
        isNoteFocused || isMorePresented
    }

    private var effectiveSurfaceOpacity: Double {
        isPinned ? opacityPercent / 100 : 1
    }

    private func colorSwatch(_ color: NoteColor, diameter: CGFloat) -> some View {
        Circle()
            .fill(Self.backgroundColor(for: color))
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .stroke(
                        color == selectedColor ? Self.accentColor(for: color) : strongContentColor.opacity(0.18),
                        lineWidth: color == selectedColor ? 1.5 : 0.75
                    )
            }
            .contentShape(Circle())
    }

    private var selectedColor: NoteColor {
        NoteColor(rawValue: note.color) ?? .white
    }

    private var isPinned: Bool {
        note.windowLevel == .pinned
    }

    private var noteBackgroundColor: Color {
        Self.backgroundColor(for: selectedColor)
    }

    private var primaryContentColor: Color {
        Self.srgb(41, 37, 43)
    }

    private var strongContentColor: Color {
        Self.srgb(23, 20, 25)
    }

    private var noteAccentColor: Color {
        Self.accentColor(for: selectedColor)
    }

    private static func backgroundColor(for color: NoteColor) -> Color {
        switch color {
        case .white:
            return srgb(255, 255, 255)
        case .pink:
            return srgb(255, 229, 249)
        case .gray:
            return srgb(255, 232, 228)
        case .yellow:
            return srgb(255, 238, 220)
        case .green:
            return srgb(229, 247, 239)
        case .blue:
            return srgb(231, 238, 255)
        case .purple:
            return srgb(238, 231, 255)
        }
    }

    private static func accentColor(for color: NoteColor) -> Color {
        switch color {
        case .white:
            return srgb(123, 116, 126)
        case .pink:
            return srgb(232, 90, 174)
        case .gray:
            return srgb(222, 122, 108)
        case .yellow:
            return srgb(200, 138, 62)
        case .green:
            return srgb(75, 156, 120)
        case .blue:
            return srgb(92, 123, 217)
        case .purple:
            return srgb(128, 101, 214)
        }
    }

    private static func srgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(.sRGB, red: red / 255, green: green / 255, blue: blue / 255)
    }

    private static func nsSRGB(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }

}

/// A compact, high-contrast slider without AppKit's automatic per-step tick
/// marks. The white thumb remains visible in both light and dark appearances.
private struct NoteOpacitySlider: View {
    @Binding var value: Double

    private enum Layout {
        static let minimumValue = 10.0
        static let maximumValue = 100.0
        static let trackHeight: CGFloat = 5
        static let thumbDiameter: CGFloat = 14
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Layout.thumbDiameter, 1)
            let progress = normalizedProgress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.22))
                    .frame(width: travel, height: Layout.trackHeight)
                    .offset(x: Layout.thumbDiameter / 2)

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: travel * progress, height: Layout.trackHeight)
                    .offset(x: Layout.thumbDiameter / 2)

                Circle()
                    .fill(Color.white)
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.28), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(0.22), radius: 1.5, y: 1)
                    .frame(width: Layout.thumbDiameter, height: Layout.thumbDiameter)
                    .offset(x: travel * progress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let rawProgress = (gesture.location.x - Layout.thumbDiameter / 2) / travel
                        let clampedProgress = min(max(rawProgress, 0), 1)
                        value = (Layout.minimumValue
                            + clampedProgress * (Layout.maximumValue - Layout.minimumValue)).rounded()
                    }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityValue("\(Int(value.rounded()))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                value = min(value + 1, Layout.maximumValue)
            case .decrement:
                value = max(value - 1, Layout.minimumValue)
            @unknown default:
                break
            }
        }
    }

    private var normalizedProgress: CGFloat {
        CGFloat(
            (min(max(value, Layout.minimumValue), Layout.maximumValue) - Layout.minimumValue)
                / (Layout.maximumValue - Layout.minimumValue)
        )
    }
}


/// AppKit-owned window background behind the editor and controls. It participates
/// in standard background movement and watches window-wide paste/font shortcuts.
private struct NoteWindowDragArea: NSViewRepresentable {
    let onFocusChange: (Bool) -> Void
    let onFocusEditor: () -> Void
    let onPasteAttachments: () -> Bool
    let onIncreaseFontSize: () -> Void
    let onDecreaseFontSize: () -> Void

    func makeNSView(context: Context) -> NoteWindowDragView {
        let view = NoteWindowDragView()
        view.onFocusChange = onFocusChange
        view.onFocusEditor = onFocusEditor
        view.onPasteAttachments = onPasteAttachments
        view.onIncreaseFontSize = onIncreaseFontSize
        view.onDecreaseFontSize = onDecreaseFontSize
        return view
    }

    func updateNSView(_ nsView: NoteWindowDragView, context: Context) {
        nsView.onFocusChange = onFocusChange
        nsView.onFocusEditor = onFocusEditor
        nsView.onPasteAttachments = onPasteAttachments
        nsView.onIncreaseFontSize = onIncreaseFontSize
        nsView.onDecreaseFontSize = onDecreaseFontSize
    }
}

private final class NoteWindowDragView: NSView {
    var onFocusChange: ((Bool) -> Void)?
    var onFocusEditor: (() -> Void)?
    var onPasteAttachments: (() -> Bool)?
    var onIncreaseFontSize: (() -> Void)?
    var onDecreaseFontSize: (() -> Void)?

    private var interactionMonitor: Any?
    private static let resizeFocusExclusionWidth: CGFloat = 8

    override var mouseDownCanMoveWindow: Bool { true }


    override func viewWillMove(toWindow newWindow: NSWindow?) {
        NotificationCenter.default.removeObserver(self)
        if newWindow == nil { removeInteractionMonitor() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installInteractionMonitorIfNeeded()
        guard let window else { return }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFocusChanged(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowFocusChanged(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )

        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.onFocusChange?(window.isKeyWindow)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeInteractionMonitor()
    }

    /// One local monitor per note window. Ordinary mouse-down focuses before
    /// SwiftUI's gesture arbitration; frame-resize mouse-down only makes the
    /// panel key, preserving the responder and avoiding editor relayout.
    /// Cmd+V keeps its attachment path, and font shortcuts affect only the key
    /// note. Every unhandled event continues untouched.
    private func installInteractionMonitorIfNeeded() {
        guard interactionMonitor == nil, window != nil else { return }
        interactionMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, let window = self.window, event.window === window else {
                return event
            }

            if event.type == .leftMouseDown {
                if self.isWindowResizeMouseDown(event, in: window) {
                    window.makeKey()
                } else {
                    self.onFocusEditor?()
                }
                return event
            }

            guard window.isKeyWindow else { return event }
            let modifiers = event.modifierFlags.intersection([
                .command, .shift, .option, .control
            ])
            let key = event.charactersIgnoringModifiers?.lowercased()

            if modifiers == .command, key == "v" {
                return self.onPasteAttachments?() == true ? nil : event
            }

            guard modifiers == .command || modifiers == [.command, .shift] else {
                return event
            }
            switch key {
            case "=", "+":
                self.onIncreaseFontSize?()
                return nil
            case "-", "_":
                self.onDecreaseFontSize?()
                return nil
            default:
                return event
            }
        }
    }

    private func isWindowResizeMouseDown(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard
            window.styleMask.contains(.resizable),
            let contentView = window.contentView
        else { return false }

        let point = contentView.convert(event.locationInWindow, from: nil)
        let bounds = contentView.bounds
        if !bounds.contains(point) { return true }
        return !bounds.insetBy(
            dx: Self.resizeFocusExclusionWidth,
            dy: Self.resizeFocusExclusionWidth
        ).contains(point)
    }



    private func removeInteractionMonitor() {
        if let interactionMonitor {
            NSEvent.removeMonitor(interactionMonitor)
            self.interactionMonitor = nil
        }
    }


    @objc private func windowFocusChanged(_ notification: Notification) {
        onFocusChange?(window?.isKeyWindow == true)
    }

}




/// A transparent AppKit layer above the whole note that claims file and image
/// drags before the editor's NSTextView can turn them into pasted path text.
/// AppKit picks the frontmost registered view as the dragging destination, so
/// this view must stay the last (topmost) layer; hitTest(nil) keeps every
/// click, scroll, and text interaction working underneath. The drop point is
/// forwarded (in window coordinates) so images can enter the text right
/// where they were dropped.
private struct NoteDropCatcher: NSViewRepresentable {
    let onTargeted: (Bool) -> Void
    let onDrop: (NSPasteboard, NSPoint) -> Bool

    func makeNSView(context: Context) -> NoteDropCatcherView {
        let view = NoteDropCatcherView()
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: NoteDropCatcherView, context: Context) {
        nsView.onTargeted = onTargeted
        nsView.onDrop = onDrop
    }
}

private final class NoteDropCatcherView: NSView {
    var onTargeted: ((Bool) -> Void)?
    var onDrop: ((NSPasteboard, NSPoint) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.image.identifier),
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("NoteDropCatcherView is code-only")
    }

    /// Mouse events never land here; only the dragging-destination protocol does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender.draggingPasteboard) else { return [] }
        onTargeted?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onTargeted?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onTargeted?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        return onDrop?(sender.draggingPasteboard, sender.draggingLocation) ?? false
    }

    private func accepts(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            return true
        }
        return pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier])
    }
}
