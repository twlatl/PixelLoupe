import Foundation

/// PixelLoupe's presets: the `.xmp` files in its own folder (one subfolder per group), loaded off the
/// main thread. Importing copies preset files (or every preset in a folder, such as Lightroom's own)
/// into it.
@MainActor
final class PresetLibrary {
    static let shared = PresetLibrary(directory: defaultDirectory)

    /// `~/Library/Application Support/Pixegen/PixelLoupe/Settings`. (Per user: `/Library` would need an
    /// administrator to write to it.)
    nonisolated static var defaultDirectory: URL {
        AppSupport.directory.appending(path: "Settings", directoryHint: .isDirectory)
    }

    /// Where Lightroom Classic and Camera Raw keep their presets, newest location first (the last is
    /// Lightroom 7.2 and earlier's, of `.lrtemplate` files).
    nonisolated static var lightroomDirectories: [URL] {
        let user = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return [
            URL(filePath: "/Library/Application Support/Adobe/CameraRaw/Settings", directoryHint: .isDirectory),
            user?.appending(path: "Adobe/CameraRaw/Settings", directoryHint: .isDirectory),
            user?.appending(path: "Adobe/Lightroom/Develop Presets", directoryHint: .isDirectory),
        ].compactMap { $0 }.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    static let didChangeNotification = Notification.Name("PresetLibraryDidChange")

    let directory: URL
    /// Where imported profiles go: the shared library, or (for a library elsewhere, as in tests) a
    /// Profiles folder beside it.
    let profiles: AdobeProfileLibrary
    private(set) var presets: [DevelopPreset] = []
    private(set) var isLoaded = false
    private var loadTask: Task<Void, Never>?

    init(directory: URL) {
        self.directory = directory
        profiles = directory.standardizedFileURL == Self.defaultDirectory.standardizedFileURL
            ? .shared
            : AdobeProfileLibrary(directory: directory.deletingLastPathComponent().appending(path: "Profiles", directoryHint: .isDirectory))
    }

    /// Presets grouped and sorted as Lightroom lists them.
    var groups: [(name: String, presets: [DevelopPreset])] {
        Dictionary(grouping: presets, by: \.group)
            .map { (name: $0.key, presets: $0.value.sorted { $0.sortName.localizedStandardCompare($1.sortName) == .orderedAscending }) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Loads the presets (once, unless `force`), then posts `didChangeNotification`.
    func load(force: Bool = false) async {
        if isLoaded, !force { return }
        if let loadTask, !force { await loadTask.value; return }
        let directory = directory
        let task = Task {
            let loaded = await Self.read(directory)
            presets = loaded
            isLoaded = true
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    @concurrent
    private nonisolated static func read(_ directory: URL) async -> [DevelopPreset] {
        presetFiles(in: directory).compactMap { url, group in DevelopPreset.load(url, defaultGroup: group) }
    }

    /// Every `.xmp` file (or file of `extensions`) in `directory` and below, with the folder it's in as
    /// its fallback group.
    nonisolated static func presetFiles(in directory: URL, extensions: Set<String> = ["xmp"]) -> [(url: URL, group: String)] {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: [(URL, String)] = []
        for case let url as URL in enumerator where extensions.contains(url.pathExtension.lowercased()) {
            let folder = url.deletingLastPathComponent()
            files.append((url, folder.standardizedFileURL == directory.standardizedFileURL ? "User Presets" : folder.lastPathComponent))
        }
        return files
    }

    struct ImportResult: Equatable {
        var presets = 0
        var profiles = 0
    }

    /// Copies the presets among `sources` (files, or folders searched for presets) into the library,
    /// filed under their group, and reloads. Older `.lrtemplate` presets are converted to `.xmp`.
    /// Profiles go to the profile library; other files are skipped. A preset already in the library with the same group and name is replaced.
    @discardableResult
    func importPresets(from sources: [URL]) async -> ImportResult {
        let directory = directory
        let result = await Self.copy(sources, into: directory, profiles: profiles)
        await load(force: true)
        if result.profiles > 0 { NotificationCenter.default.post(name: AdobeProfileLibrary.didChangeNotification, object: profiles) }
        return result
    }

    @concurrent
    private nonisolated static func copy(_ sources: [URL], into directory: URL, profiles: AdobeProfileLibrary) async -> ImportResult {
        let fileManager = FileManager.default
        var result = ImportResult()
        defer { if result.profiles > 0 { profiles.saveIndex() } }
        for source in sources {
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isFolder) else { continue }
            let files = isFolder.boolValue
                ? presetFiles(in: source, extensions: ["xmp", LegacyPreset.fileExtension])
                : [(source, source.deletingLastPathComponent().lastPathComponent)]
            for (file, folder) in files {
                if file.pathExtension.lowercased() == LegacyPreset.fileExtension {
                    guard let data = try? Data(contentsOf: file),
                          let converted = LegacyPreset.convert(data, url: file, defaultGroup: folder) else { continue }
                    let destination = directory.appending(path: safeName(converted.group), directoryHint: .isDirectory)
                        .appending(path: safeName(converted.name) + ".xmp")
                    do {
                        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try converted.xmp.write(to: destination, options: .atomic)
                        result.presets += 1
                    } catch {}
                    continue
                }
                guard let preset = DevelopPreset.load(file, defaultGroup: folder) else {
                    if profiles.importProfile(file) { result.profiles += 1 }
                    continue
                }
                let groupFolder = directory.appending(path: safeName(preset.group), directoryHint: .isDirectory)
                let destination = groupFolder.appending(path: safeName(preset.name) + ".xmp")
                do {
                    try fileManager.createDirectory(at: groupFolder, withIntermediateDirectories: true)
                    if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) { try fileManager.removeItem(at: destination) }
                    try fileManager.copyItem(at: file, to: destination)
                    result.presets += 1
                } catch {
                    continue
                }
            }
        }
        return result
    }

    // MARK: - Your own presets

    enum PresetError: LocalizedError {
        case nameTaken(String)
        case emptyName
        case notInLibrary

        var errorDescription: String? {
            switch self {
            case .nameTaken(let name): "A preset named “\(name)” is already in that group."
            case .emptyName: "A preset needs a name."
            case .notInLibrary: "That preset isn’t in PixelLoupe’s presets folder."
            }
        }
    }

    private func file(name: String, group: String) -> URL {
        directory.appending(path: Self.safeName(group), directoryHint: .isDirectory).appending(path: Self.safeName(name) + ".xmp")
    }

    /// Saves `sections` of `adjustments` as a new preset (Lightroom-compatible `.xmp`) and reloads.
    @discardableResult
    func createPreset(name: String, group: String, from adjustments: PhotoAdjustments, sections: Set<PresetSection>) async throws -> DevelopPreset {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User Presets" : group.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetError.emptyName }
        let url = file(name: name, group: group)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw PresetError.nameTaken(name) }
        let data = PresetWriter.xmp(name: name, group: group, settings: PresetWriter.settings(for: adjustments, sections: sections, profiles: profiles))
        try await Self.write(data, to: url)
        await load(force: true)
        guard let preset = presets.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { throw PresetError.notInLibrary }
        return preset
    }

    /// Lightroom's Update with Current Settings: the sections the preset holds, from `adjustments`.
    func update(_ preset: DevelopPreset, with adjustments: PhotoAdjustments) async throws {
        try requireInLibrary(preset)
        let sections = PresetSection.sections(of: preset.settingKeys)
        let uuid = preset.settings["UUID"]?.string ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let data = PresetWriter.xmp(name: preset.name, group: preset.group,
                                    settings: PresetWriter.settings(for: adjustments, sections: sections, profiles: profiles), uuid: uuid)
        try await Self.write(data, to: preset.url)
        await load(force: true)
    }

    /// Renames a preset or moves it to another group. Only its name and group change in the file.
    func rename(_ preset: DevelopPreset, to name: String, group: String? = nil) async throws {
        try requireInLibrary(preset)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetError.emptyName }
        let group = group ?? preset.group
        let destination = file(name: name, group: group)
        if destination.standardizedFileURL != preset.url.standardizedFileURL,
           FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) { throw PresetError.nameTaken(name) }
        guard var text = try? String(contentsOf: preset.url, encoding: .utf8) else { throw PresetError.notInLibrary }
        text = Self.replacingText(of: "Name", with: name, in: text)
        text = Self.replacingText(of: "Group", with: group, in: text)
        try await Self.write(Data(text.utf8), to: destination)
        if destination.standardizedFileURL != preset.url.standardizedFileURL { try? FileManager.default.removeItem(at: preset.url) }
        await load(force: true)
    }

