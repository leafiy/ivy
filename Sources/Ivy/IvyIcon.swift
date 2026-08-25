import AppKit
import SwiftUI

/// The single semantic icon vocabulary used by Ivy's SwiftUI and AppKit UI.
/// Concrete Lucide names stay here instead of leaking through feature code.
enum IvyIcon: CaseIterable {
    case bold
    case close
    case download
    case file
    case highlight
    case image
    case leaf
    case more
    case note
    case noteHidden
    case notesDatabase
    case paperclip
    case pin
    case pinOff
    case todo
    case todoChecked
    case todoUnchecked
    case trash
    case underline

    static func pinState(_ isPinned: Bool) -> IvyIcon {
        isPinned ? .pinOff : .pin
    }

    /// SwiftPM's generated accessor looks beside `Bundle.main.bundleURL`,
    /// while Ivy's hand-built app correctly keeps package resources under
    /// `Contents/Resources`. Prefer that installed-app location and retain
    /// `Bundle.module` as the test/development fallback.
    private static let resourceBundle: Bundle = {
        let bundleName = "Ivy_Ivy.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.module
    }()

    private static let sourceImages: [IvyIcon: NSImage] = Dictionary(
        uniqueKeysWithValues: allCases.map { icon in
            guard
                let url = resourceBundle.url(
                    forResource: icon.resourceName,
                    withExtension: "svg"
                ),
                let image = NSImage(contentsOf: url)
            else {
                preconditionFailure("Missing Lucide icon resource: \(icon.resourceName).svg")
            }
            image.isTemplate = true
            return (icon, image)
        }
    )

    private var resourceName: String {
        switch self {
        case .bold: "bold"
        case .close: "x"
        case .download: "download"
        case .file: "file"
        case .highlight: "highlighter"
        case .image: "image"
        case .leaf: "leaf"
        case .more: "ellipsis"
        case .note: "sticky-note"
        case .noteHidden: "eye-off"
        case .notesDatabase: "notebook-tabs"
        case .paperclip: "paperclip"
        case .pin: "pin"
        case .pinOff: "pin-off"
        case .todo: "list-todo"
        case .todoChecked: "square-check-big"
        case .todoUnchecked: "square"
        case .trash: "trash-2"
        case .underline: "underline"
        }
    }

    /// Returns an independent template image so callers may safely resize it
    /// without mutating the bundle-owned Lucide SVG representation.
    var nsImage: NSImage {
        guard let source = Self.sourceImages[self] else {
            preconditionFailure("Lucide icon was not registered: \(resourceName)")
        }
        return (source.copy() as? NSImage) ?? source
    }

    func nsImage(size: CGFloat) -> NSImage {
        let image = nsImage
        image.size = NSSize(width: size, height: size)
        return image
    }
}

/// A consistently sized, tintable Lucide icon for SwiftUI surfaces.
struct IvyIconView: View {
    let icon: IvyIcon
    let size: CGFloat

    init(_ icon: IvyIcon, size: CGFloat = 14) {
        self.icon = icon
        self.size = size
    }

    var body: some View {
        Image(nsImage: icon.nsImage)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A text label whose decorative icon always comes from Ivy's Lucide map.
struct IvyIconLabel: View {
    let title: String
    let icon: IvyIcon
    let iconSize: CGFloat

    init(_ title: String, icon: IvyIcon, iconSize: CGFloat = 14) {
        self.title = title
        self.icon = icon
        self.iconSize = iconSize
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            IvyIconView(icon, size: iconSize)
        }
    }
}
