import Foundation

/// One field of the Metadata panel: what it's called, whether it can be edited, and what its
/// button does.
nonisolated struct MetadataField: Sendable, Equatable {
    enum ID: String, Sendable, CaseIterable {
        // File
        case fileName, originalFilename, copyName, sidecarFiles, folder, filePath, fileSize, fileType
        case metadataStatus, metadataDate, audioFile, rating, label
        case fileDimensions, currentDimensions, captureDate, captureTime, camera
        // EXIF
        case dateTimeOriginal, dateTimeDigitized, dateTime
        case exposure, focalLength, focalLength35mm, brightnessValue, exposureBias, isoSpeedRating
        case flash, exposureProgram, meteringMode, make, model, serialNumber, lens, artist, software
        case userComment, gps, altitude, direction
        // DNG
        case dngVersion, dngCompatibility, compatibility, fastLoadData, lossyCompression
        // Descriptive (IPTC core)
        case title, caption, copyright, creator
        case creatorJobTitle, creatorAddress, creatorCity, creatorState, creatorPostalCode, creatorCountry
        case creatorPhone, creatorEmail, creatorWebsite
        case headline, iptcSubjectCode, descriptionWriter, category, otherCategories
        case dateCreated, intellectualGenre, scene, sublocation, city, state, country, isoCountryCode
        case jobIdentifier, instructions, creditLine, source, copyrightStatus, rightsUsageTerms, copyrightInfoURL
        // IPTC Extension
        case imageGUID, personShown, locationCreated, locationShown, nameOfOrgShown, codeOfOrgShown, event
        case artworkShown, additionalModelInfo, modelAge, minorAgeDisclosure, modelReleaseStatus, modelReleaseID
        case imageSupplier, supplierImageID, imageRegistryEntry, maxAvailHeight, maxAvailWidth, sourceType
        case imageCreator, copyrightOwner, licensor, propertyReleaseID
        // 3D
        case projection, createdBy
        // Video
        case duration, trimmedDuration, videoFrameRate, videoAlphaMode, videoDimensions
        case audioChannelType, audioSampleRate, audioSampleType
        case speakerPlacement, tapeName, alternateTapeName, videoScene, shotName, shotDate, shotLocation, logComment
        case videoArtist, album, genre, releaseDate, composer, engineer, instrument
        case comment, client, good, projectName, director, directorOfPhotography, cameraModel
        case cameraAngle, cameraMove, dayOfShoot
    }

    enum Kind: Sendable, Equatable {
        /// Shown from the file or the catalog; can't be edited.
        case readOnly
        /// A one-line text field.
        case text
        /// A text box several lines tall.
        case multiline(lines: Int)
        /// A pop-up menu of values.
        case choice([String])
    }

    /// The small arrow button next to some fields.
    enum Action: Sendable, Equatable {
        /// Shows the photo's folder in the Library.
        case showFolder
        /// Shows the file in the Finder.
        case revealInFinder
        /// Opens the location in Maps.
        case openMap
    }

    let id: ID
    let label: String
    let kind: Kind
    let action: Action?

    var isEditable: Bool { kind != .readOnly }

    private init(_ id: ID, _ label: String, _ kind: Kind = .readOnly, action: Action? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.action = action
    }

    /// The same field under another label (IPTC calls the caption "Description").
    func labelled(_ label: String) -> MetadataField { MetadataField(id, label, kind, action: action) }

    static func field(_ id: ID) -> MetadataField { all[id]! }

    private static let unspecified = ["Unspecified"]

    static let all: [ID: MetadataField] = {
        let fields: [MetadataField] = [
            MetadataField(.fileName, "File Name"),
            MetadataField(.originalFilename, "Original Filename"),
            MetadataField(.copyName, "Copy Name", .text),
            MetadataField(.sidecarFiles, "Sidecar Files"),
            MetadataField(.folder, "Folder", action: .showFolder),
            MetadataField(.filePath, "File Path", action: .revealInFinder),
            MetadataField(.fileSize, "File Size"),
            MetadataField(.fileType, "File Type"),
            MetadataField(.metadataStatus, "Metadata Status"),
            MetadataField(.metadataDate, "Metadata Date"),
            MetadataField(.audioFile, "Audio File"),
            MetadataField(.rating, "Rating"),
            MetadataField(.label, "Label", .choice(ColorLabel.allCases.map(\.title))),
            MetadataField(.fileDimensions, "File Dimensions"),
            MetadataField(.currentDimensions, "Current Dimensions"),
            MetadataField(.captureDate, "Capture Date"),
            MetadataField(.captureTime, "Capture Time"),
            MetadataField(.camera, "Camera"),

            MetadataField(.dateTimeOriginal, "Date Time Original"),
            MetadataField(.dateTimeDigitized, "Date Time Digitized"),
            MetadataField(.dateTime, "Date Time"),
            MetadataField(.exposure, "Exposure"),
            MetadataField(.focalLength, "Focal Length"),
            MetadataField(.focalLength35mm, "Focal Length 35mm"),
            MetadataField(.brightnessValue, "Brightness Value"),
            MetadataField(.exposureBias, "Exposure Bias"),
            MetadataField(.isoSpeedRating, "ISO Speed Rating"),
            MetadataField(.flash, "Flash"),
            MetadataField(.exposureProgram, "Exposure Program"),
            MetadataField(.meteringMode, "Metering Mode"),
            MetadataField(.make, "Make"),
            MetadataField(.model, "Model"),
            MetadataField(.serialNumber, "Serial Number"),
            MetadataField(.lens, "Lens"),
            MetadataField(.artist, "Artist"),
            MetadataField(.software, "Software"),
            MetadataField(.userComment, "User Comment", .text),
            MetadataField(.gps, "GPS", .text, action: .openMap),
            MetadataField(.altitude, "Altitude", .text),
            MetadataField(.direction, "Direction", .text),

            MetadataField(.dngVersion, "DNG Version"),
            MetadataField(.dngCompatibility, "DNG Compatibility"),
            MetadataField(.compatibility, "Compatibility"),
            MetadataField(.fastLoadData, "Fast Load Data"),
            MetadataField(.lossyCompression, "Lossy Compression"),

            MetadataField(.title, "Title", .text),
            MetadataField(.caption, "Caption", .multiline(lines: 3)),
            MetadataField(.copyright, "Copyright", .text),
            MetadataField(.creator, "Creator", .text),
            MetadataField(.creatorJobTitle, "Job Title", .text),
            MetadataField(.creatorAddress, "Address", .text),
            MetadataField(.creatorCity, "City", .text),
            MetadataField(.creatorState, "State / Province", .text),
            MetadataField(.creatorPostalCode, "Postal Code", .text),
            MetadataField(.creatorCountry, "Country / Region", .text),
            MetadataField(.creatorPhone, "Phone", .text),
            MetadataField(.creatorEmail, "E-Mail", .text),
            MetadataField(.creatorWebsite, "Website", .text),
            MetadataField(.headline, "Headline", .text),
            MetadataField(.iptcSubjectCode, "IPTC Subject Code", .text),
            MetadataField(.descriptionWriter, "Description Writer", .text),
            MetadataField(.category, "Category", .text),
            MetadataField(.otherCategories, "Other Categories", .text),
            MetadataField(.dateCreated, "Date Created", .text),
            MetadataField(.intellectualGenre, "Intellectual Genre", .text),
            MetadataField(.scene, "Scene", .text),
            MetadataField(.sublocation, "Sublocation", .text),
            MetadataField(.city, "City", .text),
            MetadataField(.state, "State", .text),
            MetadataField(.country, "Country / Region", .text),
            MetadataField(.isoCountryCode, "ISO Country Code", .text),
            MetadataField(.jobIdentifier, "Job Identifier", .text),
            MetadataField(.instructions, "Instructions", .text),
            MetadataField(.creditLine, "Credit Line", .text),
            MetadataField(.source, "Source", .text),
            MetadataField(.copyrightStatus, "Copyright Status", .choice(["Unknown", "Copyrighted", "Public Domain"])),
            MetadataField(.rightsUsageTerms, "Rights Usage Terms", .text),
            MetadataField(.copyrightInfoURL, "Copyright Info URL", .text),

            MetadataField(.imageGUID, "Image GUID"),
            MetadataField(.personShown, "Person Shown", .text),
            MetadataField(.locationCreated, "Location Created"),
            MetadataField(.locationShown, "Location Shown"),
            MetadataField(.nameOfOrgShown, "Name of Org Shown", .text),
            MetadataField(.codeOfOrgShown, "Code of Org Shown", .text),
            MetadataField(.event, "Event", .text),
            MetadataField(.artworkShown, "Artwork Shown"),
            MetadataField(.additionalModelInfo, "Additional Info", .text),
            MetadataField(.modelAge, "Age", .text),
            MetadataField(.minorAgeDisclosure, "Minor Age Disclosure", .choice(unspecified + [
                "Age Unknown", "Age 25 or Over", "Age 24", "Age 23", "Age 22", "Age 21", "Age 20", "Age 19", "Age 18",
                "Age 17", "Age 16", "Age 15", "Age 14 or Under",
            ])),
            MetadataField(.modelReleaseStatus, "Release Status", .choice(unspecified + [
                "None", "Not Applicable", "Unlimited Model Releases", "Limited or Incomplete Model Releases",
            ])),
            MetadataField(.modelReleaseID, "Release Id", .text),
            MetadataField(.imageSupplier, "Image Supplier"),
            MetadataField(.supplierImageID, "Supplier Image ID", .text),
            MetadataField(.imageRegistryEntry, "Image Registry Entry"),
            MetadataField(.maxAvailHeight, "Max Avail Height", .text),
            MetadataField(.maxAvailWidth, "Max Avail Width", .text),
            MetadataField(.sourceType, "Source Type", .choice(unspecified + [
                "Original Digital Capture of a Real Life Scene", "Digitized from a Negative on Film",
                "Digitized from a Positive on Film", "Digitized from a Print on Non-Transparent Media",
                "Created by Software",
            ])),
            MetadataField(.imageCreator, "Image Creator"),
            MetadataField(.copyrightOwner, "Copyright Owner"),
            MetadataField(.licensor, "Licensor"),
            MetadataField(.propertyReleaseID, "Release Id", .text),

            MetadataField(.projection, "Projection", .choice(["", "Equirectangular"])),
            MetadataField(.createdBy, "Created By"),

            MetadataField(.duration, "Duration"),
            MetadataField(.trimmedDuration, "Trimmed Duration"),
            MetadataField(.videoFrameRate, "Video Frame Rate"),
            MetadataField(.videoAlphaMode, "Video Alpha Mode", .text),
            MetadataField(.videoDimensions, "Video Dimensions"),
            MetadataField(.audioChannelType, "Audio Channel Type", .text),
            MetadataField(.audioSampleRate, "Audio Sample Rate"),
            MetadataField(.audioSampleType, "Audio Sample Type", .text),
            MetadataField(.speakerPlacement, "Speaker Placement", .text),
            MetadataField(.tapeName, "Tape Name", .text),
            MetadataField(.alternateTapeName, "Alternate Tape Name", .text),
            MetadataField(.videoScene, "Scene", .text),
            MetadataField(.shotName, "Shot Name", .text),
            MetadataField(.shotDate, "Shot Date", .text),
            MetadataField(.shotLocation, "Shot Location", .text),
            MetadataField(.logComment, "Log Comment", .text),
            MetadataField(.videoArtist, "Artist", .text),
            MetadataField(.album, "Album", .text),
            MetadataField(.genre, "Genre", .text),
            MetadataField(.releaseDate, "Release Date", .text),
            MetadataField(.composer, "Composer", .text),
            MetadataField(.engineer, "Engineer", .text),
            MetadataField(.instrument, "Instrument", .text),
            MetadataField(.comment, "Comment", .text),
            MetadataField(.client, "Client", .text),
            MetadataField(.good, "Good", .choice(["", "Yes", "No"])),
            MetadataField(.projectName, "Project Name", .text),
            MetadataField(.director, "Director", .text),
            MetadataField(.directorOfPhotography, "Director of Photography", .text),
            MetadataField(.cameraModel, "Camera Model", .text),
            MetadataField(.cameraAngle, "Camera Angle", .choice(["", "Establishing Shot", "Extreme Long Shot", "Long Shot",
                "Medium Shot", "Medium Close-Up", "Close-Up", "Extreme Close-Up", "Point of View", "Over the Shoulder"])),
            MetadataField(.cameraMove, "Camera Move", .choice(["", "Aerial", "Boom Up", "Boom Down", "Crane Up", "Crane Down",
                "Dolly In", "Dolly Out", "Pan Left", "Pan Right", "Tilt Up", "Tilt Down", "Tracking", "Zoom In", "Zoom Out"])),
            MetadataField(.dayOfShoot, "Day of Shoot", .text),
        ]
        return Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0) })
    }()
}

