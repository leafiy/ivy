#if !canImport(Darwin)
import Foundation

/// On macOS this type comes from the Leafiy UI family library, whose UI
/// targets do not build on Linux. This mirror only exists so IvyCore (and its
/// tests) compile on Linux; keep it in sync with the real declaration.
public enum LeafiyApplicationIconMode: String, Codable, CaseIterable, Equatable, Sendable {
    case menuBar
    case dock
}
#endif
