import AppKit
import OSLog
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var catalogWindowController: CatalogWindowController?
    private var watermarkEditor: WatermarkEditorWindowController?
    private var welcomeWindowController: WelcomeWindowController?
    private var newCatalogController: NewCatalogWindowController?
    private var lightroomImport: LightroomImportCoordinator?
    private var settingsWindowController: SettingsWindowController?
    private var aboutWindowController: AboutWindowController?

    private static let lastCatalogKey = "LastCatalogPath"
    /// Launch argument (`-PixelLoupeSkipRestore YES`) that starts at the welcome window, used by UI tests.
    private static let skipRestoreKey = "PixelLoupeSkipRestore"
    private static let logger = Logger(subsystem: "net.pixegen.PixelLoupe", category: "App")

    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A catalog is one window; window tabs (View ▸ Show Tab Bar, Show All Tabs) don't apply.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        AppSettings.shared.applyAppearance()
        Accent.startFollowingWindows()
        guard !Self.isRunningUnitTests, catalogWindowController == nil else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeDidMount(_:)), name: NSWorkspace.didMountNotification, object: nil)

        let defaults = Defaults.store
        if !defaults.bool(forKey: Self.skipRestoreKey),
           let path = defaults.string(forKey: Self.lastCatalogKey),
           FileManager.default.fileExists(atPath: path),
           openCatalog(at: URL(filePath: path, directoryHint: .isDirectory), presentErrors: false) {
            return
        }
        showWelcome()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: CatalogPackage.isCatalog) {
            openCatalog(at: url)
        }
    }

    /// Settings ▸ Import ▸ Open the import window when a memory card is inserted.
    @objc private func volumeDidMount(_ notification: Notification) {
        guard AppSettings.shared.opensImportOnCardInsert,
              let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              ImportCards.isCard(volume), let catalogWindowController else { return }
        NSApp.activate()
        catalogWindowController.showImportWindow(source: ImportWindowSource(urls: [volume]))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let window = catalogWindowController?.window {
                window.makeKeyAndOrderFront(nil)
            } else {
                showWelcome()
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard Self.shouldAskBeforeQuitting(confirmsQuit: AppSettings.shared.confirmsQuit, event: NSAppleEventManager.shared().currentAppleEvent)
        else { return .terminateNow }
        let alert = Self.quitAlert()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { AppSettings.shared.confirmsQuit = false }
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Asks unless the setting is off, while hosting tests, or when macOS is logging out, restarting
    /// or shutting down (it has asked already).
    static func shouldAskBeforeQuitting(confirmsQuit: Bool, event: NSAppleEventDescriptor?) -> Bool {
        guard confirmsQuit, !isRunningUnitTests else { return false }
        if let event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
           event.attributeDescriptor(forKeyword: kAEQuitReason) != nil {
            return false
        }
        return true
    }

    /// "Are you sure you want to quit?": Quit is the default button (Return), Cancel is Escape.
    static func quitAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to quit?"
        alert.informativeText = "You can turn this off in Settings ▸ General."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        return alert
    }

    func applicationWillTerminate(_ notification: Notification) {
        catalogWindowController?.saveSelection()
        catalogWindowController?.store.save()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// PixelLoupe ▸ About PixelLoupe (see ``AboutWindowController``): holding ⌥⌘ as it's chosen rolls the credits.
    @objc func showAbout(_ sender: Any?) {
        if aboutWindowController == nil {
            aboutWindowController = AboutWindowController()
        }
        aboutWindowController?.show(modifiers: NSEvent.modifierFlags)
    }

    /// PixelLoupe ▸ Check for Updates… (see ``Updates``).
    @objc func checkForUpdates(_ sender: Any?) {
        Updates.shared.checkForUpdates()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
    }

    /// PixelLoupe ▸ Edit Watermarks…: previews the selected photos of the open catalog.
    @objc func showWatermarkEditor(_ sender: Any?) {
        if let watermarkEditor, watermarkEditor.window?.isVisible == true {
            watermarkEditor.showWindow(nil)
            return
        }
        let editor = WatermarkEditorWindowController(source: catalogWindowController?.watermarkPreviews ?? WatermarkPreviewSource([]))
        editor.onClose = { [weak self] in self?.watermarkEditor = nil }
        watermarkEditor = editor
        editor.showWindow(nil)
    }

    // MARK: - Catalogs

    @objc func newCatalog(_ sender: Any?) {
        guard newCatalogController == nil else {
            newCatalogController?.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NewCatalogWindowController { [weak self] request in
            guard let self else { return }
            newCatalogController = nil
            guard let request else { return }
            do {
                let store = try CatalogStore.create(at: request.packageURL, info: request.info)
                present(store)
            } catch {
                NSApp.presentError(error)
            }
        }
        newCatalogController = controller
        controller.present(over: catalogWindowController?.window ?? welcomeWindowController?.window)
    }

    /// File ▸ Import Lightroom Catalog…: builds a new PixelLoupe catalog from a Lightroom Classic one.
    @objc func importLightroomCatalog(_ sender: Any?) {
        guard lightroomImport == nil else { return }
        let coordinator = LightroomImportCoordinator(
            parentWindow: catalogWindowController?.window ?? welcomeWindowController?.window
        ) { [weak self] store, report in
            guard let self else { return }
            lightroomImport = nil
            guard let store, let report else { return }
            present(store)
            catalogWindowController?.presentLightroomImportReport(report)
        }
        lightroomImport = coordinator
        coordinator.start()
    }

    @objc func openCatalogDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Catalog"
        panel.allowedContentTypes = UTType.catalogTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openCatalog(at: url)
    }

    /// File ▸ Open Recent (and the welcome window's Open Recent menu): a catalog that has gone away is
    /// dropped from the list after the error is shown.
    @objc func openRecentCatalog(_ sender: Any?) {
        guard let url = (sender as? RecentCatalogSender)?.recentCatalogURL else { return }
        if !openCatalog(at: url), !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            RecentCatalogs.shared.remove(url)
        }
    }

    @objc func clearRecentCatalogs(_ sender: Any?) {
        RecentCatalogs.shared.clear()
    }

    @discardableResult
    func openCatalog(at url: URL, presentErrors: Bool = true) -> Bool {
        if catalogWindowController?.store.packageURL.standardizedFileURL == url.standardizedFileURL {
            catalogWindowController?.showWindow(nil)
            return true
        }
        do {
            present(try CatalogStore.open(at: url))
            return true
        } catch {
            Self.logger.error("Failed to open catalog: \(error.localizedDescription, privacy: .public)")
            if presentErrors { NSApp.presentError(error) }
            return false
        }
    }

    private func present(_ store: CatalogStore) {
        if let current = catalogWindowController {
            current.onClose = nil
            current.close()
        }
        let controller = CatalogWindowController(store: store)
        controller.onClose = { [weak self] in
            self?.catalogWindowController = nil
            self?.showWelcome()
        }
        catalogWindowController = controller
        controller.fillScreen()
        controller.showWindow(nil)
        controller.restoreSecondaryWindow()

        welcomeWindowController?.close()
        welcomeWindowController = nil
        rememberLastCatalog(store)
        NSDocumentController.shared.noteNewRecentDocumentURL(store.packageURL)
    }

    /// Remembers the catalog to reopen at next launch and adds it to Open Recent. A catalog passed on
    /// the command line (`-LastCatalogPath`, as UI tests do) is opened without changing either.
    private func rememberLastCatalog(_ store: CatalogStore) {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard arguments[Self.lastCatalogKey] == nil else { return }
        Defaults.store.set(store.packageURL.path(percentEncoded: false), forKey: Self.lastCatalogKey)
        RecentCatalogs.shared.noteOpened(store.packageURL, name: store.info.name)
    }

    private func showWelcome() {
        if welcomeWindowController == nil {
            welcomeWindowController = WelcomeWindowController()
        }
        welcomeWindowController?.showWindow(nil)
        welcomeWindowController?.window?.center()
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Check for Updates… is unavailable while a check is under way, and in builds that don't update.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates(_:)) { return Updates.shared.canCheckForUpdates }
        return true
    }
}
