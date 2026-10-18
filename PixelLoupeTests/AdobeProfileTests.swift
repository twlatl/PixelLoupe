import AppKit
import CoreData
import CoreImage
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-56. The profiles here are made by the tests in Adobe's format (Adobe's own profiles aren't in
/// the repository).
enum ProfileFixtures {
    /// An RGB table of `divisions`³ in the DNG SDK's layout, made from `transform` (on 0…1 RGB).
    static func rgbTable(divisions n: Int, primaries: UInt32 = 0, gamma: UInt32 = 1, range: ClosedRange<Double> = 0...2,
                         _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put64(_ value: Double) { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        [1, 1, 3, UInt32(n)].forEach(put32)
        func identity(_ index: Int) -> Int { (index * 0xFFFF + (n - 1) / 2) / (n - 1) }
        for r in 0..<n { for g in 0..<n { for b in 0..<n {
            let out = transform(SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1))
            for (channel, index) in [r, g, b].enumerated() {
                let value = Int((out[channel].clamped(to: 0...1) * 65535).rounded())
                put16(UInt16((value - identity(index)) & 0xFFFF))
            }
        } } }
        [primaries, gamma, 0].forEach(put32)
        put64(range.lowerBound)
        put64(range.upperBound)
        return data
    }

    /// A look table with the same change everywhere.
    static func lookTable(hueShift: Float, saturationScale: Float = 1, valueScale: Float = 1) -> Data {
        var data = Data()
        func put32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        [0, 1, 6, 4, 2, 0].forEach(put32)
        for _ in 0..<(6 * 4 * 2) {
            for value in [hueShift, saturationScale, valueScale] { put32(value.bitPattern) }
        }
        return data
    }

    static func xmp(name: String, group: String, uuid: String, camera: String = "", monochrome: Bool = false,
                    rgbTable: Data? = nil, lookTable: Data? = nil, tableAmount: Double? = nil,
                    settings: [String: String] = [:]) -> Data {
        var attributes = [
            "PresetType": "Look", "UUID": uuid, "SupportsAmount": "True", "CameraModelRestriction": camera,
            "ConvertToGrayscale": monochrome ? "True" : "False", "Version": "13.0", "ProcessVersion": "11.0",
        ]
        for (key, value) in settings { attributes[key] = value }
        if let rgbTable { attributes["RGBTable"] = "AAAA0001"; attributes["Table_AAAA0001"] = BigTable.encode(rgbTable) }
        if let lookTable { attributes["LookTable"] = "BBBB0002"; attributes["Table_BBBB0002"] = BigTable.encode(lookTable) }
        if let tableAmount { attributes["RGBTableAmount"] = String(tableAmount) }
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        }
        let attributeText = attributes.sorted { $0.key < $1.key }.map { "   crs:\($0.key)=\"\(escaped($0.value))\"" }.joined(separator: "\n")
        func alt(_ element: String, _ text: String) -> String {
            "   <crs:\(element)>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">\(escaped(text))</rdf:li>\n    </rdf:Alt>\n   </crs:\(element)>"
        }
        return Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        \(attributeText)
           crs:HasSettings="True">
        \(alt("Name", name))
        \(alt("Group", group))
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }

    /// A profile that swaps red and blue (so its effect is easy to see).
    static func swapProfile(name: String = "Swap", uuid: String = UUID().uuidString, camera: String = "") -> Data {
        xmp(name: name, group: "Test Looks", uuid: uuid, camera: camera,
            rgbTable: rgbTable(divisions: 9) { SIMD3($0.z, $0.y, $0.x) })
    }
}

@Suite("Adobe profiles: reading and rendering")
struct AdobeProfileTests {
    @Test func bigTablesRoundTrip() throws {
        let original = Data((0..<10_000).map { UInt8(($0 * 7 + $0 / 13) & 0xFF) })
        let encoded = BigTable.encode(original)
        #expect(encoded.utf8.allSatisfy { BigTable.alphabet.contains($0) })
        #expect(BigTable.decode(encoded) == original)
        #expect(BigTable.decode("not a table") == nil)
    }

