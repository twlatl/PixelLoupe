import Foundation

/// The Adobe profiles imported into PixelLoupe, in `~/Library/Application Support/Pixegen/PixelLoupe/Profiles`,
/// with an index (name, UUID, group, camera) so finding one is quick; a profile's tables are decoded
/// when it's first used. Safe from any thread: the renderer, the catalog import and presets all use it.
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
    }

    let directory: URL
    private let lock = NSLock()
    private var entries: [String: Entry]?
    private var loaded: [String: AdobeProfile] = [:]
    /// Profiles added in memory only (tests).
    private var registered: [String: AdobeProfile] = [:]
    private var cubeCache: [String: [AdobeProfile.Cube]] = [:]
    private var hiddenCache: [String: PhotoAdjustments] = [:]
    private var cubeOrder: [String] = []

    init(directory: URL) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appending(path: "Index.json") }

    // MARK: - Finding

    /// Every profile, sorted by group and name.
    var allEntries: [Entry] {
        withIndex { Array($0.values) }.sorted {
            $0.group != $1.group
                ? $0.group.localizedStandardCompare($1.group) == .orderedAscending
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func entry(id: String) -> Entry? { withIndex { $0[id] } }

    /// The profile Lightroom's settings name: by UUID when they give one, else by name, among the
    /// profiles for this camera (or for any camera).
    func find(id: String?, name: String, cameraModel: String?) -> Entry? {
        withIndex { index in
            if let id, let entry = index[id] { return entry }
            let matches = index.values.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            let model = cameraModel.map(AdobeProfile.normalized)
            return matches.first { !$0.cameraModel.isEmpty && model == AdobeProfile.normalized($0.cameraModel) }
                ?? matches.first { $0.cameraModel.isEmpty }
        }
    }

    /// The profile itself, its tables decoded (once).
    func profile(id: String) -> AdobeProfile? {
        lock.lock()
        if let profile = registered[id] ?? loaded[id] { lock.unlock(); return profile }
        lock.unlock()
        guard let entry = entry(id: id), let profile = AdobeProfile.load(directory.appending(path: entry.file)) else { return nil }
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