    /// Deleting moves the file to the Trash (tests, whose libraries are temporary, delete outright
    /// rather than fill the user's Trash).
    var deletesToTrash = true

    /// Moves a preset's file to the Trash.
    func delete(_ preset: DevelopPreset) async throws {
        try requireInLibrary(preset)
        if deletesToTrash { try FileManager.default.trashItem(at: preset.url, resultingItemURL: nil) } else { try FileManager.default.removeItem(at: preset.url) }
        await load(force: true)
    }

    /// Renames a group: every preset in it.
    func renameGroup(_ group: String, to name: String) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PresetError.emptyName }
        for preset in presets where preset.group == group { try await rename(preset, to: preset.name, group: name) }
    }

    private func requireInLibrary(_ preset: DevelopPreset) throws {
        let folder = directory.standardizedFileURL.path(percentEncoded: false)
        guard preset.url.standardizedFileURL.path(percentEncoded: false).hasPrefix(folder) else { throw PresetError.notInLibrary }
    }

    @concurrent
    private nonisolated static func write(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// `text` with the `crs:` text element `element` (an `rdf:Alt` list) set to `value`.
    nonisolated static func replacingText(of element: String, with value: String, in text: String) -> String {
        let escaped = value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let pattern = "(<crs:\(element)>\\s*<rdf:Alt>\\s*)<rdf:li xml:lang=\"x-default\"(?:/>|>[^<]*</rdf:li>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let replacement = "$1<rdf:li xml:lang=\"x-default\">" + NSRegularExpression.escapedTemplate(for: escaped) + "</rdf:li>"
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// A file or folder name for a preset or group name (no slashes or colons).
    nonisolated static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Preset" : cleaned
    }
}

/// What Paste Settings applies: a preset, or the settings copied from a photo (⇧⌘C).
@MainActor
enum SettingsClipboard {
    enum Content {
        case preset(DevelopPreset)
        /// A photo's settings, and which of them to paste (Copy Settings' checkboxes).
        case settings(PhotoAdjustments, from: String, only: Set<DevelopSetting> = DevelopSetting.defaultSelection)

        var title: String {
            switch self {
            case .preset(let preset): preset.name
            case .settings(_, let name, _): "Settings from \(name)"
            }
        }
    }

    static var content: Content?

    /// `adjustments` with the copied settings applied. A photo's settings replace the ones chosen
    /// when copying; by default everything except what belongs to that photo alone (crop, rotation,
    /// spots, red eye and masks, which are placed on the photo itself).
    static func applied(_ content: Content, to adjustments: PhotoAdjustments, isRaw: Bool, cameraModel: String? = nil,
                        iso: Double? = nil) -> PhotoAdjustments {
        switch content {
        case .preset(let preset):
            return preset.applied(to: adjustments, isRaw: isRaw, cameraModel: cameraModel, iso: iso)
        case .settings(let copied, _, let settings):
            return DevelopSetting.apply(settings, from: copied, to: adjustments)
        }
    }
}