    @Test func readsAProfileAndItsRGBTable() throws {
        let data = ProfileFixtures.xmp(name: "Modern 99", group: "Modern", uuid: "ABCDEF", tableAmount: 0.75,
                                       settings: ["Clarity2012": "+10"])
        #expect(AdobeProfile.parse(data)?.rgbTable == nil)
        let table = ProfileFixtures.rgbTable(divisions: 5, primaries: 1, gamma: 3, range: 0...1.5) { SIMD3($0.z, $0.y, $0.x) }
        let profile = try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "Modern 99", group: "Modern", uuid: "ABCDEF", rgbTable: table, tableAmount: 0.75)))
        #expect(profile.name == "Modern 99" && profile.group == "Modern" && profile.id == "ABCDEF" && profile.tableAmount == 0.75)
        let rgb = try #require(profile.rgbTable)
        #expect(rgb.divisions == 5 && rgb.colorSpaceName == CGColorSpace.adobeRGB1998 as String && rgb.amountRange == 0...1.5)
        // The red corner (4, 0, 0) holds blue.
        let red = ((4 * 5 + 0) * 5 + 0) * 3
        #expect(abs(rgb.samples[red] - 0) < 0.001 && abs(rgb.samples[red + 2] - 1) < 0.001)
        // Not a profile: a preset.
        #expect(AdobeProfile.parse(PresetFixtures.xmp(name: "P", group: "G", attributes: [:])) == nil)
    }

    @Test func theRGBTableCubeScalesWithAmount() throws {
        let profile = try #require(AdobeProfile.parse(ProfileFixtures.swapProfile()))
        let table = try #require(profile.rgbTable)
        func cubeRed(_ amount: Double) -> (Float, Float) {
            let cube = table.cube(amount: amount)
            let n = cube.dimension
            let values = cube.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let index = ((0 * n + 0) * n + (n - 1)) * 4   // red fastest: pure red input
            return (values[index], values[index + 2])
        }
        #expect(cubeRed(1) == (0, 1), "red becomes blue at 100%")
        #expect(cubeRed(0) == (1, 0), "unchanged at 0%")
        #expect(cubeRed(0.5) == (0.5, 0.5))
    }

    @Test func theLookTableTurnsHues() throws {
        let look = try #require(AdobeProfile.LookTable.parse(ProfileFixtures.lookTable(hueShift: 120, saturationScale: 1, valueScale: 0.5)))
        let red = look.apply(SIMD3(0.8, 0.1, 0.1), amount: 1)
        #expect(red.y > red.x && red.y > red.z, "a 120° turn makes red green: \(red)")
        #expect(abs(max(red.x, red.y, red.z) - 0.4) < 0.01, "and halves the value")
        let half = look.apply(SIMD3(0.8, 0.1, 0.1), amount: 0)
        #expect(abs(half.x - 0.8) < 0.001, "no change at 0%")
        let gray = look.apply(SIMD3(0.5, 0.5, 0.5), amount: 1)
        #expect(abs(gray.x - gray.y) < 0.001, "gray has no hue to turn")
    }

    /// The cube, as Core Image applies it to an image.
    @Test func rendersThroughCoreImage() throws {
        let profile = try #require(AdobeProfile.parse(ProfileFixtures.swapProfile()))
        let cube = try #require(profile.cubes(amount: 1).first)
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        filter.cubeDimension = Float(cube.dimension)
        filter.cubeData = cube.data
        filter.colorSpace = CGColorSpace(name: cube.colorSpaceName as CFString)
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(try #require(filter.outputImage), toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        #expect(pixel[2] > 0.8 && pixel[0] < 0.2, "red and blue swapped: \(pixel)")
    }
}

