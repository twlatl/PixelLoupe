import Foundation

/// Grid sort orders offered in the Library bottom toolbar.
nonisolated enum PhotoSortKey: String, CaseIterable, Sendable {
    case captureTime
    case importTime
    case editTime
    case fileName
    case rating
    case flag
    case colorLabel
    /// A collection's own order (Lightroom's custom sort); other places sort by capture time.
    case customOrder
    case fileType
    case camera

    var title: String {
        switch self {
        case .captureTime: "Capture Time"
        case .importTime: "Import Time"
        case .editTime: "Edit Time"
        case .fileName: "File Name"
        case .rating: "Rating"
        case .flag: "Pick"
        case .colorLabel: "Label Color"
        case .customOrder: "Custom Order"
        case .fileType: "File Type"
        case .camera: "Camera"
        }
    }

    var keyPath: String {
        switch self {
        case .captureTime: #keyPath(Photo.captureDate)
        case .importTime: #keyPath(Photo.importDate)
        case .editTime: #keyPath(Photo.editDate)
        case .fileName: #keyPath(Photo.fileName)
        case .rating: #keyPath(Photo.rating)
        case .flag: #keyPath(Photo.flag)
        case .colorLabel: #keyPath(Photo.colorLabel)
        case .customOrder: #keyPath(Photo.captureDate)
        case .fileType: #keyPath(Photo.fileType)
        case .camera: #keyPath(Photo.cameraModel)
        }
    }

    var isStringKey: Bool {
        switch self {
        case .fileName, .fileType, .camera: true
        default: false
        }
    }
}
