import AppKit
import CoreImage
import Testing
@testable import PixelLoupe

@Suite("White balance")
@MainActor
struct WhiteBalanceTests {
    private func panel(isRaw: Bool, _ adjustments: PhotoAdjustments = .init()) -> AdjustmentsPanelViewController {
        let panel = AdjustmentsPanelViewController()
        _ = panel.view
        panel.display(adjustments, asShotWhiteBalance: (5200, -8), isRaw: isRaw)
        return panel
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    private func row(_ title: String, in panel: AdjustmentsPanelViewController) throws -> SliderRow {
        try #require(views(panel.view).first { $0.accessibilityIdentifier() == "slider.White Balance.\(title)" } as? SliderRow)
    }

    private func popUp(in panel: AdjustmentsPanelViewController) throws -> NSPopUpButton {
        try #require(views(panel.view).first { $0.accessibilityIdentifier() == "whiteBalancePreset" } as? NSPopUpButton)
    }

    @Test("White Balance is the first section after Profile, open by default")
    func sectionOrder() throws {
        let panel = panel(isRaw: true)
        let titles = views(panel.view).compactMap { ($0 as? AdjustmentSectionView)?.title }
        #expect(Array(titles.prefix(3)) == ["Profile", "White Balance", "Light"])
    }

    @Test("A RAW file lists the light sources; any other file only As Shot, Auto and Custom")
    func popUpChoices() throws {
        let raw = panel(isRaw: true)
        #expect(try popUp(in: raw).itemTitles == ["As Shot", "Auto", "Daylight", "Cloudy", "Shade", "Tungsten", "Fluorescent", "Flash", "Custom"])
        let jpeg = panel(isRaw: false)
        #expect(try popUp(in: jpeg).itemTitles == ["As Shot", "Auto", "Custom"])

        // A light source on a JPEG (from a preset) reads as Custom there.
        var daylight = PhotoAdjustments()
        daylight.whiteBalance = .init(isEnabled: true, temperature: 5500, tint: 10, preset: "Daylight")
        jpeg.display(daylight, asShotWhiteBalance: (6500, 0), isRaw: false)
        #expect(try popUp(in: jpeg).titleOfSelectedItem == "Custom")
        jpeg.display(daylight, asShotWhiteBalance: (5200, -8), isRaw: true)
        #expect(try popUp(in: jpeg).itemTitles.count == 9 && popUp(in: jpeg).titleOfSelectedItem == "Daylight")
    }

    @Test("Temp runs 2,000–50,000 on a logarithmic track and Tint −150…+150, both shown as Lightroom does")
    func sliders() throws {
        let panel = panel(isRaw: true)
        let temp = try row("Temp", in: panel)
        let tint = try row("Tint", in: panel)
        #expect(temp.value == 5200 && temp.displayedValue == "5,200")
        #expect(tint.value == -8 && tint.displayedValue == "\u{2212}8")
        #expect(temp.slider is GradientSlider && tint.slider is GradientSlider)

        temp.value = 50000
        #expect(abs(temp.value - 50000) < 0.5 && temp.slider.doubleValue == 1)
        temp.value = 2000
        #expect(abs(temp.value - 2000) < 0.5 && temp.slider.doubleValue == 0)
        temp.value = 100_000
        #expect(abs(temp.value - 50000) < 0.5, "clamped")
        // The low end gets the room: 6,500 K is about a third of the way along.
        temp.value = 6500
        #expect(temp.slider.doubleValue > 0.3 && temp.slider.doubleValue < 0.4)
        #expect(tint.slider.minValue == -150 && tint.slider.maxValue == 150)

        // Moving the knob sets the temperature in kelvin.
        var changes: [PhotoAdjustments] = []
        panel.onChange = { adjustments, _, _ in changes.append(adjustments) }
        temp.slider.doubleValue = SliderScale.logarithmic(2000...50000).position(for: 30000)
        _ = temp.slider.sendAction(temp.slider.action, to: temp.slider.target)
        #expect(changes.last?.whiteBalance.temperature == 30000 && temp.displayedValue == "30,000")
    }

    @Test("Value formats")
    func formats() {
        #expect(AdjustmentsPanelViewController.temperatureText(6000) == "6,000")
        #expect(AdjustmentsPanelViewController.tintText(22) == "+22")
        #expect(AdjustmentsPanelViewController.tintText(-22) == "\u{2212}22")
        #expect(AdjustmentsPanelViewController.tintText(0.2) == "0")
        let scale = SliderScale.logarithmic(2000...50000)
        for value in [2000.0, 4321, 10000, 50000] { #expect(abs(scale.value(at: scale.position(for: value)) - value) < 0.001) }
    }

    // MARK: - Neutral target

    @Test("The neutral target reads a 5 × 5 grid around the pointer, top row first, and averages it")
    func readsGrid() throws {
        // 100 × 100 pixels shown at 50 × 50 points: the top half red, the bottom half blue.
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 50, width: 100, height: 50))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 50))
        let image = red.composited(over: blue)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!])
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        let sample = try #require(NeutralTargetSample.read(image, shownIn: rect, at: CGPoint(x: 35, y: 35), context: context))
        #expect(sample.grid.count == 25)
        #expect(sample.grid[0][0] > 0.8 && sample.grid[0][2] < 0.3, "top row is red")
        #expect(sample.grid[24][2] > 0.8 && sample.grid[24][0] < 0.3, "bottom row is blue")
        #expect(NeutralTargetSample.read(image, shownIn: rect, at: CGPoint(x: 5, y: 5), context: context) == nil, "off the photo")
    }

    @Test("The readout is the grid's average in percent")
    func readout() {
        let sample = NeutralTargetSample(grid: Array(repeating: [0.5, 0.25, 1], count: 25))
        #expect(sample.average == [0.5, 0.25, 1])
        #expect(sample.readout == "R 50.0  G 25.0  B 100.0 %")
    }

    @Test("The loupe follows the pointer inside the preview and hides off the photo")
    func loupe() {
        let picker = WhiteBalancePickerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var onPhoto = true
        picker.sample = { _ in onPhoto ? NeutralTargetSample(grid: Array(repeating: [0.4, 0.4, 0.4], count: 25)) : nil }
        picker.updateLoupe(at: CGPoint(x: 100, y: 200))
        #expect(!picker.loupe.isHidden && picker.loupe.readout.stringValue == "R 40.0  G 40.0  B 40.0 %")
        #expect(picker.loupe.frame.minX > 100 && picker.loupe.frame.maxY < 200, "below and to the right of the pointer")
        // Near the bottom-right corner it flips to stay in view.
        picker.updateLoupe(at: CGPoint(x: 390, y: 10))
        #expect(picker.bounds.contains(picker.loupe.frame))
        onPhoto = false
        picker.updateLoupe(at: CGPoint(x: 100, y: 200))
        #expect(picker.loupe.isHidden)
    }
}
