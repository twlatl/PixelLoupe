import CoreData
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

@Suite("Lightroom crop import")
struct CropImportTests {
    private typealias Crop = LightroomCropConverter.Crop

    @Test("An unrotated crop is the same rectangle with the y axis flipped")
    func unrotated() throws {
        let crop = try #require(LightroomCropConverter.convert(Crop(left: 0.1, top: 0.2, right: 0.6, bottom: 0.8), size: CGSize(width: 1000, height: 500)))
        #expect(crop.angle == 0)
        #expect(abs(crop.rect.minX - 0.1) < 1e-9 && abs(crop.rect.minY - 0.2) < 1e-9)   // bottom 0.8 from the top = 0.2 from the bottom
        #expect(abs(crop.rect.width - 0.5) < 1e-9 && abs(crop.rect.height - 0.6) < 1e-9)
        #expect(crop.constrainToImage)
        // A crop touching the top edge touches the top of PixelLoupe's frame (y = 1).
        let top = try #require(LightroomCropConverter.convert(Crop(left: 0, top: 0, right: 1, bottom: 0.5), size: CGSize(width: 1000, height: 500)))
        #expect(abs(top.rect.maxY - 1) < 1e-9)
    }

    @Test("No crop gives nothing")
    func none() {
        #expect(LightroomCropConverter.convert(Crop(), size: CGSize(width: 100, height: 100)) == nil)
        #expect(LightroomCropConverter.convert(Crop(left: 0.5, top: 0, right: 0.4, bottom: 1), size: CGSize(width: 100, height: 100)) == nil)
        #expect(LightroomCropConverter.convert(Crop(angle: 2), size: .zero) == nil)
    }

    @Test("A straightened crop with no cropping still gets its angle")
    func angleOnly() throws {
        let crop = try #require(LightroomCropConverter.convert(Crop(angle: 3), size: CGSize(width: 600, height: 400)))
        #expect(crop.angle == -3 * 1 || crop.angle == LightroomCropConverter.angleSign * 3)
        #expect(crop.rect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    // MARK: Rendering matrix

    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// An image whose color says where each pixel is: R = x ÷ width, G = y ÷ height (y up).
    private func positionImage(width: Int, height: Int) -> CIImage {
        var data = [Float](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            // (Bitmap rows run top to bottom; the color records y counted up from the bottom.)
            let i = ((height - 1 - y) * width + x) * 4
            data[i] = Float(x) / Float(width); data[i + 1] = Float(y) / Float(height); data[i + 2] = 0; data[i + 3] = 1
        } }
        return CIImage(bitmapData: data.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: nil)
    }

