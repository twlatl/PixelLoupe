import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PixelLoupe

@Suite("Export borders")
struct ExportBorderTests {
    private let landscape = CGSize(width: 6000, height: 4000)

    private func bordered(_ update: (inout ExportSettings) -> Void = { _ in }) -> ExportSettings {
        var settings = ExportSettings()
        settings.borders = true
        settings.format = .png
        update(&settings)
        return settings
    }

    /// The file's size: the photo with its border on both sides.
    private func outputSize(_ settings: ExportSettings, _ size: CGSize) -> CGSize {
        let scale = settings.photoScale(for: size), border = settings.borderPixels(for: size)
        return CGSize(width: (size.width * scale).rounded() + 2 * border, height: (size.height * scale).rounded() + 2 * border)
    }

    @Test func borderAddsToTheFullSizePhoto() {
        let settings = bordered()
        #expect(settings.photoScale(for: landscape) == 1)
        #expect(outputSize(settings, landscape) == CGSize(width: 6100, height: 4100))
    }

    @Test func borderFitsInsideResizeToFit() {
        var settings = bordered { $0.resizes = true; $0.edge = 2000 }
        #expect(outputSize(settings, landscape).width == 2000)
        #expect((landscape.width * settings.photoScale(for: landscape)).rounded() == 1900)
        settings.resizeMode = .shortEdge
        #expect(outputSize(settings, landscape).height == 2000)
        settings.resizeMode = .widthHeight
        (settings.width, settings.height) = (3000, 1000)
        #expect(outputSize(settings, landscape).height == 1000)
        settings.resizeMode = .dimensions
        (settings.width, settings.height) = (2000, 3000)
        #expect(outputSize(settings, landscape).height == 2000 && outputSize(settings, landscape).width <= 3000)
        settings.resizeMode = .megapixels
        settings.megapixels = 6
        let size = outputSize(settings, landscape)
        #expect(abs(size.width * size.height - 6_000_000) < 5_000)
        settings.resizeMode = .percentage
        settings.percentage = 50
        #expect(outputSize(settings, landscape).height == 2000 && outputSize(settings, landscape).width <= 3000)
    }

    @Test func wideBordersLeaveRoomForSmallPhotos() {
        let settings = bordered { $0.resizes = true; $0.edge = 100; $0.borderWidth = 500 }
        #expect(settings.borderPixels(for: landscape) == 16, "a quarter of the short side")
        #expect(outputSize(settings, landscape).width == 100)
    }

    @Test func framesArePrintSizes() {
        var settings = bordered { $0.borderStyle = .frame; $0.resolution = 300; $0.resizes = true; $0.edge = 100 }
        let expected: [(ExportSettings.FrameSize, CGFloat, CGFloat)] = [
            (.threeByFive, 900, 1500), (.fourBySix, 1200, 1800), (.fiveBySeven, 1500, 2100), (.eightByEight, 2400, 2400),
        ]
        for (frame, short, long) in expected {
            settings.frameSize = frame
            #expect(settings.framePixels(for: landscape) == CGSize(width: long, height: short))
            #expect(settings.framePixels(for: CGSize(width: 4000, height: 6000)) == CGSize(width: short, height: long))
        }
        settings.frameSize = .eightByEight
        #expect(settings.photoScale(for: landscape) == 0.4, "touches the frame, not Resize to Fit's size")
        settings.resolutionUnit = .pixelsPerCentimeter
        settings.resolution = 100
        #expect(settings.framePixels(for: landscape).width == 2032)
    }

    @Test func originalsHaveNoBorder() {
        let settings = bordered { $0.format = .original; $0.borderStyle = .frame }
        #expect(!settings.usesFrame)
        #expect(settings.borderPixels(for: landscape) == 0)
    }

    @Test func settingsSurviveEncodingAndOldPresetsHaveNoBorder() throws {
        let settings = bordered { $0.borderColor = .black; $0.borderStyle = .frame; $0.borderWidth = 12; $0.frameSize = .fiveBySeven }
        #expect(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(try !JSONDecoder().decode(ExportSettings.self, from: Data("{}".utf8)).borders)
    }

    // MARK: Rendering

