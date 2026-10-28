import AppKit
import Testing
@testable import PixelLoupe

@Suite("About window") @MainActor
struct AboutWindowTests {
    @Test func looksLikeTheWelcomeWindowWithTheCreditsOnTheLeft() throws {
        let controller = AboutWindowController()
        let window = try #require(controller.window)
        #expect(window.title == "About PixelLoupe")
        #expect(window.contentRect(forFrameRect: window.frame).size == WelcomeWindowController.size)
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent)

        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let views = Self.allSubviews(of: content)
        let labels = views.compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(labels.contains("PixelLoupe"))
        // The version alone, without the build number.
        let version = try #require(views.first { $0.accessibilityIdentifier() == "aboutVersion" } as? NSTextField)
        #expect(version === controller.versionLabel)
        #expect(version.stringValue == WelcomeWindowController.shortVersionString())
        #expect(!labels.contains(WelcomeWindowController.versionString()))
        #expect(!labels.contains(WelcomeWindowController.buildString()))
        #expect(views.contains { $0 is NSImageView && $0.accessibilityLabel() == "PixelLoupe" })

        // The credits take the place of the welcome window's buttons and recent catalogs.
        let credits = try #require(views.first { $0.accessibilityIdentifier() == "aboutCredits" } as? NSTextView)
        #expect(credits === controller.creditsView)
        #expect(!credits.isEditable && credits.isSelectable)
        #expect(credits.accessibilityLabel() == "Credits")
        for identifier in ["newCatalogButton", "openCatalogButton", "openRecentButton", "importLightroomCatalogButton", "recentCatalogsList"] {
            #expect(!views.contains { $0.accessibilityIdentifier() == identifier }, "\(identifier)")
        }

        // The featured photo, with its caption, fills the other side.
        let photo = try #require(views.first { $0.accessibilityIdentifier() == "aboutPhoto" })
        #expect(photo === controller.photoView)
        #expect(photo.accessibilityRole() == .image)
        #expect(photo.accessibilityLabel() == WelcomeWindowController.FeaturedPhoto.accessibilityDescription)
        #expect(labels.contains("FEATURED PHOTO") && labels.contains(WelcomeWindowController.FeaturedPhoto.credit))
        let creditsFrame = controller.creditsScrollView.convert(controller.creditsScrollView.bounds, to: nil)
        let photoFrame = photo.convert(photo.bounds, to: nil)
        #expect(creditsFrame.maxX <= photoFrame.minX)
        #expect(creditsFrame.height > 300)
        #expect(photoFrame.width == WelcomeWindowController.size.width - WelcomeWindowController.sidebarWidth)
        #expect(photoFrame.height == WelcomeWindowController.size.height)
    }

    @Test func showsCreditsHTMLWithItsLinks() throws {
        let bundle = Bundle(for: Photo.self)
        let html = try String(contentsOf: try #require(bundle.url(forResource: "Credits", withExtension: "html")), encoding: .utf8)
        let controller = AboutWindowController()
        let text = controller.creditsView.string
        #expect(text.contains("Free and open source under the MIT License."))
        #expect(text.contains("LensFun") && text.contains("Sparkle") && text.contains("libjxl"))
        #expect(text.contains("Rim Light comes from Compositor by Robbie Tilton"))
        #expect(text.contains("This app isn’t affiliated with or endorsed by Adobe."))
        #expect(!text.contains("<p>"), "the HTML is rendered, not shown as source")

        let storage = try #require(controller.creditsView.textStorage)
        var links: Set<String> = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let url = value as? URL { links.insert(url.absoluteString) } else if let string = value as? String { links.insert(string) }
        }
        let hrefs = Set(html.matches(of: /href="([^"]+)"/).map { String($0.output.1) })
        #expect(hrefs.count == 9)
        // The importer writes https://sparkle-project.org as https://sparkle-project.org/.
        func trimmed(_ urls: Set<String>) -> Set<String> { Set(urls.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) }
        #expect(trimmed(links) == trimmed(hrefs))

        // In the sidebar's type, in a color that follows light and dark appearance.
        let attributes = storage.attributes(at: 0, effectiveRange: nil)
        #expect((attributes[.font] as? NSFont)?.pointSize == 13)
        #expect(attributes[.foregroundColor] as? NSColor == .secondaryLabelColor)
        // Flush left, not centered.
        var alignments: Set<NSTextAlignment.RawValue> = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            alignments.insert(((value as? NSParagraphStyle)?.alignment ?? .natural).rawValue)
        }
        #expect(!alignments.isEmpty && alignments.isSubset(of: [NSTextAlignment.left.rawValue, NSTextAlignment.natural.rawValue]))
    }

    @Test func openedNormallyItShowsTheFeaturedPhotoAndTheCreditsStayPut() {
        let controller = AboutWindowController()
        controller.modifierFlags = { [.option, .command] }
        for modifiers: NSEvent.ModifierFlags in [[], [.option], [.command], [.control, .command], [.shift, .option]] {
            controller.prepare(openedWith: modifiers)
            #expect(!controller.rollsCredits)
            #expect(controller.versionLabel.stringValue == WelcomeWindowController.shortVersionString())
            #expect(controller.photoView.content == .featured)
            #expect(controller.creditsView.textContainerInset.height == 0)
            #expect(controller.creditsScrollView.hasVerticalScroller)
            controller.advanceCredits(by: 1)
            #expect(controller.creditsOffset == 0, "holding ⌥⌘ after opening doesn't start the roll")
        }
    }

    @Test func openedWithOptionCommandItShowsTheBuildNumberTheSecretPhotoAndTheCreditsStartBelowTheBottom() throws {
        let controller = AboutWindowController()
        controller.prepare(openedWith: [.option, .command])
        #expect(controller.rollsCredits)
        // The build number takes the version's place.
        #expect(controller.versionLabel.stringValue == WelcomeWindowController.buildString())
        #expect(controller.photoView.content == .secret)
        #expect(controller.photoView.accessibilityLabel() == AboutWindowController.secretPhotoDescription)
        // The secret photo has no caption.
        let caption = Self.allSubviews(of: controller.photoView).compactMap { $0 as? NSTextField }
        #expect(!caption.isEmpty && caption.allSatisfy { $0.isHiddenOrHasHiddenAncestor })

        // A blank screenful above the credits, so they roll in from the bottom edge, and one below, so
        // the roll ends once the last line has left the top.
        let visibleHeight = controller.creditsScrollView.contentView.bounds.height
        #expect(visibleHeight > 300)
        #expect(controller.creditsOffset == 0)
        #expect(controller.creditsView.textContainerInset.height == visibleHeight)
        #expect(controller.creditsView.frame.height > 2 * visibleHeight)
        #expect(controller.creditsLength == controller.creditsView.frame.height - visibleHeight)
        #expect(!controller.creditsScrollView.hasVerticalScroller)
        #expect(controller.creditsScrollView.layer?.mask is CAGradientLayer, "they fade in and out at the edges")

        // Choosing About again without ⌥⌘ puts it back.
        controller.prepare(openedWith: [])
        #expect(controller.versionLabel.stringValue == WelcomeWindowController.shortVersionString())
        #expect(controller.photoView.content == .featured)
        #expect(controller.photoView.accessibilityLabel() == WelcomeWindowController.FeaturedPhoto.accessibilityDescription)
        #expect(caption.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        #expect(controller.creditsView.textContainerInset.height == 0)
        #expect(controller.creditsScrollView.layer?.mask == nil)
    }

    @Test func theCreditsRollTwiceAsFastWhileOptionCommandStayHeld() {
        let controller = AboutWindowController()
        var held: NSEvent.ModifierFlags = [.option, .command]
        controller.modifierFlags = { held }
        controller.prepare(openedWith: held)
        controller.advanceCredits(by: 1)
        #expect(controller.creditsOffset == 2 * CreditsRoll.speed)

        held = []
        controller.advanceCredits(by: 1)
        #expect(controller.creditsOffset == 3 * CreditsRoll.speed, "released, they roll at the normal speed")

        held = [.option, .command, .capsLock]
        controller.advanceCredits(by: 0.5)
        #expect(controller.creditsOffset == 4 * CreditsRoll.speed, "held again, they speed up again")

        // Choosing About again starts the roll over.
        controller.prepare(openedWith: held)
        #expect(controller.creditsOffset == 0)
    }

    @Test func aboutPixelLoupeOpensIt() throws {
        let appMenu = try #require(MainMenu.make().items.first?.submenu)
        let about = try #require(appMenu.items.first)
        #expect(about.title == "About PixelLoupe")
        #expect(about.action == #selector(AppDelegate.showAbout(_:)))
        #expect(about.keyEquivalent.isEmpty)
    }

    @Test func theSecretPhotoIsInTheAssetCatalog() {
        #expect(NSImage(named: "AboutSecret") != nil)
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}

