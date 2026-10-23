/// API credentials for the services PixelLoupe talks to (`flickrKey`, `flickrSecret`). The values are compiled in from
/// .env, or the release workflow's repository secrets, by Scripts/generate-secrets.sh (the Generate Secrets build
/// phase), XOR-masked so they don't sit in the binary as plain strings. That only stops casual extraction: see
/// docs/adr/0001-embedded-service-secrets.md. A build without them has empty values.
nonisolated enum Secrets {
    /// Whether this build can sign Flickr requests.
    static var hasFlickr: Bool { !flickrKey.isEmpty && !flickrSecret.isEmpty }

    /// Unmasks a generated value: each byte XORed with the mask, which repeats.
    static func reveal(_ masked: [UInt8], mask: [UInt8]) -> String {
        guard !mask.isEmpty else { return "" }
        let bytes = masked.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }
        return String(decoding: bytes, as: UTF8.self)
    }
}
