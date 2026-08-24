import Foundation
import IvyCore
import LeafiyUICore

/// App strings resolved against this target's zh-Hans table.
private let appBundle = LeafiyLocalization.moduleBundle(package: "Ivy", target: "Ivy")

@inline(__always)
func L(_ key: String) -> String { LeafiyLocalization.string(key, bundle: appBundle) }

extension NoteColor {
    var localizationKey: String {
        switch self {
        case .white: return "White"
        case .pink: return "Sakura Pink"
        case .gray: return "Peach"
        case .yellow: return "Cream Apricot"
        case .green: return "Mint"
        case .blue: return "Misty Blue"
        case .purple: return "Lavender"
        }
    }
}

extension AppSettings {
    var selectedAppLanguage: AppLanguage {
        get { AppLanguage(rawValue: appLanguage) ?? .system }
        set { appLanguage = newValue.rawValue }
    }
}