@Suite("Adobe profiles: library, import and presets")
@MainActor
struct AdobeProfileLibraryTests {
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func importsProfilesWithPresetsAndFindsThemByIDNameAndCamera() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Lightroom")
        try write(ProfileFixtures.swapProfile(name: "Modern 99", uuid: "UUID-MODERN"), to: source.appending(path: "Profiles/Modern/Modern 99.xmp"))
        try write(ProfileFixtures.swapProfile(name: "Camera Carbon", uuid: "UUID-NIKON", camera: "Nikon Z 50 2"),
                  to: source.appending(path: "Profiles/Camera/Nikon Z 50 2 Camera Carbon.xmp"))
        try write(ProfileFixtures.swapProfile(name: "Camera Carbon", uuid: "UUID-CANON", camera: "Canon EOS R5"),
                  to: source.appending(path: "Profiles/Camera/Canon EOS R5 Camera Carbon.xmp"))
        try write(PresetFixtures.xmp(name: "Warm", group: "Color", attributes: ["Vibrance": "20"]), to: source.appending(path: "Presets/Warm.xmp"))

        let presets = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory))
        let result = await presets.importPresets(from: [source])
        #expect(result == .init(presets: 1, profiles: 3))
        let library = presets.profiles
        #expect(library.directory != AdobeProfileLibrary.defaultDirectory, "tests keep their own profiles")
        #expect(library.find(id: "UUID-MODERN", name: "whatever", cameraModel: nil)?.name == "Modern 99", "by UUID")
        #expect(library.find(id: nil, name: "modern 99", cameraModel: nil)?.id == "UUID-MODERN", "by name")
        #expect(library.find(id: nil, name: "Camera Carbon", cameraModel: "NIKON Z 50_2")?.id == "UUID-NIKON", "for this camera")
        #expect(library.find(id: nil, name: "Camera Carbon", cameraModel: "Sony A1") == nil, "not for another camera")
        #expect(library.profile(id: "UUID-MODERN")?.rgbTable != nil, "its tables load")

        // The index is saved: a new library finds them without reading every profile.
        let reopened = AdobeProfileLibrary(directory: library.directory)
        #expect(reopened.allEntries.count == 3)
    }

    @Test func lightroomSettingsUseTheImportedProfile() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.swapProfile(name: "Vintage 06", uuid: "UUID-VINTAGE"))))
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "B&W 11", group: "B&W", uuid: "UUID-BW", monochrome: true,
                                                                              lookTable: ProfileFixtures.lookTable(hueShift: 0)))))
        func map(_ text: String) throws -> (PhotoAdjustments, [LightroomDevelopMapper.Difference]) {
            var adjustments = PhotoAdjustments()
            var input = LightroomDevelopMapper.Input(settings: try #require(try LuaTableParser.parse(text).table), processVersion: "11.0",
                                                     whiteBalance: nil, isRaw: true)
            input.profiles = library
            let differences = LightroomDevelopMapper.apply(input, to: &adjustments)
            return (adjustments, differences)
        }
        let vintage = try map(#"{ Look = { Name = "Vintage 06", Amount = 0.8, UUID = "UUID-VINTAGE" } }"#)
        #expect(vintage.0.profile == .init(kind: .standard, amount: 0.8, importedName: "Vintage 06", adobeID: "UUID-VINTAGE"))
        #expect(vintage.1.isEmpty, "rendered from its own tables: nothing to report")
        let bw = try map(#"{ Look = { Name = "B&W 11", Amount = 1 } }"#)
        #expect(bw.0.profile.adobeID == "UUID-BW" && bw.0.blackAndWhite.isEnabled)
        // Not imported: as before.
        let missing = try map(#"{ Look = { Name = "Modern 05", Amount = 1 } }"#)
        #expect(missing.0.profile.adobeID == nil && missing.1.map(\.key) == ["profile-modern-05"])
        // Adobe's default stays PixelLoupe's own rendering.
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "Adobe Color", group: "Adobe Raw", uuid: "UUID-COLOR",
                                                                              lookTable: ProfileFixtures.lookTable(hueShift: 5)))))
        #expect(try map(#"{ Look = { Name = "Adobe Color", Amount = 1 } }"#).0.profile.adobeID == nil)
    }

    @Test func aPresetsProfileComesAlong() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.swapProfile(name: "Modern 08", uuid: "UUID-M8"))))
        let preset = try #require(DevelopPreset.parse(
            PresetFixtures.xmp(name: "Warm Contrast", group: "Creative", attributes: ["Contrast2012": "+20"], look: "Modern 08"),
            url: URL(filePath: "/p/w.xmp"), defaultGroup: "x"))
        let result = preset.applied(to: PhotoAdjustments(), isRaw: true, profiles: library)
        #expect(result.profile.adobeID == "UUID-M8" && result.profile.isActive)
        #expect(result.light.contrast > 0)
    }

    @Test func aProfilesOwnSettingsRenderWithItButStayOffTheSliders() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.xmp(
            name: "Adobe Vivid", group: "Adobe Raw", uuid: "UUID-VIVID", lookTable: ProfileFixtures.lookTable(hueShift: 0, saturationScale: 1.2),
            settings: ["Clarity2012": "+20", "ConvertToGrayscale": "False"]))))
        var photo = PhotoAdjustments()
        photo.profile = .init(kind: .standard, amount: 0.5, importedName: "Adobe Vivid", adobeID: "UUID-VIVID")
        photo.presence.clarity = 0.1
        let rendered = AdobeProfileLook.withProfileSettings(photo, library: library)
        #expect(abs(rendered.presence.clarity - (0.1 + 0.2 * 0.5)) < 1e-9, "added at the profile's amount")
        #expect(photo.presence.clarity == 0.1, "the photo's own setting is unchanged")
        photo.profile.adobeID = nil
        #expect(AdobeProfileLook.withProfileSettings(photo, library: library) == photo, "nothing without the profile")
    }

    @Test func theProfilePopUpListsImportedProfilesAndSwitchesBlackAndWhite() throws {
        let directory = try TemporaryDirectory()
        let library = AdobeProfileLibrary(directory: directory.url)
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.swapProfile(name: "Vintage 06", uuid: "UUID-V6"))))
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.xmp(name: "B&W 11", group: "B&W", uuid: "UUID-B11", monochrome: true,
                                                                              lookTable: ProfileFixtures.lookTable(hueShift: 0)))))
        library.register(try #require(AdobeProfile.parse(ProfileFixtures.swapProfile(name: "Camera Carbon", uuid: "UUID-CC", camera: "Canon EOS R5"))))
        let panel = AdjustmentsPanelViewController()
        panel.profiles = library
        _ = panel.view
        panel.isEditingEnabled = true
        var changes: [PhotoAdjustments] = []
        panel.onChange = { adjustments, _, _ in changes.append(adjustments) }
        panel.cameraModel = "Nikon Z 9"
        func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
        let popUp = try #require(allViews(panel.view).first { $0.accessibilityIdentifier() == "profilePopUp" } as? NSPopUpButton)
        #expect(Array(popUp.itemTitles.prefix(6)) == ["Default", "Neutral", "Vivid", "Landscape", "Portrait", "Monochrome"])
        let groups = popUp.menu?.items.compactMap { $0.submenu?.title } ?? []
        #expect(groups == ["B&W", "Test Looks"], "Camera Carbon is for another camera")
        panel.cameraModel = "Canon EOS R5"
        #expect(popUp.menu?.items.compactMap { $0.submenu?.title }.contains("Camera Matching") == true)

        // Choose B&W 11: black and white with the profile.
        func choose(_ name: String) throws {
            let item = try #require(popUp.menu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.title == name })
            _ = (item.target as AnyObject).perform(item.action, with: item)
        }
        try choose("B&W 11")
        #expect(changes.last?.profile.adobeID == "UUID-B11" && changes.last?.blackAndWhite.isEnabled == true)
        #expect(popUp.titleOfSelectedItem == "B&W 11", "shown as the current profile")
        // Then a color one: back to color.
        try choose("Vintage 06")
        #expect(changes.last?.profile.adobeID == "UUID-V6" && changes.last?.blackAndWhite.isEnabled == false)
        // And a PixelLoupe look clears the Adobe profile.
        popUp.selectItem(at: 2)
        _ = popUp.target?.perform(popUp.action, with: popUp)
        #expect(changes.last?.profile.kind == .vivid && changes.last?.profile.adobeID == nil)
    }
}