    private func pixel(_ image: CIImage, _ x: Double, _ y: Double) -> (x: Double, y: Double) {
        var data = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &data, rowBytes: 16,
                       bounds: CGRect(x: Int(x.rounded(.down)), y: Int(y.rounded(.down)), width: 1, height: 1), format: .RGBAf, colorSpace: nil)
        return (Double(data[0]), Double(data[1]))
    }

    /// The photo content at the crop's center and corners must be the content Lightroom's crop
    /// rectangle (turned about its own center) covers.
    @Test("Rendered crops pick the right content for every size, angle and position",
          arguments: [(400, 300), (300, 400), (320, 320)],
          [-20.0, -3.5, 0, 0.8, 7, 30])
    func renderedMatrix(size: (Int, Int), angle: Double) throws {
        let (width, height) = (Double(size.0), Double(size.1))
        let source = positionImage(width: size.0, height: size.1)
        // Centered, and hugging each edge (as far as a rotated crop of this size can).
        let boxes: [(Double, Double, Double, Double)] = [
            (0.35, 0.35, 0.65, 0.65), (0.30, 0.38, 0.52, 0.62), (0.48, 0.38, 0.70, 0.62), (0.38, 0.30, 0.62, 0.52), (0.38, 0.48, 0.62, 0.70),
        ]
        for (left, top, right, bottom) in boxes {
            let lightroom = Crop(left: left, top: top, right: right, bottom: bottom, angle: angle)
            let crop = try #require(LightroomCropConverter.convert(lightroom, size: CGSize(width: width, height: height)))
            var adjustments = PhotoAdjustments()
            adjustments.crop = crop
            let output = CropRenderer.apply(crop, to: source, frame: source.extent, rendering: .cropped)

            // Where output pixel (u, v) (y up, from the output's bottom-left) comes from, by Lightroom's
            // description: the crop rectangle's center C plus the offset from the output's center, turned
            // by the straightening angle's opposite (the picture was turned by it).
            let cropWidth = (right - left) * width, cropHeight = (bottom - top) * height
            let center = (x: (left + right) / 2 * width, y: height - (top + bottom) / 2 * height)
            let turn = -(LightroomCropConverter.angleSign * angle) * .pi / 180   // from the straightened frame back to the photo
            for (du, dv) in [(0.0, 0.0), (-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
                let offset = (x: du * (cropWidth / 2 - 2), y: dv * (cropHeight / 2 - 2))
                let expected = (x: center.x + offset.x * cos(turn) - offset.y * sin(turn), y: center.y + offset.x * sin(turn) + offset.y * cos(turn))
                let u = output.extent.width / 2 + offset.x, v = output.extent.height / 2 + offset.y
                let seen = pixel(output, u, v)
                #expect(abs(seen.x * width - expected.x) < 2.5 && abs(seen.y * height - expected.y) < 2.5,
                        "angle \(angle) box \((left, top, right, bottom)) corner \((du, dv)): saw \((seen.x * width, seen.y * height)) expected \(expected)")
            }
            #expect(abs(output.extent.width - cropWidth) <= 2.5 && abs(output.extent.height - cropHeight) <= 2.5)
        }
    }

    // MARK: Aspect

    @Test("A constrained crop is recognized as the photo's ratio or a standard one")
    func aspects() throws {
        let size = CGSize(width: 6000, height: 4000)
        func convert(_ w: Double, _ h: Double, constrained: Bool = true) throws -> PhotoAdjustments.Crop {
            let crop = Crop(left: 0.1, top: 0.1, right: 0.1 + w / 6000, bottom: 0.1 + h / 4000, constrainAspectRatio: constrained)
            return try #require(LightroomCropConverter.convert(crop, size: size))
        }
        #expect(try convert(3000, 2000).aspect == .original)
        #expect(try convert(2000, 2000).aspect == .ratio(width: 1, height: 1))
        #expect(try convert(2000, 1500).aspect == .ratio(width: 4, height: 3))     // 4:3
        #expect(try convert(1600, 2000).aspect == .ratio(width: 5, height: 4))     // portrait 4:5 is stored landscape
        #expect(try convert(1920, 1080).aspect == .ratio(width: 16, height: 9))
        let odd = try convert(2000, 1111)
        #expect(odd.aspect == .custom && odd.isAspectLocked)
        let free = try convert(2000, 2000, constrained: false)
        #expect(free.aspect == .custom && !free.isAspectLocked)
        // Within half a percent counts.
        #expect(try convert(2000, 1496).aspect == .ratio(width: 4, height: 3))
        #expect(try convert(2000, 1480).aspect == .custom)
    }

    // MARK: Mapper

    private func map(_ text: String, size: CGSize) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
        var adjustments = PhotoAdjustments()
        let differences = LightroomDevelopMapper.apply(
            .init(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0", whiteBalance: nil, isRaw: true, imageSize: size),
            to: &adjustments)
        return (adjustments, differences)
    }

    @Test("The mapper imports Lightroom's crop settings")
    func mapperImportsCrop() throws {
        let (adjustments, differences) = try map("""
            { CropLeft = 0.1, CropRight = 0.9, CropTop = 0.2, CropBottom = 0.8, CropAngle = 0, CropConstrainAspectRatio = true,
              CropWidth = 3, CropHeight = 2, CropUnit = 2, CropAspectRatioW = 3 }
            """, size: CGSize(width: 6000, height: 4000))
        #expect(differences.isEmpty)
        #expect(abs(adjustments.crop.rect.minX - 0.1) < 1e-9 && abs(adjustments.crop.rect.width - 0.8) < 1e-9)
        #expect(adjustments.crop.isAspectLocked && adjustments.crop.constrainToImage)
        // Without a crop nothing is set.
        #expect(try map("{ CropLeft = 0, CropRight = 1, CropTop = 0, CropBottom = 1, CropAngle = 0 }", size: CGSize(width: 10, height: 10)).0.isDefault)
        // A straightened crop with no known size is reported.
        let unknown = try map("{ CropLeft = 0.1, CropRight = 0.9, CropAngle = 2 }", size: .zero)
        #expect(unknown.1 == [LightroomDevelopMapper.cropApproximated] && unknown.0.crop.isActive)
    }

    @Test("A photo's displayed size follows the camera and PixelLoupe orientation")
    @MainActor
    func displayedSize() throws {
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: try TemporaryDirectory().url.appending(path: "C.pixelloupe"))
        let photo = Photo(context: store.viewContext)
        photo.pixelWidth = 6000
        photo.pixelHeight = 4000
        photo.orientation = 1
        #expect(photo.displayedPixelSize == CGSize(width: 6000, height: 4000))
        photo.orientation = 6
        #expect(photo.displayedPixelSize == CGSize(width: 4000, height: 6000))
        var adjustments = PhotoAdjustments()
        adjustments.orientation = .init(quarterTurns: 1, isMirrored: false)
        photo.adjustments = adjustments
        #expect(photo.displayedPixelSize == CGSize(width: 6000, height: 4000))
    }
}
