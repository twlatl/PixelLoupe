import AppKit
import Foundation
import Testing
@testable import PixelLoupe

/// Sparkle updates (RAW-110): the updater PixelLoupe drives, its menu item and settings, what the app ships with, and
/// the update feed the Publish Appcast workflow writes.
@Suite("Updates")
struct UpdatesTests {
    final class FakeUpdater: Updater {
        var canCheckForUpdates = true
        var automaticallyChecksForUpdates = false
        var automaticallyDownloadsUpdates = false
        var checks = 0
        func checkForUpdates() { checks += 1 }
    }

    @Test func testsNeverCheckOrTouchSparklesPreferences() {
        // The shared updater in tests (and development builds) is the one that never starts Sparkle.
        #expect(!Updates.shared.isAvailable)
        #expect(!Updates.shared.canCheckForUpdates)
    }

    @Test func settingsChangeTheUpdatersOwnSettings() {
        let updater = FakeUpdater()
        updater.automaticallyChecksForUpdates = true
        let updates = Updates(updater: updater)
        #expect(updates.automaticallyChecks && !updates.automaticallyDownloads)

        updates.automaticallyDownloads = true
        #expect(updater.automaticallyDownloadsUpdates)
        updates.automaticallyChecks = false
        #expect(!updater.automaticallyChecksForUpdates)

        // Sparkle's own question at the second launch changes them outside Settings.
        updater.automaticallyChecksForUpdates = true
        updates.refresh()
        #expect(updates.automaticallyChecks)
    }

    @Test func checkingWaitsForTheUpdater() {
        let updater = FakeUpdater()
        let updates = Updates(updater: updater)
        updates.checkForUpdates()
        #expect(updater.checks == 1)

        // A check under way.
        updater.canCheckForUpdates = false
        #expect(!updates.canCheckForUpdates)
        updates.checkForUpdates()
        #expect(updater.checks == 1)

        #expect(!Updates(updater: FakeUpdater(), isAvailable: false).canCheckForUpdates)
    }

    @Test func checkForUpdatesFollowsAboutInTheAppMenu() throws {
        let appMenu = try #require(MainMenu.make().items.first?.submenu)
        let about = try #require(appMenu.items.firstIndex { $0.title == "About PixelLoupe" })
        let item = appMenu.items[about + 1]
        #expect(item.title == "Check for Updates…")
        #expect(item.action == #selector(AppDelegate.checkForUpdates(_:)))
        // Unavailable in a build that doesn't update, such as this one.
        #expect(!AppDelegate().validateMenuItem(item))
    }

    @Test func theAppShipsSparkleItsFeedAndItsKey() throws {
        let bundle = Bundle(for: Photo.self)
        let info = try #require(bundle.infoDictionary)
        #expect(info["SUFeedURL"] as? String == "https://github.com/twlatl/PixelLoupe/releases/latest/download/appcast.xml")
        // Scripts/setup-release-secrets.sh makes the key and adds its public half.
        let key = try #require(info["SUPublicEDKey"] as? String, "Config/Info.plist has no SUPublicEDKey")
        #expect(Data(base64Encoded: key)?.count == 32, "an Ed25519 public key is 32 bytes")
        // Sparkle asks whether to check automatically at the second launch, rather than deciding for the user.
        #expect(info["SUEnableAutomaticChecks"] == nil)

        let framework = try #require(bundle.privateFrameworksURL).appending(path: "Sparkle.framework")
        #expect(FileManager.default.fileExists(atPath: framework.path(percentEncoded: false)))
    }

    // MARK: - The feed

    nonisolated private static let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    struct ScriptFailed: Error { let message: String }

    /// Runs Scripts/appcast.sh with a release's metadata and notes, returning the feed it writes.
    private func appcast(notes: String, metadata: [String: Any]) async throws -> XMLDocument {
        let directory = try TemporaryDirectory()
        let metadataURL = directory.url.appending(path: "PixelLoupe-1.2.0.appcast.json")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        let notesURL = directory.url.appending(path: "notes.md")
        try Data(notes.utf8).write(to: notesURL)
        let (status, output, errors) = try await Self.run(
            ["Scripts/appcast.sh", metadataURL.path(percentEncoded: false), "v1.2.0",
             notesURL.path(percentEncoded: false), "2026-10-19T13:05:00Z"])
        guard status == 0 else { throw ScriptFailed(message: String(decoding: errors, as: UTF8.self)) }
        return try XMLDocument(data: output)
    }

    /// Runs a script with bash from the repository, off the main actor: the other tests run there, and waiting with
    /// waitUntilExit() would run them inside this one's wait. (The output is small enough to read once it has exited.)
    @concurrent private static func run(_ arguments: [String]) async throws -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.currentDirectoryURL = repository
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GITHUB_REPOSITORY": "twlatl/PixelLoupe"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                continuation.resume(returning: (process.terminationStatus, output.fileHandleForReading.readDataToEndOfFile(),
                                                errors.fileHandleForReading.readDataToEndOfFile()))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private let metadata: [String: Any] = [
        "shortVersion": "1.2.0", "version": "202610190900", "minimumSystemVersion": "27.0.0",
        "file": "PixelLoupe-1.2.0.dmg", "length": 5_033_473, "edSignature": "UbREz+C8AvRLxA+Wg315abc==",
    ]

    @Test func theFeedOffersTheReleaseWithItsNotes() async throws {
        let notes = "## What's Changed\n* Previous Import by @twlatl\n* An odd line: a < b & c ]]> d"
        let feed = try await appcast(notes: notes, metadata: metadata)
        let item = try #require(feed.rootElement()?.elements(forName: "channel").first?.elements(forName: "item").first)
        func text(_ name: String) -> String? { item.elements(forName: name).first?.stringValue }

        #expect(text("sparkle:version") == "202610190900")
        #expect(text("sparkle:shortVersionString") == "1.2.0")
        #expect(text("sparkle:minimumSystemVersion") == "27.0.0")
        #expect(text("pubDate") == "Mon, 19 Oct 2026 13:05:00 +0000")
        #expect(text("sparkle:fullReleaseNotesLink") == "https://github.com/twlatl/PixelLoupe/releases")

        // The notes as published, Markdown that Sparkle renders, even with the sequence that ends a CDATA section.
        let description = try #require(item.elements(forName: "description").first)
        #expect(description.attribute(forName: "sparkle:format")?.stringValue == "markdown")
        #expect(description.stringValue == notes)

        let enclosure = try #require(item.elements(forName: "enclosure").first)
        #expect(enclosure.attribute(forName: "url")?.stringValue
                == "https://github.com/twlatl/PixelLoupe/releases/download/v1.2.0/PixelLoupe-1.2.0.dmg")
        #expect(enclosure.attribute(forName: "length")?.stringValue == "5033473")
        #expect(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == "UbREz+C8AvRLxA+Wg315abc==")
    }

    @Test func aReleaseWithoutNotesHasNoDescription() async throws {
        let feed = try await appcast(notes: "  \n", metadata: metadata)
        let item = try #require(feed.rootElement()?.elements(forName: "channel").first?.elements(forName: "item").first)
        #expect(item.elements(forName: "description").isEmpty)
    }

    @Test func metadataThatWouldBreakTheFeedIsRefused() async throws {
        var broken = metadata
        broken["shortVersion"] = "1.2.0\"><evil"
        let error = await #expect(throws: ScriptFailed.self) { _ = try await appcast(notes: "Notes", metadata: broken) }
        #expect(error?.message.contains("unexpected version") == true)
    }
}
