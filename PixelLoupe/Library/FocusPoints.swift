import CoreGraphics
import Foundation

/// Where the camera focused, read from the RAW file's maker notes (View ▸ Show Focus Points, RAW-308).
///
/// ImageIO doesn't pass AF information through (it has no Sony maker-note dictionary, and its Canon one leaves
/// AFInfo out), so the maker notes are read directly with ``TIFFFile``. Supported so far:
///
/// - **Sony** (ARW): `FocusLocation` (0x2027), or `FocusLocation2` (0x204A) on newer bodies: the sensor
///   size and the focus point, in the stored image's pixels.
///
/// Other makes return `nil` until there are sample files with in-focus AF points to check them against.
nonisolated struct FocusPoints: Equatable, Sendable {
    /// The AF areas, in unit coordinates of the image as stored (before the camera's orientation is applied),
    /// origin top-left. A zero-size rectangle is a point with no known area.
    var areas: [CGRect]

    /// Reads the focus points of the RAW file at `url`; `nil` when the file has none we can read.
    static func read(from url: URL) -> FocusPoints? {
        guard let file = TIFFFile(contentsOf: url) else { return nil }
        return read(from: file)
    }

    static func read(from file: TIFFFile) -> FocusPoints? {
        let make = file.ifd0[271].flatMap(file.string)?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        guard let exif = file.exif(of: file.ifd0), let makerNote = exif[0x927C] else { return nil }
        if make.hasPrefix("SONY") { return sony(file, makerNote: makerNote) }
        return nil
    }

    // MARK: - Sony

    /// Sony's maker note is a TIFF directory after a 12-byte "SONY DSC " (or similar) header, or with no header
    /// on some bodies; its offsets count from the start of the file.
    private static func sony(_ file: TIFFFile, makerNote: TIFFFile.Entry) -> FocusPoints? {
        guard let header = file.bytes(TIFFFile.Entry(tag: 0, type: 7, count: min(12, makerNote.count), valueOffset: makerNote.valueOffset))
        else { return nil }
        let start = header.starts(with: Data("SONY".utf8)) ? makerNote.valueOffset + 12 : makerNote.valueOffset
        guard let directory = file.directory(at: start) else { return nil }
        for tag: UInt16 in [0x2027, 0x204A] {
            guard let entry = directory[tag], entry.count == 4 else { continue }
            let values = file.integers(entry)
            guard values.count == 4 else { continue }
            let (width, height, x, y) = (values[0], values[1], values[2], values[3])
            // Manual focus (and some drive modes) write zeros.
            guard width > 0, height > 0, x > 0 || y > 0, x <= width, y <= height else { continue }
            let point = CGRect(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height), width: 0, height: 0)
            return FocusPoints(areas: [point])
        }
        return nil
    }

    // MARK: - Placing

    /// The areas in unit coordinates of the photo's frame, as masks and the crop are stored: after the camera's
    /// orientation (`fileOrientation`, EXIF 1–8) and Photo ▸ Rotate/Flip, before straightening and cropping,
    /// origin bottom-left.
    func frameAreas(fileOrientation: Int, orientation: PhotoAdjustments.Orientation) -> [CGRect] {
        areas.map { area in
            let corners = [CGPoint(x: area.minX, y: area.minY), CGPoint(x: area.maxX, y: area.maxY)].map {
                Self.framePoint($0, fileOrientation: fileOrientation, orientation: orientation)
            }
            return CGRect(
                x: min(corners[0].x, corners[1].x), y: min(corners[0].y, corners[1].y),
                width: abs(corners[0].x - corners[1].x), height: abs(corners[0].y - corners[1].y)
            )
        }
    }

    /// The outline to draw for each area placed by `frame` (see ``PreviewFrame``): the area itself when it has a
    /// size, else a square around the point. Areas cropped out of `frame.visible` are left out.
    static func markerPath(frameAreas: [CGRect], in frame: PreviewFrame) -> CGPath {
        let path = CGMutablePath()
        let visible = frame.visible
        guard frame.rect.width > 0, frame.rect.height > 0 else { return path }
        // Big enough to find at a glance, small enough not to hide what's in focus.
        let side = max(16, min(visible.width, visible.height) * 0.04)
        for area in frameAreas {
            func view(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                frame.viewPoint(CGPoint(x: x * frame.rect.width, y: y * frame.rect.height))
            }
            let center = view(area.midX, area.midY)
            guard visible.insetBy(dx: -0.5, dy: -0.5).contains(center) else { continue }
            if area.width > 0, area.height > 0 {
                path.addLines(between: [
                    view(area.minX, area.minY), view(area.maxX, area.minY), view(area.maxX, area.maxY), view(area.minX, area.maxY),
                ])
                path.closeSubpath()
            } else {
                path.addRect(CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
            }
        }
        return path
    }

    /// A stored-image point (unit, origin top-left) in the frame (unit, origin bottom-left).
    static func framePoint(_ point: CGPoint, fileOrientation: Int, orientation: PhotoAdjustments.Orientation) -> CGPoint {
        let (u, v) = (point.x, point.y)
        // Where the camera's orientation puts it, still origin top-left.
        let shown: CGPoint = switch fileOrientation {
        case 2: CGPoint(x: 1 - u, y: v)
        case 3: CGPoint(x: 1 - u, y: 1 - v)
        case 4: CGPoint(x: u, y: 1 - v)
        case 5: CGPoint(x: v, y: u)
        case 6: CGPoint(x: 1 - v, y: u)
        case 7: CGPoint(x: 1 - v, y: 1 - u)
        case 8: CGPoint(x: v, y: 1 - u)
        default: point
        }
        var result = CGPoint(x: shown.x, y: 1 - shown.y)
        // Rotate/Flip: mirrored first, then turned counterclockwise a quarter at a time.
        if orientation.isMirrored { result.x = 1 - result.x }
        for _ in 0..<(((orientation.quarterTurns % 4) + 4) % 4) {
            result = CGPoint(x: 1 - result.y, y: result.x)
        }
        return result
    }
}

/// Focus points already read, by file, so stepping back and forth through photos reads each file once.
final class FocusPointsCache {
    static let shared = FocusPointsCache()

    /// `.some(nil)`: read, and the file has none.
    private var points: [URL: FocusPoints?] = [:]

    /// What's been read for `url` (`nil` if it hasn't been read yet).
    func cached(_ url: URL) -> FocusPoints?? { points[url] }

    /// The focus points of the file at `url`, reading it off the main thread the first time.
    func points(for url: URL) async -> FocusPoints? {
        if let known = points[url] { return known }
        let read = await Self.read(url)
        points[url] = read
        return read
    }

    @concurrent
    private static func read(_ url: URL) async -> FocusPoints? {
        FocusPoints.read(from: url)
    }
}
