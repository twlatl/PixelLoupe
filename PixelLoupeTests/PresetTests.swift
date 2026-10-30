import AppKit
import CoreData
import Foundation
import Testing
@testable import PixelLoupe

/// RAW-13. The presets here are written by the tests (Lightroom's own presets aren't copied into the
/// repository); they follow the files Lightroom writes.
enum PresetFixtures {
    /// A preset file as Lightroom writes it: attributes for settings, text elements for the name, group
    /// and sort name, and optionally a look (whose own name must not be taken for the preset's).
    static func xmp(name: String, group: String, sortName: String? = nil, type: String = "Normal",
                    attributes: [String: String], look: String? = nil, curve: [String]? = nil) -> Data {
        let attributeText = attributes.sorted { $0.key < $1.key }.map { "   crs:\($0.key)=\"\($0.value)\"" }.joined(separator: "\n")
        func alt(_ element: String, _ text: String) -> String {
            "   <crs:\(element)>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">\(text)</rdf:li>\n    </rdf:Alt>\n   </crs:\(element)>"
        }
        let lookText = look.map {
            """
               <crs:Look>
                <rdf:Description crs:Name="\($0)" crs:Amount="0.5" crs:UUID="00">
                \(alt("SortName", "Look sort"))
                \(alt("Group", "Look group"))
                </rdf:Description>
               </crs:Look>
            """
        } ?? ""
        let curveText = curve.map { points in
            "   <crs:ToneCurvePV2012>\n    <rdf:Seq>\n" + points.map { "     <rdf:li>\($0)</rdf:li>" }.joined(separator: "\n")
                + "\n    </rdf:Seq>\n   </crs:ToneCurvePV2012>"
        } ?? ""
        return Data("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
           crs:PresetType="\(type)"
           crs:UUID="11111111111111111111111111111111"
        \(attributes["SupportsAmount"] == nil ? "   crs:SupportsAmount=\"True\"" : "")
           crs:Version="15.0"
           crs:ProcessVersion="11.0"
        \(attributeText)
           crs:HasSettings="True">
        \(alt("Name", name))
        \(alt("SortName", sortName ?? name))
        \(alt("Group", group))
        \(lookText)
        \(curveText)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """.utf8)
    }
}

@Suite("Presets: reading and applying")
struct PresetApplyTests {
    @Test func readsNameGroupAndSettingsNotTheLooksName() throws {
        let data = PresetFixtures.xmp(name: "Soft B&amp;W", group: "Black &amp; White", sortName: "BW 06",
                                      attributes: ["Blacks2012": "-25", "Clarity2012": "-30"], look: "B&amp;W 12")
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/soft.xmp"), defaultGroup: "Folder"))
        #expect(preset.name == "Soft B&W" && preset.group == "Black & White" && preset.sortName == "BW 06")
        #expect(preset.settingKeys.isSuperset(of: ["Blacks2012", "Clarity2012", "Look"]))
        #expect(!preset.settingKeys.contains("Name") && !preset.settingKeys.contains("PresetType"))
    }

    @Test func profilesAreNotPresets() {
        let profile = PresetFixtures.xmp(name: "Modern 01", group: "Modern", type: "Look", attributes: [:])
        #expect(DevelopPreset.parse(profile, url: URL(filePath: "/p/m.xmp"), defaultGroup: "x") == nil)
    }

    @Test func applyingChangesOnlyWhatThePresetHolds() throws {
        let data = PresetFixtures.xmp(name: "Look", group: "Creative", attributes: [
            "Blacks2012": "-25", "Clarity2012": "0", "GrayMixerRed": "-12", "ConvertToGrayscale": "True",
            "Sharpness": "60", "SharpenRadius": "1.2", "SharpenDetail": "30", "SharpenEdgeMasking": "10",
        ])
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/look.xmp"), defaultGroup: "x"))
        var photo = PhotoAdjustments()
        photo.light.exposure = 0.5
        photo.presence.clarity = 0.3
        photo.presence.vibrance = 0.2
        photo.crop.rect = CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        photo.vignette.strength = 0.4

        let result = preset.applied(to: photo, isRaw: true)
        #expect(result.light.exposure == 0.5 && result.presence.vibrance == 0.2, "settings the preset doesn't hold are kept")
        #expect(result.crop == photo.crop && result.vignette == photo.vignette)
        #expect(result.presence.clarity == 0, "a setting at 0 in the preset resets it")
        #expect(result.light.blackPoint != photo.light.blackPoint, "Blacks applied")
        #expect(result.blackAndWhite.isEnabled && result.blackAndWhite[.red] < 0, "black and white with its mix")
        #expect(result.sharpen.intensity > 0)
    }

    /// Like Lightroom's "B&W Flat": no ConvertToGrayscale; the B&W profile makes it black and white.
    @Test func aBlackAndWhitePresetMakesThePhotoBlackAndWhite() throws {
        let data = PresetFixtures.xmp(name: "B&amp;W Flat", group: "B&amp;W",
                                      attributes: ["GrayMixerRed": "-12", "GrayMixerGreen": "-28", "Clarity2012": "+20"], look: "B&amp;W 11")
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/flat.xmp"), defaultGroup: "x"))
        var photo = PhotoAdjustments()
        photo.light.exposure = 0.3
        let result = preset.applied(to: photo, isRaw: true)
        #expect(result.blackAndWhite.isEnabled, "black and white")
        #expect(result.blackAndWhite[.red] < 0 && result.blackAndWhite[.green] < 0, "with the preset's mix")
        #expect(result.presence.clarity > 0 && result.light.exposure == 0.3)
    }

    @Test func curvesAndColorGradingApply() throws {
        let data = PresetFixtures.xmp(name: "Fade", group: "Curve",
                                      attributes: ["ColorGradeShadowHue": "220", "ColorGradeShadowSat": "20", "ParametricLights": "15"],
                                      curve: ["0, 30", "128, 128", "255, 230"])
        let preset = try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/fade.xmp"), defaultGroup: "x"))
        let result = preset.applied(to: PhotoAdjustments(), isRaw: false)
        #expect(!result.curves.rgb.isIdentity, "the point curve")
        #expect(result.curves.parametric.lights > 0, "the parametric curve")
        #expect(result.color.shadows.amount > 0, "the shadows wheel")
        #expect(result.color.highlights == PhotoAdjustments.ColorWheel(), "other wheels untouched")
    }

    /// Every setting the Lightroom import maps can also come from a preset (except those that belong to
    /// one photo: crop, masks, spots, red eye).
    @Test func everyMappedSettingCanBeAppliedFromAPreset() {
        let perPhoto: Set<String> = [
            "CropLeft", "CropRight", "CropTop", "CropBottom", "CropAngle", "CropConstrainAspectRatio", "CropConstrainToWarp",
            "MaskGroupBasedCorrections", "GradientBasedCorrections", "CircularGradientBasedCorrections", "PaintBasedCorrections",
            "RetouchInfo", "RetouchAreas", "RedEyeInfo",
        ]
        let mapped = Set(LightroomDevelopCoverage.table.filter { $0.value == .mapped }.map(\.key)).subtracting(perPhoto)
        let missing = mapped.subtracting(PresetMerge.supportedKeys)
        #expect(missing.isEmpty, "\(missing.sorted())")
    }
}

@Suite("Presets: library, panel and pasting")
@MainActor
struct PresetLibraryTests {
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test func importsPresetsByGroupAndSkipsEverythingElse() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Adobe Settings")
        try write(PresetFixtures.xmp(name: "Warm", group: "Color", attributes: ["Vibrance": "20"]), to: source.appending(path: "Color/Warm.xmp"))
        try write(PresetFixtures.xmp(name: "Cool", group: "Color", sortName: "A", attributes: ["Vibrance": "-10"]), to: source.appending(path: "Color/Cool.xmp"))
        try write(PresetFixtures.xmp(name: "Grit", group: "Grain", attributes: ["GrainAmount": "30"]), to: source.appending(path: "Grain/Grit.xmp"))
        try write(PresetFixtures.xmp(name: "Modern 01", group: "Modern", type: "Look", attributes: [:]), to: source.appending(path: "Profiles/Modern 01.xmp"))
        try write(Data("not a preset".utf8), to: source.appending(path: "Color/readme.txt"))

        let library = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory))
        let count = await library.importPresets(from: [source])
        #expect(count.presets == 3, "the three presets; not the profile or the text file")
        #expect(library.groups.map(\.name) == ["Color", "Grain"])
        #expect(library.groups[0].presets.map(\.name) == ["Cool", "Warm"], "sorted by Lightroom's sort name")
        let copied = library.directory.appending(path: "Color/Warm.xmp")
        #expect(FileManager.default.fileExists(atPath: copied.path(percentEncoded: false)), "filed under its group")

        // Importing again replaces rather than duplicates.
        #expect(await library.importPresets(from: [source]).presets == 3)
        #expect(library.presets.count == 3)
    }

    @Test func panelSearchesByNameAndCopies() async throws {
        let directory = try TemporaryDirectory()
        let source = try directory.subdirectory("Source")
        try write(PresetFixtures.xmp(name: "Warm Glow", group: "Color", attributes: ["Vibrance": "20"]), to: source.appending(path: "a.xmp"))
        try write(PresetFixtures.xmp(name: "Deep Shadows", group: "Tone", attributes: ["Shadows2012": "-20"]), to: source.appending(path: "b.xmp"))
        let library = PresetLibrary(directory: directory.url.appending(path: "Settings", directoryHint: .isDirectory))
        await library.importPresets(from: [source])

        let panel = PresetsPanelViewController(library: library)
        _ = panel.view
        panel.reloadList()
        #expect(panel.groups.map(\.name) == ["Color", "Tone"])
        panel.searchField.stringValue = "glow"
        panel.reloadList()
        #expect(panel.groups.map(\.name) == ["Color"] && panel.groups[0].presets.map(\.name) == ["Warm Glow"])

        // Select it and copy.
        let row = (0..<panel.outline.numberOfRows).first { (panel.outline.item(atRow: $0) as? PresetsPanelViewController.Item)?.preset.name == "Warm Glow" }
        panel.outline.selectRowIndexes(IndexSet(integer: try #require(row)), byExtendingSelection: false)
        #expect(panel.applyButton.isEnabled && panel.copyButton.isEnabled)
        panel.copySelected(nil)
        guard case .preset(let copied)? = SettingsClipboard.content else { Issue.record("nothing copied"); return }
        #expect(copied.name == "Warm Glow")
        SettingsClipboard.content = nil
    }

    @Test func pasteSettingsAppliesToEverySelectedPhotoInOneUndo() throws {
        let directory = try TemporaryDirectory()
        let store = try CatalogStore.inMemory(info: Fixtures.referencedInfo, packageURL: directory.url.appending(path: "C.pixelloupe"))
        for index in 0..<3 {
            let photo = Photo(context: store.viewContext)
            photo.id = UUID()
            photo.fileName = "IMG_\(index).jpg"
            photo.filePath = directory.url.appending(path: photo.fileName).path(percentEncoded: false)
            photo.fileType = "JPG"
            photo.captureDate = Date(timeIntervalSince1970: Double(index))
            photo.importDate = Date()
            photo.editDate = Date()
            var adjustments = PhotoAdjustments()
            adjustments.light.exposure = Double(index) / 10
            adjustments.crop.rect = CGRect(x: 0, y: 0, width: 0.5 + Double(index) / 10, height: 1)
            photo.adjustments = adjustments
        }
        try store.viewContext.save()
        let controller = CatalogWindowController(store: store)
        defer { controller.close() }
        controller.showWindow(nil)
        let ids = Array(controller.state.photoOrder.prefix(2))
        controller.state.selectedPhotoIDs = ids

        let data = PresetFixtures.xmp(name: "Punch", group: "Color", attributes: ["Vibrance": "40", "Clarity2012": "20"])
        SettingsClipboard.content = .preset(try #require(DevelopPreset.parse(data, url: URL(filePath: "/p/punch.xmp"), defaultGroup: "x")))
        defer { SettingsClipboard.content = nil }
        controller.pasteSettings(nil)

        let photos = ids.compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }
        #expect(photos.count == 2)
        for photo in photos {
            #expect(photo.adjustments.presence.vibrance > 0 && photo.adjustments.presence.clarity > 0)
            #expect(DevelopHistory.steps(for: photo).last?.name == "Punch", "a history step named after the preset")
        }
        #expect(photos[0].adjustments.light.exposure != photos[1].adjustments.light.exposure, "each keeps its own exposure")
        let others = controller.state.photoOrder.dropFirst(2).compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }
        #expect(others.allSatisfy { $0.adjustments.presence.vibrance == 0 }, "unselected photos untouched")

        // Copy Settings from one photo, paste onto another: everything but its crop.
        controller.state.selectedPhotoIDs = [ids[0]]
        controller.copySettings(nil)
        let target = try #require(others.first)
        controller.state.selectedPhotoIDs = [target.objectID]
        let targetCrop = target.adjustments.crop
        controller.pasteSettings(nil)
        #expect(target.adjustments.presence.vibrance == photos[0].adjustments.presence.vibrance)
        #expect(target.adjustments.light.exposure == photos[0].adjustments.light.exposure)
        #expect(target.adjustments.crop == targetCrop, "the crop stays the photo's own")

        store.viewContext.undoManager?.undo()
        #expect(target.adjustments.presence.vibrance == 0, "undoable")
    }
}

/// RAW-58: ISO-adaptive presets and Lightroom's baseline presets.
@Suite("Presets: ISO and baseline")
struct PresetISOTests {
    /// Like Lightroom's "Adobe Color + Lens + NR": a baseline, base settings, and settings by ISO.
    static func adaptive() -> Data {
        var data = String(decoding: PresetFixtures.xmp(name: "Color + NR", group: "Defaults",
                                                         attributes: ["Baseline": "Adobe Default", "LuminanceSmoothing": "10", "ColorNoiseReduction": "25"]),
                          as: UTF8.self)
        let points = [(100, 0, 25), (800, 15, 25), (6400, 20, 40), (25600, 40, 80)].map { iso, luminance, color in
            "     <rdf:li crs:ISO=\"\(iso)\" crs:LuminanceSmoothing=\"\(luminance)\" crs:ColorNoiseReduction=\"\(color)\"/>"
        }.joined(separator: "\n")
        data = data.replacingOccurrences(of: "  </rdf:Description>\n </rdf:RDF>", with: """
           <crs:ISODependent>
            <rdf:Seq>
        \(points)
            </rdf:Seq>
           </crs:ISODependent>
          </rdf:Description>
         </rdf:RDF>
        """)
        return Data(data.utf8)
    }

    @Test func readsTheISOPoints() throws {
        let preset = try #require(DevelopPreset.parse(Self.adaptive(), url: URL(filePath: "/p/nr.xmp"), defaultGroup: "x"))
        #expect(preset.isoPoints.map(\.iso) == [100, 800, 6400, 25600])
        #expect(preset.isoPoints[1].settings == ["LuminanceSmoothing": 15, "ColorNoiseReduction": 25])
        #expect(!preset.settingKeys.contains("ISODependent") && !preset.settingKeys.contains("Baseline"))
    }

    @Test func noiseReductionFollowsThePhotosISO() throws {
        let preset = try #require(DevelopPreset.parse(Self.adaptive(), url: URL(filePath: "/p/nr.xmp"), defaultGroup: "x"))
        func luminance(at iso: Double?) -> Double { preset.applied(to: PhotoAdjustments(), isRaw: false, iso: iso).noiseReduction.amount }
        #expect(luminance(at: 100) == 0, "the first point, and below it")
        #expect(luminance(at: 50) == 0)
        #expect(abs(luminance(at: 800) - 0.15) < 1e-9)
        #expect(abs(luminance(at: 2263) - 0.175) < 0.002, "halfway between 800 and 6400 on a log scale")
        #expect(abs(luminance(at: 51200) - 0.40) < 1e-9, "the last point, and above it")
        #expect(abs(luminance(at: nil) - 0.10) < 1e-9, "without an ISO, the preset's own value")
        let pointsOnly = DevelopPreset.settings(at: 1600, of: preset.isoPoints)
        #expect(pointsOnly["LuminanceSmoothing"].map { $0 > 15 && $0 < 20 } == true)
    }

    @Test func baselinePresetsStartFromTheDefaults() throws {
        var photo = PhotoAdjustments()
        photo.light.exposure = 0.7
        photo.presence.clarity = 0.4
        photo.crop.rect = CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        photo.orientation.quarterTurns = 1
        photo.profile = .init(kind: .standard, amount: 1, importedName: "Modern 08", adobeID: "X")
        for baseline in ["Adobe Default", "Camera Settings"] {
            let preset = try #require(DevelopPreset.parse(PresetFixtures.xmp(name: baseline, group: "Defaults", attributes: ["Baseline": baseline]),
                                                          url: URL(filePath: "/p/b.xmp"), defaultGroup: "x"))
            let result = preset.applied(to: photo, isRaw: true)
            #expect(result.light.exposure == 0 && result.presence.clarity == 0, "\(baseline): back to the defaults")
            #expect(result.crop == photo.crop && result.orientation == photo.orientation, "\(baseline): the photo's crop and rotation stay")
            #expect(result.profile.adobeID == nil)
        }
        // A baseline with settings of its own: defaults, then those.
        let preset = try #require(DevelopPreset.parse(Self.adaptive(), url: URL(filePath: "/p/nr.xmp"), defaultGroup: "x"))
        let result = preset.applied(to: photo, isRaw: false, iso: 800)
        #expect(result.light.exposure == 0 && abs(result.noiseReduction.amount - 0.15) < 1e-9)
    }
}

/// RAW-228.
@Suite("New Preset sheet")
struct NewPresetSheetTests {
    /// The sheet's controls line up with its text (they sat at its left edge), short or with a checkbox
    /// for every section.
    @Test func theControlsLineUpWithTheSheetsText() async throws {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        for count in [2, PresetSection.allCases.count] {
            let checks = NSStackView(views: (0..<count).map { NSButton(checkboxWithTitle: "Section \($0)", target: nil, action: nil) })
            checks.orientation = .vertical
            checks.alignment = .leading
            let name = NSTextField(string: "")
            name.widthAnchor.constraint(equalToConstant: 300).isActive = true
            let stack = NSStackView(views: [name, checks])
            stack.orientation = .vertical
            stack.alignment = .leading

            let alert = NSAlert()
            alert.messageText = "New Preset"
            alert.informativeText = "Saves the chosen settings of this photo as a preset."
            alert.accessoryView = PresetsPanelViewController.alertAccessory(stack)
            alert.beginSheetModal(for: host, completionHandler: nil)
            alert.window.layoutIfNeeded()
            let content = try #require(alert.window.contentView)
            let title = try #require(content.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "New Preset" })
            let titleX = title.convert(title.bounds, to: nil).minX
            let fieldX = name.convert(name.bounds, to: nil).minX
            host.endSheet(alert.window)
            #expect(titleX > 0 && abs(fieldX - titleX) <= 4, "\(count) checkboxes: the name field is at \(fieldX), the title at \(titleX)")
        }
    }
}
