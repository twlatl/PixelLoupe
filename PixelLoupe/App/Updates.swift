import AppKit
import Observation
import Sparkle

/// What PixelLoupe asks of an updater, so development builds and tests can use one that never checks.
protocol Updater: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    func checkForUpdates()
}

/// New versions through Sparkle (RAW-110): PixelLoupe ▸ Check for Updates…, the background check Sparkle offers to
/// turn on at the second launch, and Settings ▸ General's update options.
///
/// The feed (`SUFeedURL` in Info.plist) is the `appcast.xml` the Publish Appcast workflow attaches to the latest
/// published GitHub release, with that release's notes, which Sparkle's update window shows. Updates are disk images
/// signed with the EdDSA key whose public half is `SUPublicEDKey`, and with the same Developer ID as the app.
@Observable
final class Updates {
    static let shared: Updates = {
        let updater = makeUpdater()
        return Updates(updater: updater, isAvailable: !(updater is NoUpdater))
    }()

    @ObservationIgnored private let updater: Updater
    /// Whether this build updates itself. Development builds and tests don't: a development build would always find
    /// the latest release newer, and tests mustn't check, or write Sparkle's state into the user's preferences.
    let isAvailable: Bool

    /// Settings ▸ General ▸ Check for updates automatically. Sparkle keeps the setting; this mirrors it for the view.
    var automaticallyChecks: Bool {
        didSet { if automaticallyChecks != updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }

    /// Settings ▸ General ▸ Download and install updates automatically.
    var automaticallyDownloads: Bool {
        didSet { if automaticallyDownloads != updater.automaticallyDownloadsUpdates { updater.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }

    init(updater: Updater, isAvailable: Bool = true) {
        self.updater = updater
        self.isAvailable = isAvailable
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }

    /// False while a check is under way, and always in builds that don't update.
    var canCheckForUpdates: Bool { isAvailable && updater.canCheckForUpdates }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    /// Picks up changes made outside Settings, such as the answer to Sparkle's "check automatically?" question.
    func refresh() {
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
    }

    private static func makeUpdater() -> Updater {
        #if DEBUG
        return NoUpdater()
        #else
        return AppDelegate.isRunningUnitTests ? NoUpdater() : SparkleUpdater()
        #endif
    }
}

/// Sparkle's standard updater and update windows, started at launch.
final class SparkleUpdater: Updater {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Development builds and tests: never checks, and leaves Sparkle's preferences alone.
final class NoUpdater: Updater {
    let canCheckForUpdates = false
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    func checkForUpdates() {}
}
