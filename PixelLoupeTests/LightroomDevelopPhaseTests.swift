import CoreData
import Foundation
import Testing
@testable import PixelLoupe

@MainActor
struct LightroomDevelopPhaseTests {
    private func sql(_ text: String) -> String { text.replacingOccurrences(of: "'", with: "''") }

    @Test("Stores mapped settings as adjustments, keeps earlier ones, and reports what wasn't imported")
    func importsDevelopSettings() async throws {
        let fixture = try PhotosFixture()
        let settings = DevelopSettingsFixtures.self
        // A.jpg (image 10): edited JPEG; D.cr2 (13): RAW with custom white balance; E.jpg (15): untouched; B.jpg (11 is its copy).
        try fixture.run("""
            INSERT INTO Adobe_imageDevelopSettings (image, processVersion, whiteBalance, text) VALUES
                (10, '11.0', 'Custom', '\(sql(settings.editedJPEG.text))'),
                (13, '11.0', 'Custom', '\(sql(settings.rawCustomWhiteBalance.text))'),
                (15, '11.0', 'As Shot', '\(sql(settings.untouched.text))');
            """)
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomDevelopPhase() }])
        let photos = Dictionary(try store.viewContext.fetch(Photo.fetchRequest()).filter { !$0.isVirtualCopy }.map { ($0.fileName, $0) }) { first, _ in first }

        let a = try #require(photos["A.jpg"])
        #expect(a.adjustments.light.exposure == -0.35)
        #expect((a.adjustments.whiteBalance.temperature ?? 0) > 6500 && a.adjustments.whiteBalance.preset == nil)
        // Lightroom rotated D (DA → 8) while the file says 1; the orientation from the photos phase is kept.
        let d = try #require(photos["D.cr2"])
        #expect(d.adjustments.whiteBalance == .init(isEnabled: true, temperature: 4350, tint: -8, preset: nil))
        #expect(d.adjustments.light.exposure == 0.65)
        #expect(d.importDifferences == nil)
        #expect(try #require(photos["E.jpg"]).adjustments.isDefault && photos["E.jpg"]?.importDifferences == nil)
        #expect(photos["B.jpg"]?.adjustments.light.exposure == 0 && photos["B.jpg"]?.adjustments.whiteBalance.isActive == false)

        // A.jpg is 64×48 on disk: the crop and its angle are imported using that size, so nothing is left to report.
        #expect(a.adjustments.crop.isActive && a.adjustments.crop.angle == -1.09 && a.importDifferences == nil)
        let groups = Dictionary(uniqueKeysWithValues: report.groups.map { ($0.key, $0.photoCount) })
        #expect(groups["crop"] == nil && groups["presence"] == nil)
        #expect(report.imported.contains(.init(title: "Photos with develop settings", count: 2)))
    }

    @Test("A catalog without develop settings imports nothing and does not fail")
    func noSettings() async throws {
        let fixture = try PhotosFixture()
        let (store, report) = try await fixture.importAll(phases: [{ LightroomPhotosPhase() }, { LightroomDevelopPhase() }])
        #expect(try store.viewContext.fetch(Photo.fetchRequest()).allSatisfy { $0.adjustments.light.exposure == 0 && !$0.adjustments.whiteBalance.isActive })
        #expect(report.imported.allSatisfy { $0.title != "Photos with develop settings" })
    }
}