    /// Exports a 64 × 48 mid-gray photo and decodes the file.
    private func export(_ settings: ExportSettings) async throws -> (image: CGImage, properties: [CFString: Any]) {
        let directory = try TemporaryDirectory()
        let source = directory.url.appending(path: "Gray.png")
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        let item = ExportItem(source: source, adjustments: PhotoAdjustments(), metadata: PhotoMetadata(), keywords: [], rating: 0, captureDate: .now)
        let url = directory.url.appending(path: "Out.\(settings.format.fileExtension ?? "png")")
        try await PhotoExporter.export(item, to: url, settings: settings, watermark: nil)
        // In memory: images decode lazily, and the folder goes when this returns.
        let file = try #require(CGImageSourceCreateWithData(try Data(contentsOf: url) as CFData, nil))
        return (try #require(CGImageSourceCreateImageAtIndex(file, 0, nil)),
                try #require(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any]))
    }

    /// A pixel's red, green and blue in the image's own color space, from the top left.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: image.colorSpace!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: y + 1 - image.height, width: image.width, height: image.height))
        }
        return bytes.prefix(3).map(Int.init)
    }

    private func isGray(_ pixel: [Int]) -> Bool { pixel.allSatisfy { (60...200).contains($0) } }

    @Test(arguments: ExportSettings.ColorSpace.allCases, [8, 16])
    func borderIsPureColorOnEverySide(colorSpace: ExportSettings.ColorSpace, bitDepth: Int) async throws {
        for color in ExportSettings.BorderColor.allCases {
            let (image, _) = try await export(bordered {
                $0.borderColor = color; $0.borderWidth = 10; $0.colorSpace = colorSpace; $0.bitDepth = bitDepth
            })
            #expect(image.width == 84 && image.height == 68)
            let level = color == .white ? 255 : 0
            for (x, y) in [(0, 0), (83, 67), (9, 34), (74, 34), (42, 9), (42, 58)] {
                #expect(pixel(image, x, y) == [level, level, level])
            }
            for (x, y) in [(11, 11), (72, 56), (42, 34)] { #expect(isGray(pixel(image, x, y))) }
        }
    }

    @Test func framedPhotoIsCenteredAndEnlargedToTouch() async throws {
        let (image, properties) = try await export(bordered { $0.borderStyle = .frame; $0.frameSize = .eightByEight; $0.resolution = 20 })
        #expect(image.width == 160 && image.height == 160)
        #expect((properties[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 20) < 0.1 } == true, "prints at 8 × 8 in")
        // 64 × 48 fits as 160 × 120, with 20 pixels above and below.
        #expect(pixel(image, 80, 18) == [255, 255, 255] && pixel(image, 80, 141) == [255, 255, 255])
        for (x, y) in [(1, 80), (158, 80), (80, 22), (80, 137)] { #expect(isGray(pixel(image, x, y))) }
    }

    // MARK: Form

    @Test @MainActor func formChoosesOneStyleOrTheOther() throws {
        let directory = try TemporaryDirectory()
        let form = ExportSettingsForm(settings: ExportSettings(), watermarks: WatermarkPresets(directory: directory.url))
        let section = form.section(.borders, stateKey: "ExportBorderTests")
        _ = section
        #expect(!form.borderWidthButton.isEnabled && !form.frameSizePopUp.isEnabled)
        form.borderCheckbox.performClick(nil)
        #expect(form.settings.borders && form.borderWidthRow.slider.isEnabled && !form.frameSizePopUp.isEnabled)
        form.borderColorButtons[0].performClick(nil)
        #expect(form.settings.borderColor == .black)
        #expect(form.borderColorButtons.map(\.state) == [.on, .off] && form.borderWidthButton.state == .on)
        form.frameButton.performClick(nil)
        #expect(form.settings.borderStyle == .frame && form.borderWidthButton.state == .off)
        #expect(!form.borderWidthRow.slider.isEnabled && form.frameSizePopUp.isEnabled && !form.resizeCheckbox.isEnabled)
        form.borderWidthButton.performClick(nil)
        #expect(form.settings.borderStyle == .width && form.frameButton.state == .off && form.resizeCheckbox.isEnabled)
        #expect(form.settings.borderColor == .black, "the color's radio buttons are a group of their own")
        form.settings.format = .original
        #expect(!form.borderCheckbox.isEnabled && !form.borderWidthButton.isEnabled)
    }
}
