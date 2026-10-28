import AppKit
import SwiftUI

/// The Settings window (⌘,), with one pane per category in its toolbar.
final class SettingsWindowController: NSWindowController {
    init() {
        let tabs = SettingsTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.tab("General", symbol: "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(Self.tab("Appearance", symbol: "paintpalette", AppearanceSettingsView()))
        tabs.addTabViewItem(Self.tab("Import", symbol: "square.and.arrow.down", ImportSettingsView()))
        tabs.addTabViewItem(Self.tab("Displays", symbol: "display.2", DisplaysSettingsView()))
        tabs.addTabViewItem(Self.tab("External Editing", symbol: "arrow.up.forward.app", pane: ScrollingSettingsPane(ExternalEditingSettingsView())))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.identifier = NSUserInterfaceItemIdentifier("settingsWindow")
        window.isReleasedWhenClosed = false
        // Open over the app when it's in full screen, rather than in a separate space.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        super.init(window: window)
        tabs.fitWindowToSelectedPane(animated: false)
        window.center()
    }

    /// A pane sized to its SwiftUI content, titled with its label (the window shows the pane's title).
    private static func tab(_ label: String, symbol: String, _ view: some View) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        return tab(label, symbol: symbol, pane: hosting)
    }

    private static func tab(_ label: String, symbol: String, pane: NSViewController) -> NSTabViewItem {
        pane.title = label
        let item = NSTabViewItem(viewController: pane)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Resizes the window to fit each pane as it's chosen, keeping the window's top edge in place, as
/// System Settings-style preference windows do.
final class SettingsTabViewController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindowToSelectedPane(animated: view.window?.isVisible ?? false)
    }

    func fitWindowToSelectedPane(animated: Bool) {
        guard let window = view.window, tabViewItems.indices.contains(selectedTabViewItemIndex),
              let pane = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        pane.view.layoutSubtreeIfNeeded()
        var size = pane.preferredContentSize
        if size.width <= 0 || size.height <= 0 { size = pane.view.fittingSize }
        guard size.width > 0, size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let toolbarHeight = content.height - view.frame.height
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height - toolbarHeight, width: size.width, height: size.height + toolbarHeight))
        frame.origin.y = window.frame.maxY - frame.height
        // A pane taller than the screen scrolls instead.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.height = min(frame.height, visible.height)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// A pane too long to show whole (External Editing): a fixed-height window onto it, with a vertical
/// scroll bar that stays visible even when the system shows scroll bars only while scrolling.
final class ScrollingSettingsPane: NSViewController {
    /// The SwiftUI content's width.
    static let contentWidth: CGFloat = 500
    /// About half the External Editing pane's full height.
    static let visibleHeight: CGFloat = 480

    private let hostingView: NSView

    init(_ content: some View) {
        hostingView = NSHostingView(rootView: content)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.setAccessibilityIdentifier("settingsPaneScrollView")
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hostingView
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: clip.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            hostingView.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        preferredContentSize = NSSize(width: Self.contentWidth + scrollerWidth, height: Self.visibleHeight)
        scrollView.frame = NSRect(origin: .zero, size: preferredContentSize)
        view = scrollView
    }

    /// Content starts at the top.
    private final class FlippedClipView: NSClipView {
        override var isFlipped: Bool { true }
    }
}

struct GeneralSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable var updates = Updates.shared

    var body: some View {
        Form {
            Toggle("Confirm when quitting PixelLoupe", isOn: $settings.confirmsQuit)
                .accessibilityIdentifier("confirmQuitToggle")
            Toggle("Check for updates automatically", isOn: $updates.automaticallyChecks)
                .accessibilityIdentifier("automaticUpdateChecksToggle")
                .disabled(!updates.isAvailable)
                .padding(.top, 8)
            Toggle("Download and install updates automatically", isOn: $updates.automaticallyDownloads)
                .accessibilityIdentifier("automaticUpdateDownloadsToggle")
                .disabled(!updates.isAvailable || !updates.automaticallyChecks)
            Text(updates.isAvailable
                 ? "PixelLoupe ▸ Check for Updates… checks now. Each update shows what's changed before it's installed."
                 : "This build doesn't update itself (a development build). Release builds check for updates.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { updates.refresh() }
    }
}

struct ImportSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Toggle("Treat JPEG files next to RAW files as separate photos", isOn: $settings.treatJPEGsAsSeparate)
                .accessibilityIdentifier("separateJPEGsToggle")
            Text("When this is off, a JPEG with the same name as a RAW file is that photo's sidecar: it isn't a photo of its own, and removing the photo removes both files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open the import window when a memory card is inserted", isOn: $settings.opensImportOnCardInsert)
                .accessibilityIdentifier("importOnCardToggle")
                .padding(.top, 8)
            Text("A card is a disk with a DCIM folder, where cameras keep their photos. The import window opens for the catalog that's open, with the card chosen.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct AppearanceSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    /// The theme's matte: reads the Appearance setting (not only the color scheme, which is light in
    /// Gray) so the slider moves when it changes.
    private var themeMatte: Double {
        if colorScheme == .dark { return AppSettings.darkMatte }
        return settings.appearance == .gray ? AppSettings.grayMatte : AppSettings.lightMatte
    }

    /// Slider position for the matte; follows the theme's default until the user moves it.
    private var matte: Binding<Double> {
        Binding(
            get: { settings.matte ?? themeMatte },
            set: { settings.matte = $0 }
        )
    }

    var body: some View {
        Form {
            Picker("Appearance:", selection: $settings.appearance) {
                ForEach(AppSettings.Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("appearancePicker")

            LabeledContent("Matte Color:") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        swatch(.white)
                        MonochromeSliderView(value: matte, range: 0...1, label: "Matte color", identifier: "matteSlider")
                        swatch(.black)
                    }
                    Button("Use Theme Default") { settings.matte = nil }
                        .disabled(settings.matte == nil)
                        .accessibilityIdentifier("matteDefaultButton")
                }
            }

            LabeledContent("Monochrome Mode:") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Use gray instead of the accent color", isOn: $settings.isMonochrome)
                        .accessibilityIdentifier("monochromeToggle")
                    Text("Buttons and icons turn dark gray in Dark Mode and black in Light Mode and Gray. Checkboxes and focus rings change the next time PixelLoupe opens.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(settings.isMonochrome ? Color(nsColor: Accent.monochrome) : nil)
        .padding(20)
        .frame(width: 460)
    }

    private func swatch(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.separator))
            .frame(width: 14, height: 14)
            .accessibilityHidden(true)
    }
}
