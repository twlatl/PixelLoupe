import AppKit

/// Selectors handled along the responder chain by the catalog window and Library views.
@objc protocol PixelLoupeActions {
    @objc optional func showAbout(_ sender: Any?)
    @objc optional func newCatalog(_ sender: Any?)
    @objc optional func checkForUpdates(_ sender: Any?)
    @objc optional func openCatalogDocument(_ sender: Any?)
    @objc optional func openRecentCatalog(_ sender: Any?)
    @objc optional func clearRecentCatalogs(_ sender: Any?)
    @objc optional func toggleSecondaryWindow(_ sender: Any?)
    @objc optional func toggleSecondaryFullScreen(_ sender: Any?)
    @objc optional func toggleSecondaryPreview(_ sender: Any?)
    @objc optional func toggleSecondarySlideshow(_ sender: Any?)
    @objc optional func impromptuSlideshow(_ sender: Any?)
    @objc optional func showContactSheet(_ sender: Any?)
    @objc optional func showSecondaryView(_ sender: NSMenuItem)
    @objc optional func importPhotos(_ sender: Any?)
    @objc optional func importLightroomCatalog(_ sender: Any?)
    @objc optional func locateMissingPhoto(_ sender: Any?)
    @objc optional func findMissingFolder(_ sender: Any?)
    @objc optional func createFolderInside(_ sender: Any?)
    @objc optional func createCollectionSetFromFolder(_ sender: Any?)
    @objc optional func createCollectionFromFolder(_ sender: Any?)
    @objc optional func toggleFolderFavorite(_ sender: Any?)
    @objc optional func setFolderColorLabel(_ sender: NSMenuItem)
    @objc optional func renameFolder(_ sender: Any?)
    @objc optional func removeFolder(_ sender: Any?)
    @objc optional func hideFolderParent(_ sender: Any?)
    @objc optional func showFolderParent(_ sender: Any?)
    @objc optional func synchronizeFolder(_ sender: Any?)
    @objc optional func importToFolder(_ sender: Any?)
    @objc optional func exportFolderAsCatalog(_ sender: Any?)
    @objc optional func showFolderInFinder(_ sender: Any?)
    @objc optional func getFolderInfo(_ sender: Any?)
    @objc optional func showLightroomImportReport(_ sender: Any?)
    @objc optional func buildSmartPreviews(_ sender: Any?)
    @objc optional func discardSmartPreviews(_ sender: Any?)
    @objc optional func showLibrary(_ sender: Any?)
    @objc optional func showDevelop(_ sender: Any?)
    @objc optional func increaseThumbnailSize(_ sender: Any?)
    @objc optional func decreaseThumbnailSize(_ sender: Any?)
    @objc optional func focusSearch(_ sender: Any?)
    @objc optional func setRatingFromMenu(_ sender: NSMenuItem)
    @objc optional func decreaseRating(_ sender: Any?)
    @objc optional func increaseRating(_ sender: Any?)
    @objc optional func setFlagFromMenu(_ sender: NSMenuItem)
    @objc optional func setColorLabelFromMenu(_ sender: NSMenuItem)
    @objc optional func createVirtualCopy(_ sender: Any?)
    @objc optional func groupIntoStack(_ sender: Any?)
    @objc optional func unstack(_ sender: Any?)
    @objc optional func toggleStack(_ sender: Any?)
    @objc optional func moveToTopOfStack(_ sender: Any?)
    @objc optional func removeFromStack(_ sender: Any?)
    @objc optional func collapseAllStacks(_ sender: Any?)
    @objc optional func expandAllStacks(_ sender: Any?)
    @objc optional func photoMergeHDR(_ sender: Any?)
    @objc optional func photoMergePanorama(_ sender: Any?)
    @objc optional func photoMergePanoramaWithPreviousSettings(_ sender: Any?)
    @objc optional func cancelPhotoMerge(_ sender: Any?)
    @objc optional func editInPrimary(_ sender: Any?)
    @objc optional func editInAdditional(_ sender: Any?)
    @objc optional func editInPreset(_ sender: NSMenuItem)
    @objc optional func openInOtherApplication(_ sender: Any?)
    @objc optional func toggleStackFromBadge(_ sender: Any?)
    @objc optional func setCopyAsMaster(_ sender: Any?)
    @objc optional func addKeywords(_ sender: Any?)
    @objc optional func newCollection(_ sender: Any?)
    @objc optional func newSmartCollection(_ sender: Any?)
    @objc optional func newCollectionSet(_ sender: Any?)
    @objc optional func editSmartCollection(_ sender: Any?)
    @objc optional func renameCollection(_ sender: Any?)
    @objc optional func deleteCollection(_ sender: Any?)
    @objc optional func setTargetCollection(_ sender: Any?)
    @objc optional func addToCollection(_ sender: Any?)
    @objc optional func removeFromCollection(_ sender: Any?)
    @objc optional func addToTargetCollection(_ sender: Any?)
    @objc optional func revealInFinder(_ sender: Any?)
    @objc optional func showSettings(_ sender: Any?)
    @objc optional func showWatermarkEditor(_ sender: Any?)
    @objc optional func exportPhotos(_ sender: Any?)
    @objc optional func exportWithPrevious(_ sender: Any?)
    @objc optional func exportWithPreset(_ sender: NSMenuItem)
    @objc optional func cancelExport(_ sender: Any?)
    @objc optional func enlargePhoto(_ sender: Any?)
    @objc optional func viewPhotoFullScreen(_ sender: Any?)
    @objc optional func toggleLoupe(_ sender: Any?)
    @objc optional func revertToOriginal(_ sender: Any?)
    @objc optional func copySettings(_ sender: Any?)
    @objc optional func pasteSettings(_ sender: Any?)
    @objc optional func copySettingsChoosing(_ sender: Any?)
    @objc optional func syncDevelopSettings(_ sender: Any?)
    @objc optional func deleteEmptyMasks(_ sender: Any?)
    @objc optional func autoWhiteBalanceSelected(_ sender: Any?)
    @objc optional func autoSettingsSelected(_ sender: Any?)
    @objc optional func convertToBlackAndWhite(_ sender: Any?)
    @objc optional func toggleFilmstrip(_ sender: Any?)
    @objc optional func toggleFilterBar(_ sender: Any?)
    @objc optional func compare(_ sender: Any?)
    @objc optional func survey(_ sender: Any?)
    @objc optional func chooseLibraryView(_ sender: ViewModeControl)
    @objc optional func cropTool(_ sender: Any?)
    @objc optional func showClipping(_ sender: Any?)
    @objc optional func whiteBalanceSelector(_ sender: Any?)
    @objc optional func maskingTool(_ sender: Any?)
    @objc optional func spotRemovalTool(_ sender: Any?)
    @objc optional func addLinearMask(_ sender: Any?)
    @objc optional func addRadialMask(_ sender: Any?)
    @objc optional func showMaskOverlay(_ sender: Any?)
    @objc optional func showBeforeAfter(_ sender: NSMenuItem)
    @objc optional func removePhoto(_ sender: Any?)
    @objc optional func removeSelectedPhotos(_ sender: Any?)
    @objc optional func removeAndTrashPhotos(_ sender: Any?)
    @objc optional func deleteRejectedPhotos(_ sender: Any?)
    @objc optional func rotateLeft(_ sender: Any?)
    @objc optional func rotateRight(_ sender: Any?)
    @objc optional func flipHorizontal(_ sender: Any?)
    @objc optional func flipVertical(_ sender: Any?)
    @objc optional func resetToCameraOrientation(_ sender: Any?)
    @objc optional func restoreOrientationFromMetadata(_ sender: Any?)
    @objc optional func autoLight(_ sender: Any?)
}

