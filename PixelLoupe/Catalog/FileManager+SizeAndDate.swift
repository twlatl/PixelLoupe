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
}
