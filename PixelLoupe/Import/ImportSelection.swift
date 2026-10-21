import AppKit

/// What the import window's grid shows: the files a source holds, sorted and filtered, and which are
/// checked for import. Files the catalog already has ("In Library") start unchecked and can't be
/// checked. Whether a file is already in the catalog depends on Copy or Add (see
/// `ImportTransfer.duplicateRule`).
nonisolated struct ImportSelection: Sendable {
    enum Sort: String, CaseIterable, Sendable {
        case captureTime, fileName, fileType

        var title: String {
            switch self {
            case .captureTime: "Capture Time"
            case .fileName: "File Name"
            case .fileType: "File Type"
            }
        }
    }

    enum Filter: Int, CaseIterable, Sendable {
        /// Every file.
        case all
        /// Files not already in the catalog.
        case new
        /// Every file, in a section for each folder it will end up in.
        case destinationFolders

        var title: String {
            switch self {
            case .all: "All Photos"
            case .new: "New Photos"
            case .destinationFolders: "Destination Folders"
            }
        }
    }

    struct Section: Sendable, Equatable {
        /// The folder heading (Destination Folders only).
        var title: String?
        /// Indexes into `files`.
        var items: [Int]
    }

    enum CheckState: Equatable {
        case on, off, mixed
    }

    /// In the order they were scanned.
    private(set) var files: [ImportService.ScannedFile]
    private(set) var transfer: ImportTransfer
    private(set) var sort: Sort
    /// Off: the sort runs backwards (latest, Z or the last type first), folders included.
    private(set) var ascending: Bool
    private(set) var filter: Filter
    /// Where copies go, for Destination Folders' headings.
    private(set) var destination: ImportDestination?
    /// Don't Import Suspected Duplicates off: files in the library can be checked (they still start unchecked).
    private(set) var allowsDuplicates = false
    /// Don't Import Rejected Images: files rated as rejected can't be checked.
    private(set) var skipsRejected = false
    private(set) var sections: [Section] = []
    /// Indexes into `files` in sort order; a file's number in the grid is its position here plus one.
    private var order: [Int] = []
    private var numbers: [Int] = []
    private var checked: [Bool]

    init(
        files: [ImportService.ScannedFile], transfer: ImportTransfer = .copy, sort: Sort = .captureTime,
        ascending: Bool = true, filter: Filter = .all, destination: ImportDestination? = nil, allowsDuplicates: Bool = false, skipsRejected: Bool = false
    ) {
        self.files = files
        self.transfer = transfer
        self.sort = sort
        self.ascending = ascending
        self.filter = filter
        self.destination = destination
        self.allowsDuplicates = allowsDuplicates
        self.skipsRejected = skipsRejected
        checked = []
        checked = files.indices.map(startsChecked)
        arrange()
    }

    func isDuplicate(_ index: Int) -> Bool { files[index].isDuplicate(for: transfer) }

    /// Rated as rejected (`xmp:Rating` -1), in the camera or another app.
    func isRejected(_ index: Int) -> Bool { files[index].metadata.rating == -1 }

    /// Whether the file's checkbox can be checked, given File Handling's choices.
    func isCheckable(_ index: Int) -> Bool {
        !(isDuplicate(index) && !allowsDuplicates) && !(isRejected(index) && skipsRejected)
    }

    /// What a file's cell shows: its checkbox, whether it can be checked, and why not.
    struct Check: Equatable {
        var isChecked: Bool
        var isCheckable: Bool
        /// "In Library" or "Rejected", in place of the file's number.
        var badge: String?
    }

    func check(_ index: Int) -> Check {
        Check(
            isChecked: checked[index], isCheckable: isCheckable(index),
            badge: isDuplicate(index) ? "In Library" : isRejected(index) ? "Rejected" : nil)
    }

    /// Whether a file starts out checked: new, and not left out.
    private func startsChecked(_ index: Int) -> Bool {
        !isDuplicate(index) && isCheckable(index)
    }

    func isChecked(_ index: Int) -> Bool { checked[index] }

    /// The number shown on a file's cell: its place among all the files, in sort order.
    func number(of index: Int) -> Int { numbers[index] }

    func index(at indexPath: IndexPath) -> Int { sections[indexPath.section].items[indexPath.item] }

    func indexPath(of index: Int) -> IndexPath? {
        for (section, content) in sections.enumerated() {
            if let item = content.items.firstIndex(of: index) { return IndexPath(item: item, section: section) }
        }
        return nil
    }

    /// The files the grid shows, in its order.
    var shown: [Int] { sections.flatMap(\.items) }

    var checkedCount: Int { checked.count { $0 } }

    var duplicateCount: Int { files.indices.count { isDuplicate($0) } }

    /// The total size of the checked files, sidecars not included.
    var checkedBytes: Int64 { files.indices.filter { checked[$0] }.reduce(0) { $0 + files[$1].candidate.fileSize } }

    /// The checked files, in sort order, ready for `ImportService.importPhotos(_:transfer:destination:)`.
    var checkedCandidates: [ImportService.Candidate] {
        order.filter { checked[$0] }.map { files[$0].candidate }
    }

    mutating func setChecked(_ isChecked: Bool, _ indexes: some Sequence<Int>) {
        for index in indexes where isCheckable(index) {
            checked[index] = isChecked
        }
    }

    /// Checks all of `indexes` unless they're all checked already, in which case unchecks them (Space
    /// in the import window).
    mutating func toggle(_ indexes: some Collection<Int>) {
        let checkable = indexes.filter { isCheckable($0) }
        setChecked(!checkable.allSatisfy { checked[$0] }, checkable)
    }

    /// Shift-clicking a checkbox: every file the grid shows from `anchor` (the checkbox clicked before)
    /// to `target` takes the anchor's state, the one that click left it in, as in Lightroom and Finder.
    /// Uncheck one photo, then Shift-click another, and everything between is unchecked too.
    mutating func checkRange(from anchor: Int, to target: Int) {
        let shown = shown
        guard let start = shown.firstIndex(of: anchor), let end = shown.firstIndex(of: target) else {
            toggle([target])
            return
        }
        // A photo that can't be checked (in the library) has no state to pass on: use the click's.
        let state = isCheckable(anchor) ? checked[anchor] : !checked[target]
        setChecked(state, shown[min(start, end)...max(start, end)])
    }

    mutating func setAll(_ isChecked: Bool) {
        setChecked(isChecked, files.indices)
    }

    /// Switching between Copy and Add changes which files count as already in the catalog: those that
    /// become duplicates are unchecked, and those that stop being duplicates are checked.
    mutating func setTransfer(_ transfer: ImportTransfer) {
        guard transfer != self.transfer else { return }
        let wasDuplicate = files.indices.map(isDuplicate)
        self.transfer = transfer
        for index in files.indices where wasDuplicate[index] != isDuplicate(index) {
            checked[index] = startsChecked(index)
        }
        arrange()
    }

    /// Don't Import Suspected Duplicates: turned on, duplicates are unchecked; turned off, they can be
    /// checked (but aren't checked for you).
    mutating func setAllowsDuplicates(_ allows: Bool) {
        allowsDuplicates = allows
        for index in files.indices where !isCheckable(index) { checked[index] = false }
    }

    /// Don't Import Rejected Images: turned on, rejected files are unchecked; turned off, the new ones
    /// are checked again.
    mutating func setSkipsRejected(_ skips: Bool) {
        guard skips != skipsRejected else { return }
        skipsRejected = skips
        for index in files.indices where isRejected(index) { checked[index] = startsChecked(index) }
    }

    mutating func setSort(_ sort: Sort) {
        self.sort = sort
        arrange()
    }

    mutating func setAscending(_ ascending: Bool) {
        self.ascending = ascending
        arrange()
    }

    mutating func setFilter(_ filter: Filter) {
        self.filter = filter
        arrange()
    }

    mutating func setDestination(_ destination: ImportDestination?) {
        self.destination = destination
        arrange()
    }

    private mutating func arrange() {
        order = files.indices.sorted { lhs, rhs in
            let a = files[lhs], b = files[rhs]
            switch sort {
            case .captureTime:
                if a.captureDate != b.captureDate { return a.captureDate < b.captureDate }
            case .fileName:
                break
            case .fileType:
                let typeA = a.candidate.source.url.pathExtension.uppercased(), typeB = b.candidate.source.url.pathExtension.uppercased()
                if typeA != typeB { return typeA < typeB }
            }
            let nameOrder = a.candidate.source.url.lastPathComponent.localizedStandardCompare(b.candidate.source.url.lastPathComponent)
            return nameOrder == .orderedSame ? lhs < rhs : nameOrder == .orderedAscending
        }
        if !ascending { order.reverse() }
        numbers = [Int](repeating: 0, count: files.count)
        for (position, index) in order.enumerated() { numbers[index] = position + 1 }

        switch filter {
        case .all:
            sections = order.isEmpty ? [] : [Section(title: nil, items: order)]
        case .new:
            let new = order.filter { !isDuplicate($0) }
            sections = new.isEmpty ? [] : [Section(title: nil, items: new)]
        case .destinationFolders:
            var grouped: [String: [Int]] = [:]
            for index in order { grouped[folderTitle(of: index), default: []].append(index) }
            let folders = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            sections = (ascending ? folders : folders.reversed())
                .map { Section(title: $0, items: grouped[$0] ?? []) }
        }
    }

    /// The folder a file ends up in: under the destination for a copy, or where it is for an add.
    private func folderTitle(of index: Int) -> String {
        let file = files[index]
        if transfer == .copy, let destination {
            let path = destination.relativePath(
                for: file.captureDate, originalFolder: ImportDestination.originalFolder(of: file.candidate.source))
            return path.isEmpty ? destination.root.lastPathComponent : path
        }
        return file.candidate.source.url.deletingLastPathComponent().path(percentEncoded: false)
    }
}
