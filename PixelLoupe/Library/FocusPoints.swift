import CoreGraphics
import Foundation

/// Where the camera focused, read from the RAW file's maker notes (View ▸ Show Focus Points, RAW-308).
///
/// ImageIO doesn't pass AF information through (it has no Sony, Nikon or Fujifilm maker-note dictionary, and its
/// Canon one leaves AFInfo out), so the maker notes are read directly with ``TIFFFile``. Supported so far:
///
/// - **Sony** (ARW): `FocusLocation` (0x2027), or `FocusLocation2` (0x204A) on newer bodies: the sensor
///   size and the focus point, in the stored image's pixels.
/// - **Canon** (CR2): `AFInfo2` (0x26), or `AFInfo` (0x12) on older bodies: every AF point's box, centered on
///   the image with Y up, and which of them were in focus. Only the in-focus points are drawn.
/// - **Nikon** (NEF) with `AFInfo2` version 3 (Z 5/6/7/30/50/fc, D780, D6): the AF area's center and size.
///   Older DSLRs only name the primary point on their AF grid (such as "C6"), placed by ``NikonGrid``.
/// - **Fujifilm** (RAF): `FocusPixel` (0x1023), in the pixels of the embedded preview's EXIF size; manual
///   focus still records the selected point, so `FocusMode` (0x1021) is checked first.
///
/// Other makes return `nil` until there are sample files with in-focus AF points to check them against.
nonisolated struct FocusPoints: Equatable, Sendable {
    /// The AF areas, in unit coordinates of the image as stored (before the camera's orientation is applied),
    /// origin top-left. A zero-size rectangle is a point with no known area.
    var areas: [CGRect]

    /// Reads the focus points of the RAW file at `url`; `nil` when the file has none we can read.
    static func read(from url: URL) -> FocusPoints? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return read(from: data)
    }

    /// Reads the focus points of a RAW file's bytes: a TIFF-based RAW (ARW, CR2, NEF…) or a Fujifilm RAF.
    static func read(from data: Data) -> FocusPoints? {
        if data.starts(with: Data("FUJIFILMCCD-RAW".utf8)) {
            guard let exif = rafExif(data), let file = TIFFFile(data: exif) else { return nil }
            return read(from: file)
        }
        guard let file = TIFFFile(data: data) else { return nil }
        return read(from: file)
    }

    static func read(from file: TIFFFile) -> FocusPoints? {
        let make = file.ifd0[271].flatMap(file.string)?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
        guard let exif = file.exif(of: file.ifd0), let makerNote = exif[0x927C] else { return nil }
        if make.hasPrefix("SONY") { return sony(file, makerNote: makerNote) }
        if make.hasPrefix("CANON") { return canon(file, makerNote: makerNote) }
        if make.hasPrefix("NIKON") { return nikon(file, makerNote: makerNote) }
        if make.hasPrefix("FUJIFILM") { return fujifilm(file, exif: exif, makerNote: makerNote) }
        return nil
    }

    /// The 16-bit words of `entry`'s value, as signed numbers, whatever type it's tagged with.
    private static func words(_ file: TIFFFile, _ entry: TIFFFile.Entry) -> [Int] {
        guard let bytes = file.bytes(entry) else { return [] }
        return words(bytes, isBigEndian: file.isBigEndian)
    }

    private static func words(_ bytes: Data, isBigEndian: Bool) -> [Int] {
        let bytes = [UInt8](bytes)
        return stride(from: 0, to: bytes.count - 1, by: 2).map { index in
            let (high, low) = isBigEndian ? (bytes[index], bytes[index + 1]) : (bytes[index + 1], bytes[index])
            return Int(Int16(bitPattern: UInt16(high) << 8 | UInt16(low)))
        }
    }

    /// A box centered at (`x`, `y`) of `width` × `height`, in unit coordinates.
    private static func area(x: Double, y: Double, width: Double, height: Double) -> CGRect {
        CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
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

    // MARK: - Canon

    /// Canon's maker note is a plain directory whose offsets count from the start of the file. Its AF records
    /// give each point's box with 0,0 at the image center and Y up (on EOS bodies), in an `AFImageWidth` ×
    /// `AFImageHeight` image, then a bit per point that was in focus.
    private static func canon(_ file: TIFFFile, makerNote: TIFFFile.Entry) -> FocusPoints? {
        guard let directory = file.directory(at: makerNote.valueOffset) else { return nil }
        var points: [(x: Int, y: Int, width: Int, height: Int)] = []
        var size = (width: 0, height: 0)
        var inFocus: ArraySlice<Int> = []
        if let entry = directory[0x26] {
            // AFInfo2: size, mode, count, valid count, image size, AF image size, then widths, heights, Xs, Ys.
            let w = words(file, entry)
            guard w.count >= 8, w[1] != 0 else { return nil } // AFAreaMode 0 is manual focus.
            let count = w[2], valid = min(w[3], count)
            guard count > 0, w.count >= 8 + 4 * count + (count + 15) / 16 else { return nil }
            size = (w[6], w[7])
            points = (0..<valid).map { (w[8 + 2 * count + $0], w[8 + 3 * count + $0], w[8 + $0], w[8 + count + $0]) }
            inFocus = w[(8 + 4 * count)..<(8 + 4 * count + (count + 15) / 16)]
        } else if let entry = directory[0x12] {
            // AFInfo: count, valid count, image size, AF image size, one area size, then Xs, Ys.
            let w = words(file, entry)
            guard w.count >= 8 else { return nil }
            let count = w[0], valid = min(w[1], count)
            guard count > 0, w.count >= 8 + 2 * count + (count + 15) / 16 else { return nil }
            size = (w[4], w[5])
            points = (0..<valid).map { (w[8 + $0], w[8 + count + $0], w[6], w[7]) }
            inFocus = w[(8 + 2 * count)..<(8 + 2 * count + (count + 15) / 16)]
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let (width, height) = (Double(size.width), Double(size.height))
        let areas = points.indices.compactMap { index -> CGRect? in
            let word = inFocus[inFocus.startIndex + index / 16]
            guard word & (1 << (index % 16)) != 0 else { return nil }
            let point = points[index]
            return area(
                x: 0.5 + Double(point.x) / width, y: 0.5 - Double(point.y) / height,
                width: Double(max(point.width, 0)) / width, height: Double(max(point.height, 0)) / height
            )
        }
        return areas.isEmpty ? nil : FocusPoints(areas: areas)
    }

    // MARK: - Nikon

    /// Nikon's maker note is "Nikon\0", a version, and then a TIFF of its own whose offsets count from its header.
    /// `AFInfo2` (0xB7) version 3 has the AF area's center and size in an `AFImageWidth` × `AFImageHeight` image,
    /// origin top-left, when its byte 7 says coordinates are available. Versions 0100 and 0101 (DSLRs) only name the
    /// primary point on the AF grid; see ``NikonGrid``.
    private static func nikon(_ file: TIFFFile, makerNote: TIFFFile.Entry) -> FocusPoints? {
        guard makerNote.count > 18, let bytes = file.bytes(makerNote), bytes.starts(with: Data("Nikon\0".utf8)),
              let inner = TIFFFile(data: Data(bytes.dropFirst(10))), let entry = inner.ifd0[0xB7],
              let infoData = inner.bytes(entry), infoData.count >= 8
        else { return nil }
        let info = [UInt8](infoData)
        guard info[0] == UInt8(ascii: "0") else { return nil }
        if info[1] == UInt8(ascii: "1") {
            let model = file.ifd0[272].flatMap(file.string)?.trimmingCharacters(in: .whitespaces).uppercased() ?? ""
            // PrimaryAFPoint: byte 7 in version 0100, byte 0x44 in 0101; 0 when nothing was in focus.
            let at = info[3] == UInt8(ascii: "1") ? 0x44 : 7
            guard at < info.count, let grid = NikonGrid(schema: Int(info[6]), model: model),
                  let point = grid.point(Int(info[at]))
            else { return nil }
            return FocusPoints(areas: [CGRect(origin: point, size: .zero)])
        }
        guard info[1] == UInt8(ascii: "3"), info.count >= 0x36, info[7] == 1 else { return nil }
        let w = words(Data(info[0x2A..<0x36]), isBigEndian: inner.isBigEndian).map { $0 & 0xFFFF }
        let (imageWidth, imageHeight, x, y, width, height) = (w[0], w[1], w[2], w[3], w[4], w[5])
        guard imageWidth > 0, imageHeight > 0, x > 0 || y > 0, x <= imageWidth, y <= imageHeight else { return nil }
        let (iw, ih) = (Double(imageWidth), Double(imageHeight))
        return FocusPoints(areas: [area(x: Double(x) / iw, y: Double(y) / ih, width: Double(width) / iw, height: Double(height) / ih)])
    }

    // MARK: - Fujifilm

    /// The TIFF inside the EXIF segment of a RAF's embedded JPEG, whose offset and length are at bytes 84 and 88
    /// of the RAF header (big-endian).
    private static func rafExif(_ data: Data) -> Data? {
        let bytes = data
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return (0..<4).reduce(0) { $0 << 8 | Int(bytes[bytes.startIndex + at + $1]) }
        }
        guard let jpegStart = u32(84), let jpegLength = u32(88), jpegStart + jpegLength <= bytes.count,
              bytes[bytes.startIndex + jpegStart] == 0xFF, bytes[bytes.startIndex + jpegStart + 1] == 0xD8
        else { return nil }
        // Walk the JPEG's segments to APP1 "Exif\0\0".
        var at = jpegStart + 2
        let end = jpegStart + jpegLength
        while at + 4 <= end {
            let marker = bytes[bytes.startIndex + at + 1]
            let length = Int(bytes[bytes.startIndex + at + 2]) << 8 | Int(bytes[bytes.startIndex + at + 3])
            guard bytes[bytes.startIndex + at] == 0xFF, length >= 2, at + 2 + length <= end else { return nil }
            let body = (bytes.startIndex + at + 4)..<(bytes.startIndex + at + 2 + length)
            if marker == 0xE1, bytes[body].starts(with: Data("Exif\0\0".utf8)) {
                return bytes.subdata(in: (body.lowerBound + 6)..<body.upperBound)
            }
            if marker == 0xDA { return nil } // Image data: no more metadata.
            at += 2 + length
        }
        return nil
    }

    /// Fujifilm's maker note is "FUJIFILM", then the offset of its (little-endian) directory, and its offsets
    /// count from the start of the maker note. `FocusPixel` is in the pixels of the EXIF image size
    /// (`PixelXDimension` × `PixelYDimension`, the embedded preview's size), in the stored orientation.
    private static func fujifilm(_ file: TIFFFile, exif: TIFFFile.Directory, makerNote: TIFFFile.Entry) -> FocusPoints? {
        guard makerNote.count > 12, var bytes = file.bytes(makerNote), bytes.starts(with: Data("FUJIFILM".utf8)),
              let width = exif[0xA002].flatMap({ file.integers($0).first }),
              let height = exif[0xA003].flatMap({ file.integers($0).first }), width > 0, height > 0
        else { return nil }
        // Turn the header into a TIFF one so the maker note reads as a TIFF with offsets from its start.
        bytes.replaceSubrange(bytes.startIndex..<(bytes.startIndex + 8), with: [0x49, 0x49, 0x2A, 0x00] + [UInt8](bytes[(bytes.startIndex + 8)..<(bytes.startIndex + 12)]))
        guard let note = TIFFFile(data: bytes) else { return nil }
        let directory = note.ifd0
        // FocusMode: 0 auto, 1 manual, 65535 movie.
        if let mode = directory[0x1021].flatMap({ note.integers($0).first }), mode != 0 { return nil }
        guard let entry = directory[0x1023], entry.count == 2 else { return nil }
        let values = note.integers(entry)
        guard values.count == 2, values[0] > 0 || values[1] > 0, values[0] <= width, values[1] <= height else { return nil }
        let point = CGRect(x: Double(values[0]) / Double(width), y: Double(values[1]) / Double(height), width: 0, height: 0)
        return FocusPoints(areas: [point])
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

/// The AF point grids of Nikon DSLRs, which record only the primary point's number (`AFInfo2` versions 0100 and
/// 0101). The point names and their order come from ExifTool; where the grid sits in the frame isn't recorded, so
/// its spacing was fitted to where Ted's photos are sharpest (D750 for 51 points, D850 for 153, D7000 for 39), and
/// is only approximate.
nonisolated struct NikonGrid {
    /// The point names in the order the camera numbers them, from 1: row letter (A at the top) and column.
    let names: [Substring]
    /// The center point's row (A is 0) and column.
    let center: (row: Int, column: Int)
    /// Columns the short top and bottom rows (A and E) start in from the full rows' first column.
    let shortRowIndent: Int
    /// The distance between neighboring points, as a fraction of the image's width and height.
    let pitch: (x: Double, y: Double)

    /// DX bodies put the same AF module over a smaller sensor, so its points spread 1.5× wider across the frame.
    private static let dxModels: Set<String> = ["NIKON D300", "NIKON D300S", "NIKON D7100", "NIKON D7200", "NIKON D7500", "NIKON D500"]

    init?(schema: Int, model: String) {
        let crop = Self.dxModels.contains(model) ? 1.5 : 1
        switch schema {
        case 1: // 51 points: rows A–E, the full rows B–D with 11 columns, A and E with 9 (D750, D810, D4…).
            names = """
            C6 B6 A5 D6 E5 C7 B7 A6 D7 E6 C5 B5 A4 D5 E4 C8 B8 A7 D8 E7 C9 B9 A8 D9 E8 C10 B10 A9 D10 E9 C11 B11 D11 \
            C4 B4 A3 D4 E3 C3 B3 A2 D3 E2 C2 B2 A1 D2 E1 C1 B1 D1
            """.split(separator: " ")
            center = (2, 6)
            shortRowIndent = 1
            pitch = (0.0325 * crop, 0.07 * crop)
        case 3: // 39 points: rows B–D with 11 columns, A and E with 3 (D7000, D600, D610…).
            names = """
            C6 B6 A2 D6 E2 C7 B7 A3 D7 E3 C5 B5 A1 D5 E1 C8 B8 D8 C9 B9 D9 C10 B10 D10 C11 B11 D11 C4 B4 D4 C3 B3 D3 \
            C2 B2 D2 C1 B1 D1
            """.split(separator: " ")
            center = (2, 6)
            shortRowIndent = 4
            pitch = (0.06, 0.115)
        case 7: // 153 points: 9 rows (A–I) by 17 columns, numbered a column at a time from the center (D850, D5, D500).
            let columns = [9, 10, 11, 8, 7, 12, 13, 14, 15, 16, 17, 6, 5, 4, 3, 2, 1]
            names = columns.flatMap { column in "EDCBAFGHI".map { Substring("\($0)\(column)") } }
            center = (4, 9)
            shortRowIndent = 0
            pitch = (0.0325 * crop, 0.0575 * crop)
        default:
            return nil
        }
    }

    /// Where point `number` (from 1) sits, in unit coordinates of the image as stored, origin top-left.
    func point(_ number: Int) -> CGPoint? {
        guard number >= 1, number <= names.count, let letter = names[number - 1].first?.asciiValue,
              var column = Int(names[number - 1].dropFirst())
        else { return nil }
        let row = Int(letter) - Int(UInt8(ascii: "A"))
        if shortRowIndent > 0, row == 0 || row == 4 { column += shortRowIndent }
        return CGPoint(
            x: 0.5 + Double(column - center.column) * pitch.x,
            y: 0.5 + Double(row - center.row) * pitch.y
        )
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