/// Builds the app's main menu in code (the app has no storyboards or nibs).
enum MainMenu {
    static func make() -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu()))
        mainMenu.addItem(submenuItem(fileMenu()))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(libraryMenu()))
        mainMenu.addItem(submenuItem(photoMenu()))
        mainMenu.addItem(submenuItem(viewMenu()))
        let windowMenu = windowMenu()
        mainMenu.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu
        let helpMenu = NSMenu(title: "Help")
        mainMenu.addItem(submenuItem(helpMenu))
        NSApp.helpMenu = helpMenu
        return mainMenu
    }

    /// Photo ▸ Photo Merge, also in the grid's context menu, with Lightroom's shortcuts: ⌃H for HDR,
    /// ⌃M for Panorama, and ⌃⇧M (Panorama's alternate, shown while Shift is held) to merge a panorama
    /// straight away with the last settings, without the preview.
    static func photoMergeItem() -> NSMenuItem {
        let menu = NSMenu(title: "Photo Merge")
        menu.addItem(item("HDR…", #selector(PixelLoupeActions.photoMergeHDR(_:)), "h", modifiers: .control))
        menu.addItem(item("Panorama…", #selector(PixelLoupeActions.photoMergePanorama(_:)), "m", modifiers: .control))
        let headless = item("Panorama with Previous Settings", #selector(PixelLoupeActions.photoMergePanoramaWithPreviousSettings(_:)),
                            "m", modifiers: [.control, .shift])
        headless.isAlternate = true
        menu.addItem(headless)
        return submenuItem(menu)
    }

    /// Photo ▸ Edit In, also in the grid's context menu: the editors from Settings ▸ External
    /// Editing, with Lightroom's ⌘E and ⌥⌘E. Rebuilt whenever it opens (see ``EditInMenu``).
    static func editInItem() -> NSMenuItem {
        let menu = NSMenu(title: "Edit In")
        EditInMenu.shared.menuNeedsUpdate(menu)
        menu.delegate = EditInMenu.shared
        return submenuItem(menu)
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    /// ⌥⌘1 / ⌥⌘2 (Lightroom's module shortcuts) as option-key alternates of ⌘1 / ⌘2.
    private static func alternate(_ item: NSMenuItem) -> NSMenuItem {
        item.isAlternate = true
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "PixelLoupe")
        menu.addItem(item("About PixelLoupe", #selector(PixelLoupeActions.showAbout(_:))))
        menu.addItem(item("Check for Updates…", #selector(PixelLoupeActions.checkForUpdates(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(PixelLoupeActions.showSettings(_:)), ","))
        menu.addItem(item("Edit Watermarks…", #selector(PixelLoupeActions.showWatermarkEditor(_:))))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide PixelLoupe", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit PixelLoupe", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        // ⌘N is Library ▸ New Collection, as in Lightroom.
        menu.addItem(item("New Catalog…", #selector(PixelLoupeActions.newCatalog(_:)), "n", modifiers: [.command, .option]))
        menu.addItem(item("Open Catalog…", #selector(PixelLoupeActions.openCatalogDocument(_:)), "o"))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Open Recent")
        recent.submenu?.delegate = RecentCatalogsMenu.fileMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(item("Import Photos…", #selector(PixelLoupeActions.importPhotos(_:)), "i", modifiers: [.command, .shift]))
        menu.addItem(item("Import Lightroom Catalog…", #selector(PixelLoupeActions.importLightroomCatalog(_:))))
        menu.addItem(.separator())
        // Lightroom's export commands and shortcuts.
        menu.addItem(item("Export…", #selector(PixelLoupeActions.exportPhotos(_:)), "e", modifiers: [.command, .shift]))
        menu.addItem(item("Export with Previous", #selector(PixelLoupeActions.exportWithPrevious(_:)), "e", modifiers: [.command, .shift, .option]))
        let presets = NSMenuItem(title: "Export with Preset", action: nil, keyEquivalent: "")
        presets.submenu = NSMenu(title: "Export with Preset")
        presets.submenu?.delegate = ExportPresetsMenu.shared
        menu.addItem(presets)
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find", #selector(PixelLoupeActions.focusSearch(_:)), "f"))
        return menu
    }

    private static func libraryMenu() -> NSMenu {
        let menu = NSMenu(title: "Library")
        menu.addItem(item("New Collection…", #selector(PixelLoupeActions.newCollection(_:)), "n"))
        menu.addItem(item("New Smart Collection…", #selector(PixelLoupeActions.newSmartCollection(_:))))
        menu.addItem(item("New Collection Set…", #selector(PixelLoupeActions.newCollectionSet(_:))))
        menu.addItem(.separator())
        // B, as in Lightroom; handled by the window as a single key.
        menu.addItem(item("Add to Target Collection", #selector(PixelLoupeActions.addToTargetCollection(_:)), "b", modifiers: []))
        menu.addItem(item("Remove from Collection", #selector(PixelLoupeActions.removeFromCollection(_:))))
        menu.addItem(.separator())
        // Lightroom's Library ▸ Previews, without shortcuts.
        let previews = NSMenu(title: "Previews")
        previews.addItem(item("Build Smart Previews", #selector(PixelLoupeActions.buildSmartPreviews(_:))))
        previews.addItem(item("Discard Smart Previews…", #selector(PixelLoupeActions.discardSmartPreviews(_:))))
        menu.addItem(submenuItem(previews))
        menu.addItem(.separator())
        menu.addItem(item("Lightroom Import Report", #selector(PixelLoupeActions.showLightroomImportReport(_:))))
        return menu
    }

    private static func photoMenu() -> NSMenu {
        let menu = NSMenu(title: "Photo")
        // Lightroom's single keys (handled by the window; the items show them): 0–5, [ ], P, U, X.
        let ratingMenu = NSMenu(title: "Set Rating")
        RatingFormatter.ratingItems(target: nil).forEach(ratingMenu.addItem)
        menu.addItem(submenuItem(ratingMenu))
        let flagMenu = NSMenu(title: "Set Flag")
        RatingFormatter.flagItems(target: nil).forEach(flagMenu.addItem)
        menu.addItem(submenuItem(flagMenu))
        // Lightroom's color labels. 6–9 are single keys handled by the window, like the ratings.
        let labelMenu = NSMenu(title: "Set Color Label")
        for label in ColorLabel.allCases {
            let title = label.shortcut.map { "\(label.title)  (\($0))" } ?? label.title
            labelMenu.addItem(item(title, #selector(PixelLoupeActions.setColorLabelFromMenu(_:)), tag: Int(label.rawValue)))
        }
        menu.addItem(submenuItem(labelMenu))
        menu.addItem(.separator())
        // Lightroom's shortcut for Create Virtual Copy is ⌘'.
        menu.addItem(item("Create Virtual Copy", #selector(PixelLoupeActions.createVirtualCopy(_:)), "'"))
        menu.addItem(item("Set Copy as Master", #selector(PixelLoupeActions.setCopyAsMaster(_:))))
        // Lightroom's stacking commands: ⌘G, ⇧⌘G, and S / ⇧S (handled as single keys by the window).
        let stacking = NSMenu(title: "Stacking")
        stacking.addItem(item("Group into Stack", #selector(PixelLoupeActions.groupIntoStack(_:)), "g"))
        stacking.addItem(item("Unstack", #selector(PixelLoupeActions.unstack(_:)), "g", modifiers: [.command, .shift]))
        stacking.addItem(item("Collapse Stack", #selector(PixelLoupeActions.toggleStack(_:)), "s", modifiers: []))
        stacking.addItem(item("Move to Top of Stack", #selector(PixelLoupeActions.moveToTopOfStack(_:)), "s", modifiers: .shift))
        stacking.addItem(item("Remove from Stack", #selector(PixelLoupeActions.removeFromStack(_:))))
        stacking.addItem(.separator())
        stacking.addItem(item("Collapse All Stacks", #selector(PixelLoupeActions.collapseAllStacks(_:))))
        stacking.addItem(item("Expand All Stacks", #selector(PixelLoupeActions.expandAllStacks(_:))))
        menu.addItem(submenuItem(stacking))
        menu.addItem(photoMergeItem())
        menu.addItem(editInItem())
        menu.addItem(.separator())
        // Rotate and flip, with Lightroom's shortcuts.
        menu.addItem(item("Rotate Left (CCW)", #selector(PixelLoupeActions.rotateLeft(_:)), "["))
        menu.addItem(item("Rotate Right (CW)", #selector(PixelLoupeActions.rotateRight(_:)), "]"))
        menu.addItem(item("Flip Horizontal", #selector(PixelLoupeActions.flipHorizontal(_:))))
        menu.addItem(item("Flip Vertical", #selector(PixelLoupeActions.flipVertical(_:))))
        menu.addItem(item("Reset to Camera Orientation", #selector(PixelLoupeActions.resetToCameraOrientation(_:))))
        menu.addItem(item("Restore Orientation from Metadata", #selector(PixelLoupeActions.restoreOrientationFromMetadata(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Auto Light", #selector(PixelLoupeActions.autoLight(_:)), "u"))
        menu.addItem(item("Revert to Original", #selector(PixelLoupeActions.revertToOriginal(_:)), "r", modifiers: [.command, .shift]))
        // Lightroom's Copy Settings / Paste Settings: a photo's settings, or a preset copied in Develop's Presets panel.
        menu.addItem(item("Copy Settings", #selector(PixelLoupeActions.copySettings(_:)), "c", modifiers: [.command, .shift]))
        menu.addItem(item("Paste Settings", #selector(PixelLoupeActions.pasteSettings(_:)), "v", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Show in Finder", #selector(PixelLoupeActions.revealInFinder(_:)), "r"))
        menu.addItem(item("Add Keywords…", #selector(PixelLoupeActions.addKeywords(_:)), "k"))
        menu.addItem(item("Locate Missing Photo…", #selector(PixelLoupeActions.locateMissingPhoto(_:))))
        menu.addItem(.separator())
        // Lightroom's shortcuts. Delete alone is handled by the window as a single key; every item
        // is disabled while typing, so the keys reach the text field.
        let delete = String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        menu.addItem(item("Remove Photo…", #selector(PixelLoupeActions.removePhoto(_:)), delete, modifiers: []))
        menu.addItem(item("Remove Selected Photo…", #selector(PixelLoupeActions.removeSelectedPhotos(_:)), delete, modifiers: [.shift]))
        menu.addItem(item("Remove and Trash Photo…", #selector(PixelLoupeActions.removeAndTrashPhotos(_:)), delete, modifiers: [.option, .shift, .command]))
        menu.addItem(item("Delete Rejected Photos…", #selector(PixelLoupeActions.deleteRejectedPhotos(_:)), delete, modifiers: [.command]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // G and D also switch modes; they're handled as single keys by the catalog window so they
        // don't interfere with typing in text fields.
        menu.addItem(item("Library", #selector(PixelLoupeActions.showLibrary(_:)), "1"))
        menu.addItem(alternate(item("Library", #selector(PixelLoupeActions.showLibrary(_:)), "1", modifiers: [.command, .option])))
        menu.addItem(item("Develop", #selector(PixelLoupeActions.showDevelop(_:)), "2"))
        menu.addItem(alternate(item("Develop", #selector(PixelLoupeActions.showDevelop(_:)), "2", modifiers: [.command, .option])))
        menu.addItem(.separator())
        // C, as in Lightroom. The window handles the key; the menu item is disabled while typing so
        // the key equivalent never steals a "c" from a text field.
        menu.addItem(item("Compare", #selector(PixelLoupeActions.compare(_:)), "c", modifiers: []))
        // N, as in Lightroom; handled as a key by the window like C.
        menu.addItem(item("Survey", #selector(PixelLoupeActions.survey(_:)), "n", modifiers: []))
        menu.addItem(item("Crop & Straighten", #selector(PixelLoupeActions.cropTool(_:)), "r", modifiers: []))
        menu.addItem(item("Enlarge Photo", #selector(PixelLoupeActions.enlargePhoto(_:))))
        menu.addItem(item("View Photo Full Screen", #selector(PixelLoupeActions.viewPhotoFullScreen(_:))))
        menu.addItem(item("Show Loupe", #selector(PixelLoupeActions.toggleLoupe(_:))))
        // J, as in Lightroom: shadow and highlight clipping on the Develop preview.
        menu.addItem(item("Show Clipping", #selector(PixelLoupeActions.showClipping(_:)), "j", modifiers: []))
        // W, as in Lightroom: the White Balance Selector eyedropper in the Adjust panel.
        menu.addItem(item("White Balance Selector", #selector(PixelLoupeActions.whiteBalanceSelector(_:)), "w", modifiers: []))
        // Lightroom's masking keys: ⇧W opens Masking, M and ⇧M add a linear or radial gradient, O shows the overlay.
        menu.addItem(item("Masking", #selector(PixelLoupeActions.maskingTool(_:)), "w", modifiers: [.shift]))
        menu.addItem(item("Spot Removal", #selector(PixelLoupeActions.spotRemovalTool(_:)), "q", modifiers: []))
        menu.addItem(item("Linear Gradient Mask", #selector(PixelLoupeActions.addLinearMask(_:)), "m", modifiers: []))
        menu.addItem(item("Radial Gradient Mask", #selector(PixelLoupeActions.addRadialMask(_:)), "m", modifiers: [.shift]))
        menu.addItem(item("Show Mask Overlay", #selector(PixelLoupeActions.showMaskOverlay(_:)), "o", modifiers: []))
        menu.addItem(submenuItem(beforeAfterMenu()))
        menu.addItem(.separator())
        // = and - (Lightroom's thumbnail size keys) are single-key shortcuts handled by the window.
        menu.addItem(item("Larger Thumbnails", #selector(PixelLoupeActions.increaseThumbnailSize(_:))))
        menu.addItem(item("Smaller Thumbnails", #selector(PixelLoupeActions.decreaseThumbnailSize(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", modifiers: [.command, .control]))
        // \, Lightroom's Library Filter bar key; handled by the window in Library (Develop's Before Only
        // has it there).
        menu.addItem(item("Hide Filter Bar", #selector(PixelLoupeActions.toggleFilterBar(_:)), "\\", modifiers: []))
        // F6, Lightroom's filmstrip shortcut.
        menu.addItem(item("Hide Filmstrip", #selector(PixelLoupeActions.toggleFilmstrip(_:)),
                          String(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: []))
        // AppKit retitles this Enter/Exit Full Screen and won't add its own duplicate.
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control]))
        return menu
    }

    /// Develop's Before/After views with Lightroom's keys (handled by the window like C). Each item's
    /// tag is its ``BeforeAfterView``.
    private static func beforeAfterMenu() -> NSMenu {
        let menu = NSMenu(title: "Before/After")
        for view in BeforeAfterView.allCases {
            let (key, modifiers): (String, NSEvent.ModifierFlags) = switch view {
            case .leftRight: ("y", [])
            case .topBottom: ("y", .option)
            case .beforeOnly: ("\\", [])
            case .split: ("y", .shift)
            }
            menu.addItem(item(view.title, #selector(PixelLoupeActions.showBeforeAfter(_:)), key, modifiers: modifiers, tag: view.rawValue))
        }
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        let secondary = NSMenuItem(title: "Secondary Display", action: nil, keyEquivalent: "")
        secondary.submenu = SecondaryDisplayMenu.make(header: false)
        menu.addItem(secondary)
        // ⌘Return, Lightroom's Impromptu Slideshow.
        menu.addItem(item("Impromptu Slideshow", #selector(PixelLoupeActions.impromptuSlideshow(_:)), "\r"))
        menu.addItem(item("Contact Sheet", #selector(PixelLoupeActions.showContactSheet(_:)), "c", modifiers: [.control, .option, .command]))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}

enum RatingFormatter {
    static func stars(_ rating: Int) -> String {
        String(repeating: "★", count: rating) + String(repeating: "☆", count: max(0, 5 - rating))
    }

    static func menuTitle(for rating: Int) -> String {
        rating == 0 ? "None" : String(repeating: "★", count: rating)
    }

    /// The Photo menu's and the grid's right-click menu's rating items: None and ★–★★★★★ with their
    /// keys (0–5), then Decrease Rating ([) and Increase Rating (]).
    static func ratingItems(target: AnyObject?) -> [NSMenuItem] {
        var items = (0...5).map { rating in
            let item = NSMenuItem(title: menuTitle(for: rating), action: #selector(PixelLoupeActions.setRatingFromMenu(_:)), keyEquivalent: "\(rating)")
            item.keyEquivalentModifierMask = []
            item.tag = rating
            return item
        }
        items.append(.separator())
        for (title, action, key) in [("Decrease Rating", #selector(PixelLoupeActions.decreaseRating(_:)), "["),
                                     ("Increase Rating", #selector(PixelLoupeActions.increaseRating(_:)), "]")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            items.append(item)
        }
        items.forEach { $0.target = target }
        return items
    }

    /// The flag items, as Lightroom names and keys them: Flagged (P), Unflagged (U), Rejected (X).
    static func flagItems(target: AnyObject?) -> [NSMenuItem] {
        [(PhotoFlag.picked, "Flagged", "p"), (.unflagged, "Unflagged", "u"), (.rejected, "Rejected", "x")].map { flag, title, key in
            let item = NSMenuItem(title: title, action: #selector(PixelLoupeActions.setFlagFromMenu(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = []
            item.tag = Int(flag.rawValue)
            item.target = target
            return item
        }
    }
}

/// File ▸ Export with Preset: the presets, listed when the menu opens.
final class ExportPresetsMenu: NSObject, NSMenuDelegate {
    static let shared = ExportPresetsMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let userPresets = ExportPresets.shared.userPresets
        for (title, presets) in [("PixelLoupe Presets", ExportPresets.builtIn), ("User Presets", userPresets)] where !presets.isEmpty {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(.sectionHeader(title: title))
            for preset in presets {
                let item = NSMenuItem(title: preset.name, action: #selector(PixelLoupeActions.exportWithPreset(_:)), keyEquivalent: "")
                item.representedObject = preset.name
                menu.addItem(item)
            }
        }
    }
}

/// Photo ▸ Edit In: the primary editor (⌘E), the additional editor (⌥⌘E), the additional editor's
/// presets, and Open in Other Application…, named after the apps chosen in Settings.
final class EditInMenu: NSObject, NSMenuDelegate {
    static let shared = EditInMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let preferences = ExternalEditingPreferences.shared
        let primary = NSMenuItem(
            title: "Edit in \(preferences.primary.applicationName ?? "External Editor")…",
            action: #selector(PixelLoupeActions.editInPrimary(_:)), keyEquivalent: "e"
        )
        primary.keyEquivalentModifierMask = .command
        menu.addItem(primary)
        let additional = NSMenuItem(
            title: "Edit in \(preferences.additional.applicationName ?? "Additional External Editor")…",
            action: #selector(PixelLoupeActions.editInAdditional(_:)), keyEquivalent: "e"
        )
        additional.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(additional)
        if !preferences.presets.isEmpty {
            menu.addItem(.separator())
            for preset in preferences.presets {
                let item = NSMenuItem(title: preset.name, action: #selector(PixelLoupeActions.editInPreset(_:)), keyEquivalent: "")
                item.representedObject = preset.name
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open in Other Application…", action: #selector(PixelLoupeActions.openInOtherApplication(_:)), keyEquivalent: ""))
    }
}
