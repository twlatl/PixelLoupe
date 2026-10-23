import Foundation
import Testing
@testable import PixelLoupe

@Suite("Secrets")
struct SecretsTests {
    @Test func revealUnmasksWithARepeatingMask() {
        let plain = Array("a value longer than its mask".utf8)
        let mask: [UInt8] = [0x5A, 0xC3, 0x01]
        let masked = plain.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }
        #expect(Secrets.reveal(masked, mask: mask) == "a value longer than its mask")
    }

    @Test func revealOfAnEmptyValueIsEmpty() {
        #expect(Secrets.reveal([], mask: []) == "")
    }

    /// Scripts/generate-secrets.sh writes Swift whose `reveal` calls give back the values it was given, without them
    /// appearing in the source as text.
    @Test func generatedSourceRevealsTheValues() throws {
        let script = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Scripts/generate-secrets.sh")
        let output = FileManager.default.temporaryDirectory.appending(path: "Secrets+Generated-\(UUID()).swift")
        defer { try? FileManager.default.removeItem(at: output) }
        let values = ["flickrKey": "0123456789abcdef0123456789abcdef", "flickrSecret": "fedcba9876543210"]

        let process = Process()
        process.executableURL = script
        process.arguments = [output.path]
        process.environment = ["PATH": "/usr/bin:/bin", "FLICKR_KEY": values["flickrKey"]!, "FLICKR_SECRET": values["flickrSecret"]!]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let source = try String(contentsOf: output, encoding: .utf8)
        for value in values.values { #expect(!source.contains(value)) }
        let call = /static let (\w+) = reveal\(\[([0-9, ]*)\], mask: \[([0-9, ]*)\]\)/
        var revealed: [String: String] = [:]
        for match in source.matches(of: call) {
            let bytes = { (list: Substring) in list.split(separator: ", ").compactMap { UInt8($0) } }
            revealed[String(match.1)] = Secrets.reveal(bytes(match.2), mask: bytes(match.3))
        }
        #expect(revealed == values)
    }
}