/// One of the Metadata panel's views (Lightroom's metadata sets): groups of fields, each group
/// optionally titled.
nonisolated struct MetadataSet: Sendable, Equatable, Identifiable {
    struct Group: Sendable, Equatable {
        var title: String?
        var fields: [MetadataField]
    }

    let id: String
    let groups: [Group]
    /// Large Caption: the caption and copyright as big text boxes with labels above them.
    var isLargeCaption = false

    var title: String { id }

    static func group(_ title: String? = nil, _ ids: MetadataField.ID...) -> Group {
        Group(title: title, fields: ids.map(MetadataField.field))
    }

    private static func group(_ title: String?, _ fields: [MetadataField]) -> Group {
        Group(title: title, fields: fields)
    }

    private static let description = MetadataField.field(.caption).labelled("Description")

    /// In Lightroom's order.
    static let all: [MetadataSet] = [
        MetadataSet(id: "Default", groups: [
            group(nil, .fileName, .folder, .title, .caption, .copyright, .creator, .rating, .captureDate,
                  .fileDimensions, .currentDimensions),
        ]),
        MetadataSet(id: "All Plug-in Metadata", groups: [group(nil, .fileName, .copyName, .folder)]),
        MetadataSet(id: "DNG", groups: [
            group(nil, .dngVersion, .dngCompatibility, .compatibility),
            group(nil, .fastLoadData, .lossyCompression),
        ]),
        MetadataSet(id: "EXIF", groups: [
            group(nil, .fileName, .sidecarFiles, .filePath, .fileDimensions, .currentDimensions),
            group(nil, .dateTimeOriginal, .dateTimeDigitized, .dateTime),
            group(nil, .exposure, .focalLength, .focalLength35mm, .brightnessValue, .exposureBias, .isoSpeedRating,
                  .flash, .exposureProgram, .meteringMode, .make, .model, .serialNumber, .lens, .artist, .software,
                  .userComment, .gps, .altitude, .direction),
        ]),
        MetadataSet(id: "EXIF and IPTC", groups: [
            group(nil, .fileName, .originalFilename, .sidecarFiles, .copyName, .folder, .fileSize, .fileType,
                  .metadataStatus, .metadataDate, .audioFile),
            group(nil, .rating),
            group(nil, .label),
            group(nil, .title, .caption),
            group("EXIF", .fileDimensions, .currentDimensions, .exposure, .brightnessValue, .exposureBias, .flash,
                  .exposureProgram, .meteringMode, .isoSpeedRating, .focalLength, .focalLength35mm, .lens,
                  .dateTimeOriginal, .dateTimeDigitized, .dateTime, .make, .model, .serialNumber, .artist, .software,
                  .userComment, .gps, .altitude, .direction),
        ] + iptcGroups),
        MetadataSet(id: "IPTC", groups: [group(nil, .fileName, .metadataStatus)] + iptcGroups),
        MetadataSet(id: "IPTC Extension", groups: [
            group(nil, .fileName, .metadataStatus, .imageGUID),
            group("Description", .personShown, .locationCreated, .locationShown, .nameOfOrgShown, .codeOfOrgShown, .event),
            group("Artworks or Objects", .artworkShown),
            group("Models", .additionalModelInfo, .modelAge, .minorAgeDisclosure, .modelReleaseStatus, .modelReleaseID),
            group("Admin", .imageSupplier, .supplierImageID, .imageRegistryEntry, .maxAvailHeight, .maxAvailWidth, .sourceType),
            group("Rights", .imageCreator, .copyrightOwner, .licensor),
            group("Property", .propertyReleaseID),
        ]),
        MetadataSet(id: "Large Caption", groups: [group(nil, .caption, .copyright)], isLargeCaption: true),
        MetadataSet(id: "Location", groups: [
            group(nil, .fileName, .originalFilename, .copyName, .folder, .metadataStatus, .audioFile),
            group(nil, .sublocation, .city, .state, .country, .isoCountryCode, .gps, .altitude, .direction),
            group(nil, .title, .caption),
            group(nil, .dateTimeOriginal, .dateTime),
            group(nil, .dateCreated, .intellectualGenre, .scene),
        ]),
        MetadataSet(id: "Minimal", groups: [group(nil, .fileName, .rating), group(nil, .caption, .copyright)]),
        MetadataSet(id: "Quick Describe", groups: [
            group(nil, .fileName, .sidecarFiles, .copyName, .folder, .metadataStatus),
            group(nil, .rating),
            group(nil, .fileDimensions, .currentDimensions, .captureTime, .gps, .camera),
            group(nil, .title, .caption, .copyright, .creator, .sublocation),
        ]),
        MetadataSet(id: "Three Dimensional Projection", groups: [group(nil, .projection, .createdBy)]),
        MetadataSet(id: "Video", groups: [
            group(nil, .duration, .trimmedDuration, .videoFrameRate, .videoAlphaMode, .videoDimensions,
                  .audioChannelType, .audioSampleRate, .audioSampleType),
            group(nil, .speakerPlacement, .tapeName, .alternateTapeName, .videoScene, .shotName, .shotDate,
                  .shotLocation, .logComment),
            group(nil, .videoArtist, .album, .genre, .releaseDate, .composer, .engineer, .instrument),
            group(nil, .comment, .client, .good, .projectName, .director, .directorOfPhotography, .cameraModel,
                  .cameraAngle, .cameraMove, .dayOfShoot),
        ]),
    ]

    /// IPTC Core, as Lightroom groups it.
    private static let iptcGroups: [Group] = [
        group("Contact", .creator, .creatorJobTitle, .creatorAddress, .creatorCity, .creatorState, .creatorPostalCode,
              .creatorCountry, .creatorPhone, .creatorEmail, .creatorWebsite),
        group("Content", [.field(.headline), description, .field(.iptcSubjectCode), .field(.descriptionWriter),
                          .field(.category), .field(.otherCategories)]),
        group("Image", .dateCreated, .intellectualGenre, .scene, .sublocation, .city, .state, .country, .isoCountryCode),
        group("Status", .title, .jobIdentifier, .instructions, .creditLine, .source, .copyrightStatus, .copyright,
              .rightsUsageTerms, .copyrightInfoURL),
    ]

    static func named(_ id: String) -> MetadataSet { all.first { $0.id == id } ?? all[0] }
}
