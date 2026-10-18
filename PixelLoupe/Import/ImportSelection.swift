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
    private(set) var filter: Filter
    /// Where copies go, for Destination Folders' headings.
    private(set) var destination: ImportDestination?
    private(set) var sections: [Section] = []
    /// Indexes into `files` in sort order; a file's number in the grid is its position here plus one.
    private var order: [Int] = []
    private var numbers: [Int] = []
    private var checked: [Bool]

    init(
        files: [ImportService.ScannedFile], transfer: ImportTransfer = .copy, sort: Sort = .captureTime,
        filter: Filter = .all, destination: ImportDestination? = nil
    ) {
        self.files = files
        self.transfer = transfer
        self.sort = sort
        self.filter = filter
        self.destination = destination
        checked = files.map { !$0.isDuplicate(for: transfer) }
        arrange()
    }

    func isDuplicate(_ index: Int) -> Bool { files[index].isDuplicate(for: transfer) }

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
        for index in indexes where !isDuplicate(index) {
            checked[index] = isChecked
        }
    }

    /// Checks all of `indexes` unless they're all checked already, in which case unchecks them (Space
    /// in the import window).
    mutating func toggle(_ indexes: some Collection<Int>) {
        let checkable = indexes.filter { !isDuplicate($0) }
        setChecked(!checkable.allSatisfy { checked[$0] }, checkable)
    }

    /// Shift-clicking a checkbox: every file the grid shows from `anchor` (the checkbox clicked before)
    /// to `target` takes the state clicking `target` alone would give it, so a range is checked, or
    /// unchecked if `target` was already checked.
    mutating func checkRange(from anchor: Int, to target: Int) {
        let shown = shown
        guard let start = shown.firstIndex(of: anchor), let end = shown.firstIndex(of: target) else {
            toggle([target])
            return
        }
        let state = isDuplicate(target) ? checked[anchor] : !checked[target]
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
            checked[index] = !isDuplicate(index)
        }
        arrange()
    }

    mutating func setSort(_ sort: Sort) {
        self.sort = sort
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
            sections = grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { Section(title: $0, items: grouped[$0] ?? []) }
        }
    }

    /// The folder a file ends up in: under the destination for a copy, or where it is for an add.
    private func folderTitle(of index: Int) -> String {
        let file = files[index]
        if transfer == .copy, let destination {
            let path = destination.relativePath(for: file.captureDate)
            return path.isEmpty ? destination.root.lastPathComponent : path
        }
        return file.candidate.source.url.deletingLastPathComponent().path(percentEncoded: false)
    }
}
