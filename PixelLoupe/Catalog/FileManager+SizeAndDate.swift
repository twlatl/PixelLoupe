import Foundation

nonisolated extension FileManager {
    /// The size and modification date of the item at `path`, or nil when there's none.
    ///
    /// Not `attributesOfItem(atPath:)`, which reads every extended attribute as well: that can block
    /// for minutes on a file the system is holding, stalling whatever asked. These are read afresh
    /// each time (a new URL has no cached resource values).
    func sizeAndModificationDate(atPath path: String) -> (size: Int64, modified: Date?)? {
        guard let values = try? URL(filePath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return nil }
        return (Int64(values.fileSize ?? 0), values.contentModificationDate)
    }

    /// The total size of the files in the folder at `url` and its subfolders; zero when there's no folder.
    func sizeOfDirectory(at url: URL) -> Int64 {
        guard let files = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true
            else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
