import XCTest

final class PixelLoupeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsWelcomeWindow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelLoupeSkipRestore", "YES"]
        app.launch()

        let window = app.windows["welcomeWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.buttons["newCatalogButton"].exists)
        XCTAssertTrue(window.buttons["openCatalogButton"].exists)
    }

    @MainActor
    func testNewCatalogSheetOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelLoupeSkipRestore", "YES"]
        app.launch()

        let window = app.windows["welcomeWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["newCatalogButton"].click()
        XCTAssertTrue(app.buttons["createCatalogButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["catalogNameField"].exists)
    }

    @MainActor
    func testImportLightroomCatalogIsOfferedInTheWelcomeWindowAndFileMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelLoupeSkipRestore", "YES"]
        app.launch()
        let window = app.windows["welcomeWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // File ▸ Import Lightroom Catalog… is there, and so is the Welcome window's button.
        app.menuBars.menuBarItems["File"].click()
        XCTAssertTrue(app.menuBars.menuItems["Import Lightroom Catalog…"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(window.buttons["importLightroomCatalogButton"].exists)

        // The button asks for a catalog with an open panel.
        window.buttons["importLightroomCatalogButton"].click()
        XCTAssertTrue(app.dialogs.firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Needs a Lightroom catalog: run with TEST_RUNNER_PIXELLOUPE_UI_LIGHTROOM_CATALOG set to its path.
    @MainActor
    func testLightroomImportSheetOpensFromTheWelcomeWindowAndFileMenu() throws {
        guard let catalog = ProcessInfo.processInfo.environment["PIXELLOUPE_UI_LIGHTROOM_CATALOG"] else {
            throw XCTSkip("Set PIXELLOUPE_UI_LIGHTROOM_CATALOG to a Lightroom Classic catalog (.lrcat).")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-PixelLoupeSkipRestore", "YES", "-PixelLoupeLightroomCatalog", catalog]
        app.launch()
        let window = app.windows["welcomeWindow"]
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        window.buttons["importLightroomCatalogButton"].click()
        XCTAssertTrue(app.buttons["lightroomImportButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["lightroomCatalogNameField"].exists)
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.buttons["lightroomImportButton"].waitForExistence(timeout: 1))

        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Import Lightroom Catalog…"].click()
        XCTAssertTrue(app.buttons["lightroomImportButton"].waitForExistence(timeout: 15))
        app.buttons["Cancel"].click()
    }

    @MainActor
    func testWatermarkEditorOpensFromTheAppMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PixelLoupeSkipRestore", "YES"]
        app.launch()
        XCTAssertTrue(app.windows["welcomeWindow"].waitForExistence(timeout: 10))

        app.menuBars.menuBarItems["PixelLoupe"].click()
        app.menuBars.menuItems["Edit Watermarks…"].click()
        let editor = app.windows["watermarkEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.buttons["watermarkSaveButton"].exists)
        XCTAssertTrue(editor.popUpButtons["watermarkFont"].exists)
        editor.buttons["Cancel"].click()
        XCTAssertFalse(editor.waitForExistence(timeout: 1) && editor.isHittable)
    }

    /// Needs a catalog with photos: run with TEST_RUNNER_PIXELLOUPE_UI_CATALOG set to its path (a copy:
    /// the test labels and then unlabels a photo).
    @MainActor
    func testColorLabelShortcuts() throws {
        guard let catalog = ProcessInfo.processInfo.environment["PIXELLOUPE_UI_CATALOG"] else {
            throw XCTSkip("Set PIXELLOUPE_UI_CATALOG to a catalog with photos.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-LastCatalogPath", catalog]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30))
        let cell = window.groups.matching(identifier: "photoCell").firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.click()

        for (key, name) in [("6", "Red"), ("7", "Yellow"), ("8", "Green"), ("9", "Blue")] {
            window.typeKey(key, modifierFlags: [])
            XCTAssertTrue((cell.value as? String ?? "").contains("\(name) label"), "\(key) should set \(name): \(cell.value ?? "")")
        }
        // The same key again clears it.
        window.typeKey("9", modifierFlags: [])
        XCTAssertFalse((cell.value as? String ?? "").contains("label"))
        // Purple is on the Photo menu only.
        app.menuBars.menuBarItems["Photo"].click()
        app.menuBars.menuItems["Set Color Label"].click()
        app.menuBars.menuItems["Purple"].click()
        XCTAssertTrue((cell.value as? String ?? "").contains("Purple label"))
        window.typeKey("z", modifierFlags: .command)
        XCTAssertFalse((cell.value as? String ?? "").contains("label"))
    }

    /// Needs a catalog with photos: run with TEST_RUNNER_PIXELLOUPE_UI_CATALOG set to its path.
    @MainActor
    func testExportDialogOpensWithShiftCommandE() throws {
        guard let catalog = ProcessInfo.processInfo.environment["PIXELLOUPE_UI_CATALOG"] else {
            throw XCTSkip("Set PIXELLOUPE_UI_CATALOG to a catalog with photos.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-LastCatalogPath", catalog]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("a", modifierFlags: .command)
        window.typeKey("e", modifierFlags: [.command, .shift])
        let dialog = app.sheets.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(dialog.buttons["exportButton"].exists)
        XCTAssertTrue(dialog.popUpButtons["exportFormat"].exists)
        dialog.buttons["Cancel"].click()
    }
}
