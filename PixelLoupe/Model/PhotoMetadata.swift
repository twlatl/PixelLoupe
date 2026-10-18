import Foundation

/// Descriptive metadata typed into the Metadata panel (Title, Caption, Copyright, IPTC fields and
/// so on), keyed by `MetadataField.ID`. Stored in the catalog only; original files are never
/// modified. A field set here overrides what the file says, including an empty value.
nonisolated struct PhotoMetadata: Codable, Equatable, Sendable {
    var values: [String: String] = [:]

    var isEmpty: Bool { values.isEmpty }

    subscript(field: MetadataField.ID) -> String? {
        get { values[field.rawValue] }
        set { values[field.rawValue] = newValue }
    }

    init(values: [String: String] = [:]) {
        self.values = values
    }

    init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(PhotoMetadata.self, from: $0) } ?? PhotoMetadata()
    }

    /// `nil` when nothing has been entered, so photos without edits store nothing.
    var encoded: Data? {
        guard !values.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }
}

nonisolated extension Photo {
    /// Metadata entered in PixelLoupe (see `PhotoMetadata`).
    var metadata: PhotoMetadata {
        get { PhotoMetadata(data: metadataData) }
        set {
            let data = newValue.encoded
            if data != metadataData { metadataData = data }
            // What searches look at follows what is shown.
            for (id, keyPath) in [(MetadataField.ID.title, \Photo.titleText), (.caption, \.captionText), (.creator, \.creatorText), (.copyright, \.copyrightText)] {
                if let value = newValue[id], self[keyPath: keyPath] != value { self[keyPath: keyPath] = value.isEmpty ? nil : value }
            }
        }
    }
}
