import AppKit

/// Camera memory cards: mounted volumes with a `DCIM` folder at the top (the folder cameras put
/// photos in, per the DCF standard), listed under Devices in the import window.
nonisolated enum ImportCards {
    /// Whether `volume` looks like a camera card.
    static func isCard(_ volume: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let dcim = volume.appending(path: "DCIM", directoryHint: .isDirectory).path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: dcim, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The mounted cards, in the order Finder lists volumes.
    static func mountedCards() -> [URL] {
        (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .filter { $0.path(percentEncoded: false) != "/" && isCard($0) }
    }

    /// The card `url` is on, if it's on one.
    static func card(containing url: URL) -> URL? {
        guard let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              volume.path(percentEncoded: false) != "/", isCard(volume) else { return nil }
        return volume
    }

    /// Whether every file in `source` is on a card (so adding them in place would leave the catalog
    /// pointing at a card that's about to be ejected).
    static func isOnCard(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy { card(containing: $0) != nil }
    }

    /// The camera that shot the first photo on the card ("Sony ILCE-7M4"), read from one file's
    /// metadata, for the card's row.
    @concurrent
    static func cameraName(on card: URL) async -> String? {
        let enumerator = FileManager.default.enumerator(
            at: card.appending(path: "DCIM", directoryHint: .isDirectory),
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = enumerator?.nextObject() as? URL {
            guard SupportedImageTypes.isSupported(url), !SupportedImageTypes.isVideo(url) else { continue }
            guard let metadata = ImageMetadata.read(from: url) else { return nil }
            return displayName(make: metadata.cameraMake, model: metadata.cameraModel)
        }
        return nil
    }

    /// "SONY" + "ILCE-7M4" reads as "Sony ILCE-7M4"; a model that already names its maker ("Canon EOS R5")
    /// is used as it is.
    static func displayName(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard let model = model?.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return make?.capitalizedMake }
        guard let make, let maker = make.split(separator: " ").first,
              !model.lowercased().hasPrefix(maker.lowercased()) else { return model }
        return "\(make.capitalizedMake) \(model)"
    }

    /// Ejects the volume at `url`. Returns the error if it couldn't be ejected (a file is open on it).
    @concurrent
    static func eject(_ url: URL) async -> Error? {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            return nil
        } catch {
            return error
        }
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Camera makers write their names in capitals ("SONY", "NIKON CORPORATION"); shown as a word.
    nonisolated var capitalizedMake: String {
        let word = split(separator: " ").first.map(String.init) ?? self
        return word == word.uppercased() && word.count > 3 ? word.capitalized : word
    }
}
