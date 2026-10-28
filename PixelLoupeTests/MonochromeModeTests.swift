import AppKit
import Foundation
import Testing
@testable import PixelLoupe

/// These pass Monochrome Mode explicitly instead of turning on the shared setting, which other suites
/// running at the same time would see.
@Suite("Monochrome Mode")
@MainActor
struct MonochromeModeTests {
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceGray) ?? color
        }
        return result
    }

    @Test func isOffByDefault() {
        #expect(Defaults.store.object(forKey: "MonochromeMode") == nil)
        #expect(!AppSettings.shared.isMonochrome)
        #expect(Accent.color == .controlAccentColor)
    }

    @Test func accentIsDarkGrayInDarkModeAndBlackInLightMode() {
        #expect(Accent.color(monochrome: false) == .controlAccentColor)
        let mono = Accent.color(monochrome: true)
        let dark = resolved(mono, in: .darkAqua)
        let light = resolved(mono, in: .aqua)
        #expect(abs(dark.whiteComponent - 0.33) < 0.02 && dark.alphaComponent == 1, "dark gray in Dark Mode")
        #expect(light.whiteComponent == 0 && light.alphaComponent == 1, "black in Light Mode")
        var srgb = mono
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { srgb = mono.usingColorSpace(.sRGB) ?? mono }
        #expect(srgb.redComponent == 0 && srgb.greenComponent == 0 && srgb.blueComponent == 0, "exactly #000000")
        #expect(Accent.isAccent(mono) && Accent.isAccent(.controlAccentColor) && !Accent.isAccent(.systemRed) && !Accent.isAccent(nil))
    }

    @Test func nativeControlsFollowTheSettingAndGoBack() {
        let container = NSView()
        let slider = NSSlider()
        let segmented = NSSegmentedControl(labels: ["A", "B"], trackingMode: .selectOne, target: nil, action: nil)
        let defaultButton = NSButton(title: "OK", target: nil, action: nil)
        defaultButton.keyEquivalent = "\r"
        let icon = NSButton(title: "", target: nil, action: nil)
        icon.contentTintColor = .controlAccentColor
        let rejected = NSButton(title: "", target: nil, action: nil)
        rejected.contentTintColor = .systemRed
        let nested = NSView()
        nested.addSubview(segmented)
        for view in [nested, slider, defaultButton, icon, rejected] { container.addSubview(view) }

        Accent.apply(in: container, monochrome: true)
        #expect(segmented.selectedSegmentBezelColor == Accent.monochrome, "found below the top level too")
        #expect(slider.trackFillColor == nil, "sliders are monochrome whatever the setting (RAW-201)")
        #expect(defaultButton.bezelColor == Accent.monochrome)
        #expect(icon.contentTintColor == Accent.monochrome)
        #expect(rejected.contentTintColor == .systemRed, "colors that mean something are left alone")

        Accent.apply(in: container, monochrome: false)
        #expect(slider.trackFillColor == nil && segmented.selectedSegmentBezelColor == nil && defaultButton.bezelColor == nil)
        #expect(icon.contentTintColor == .controlAccentColor)
    }

    @Test func testsNeverSetTheAppsSystemAccent() {
        // Monochrome Mode writes AppleAccentColor only into the app's real preferences.
        #expect(Defaults.store !== UserDefaults.standard)
    }

    @Test func sidebarIconsUseTheMonochromeColorAndWhiteWhenSelected() throws {
        let cell = SidebarCellView(identifier: NSUserInterfaceItemIdentifier("test"))
        let icon = try #require(cell.imageView)
        cell.updateIconTint(monochrome: true)
        #expect(icon.contentTintColor == Accent.monochrome, "black (Light Mode) or dark gray instead of the accent")
        cell.backgroundStyle = NSView.BackgroundStyle.emphasized
        cell.updateIconTint(monochrome: true)
        #expect(icon.contentTintColor == .white, "white on the selected row")
        #expect(!icon.allowsVibrancy, "drawn in the exact color, not blended with the sidebar's material")
        cell.updateIconTint(monochrome: false)
        #expect(icon.contentTintColor == nil, "the source list's own accent tint when off")
        #expect(icon.allowsVibrancy == NSImageView().allowsVibrancy, "and the source list's usual vibrancy")
    }
}
