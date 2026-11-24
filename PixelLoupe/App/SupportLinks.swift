import Foundation

/// Where PixelLoupe sends people for help and to support its development.
nonisolated enum SupportLinks {
    /// Help ▸ PixelLoupe Support: the GitHub issues, where bugs are reported and features requested.
    static let support = URL(string: "https://github.com/twlatl/PixelLoupe/issues")!
    /// The About window's Buy Me a Coffee button.
    static let buyMeACoffee = URL(string: "https://www.buymeacoffee.com/pixegen")!
}