@Suite("Credits roll") @MainActor
struct CreditsRollTests {
    @Test func optionCommandRollTheCreditsWhateverElseIsHeld() {
        #expect(CreditsRoll.isHoldingKeys([.option, .command]))
        #expect(CreditsRoll.isHoldingKeys([.option, .command, .shift, .capsLock]))
        // As NSEvent reports them, with the bits for which ⌥ and ⌘ (left or right) are down.
        #expect(CreditsRoll.isHoldingKeys(NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags([.option, .command]).rawValue | 0x28)))
        #expect(!CreditsRoll.isHoldingKeys([.option]))
        #expect(!CreditsRoll.isHoldingKeys([.command]))
        #expect(!CreditsRoll.isHoldingKeys([.control, .command]))
        #expect(!CreditsRoll.isHoldingKeys([]))
    }

    @Test func twiceTheSpeedWhileOptionCommandAreHeld() {
        #expect(CreditsRoll.speed > 0)
        #expect(CreditsRoll.speed(holding: []) == CreditsRoll.speed)
        #expect(CreditsRoll.speed(holding: [.option]) == CreditsRoll.speed)
        #expect(CreditsRoll.speed(holding: [.option, .command]) == 2 * CreditsRoll.speed)
    }

    @Test func movesOnByTheTimeElapsed() {
        #expect(CreditsRoll.offset(after: 2, from: 10, length: 1000, holding: []) == 10 + 2 * CreditsRoll.speed)
        #expect(CreditsRoll.offset(after: 2, from: 10, length: 1000, holding: [.option, .command]) == 10 + 4 * CreditsRoll.speed)
        #expect(CreditsRoll.offset(after: 0, from: 10, length: 1000, holding: []) == 10)
    }

    @Test func startsOverOnceTheCreditsHaveLeftTheTop() {
        let length: CGFloat = 500
        #expect(CreditsRoll.offset(after: 1, from: length - CreditsRoll.speed, length: length, holding: []) == 0)
        #expect(CreditsRoll.offset(after: 1, from: length - 10, length: length, holding: []) == CreditsRoll.speed - 10)
        #expect(CreditsRoll.offset(after: 1, from: 0, length: 0, holding: []) == 0, "nothing to roll")
    }
}
