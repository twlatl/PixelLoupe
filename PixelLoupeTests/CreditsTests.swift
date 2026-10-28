import Foundation
import Testing
@testable import PixelLoupe

/// The About window's credits and the bundled data's license ship with the app (THIRD_PARTY_NOTICES.md).
@Suite("Credits")
struct CreditsTests {
    @Test func theAboutWindowCreditsLensFunAndTheLicenseShips() throws {
        let bundle = Bundle(for: Photo.self)
        let credits = try String(contentsOf: try #require(bundle.url(forResource: "Credits", withExtension: "html")), encoding: .utf8)
        #expect(credits.contains("LensFun") && credits.contains("CC BY-SA 3.0") && credits.contains("MIT License"))
        let license = try String(contentsOf: try #require(bundle.url(forResource: "LensFun-LICENSE", withExtension: "txt")), encoding: .utf8)
        #expect(license.contains("COMMONS PUBLIC LICENSE"))
    }

    @Test func theAboutWindowCreditsSparkleAndItsLicenseShips() throws {
        let bundle = Bundle(for: Photo.self)
        let credits = try String(contentsOf: try #require(bundle.url(forResource: "Credits", withExtension: "html")), encoding: .utf8)
        #expect(credits.contains("Sparkle"))
        let license = try String(contentsOf: try #require(bundle.url(forResource: "Sparkle-LICENSE", withExtension: "txt")), encoding: .utf8)
        #expect(license.contains("Andy Matuschak") && license.contains("Permission is hereby granted"))
    }

    @Test func theAboutWindowCreditsLibjxlAndItsLicensesShip() throws {
        let bundle = Bundle(for: Photo.self)
        let credits = try String(contentsOf: try #require(bundle.url(forResource: "Credits", withExtension: "html")), encoding: .utf8)
        #expect(credits.contains("libjxl") && credits.contains("BSD 3-Clause License"))
        let license = try String(contentsOf: try #require(bundle.url(forResource: "libjxl-LICENSE", withExtension: "txt")), encoding: .utf8)
        #expect(license.contains("the JPEG XL Project Authors") && license.contains("Additional IP Rights Grant (Patents)"))
        #expect(license.contains("The Highway Project Authors") && license.contains("the Brotli Authors") && license.contains("Google Inc."))
    }

    @Test func theAboutWindowCreditsRobbieTiltonForRimLightAndCompositorsLicenseShips() throws {
        let bundle = Bundle(for: Photo.self)
        let credits = try String(contentsOf: try #require(bundle.url(forResource: "Credits", withExtension: "html")), encoding: .utf8)
        #expect(credits.contains("Rim Light") && credits.contains("Robbie Tilton") && credits.contains("Compositor"))
        let license = try String(contentsOf: try #require(bundle.url(forResource: "Compositor-LICENSE", withExtension: "txt")), encoding: .utf8)
        #expect(license.contains("Wonder Assembly LLC (Compositor)") && license.contains("Permission is hereby granted"))
    }
}
