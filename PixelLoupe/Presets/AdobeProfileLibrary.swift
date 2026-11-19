import Foundation

/// The profiles imported into PixelLoupe, in `~/Library/Application Support/Pixegen/PixelLoupe/Profiles`: Adobe
/// profiles (`.xmp` looks) and DNG camera profiles (`.dcp`, RAW-126), with an index (name, id, group, camera) so
/// finding one is quick; a profile's tables are decoded when it's first used. Safe from any thread: the renderer, the catalog import and presets all use it.
nonisolated final class AdobeProfileLibrary: @unchecked Sendable {
    static let shared = AdobeProfileLibrary(directory: defaultDirectory)

    nonisolated static var defaultDirectory: URL {
        PresetLibrary.defaultDirectory.deletingLastPathComponent().appending(path: "Profiles", directoryHint: .isDirectory)
    }

    static let didChangeNotification = Notification.Name("AdobeProfileLibraryDidChange")

    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var group: String
        var cameraModel: String
        var isMonochrome: Bool
        /// The file, relative to the library folder.
        var file: String
        /// For a DNG camera profile (`.dcp`), the camera it was made for; nil for Adobe's `.xmp` profiles. A camera
        /// profile the user picked has no `cameraModel`, so it's offered for every camera (RAW-126).
        var cameraProfileModel: String?

        var isCameraProfile: Bool { cameraProfileModel != nil }
    }

    /// The group of the Profile menu that camera profiles the user picked are listed in, as in Lightroom.
    static let cameraProfileGroup = "Profiles"

    let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry]?
    private var loaded: [String: AdobeProfile] = [:]
    /// Profiles added in memory only (tests).
    private var registered: [String: AdobeProfile] = [:]
    private var cubeCache: [String: [AdobeProfile.Cube]] = [:]
    private var hiddenCache: [String: PhotoAdjustments] = [:]
    private var cubeOrder: [String] = []
    private var cameraProfiles: [String: DNGCameraProfile] = [:]
    /// The camera profile under a look for a camera ("look id|camera"), or "" for none: asked for on every render.
    private var baseCache: [String: String] = [:]
    /// Whether a camera profile's hue/saturation map is applied to photos from its own camera. Off: the map refines
    /// the profile's matrices, which Apple's RAW engine doesn't use, and on top of the engine's own colors it
    /// oversaturates them (measured on Sony profiles, RAW-304). `Scripts/camera-profiles.sh` renders both ways.
    var appliesHueSaturationMaps = false
    /// Camera profiles added in memory only (tests).
    private var registeredCameraProfiles: [String: DNGCameraProfile] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appending(path: "Index.json") }

    // MARK: - Finding

    /// Every profile, sorted by group and name.
    var allEntries: [Entry] {
        Self.sorted(withIndex { Array($0.values) })
    }

    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted {
            if $0.group != $1.group { return $0.group.localizedStandardCompare($1.group) == .orderedAscending }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            // Camera profiles of one name, for different cameras.
            return $0.id < $1.id
        }
    }

    /// The profiles the Profile menu offers a photo, sorted by group and name: the ones for no camera in particular
    /// and the ones for this camera, with camera profiles (`.dcp`) for RAW photos only. Filtered before sorting:
    /// with Lightroom's camera profiles imported the library holds thousands, a handful of them for any one camera.
    func entries(forCameraModel model: String?, isRaw: Bool) -> [Entry] {
        Self.sorted(withIndex { index in
            index.values.filter { ($0.cameraModel.isEmpty || AdobeProfile.isCamera($0.cameraModel, model)) && (isRaw || !$0.isCameraProfile) }
        })
    }

    func entry(id: String) -> Entry? { withIndex { $0[id] } }

    /// The profile Lightroom's settings name: by UUID when they give one, else by name, among the
    /// profiles for this camera (or for any camera).
    func find(id: String?, name: String, cameraModel: String?) -> Entry? {
        withIndex { index in
            if let id, let entry = index[id] { return entry }
            let matches = index.values.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            return matches.first { AdobeProfile.isCamera($0.cameraModel, cameraModel) }
                ?? matches.first { $0.cameraModel.isEmpty }
        }
    }

    /// The profile itself, its tables decoded (once).
    func profile(id: String) -> AdobeProfile? {
        lock.lock()
        if let profile = registered[id] ?? loaded[id] { lock.unlock(); return profile }
        lock.unlock()
        guard let entry = entry(id: id), !entry.isCameraProfile, let profile = AdobeProfile.load(directory.appending(path: entry.file)) else { return nil }
        lock.lock()
        loaded[id] = profile
        lock.unlock()
        return profile
    }

    /// The color cubes for a profile at an amount, cached for the last few used.
    func cubes(id: String, amount: Double) -> [AdobeProfile.Cube] {
        let key = "\(id)|\((amount * 100).rounded())"
        lock.lock()
        if let cubes = cubeCache[key] { lock.unlock(); return cubes }
        lock.unlock()
        guard let profile = profile(id: id) else { return [] }
        let cubes = profile.cubes(amount: (amount * 100).rounded() / 100)
        lock.lock()
        cubeCache[key] = cubes
        cubeOrder.append(key)
        if cubeOrder.count > 12 { cubeCache[cubeOrder.removeFirst()] = nil }
        lock.unlock()
        return cubes
    }

    // MARK: - Camera profiles

    /// A DNG camera profile, read (once).
    func cameraProfile(id: String) -> DNGCameraProfile? {
        guard id.hasPrefix(DNGCameraProfile.idPrefix) else { return nil }
        lock.lock()
        if let profile = registeredCameraProfiles[id] ?? cameraProfiles[id] { lock.unlock(); return profile }
        lock.unlock()
        guard let entry = entry(id: id), entry.isCameraProfile, !entry.file.isEmpty,
              let profile = DNGCameraProfile.load(directory.appending(path: entry.file)) else { return nil }
        lock.lock()
        cameraProfiles[id] = profile
        lock.unlock()
        return profile
    }

    /// The cube for a camera profile on a photo: its look table at an amount, and its tone curve. With
    /// ``appliesHueSaturationMaps``, also its hue/saturation map when the photo is from the profile's own camera, for
    /// the light the photo's white balance says (`temperature`, kelvins), taken in steps so dragging Temperature
    /// doesn't bake a cube for every value on the way. Cached for the last few used.
    func cameraProfileCube(id: String, amount: Double, temperature: Double, cameraMake: String?, cameraModel: String?) -> AdobeProfile.Cube? {
        guard let profile = cameraProfile(id: id) else { return nil }
        let usesCalibration = appliesHueSaturationMaps && profile.isFor(cameraMake: cameraMake, model: cameraModel)
        let amount = profile.lookTable == nil ? 0 : (amount * 100).rounded() / 100
        let weight = usesCalibration ? (profile.firstCalibrationWeight(temperature: temperature) * 16).rounded() / 16 : 1
        let key = "\(id)|\(amount)|\(usesCalibration ? weight : -1)"
        lock.lock()
        if let cube = cubeCache[key]?.first { lock.unlock(); return cube }
        lock.unlock()
        let cube = profile.cube(amount: amount, firstCalibrationWeight: weight, usesCalibration: usesCalibration)
        lock.lock()
        cubeCache[key] = [cube]
        cubeOrder.append(key)
        if cubeOrder.count > 12 { cubeCache[cubeOrder.removeFirst()] = nil }
        lock.unlock()
        return cube
    }

    /// The camera profile an Adobe look is built on, for a photo from `cameraModel`: the look's `crs:CameraProfile`
    /// names it ("Camera Standard" for Nikon's Creative Picture Controls), and it has to be imported, for that
    /// camera. Nil for looks that name none, and when it isn't there, which leaves the look on PixelLoupe's Default.
    func baseCameraProfileID(forLook id: String, cameraModel: String?) -> String? {
        guard !id.hasPrefix(DNGCameraProfile.idPrefix), let cameraModel, !cameraModel.isEmpty else { return nil }
        let key = id + "|" + AdobeProfile.normalized(cameraModel)
        lock.lock()
        if let cached = baseCache[key] { lock.unlock(); return cached.nonEmpty }
        lock.unlock()
        var found = ""
        if let name = profile(id: id)?.settings["CameraProfile"]?.string, !name.isEmpty {
            found = withIndex { index in
                index.values.first {
                    $0.isCameraProfile && $0.name.caseInsensitiveCompare(name) == .orderedSame
                        && AdobeProfile.isCamera($0.cameraProfileModel ?? "", cameraModel)
                }?.id ?? ""
            }
        }
        lock.lock()
        baseCache[key] = found
        lock.unlock()
        return found.nonEmpty
    }

    /// Adds a camera profile in memory only, for tests: offered for every camera unless `forItsCameraOnly`.
    func register(_ profile: DNGCameraProfile, forItsCameraOnly: Bool = false) {
        lock.lock()
        registeredCameraProfiles[profile.id] = profile
        var index = entries ?? [:]
        index[profile.id] = Self.entry(for: profile, forItsCameraOnly: forItsCameraOnly, file: "")
        entries = index
        baseCache = [:]
        cubeCache = cubeCache.filter { !$0.key.hasPrefix(profile.id + "|") }
        lock.unlock()
    }

    private static func entry(for profile: DNGCameraProfile, forItsCameraOnly: Bool, file: String) -> Entry {
        Entry(id: profile.id, name: profile.name, group: cameraProfileGroup, cameraModel: forItsCameraOnly ? profile.cameraModel : "",
              isMonochrome: false, file: file, cameraProfileModel: profile.cameraModel)
    }

    /// Where a camera profile is kept in the library: picked ones in "Camera Profiles", ones that stay with their
    /// camera beside the `.xmp` camera-matching profiles in "Camera".
    private static func file(for profile: DNGCameraProfile, forItsCameraOnly: Bool) -> String {
        (forItsCameraOnly ? "Camera/" : "Camera Profiles/") + PresetLibrary.safeName(profile.cameraModel.nonEmpty ?? "Any Camera")
            + "/" + PresetLibrary.safeName(profile.name) + ".dcp"
    }

    /// Copies a DNG camera profile (`.dcp`) into the library and indexes it. A profile the user picked is offered for
    /// every camera; `forItsCameraOnly` keeps it to the camera it names. Returns whether it was a camera profile
    /// (one without a name has nothing to be listed by, and isn't).
    @discardableResult
    func importCameraProfile(_ file: URL, forItsCameraOnly: Bool = false) -> Bool {
        guard let profile = DNGCameraProfile.load(file), !profile.name.isEmpty else { return false }
        let relative = Self.file(for: profile, forItsCameraOnly: forItsCameraOnly)
        let destination = directory.appending(path: relative)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if destination.standardizedFileURL != file.standardizedFileURL {
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: file, to: destination)
            }
        } catch {
            return false
        }
        lock.lock()
        var index = entries ?? readIndexUnlocked()
        index[profile.id] = Self.entry(for: profile, forItsCameraOnly: forItsCameraOnly, file: relative)
        entries = index
        baseCache = [:]
        cameraProfiles[profile.id] = nil
        cubeCache = cubeCache.filter { !$0.key.hasPrefix(profile.id + "|") }
        lock.unlock()
        return true
    }

    /// The settings that come inside a profile (Adobe Vivid's clarity and curve, a B&W profile's
    /// contrast), as PixelLoupe settings: rendered as part of the profile, not shown on the sliders.
    func hiddenSettings(id: String) -> PhotoAdjustments? {
        lock.lock()
        if let cached = hiddenCache[id] { lock.unlock(); return cached }
        lock.unlock()
        guard let profile = profile(id: id) else { return nil }
        var settings = profile.settings
        let notLooks: Set<String> = ["ConvertToGrayscale", "RGBTableAmount", "CameraProfile", "Look", "RequiresRGBTables", "ShowInPresets",
                                     "ShowInQuickActions", "ProfileGainTableMap", "RGBTables"]
        // The B&W mix is the profile's suggestion for the mixer, which the photo's own settings carry.
        for key in settings.hash.keys where notLooks.contains(key) || key.hasPrefix("GrayMixer") { settings.hash[key] = nil }
        var hidden = PhotoAdjustments()
        _ = LightroomDevelopMapper.apply(.init(settings: settings, processVersion: "11.0", whiteBalance: nil, isRaw: true, seed: 1), to: &hidden)
        lock.lock()
        hiddenCache[id] = hidden
        lock.unlock()
        return hidden
    }

    /// Adds a profile in memory only, for tests.
    func register(_ profile: AdobeProfile) {
        lock.lock()
        registered[profile.id] = profile
        var index = entries ?? [:]
        index[profile.id] = Entry(id: profile.id, name: profile.name, group: profile.group, cameraModel: profile.cameraModel,
                                  isMonochrome: profile.isMonochrome, file: "")
        entries = index
        baseCache = [:]
        lock.unlock()
    }

    // MARK: - Index

    private func withIndex<T>(_ body: ([String: Entry]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if entries == nil { entries = readIndex() }
        return body(entries ?? [:])
    }

    private func readIndex() -> [String: Entry] {
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            return Dictionary(list.map { ($0.id, $0) }) { first, _ in first }
        }
        // No index yet (profiles copied in by hand): build one.
        let rebuilt = Self.scan(directory)
        if !rebuilt.isEmpty { write(rebuilt) }
        return rebuilt
    }

    private static func scan(_ directory: URL) -> [String: Entry] {
        var index: [String: Entry] = [:]
        for (url, _) in PresetLibrary.presetFiles(in: directory) {
            guard let profile = AdobeProfile.load(url) else { continue }
            let relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(directory.standardizedFileURL.path(percentEncoded: false).count))
            index[profile.id] = Entry(id: profile.id, name: profile.name, group: profile.group, cameraModel: profile.cameraModel,
                                      isMonochrome: profile.isMonochrome, file: relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
        }
        for (url, _) in PresetLibrary.presetFiles(in: directory, extensions: ["dcp"]) {
            guard let profile = DNGCameraProfile.load(url), !profile.name.isEmpty else { continue }
            var relative = String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(directory.standardizedFileURL.path(percentEncoded: false).count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            // Where it was filed says how it was imported.
            index[profile.id] = entry(for: profile, forItsCameraOnly: relative.hasPrefix("Camera/"), file: relative)
        }
        return index
    }

    private func write(_ index: [String: Entry]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(index.values.sorted { $0.id < $1.id }) { try? data.write(to: indexURL, options: .atomic) }
    }

    // MARK: - Importing

    /// Copies a profile file into the library (camera-matching ones in a folder per camera) and indexes
    /// it. Returns whether it was a profile.
    @discardableResult
    func importProfile(_ file: URL) -> Bool {
        guard let profile = AdobeProfile.load(file) else { return false }
        var folder = PresetLibrary.safeName(profile.group)
        if !profile.cameraModel.isEmpty { folder = "Camera/" + PresetLibrary.safeName(profile.cameraModel) }
        let relative = folder + "/" + PresetLibrary.safeName(profile.name) + ".xmp"
        let destination = directory.appending(path: relative)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { try fileManager.removeItem(at: destination) }
            try fileManager.copyItem(at: file, to: destination)
        } catch {
            return false
        }
        lock.lock()
        var index = entries ?? readIndexUnlocked()
        index[profile.id] = Entry(id: profile.id, name: profile.name, group: profile.group, cameraModel: profile.cameraModel,
                                  isMonochrome: profile.isMonochrome, file: relative)
        entries = index
        baseCache = [:]
        loaded[profile.id] = nil
        cubeCache = cubeCache.filter { !$0.key.hasPrefix(profile.id + "|") }
        lock.unlock()
        return true
    }

    /// Writes the index after a batch of imports.
    func saveIndex() {
        lock.lock()
        let index = entries ?? [:]
        lock.unlock()
        write(index)
    }

    private func readIndexUnlocked() -> [String: Entry] {
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            return Dictionary(list.map { ($0.id, $0) }) { first, _ in first }
        }
        return [:]
    }
}
