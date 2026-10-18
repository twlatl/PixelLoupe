import Foundation

/// The app's preferences. Unit tests run inside the app, so while hosting them it uses a
/// throwaway domain, emptied at launch, instead of the user's own (tests must not touch real
/// preferences).
nonisolated enum Defaults {
    // UserDefaults is thread-safe.
    nonisolated(unsafe) static let store: UserDefaults = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else {
            // Newest name first, so its values win over older ones.
            for legacy in legacyDomains {
                migrate(from: UserDefaults.standard.persistentDomain(forName: legacy.domain), into: .standard, marker: legacy.marker)
            }
            return .standard
        }
        let suite = "net.pixegen.PixelLoupe.UnitTests"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// The preferences domains the app had before: briefly `net.pixegen.loupe` (an App Store build
    /// made during the rename), LightLoupe's, and RawLoupe's before that. Each has the key that records
    /// it was copied.
    static let legacyDomains: [(domain: String, marker: String)] = [
        ("net.pixegen.loupe", "MigratedPixegenLoupePreferences"),
        ("net.tedlee.LightLoupe", "MigratedLightLoupePreferences"),
        ("net.tedlee.RawLoupe", "MigratedRawLoupePreferences"),
    ]

    /// Each rename (RawLoupe → LightLoupe → PixelLoupe) gave the app a new bundle identifier and so a
    /// new preferences domain. Copies an old domain's preferences over once (the last catalog,
    /// settings, panel sizes) without overwriting any the new domain already has.
    static func migrate(from legacy: [String: Any]?, into defaults: UserDefaults, marker: String) {
        guard defaults.object(forKey: marker) == nil else { return }
        defaults.set(true, forKey: marker)
        for (key, value) in legacy ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}
