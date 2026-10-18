import AppKit
import CoreData

/// Single-key commands available throughout a catalog window (when not typing in a text field).
enum KeyCommand: Equatable {
    case showLibrary            // G
    case showDevelop            // D
    case rating(Int)            // 0–5
    case adjustRating(Int)      // [ decrease, ] increase
    case flag(PhotoFlag)        // P, X, U
    case colorLabel(ColorLabel) // 6 red, 7 yellow, 8 green, 9 blue (again to clear)
    case toggleStack            // S (collapse or expand the stack)
    case moveToTopOfStack       // ⇧S
    case toggleEnlarge          // Return
    case enlarge                // E (Lightroom's Loupe view)
    case toggleZoom             // Z or Space (Lightroom's Toggle Zoom View)
    case largerThumbnails       // =
    case smallerThumbnails      // -
    case fullScreen             // F
    case exit                   // Escape
    case previous               // ←
    case next                   // →
    case toggleLoupe            // `
    case compare                // C
    case survey                 // N
    case cropTool               // R (Lightroom's Crop Overlay)
    case showClipping           // J (Develop)
    case whiteBalanceTool       // W (Develop's White Balance Selector)
    case maskingTool            // ⇧W (Develop's Masking)
    case spotRemovalTool        // Q (Develop's Spot Removal)
    case linearMask             // M
    case radialMask             // ⇧M
    case maskOverlay            // O
    case toggleSidebars         // Tab
    case addToTargetCollection  // B
    case removePhoto            // Delete (Photo ▸ Remove Photo)
    case secondaryView(SecondaryView) // ⇧G grid, ⇧E loupe, ⇧C compare, ⇧N survey (Window ▸ Secondary Display)

    init?(event: NSEvent) {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        // The few shifted commands: Move to Top of Stack, Lightroom's Masking (⇧W) and Radial Gradient (⇧M),
        // and the secondary window's views (⇧G, ⇧E, ⇧C, ⇧N).
        if modifiers == .shift {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "s": self = .moveToTopOfStack
            case "w": self = .maskingTool
            case "m": self = .radialMask
            case "g": self = .secondaryView(.grid)
            case "e": self = .secondaryView(.loupe)
            case "c": self = .secondaryView(.compare)
            case "n": self = .secondaryView(.survey)
            default: return nil
            }
            return
        }
        guard modifiers.isEmpty else { return nil }

        switch event.specialKey {
        case .leftArrow?: self = .previous; return
        case .rightArrow?: self = .next; return
        case .carriageReturn?, .enter?: self = .toggleEnlarge; return
        default: break
        }
        if event.keyCode == 53 { self = .exit; return }   // Escape
        if event.keyCode == 48 { self = .toggleSidebars; return }   // Tab
        if event.keyCode == 51 { self = .removePhoto; return }   // Delete

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g": self = .showLibrary
        case "d": self = .showDevelop
        case let digit? where digit.count == 1 && ("0"..."5").contains(digit): self = .rating(Int(digit)!)
        case "s": self = .toggleStack
        case "[": self = .adjustRating(-1)
        case "]": self = .adjustRating(1)
        case "6": self = .colorLabel(.red)
        case "7": self = .colorLabel(.yellow)
        case "8": self = .colorLabel(.green)
        case "9": self = .colorLabel(.blue)
        case "p": self = .flag(.picked)
        case "x": self = .flag(.rejected)
        case "u": self = .flag(.unflagged)
        case "f": self = .fullScreen
        case "e": self = .enlarge
        case "z", " ": self = .toggleZoom
        case "=": self = .largerThumbnails
        case "-": self = .smallerThumbnails
        case "`": self = .toggleLoupe
        case "c": self = .compare
        case "n": self = .survey
        case "r": self = .cropTool
        case "j": self = .showClipping
        case "w": self = .whiteBalanceTool
        case "m": self = .linearMask
        case "q": self = .spotRemovalTool
        case "o": self = .maskOverlay
        case "b": self = .addToTargetCollection
        case "\r": self = .toggleEnlarge
        case "\u{1b}": self = .exit
        default: return nil
        }
    }
}

/// Rating, flag and tag edits applied to photos, saved and undoable as one step.
struct PhotoEditing {
    let store: CatalogStore

    func photos(_ ids: [NSManagedObjectID]) -> [Photo] {
        ids.compactMap { try? store.viewContext.existingObject(with: $0) as? Photo }
    }

    func edit(_ ids: [NSManagedObjectID], actionName: String, _ change: (Photo) -> Void) {
        let photos = photos(ids)
        guard !photos.isEmpty else { return }
        let now = Date()
        for photo in photos {
            change(photo)
            photo.editDate = now
        }
        store.viewContext.undoManager?.setActionName(actionName)
        store.save()
    }

    /// Runs `change` as one named, undoable step and saves.
    func performUndoable(_ actionName: String, _ change: () -> Void) {
        change()
        store.viewContext.undoManager?.setActionName(actionName)
        store.save()
    }

    func setRating(_ rating: Int, for ids: [NSManagedObjectID]) {
        guard !photos(ids).isEmpty else { return }
        edit(ids, actionName: "Set Rating") { $0.rating = Int16(rating.clamped(to: 0...5)) }
        announce(.rating(rating.clamped(to: 0...5)))
    }

    /// Lightroom's Increase / Decrease Rating (`]` / `[`): each photo's own rating, one star up or
    /// down, within 0…5.
    func adjustRating(by step: Int, for ids: [NSManagedObjectID]) {
        let current = photos(ids)
        guard let first = current.first else { return }
        edit(ids, actionName: step > 0 ? "Increase Rating" : "Decrease Rating") {
            $0.rating = Int16((Int($0.rating) + step).clamped(to: 0...5))
        }
        announce(.rating(Int(first.rating)))
    }

    func apply(_ change: PhotoAdjustments.OrientationChange, to ids: [NSManagedObjectID]) {
        let name = switch change {
        case .rotateLeft: "Rotate Left"
        case .rotateRight: "Rotate Right"
        case .flipHorizontal: "Flip Horizontal"
        case .flipVertical: "Flip Vertical"
        }
        edit(ids, actionName: name) { photo in
            var adjustments = photo.adjustments
            adjustments.apply(change)
            photo.adjustments = adjustments
        }
    }

    /// Clears PixelLoupe's rotate/flip. With `rereadMetadata`, also re-reads the camera orientation
    /// and dimensions from the file.
    func resetOrientation(of ids: [NSManagedObjectID], rereadMetadata: Bool) {
        edit(ids, actionName: rereadMetadata ? "Restore Orientation from Metadata" : "Reset to Camera Orientation") { photo in
            var adjustments = photo.adjustments
            adjustments.resetOrientation()
            photo.adjustments = adjustments
            if rereadMetadata, let metadata = ImageMetadata.read(from: photo.fileURL) {
                photo.orientation = Int16(metadata.orientation)
                photo.pixelWidth = Int32(metadata.pixelWidth)
                photo.pixelHeight = Int32(metadata.pixelHeight)
            }
        }
    }

    /// Sets a color label. With `toggling`, a label every photo already has is cleared instead, as
    /// pressing 6–9 twice does in Lightroom.
    func setColorLabel(_ label: ColorLabel, for ids: [NSManagedObjectID], toggling: Bool = false) {
        let current = photos(ids)
        guard !current.isEmpty else { return }
        let target = toggling && current.allSatisfy({ $0.label == label }) ? ColorLabel.none : label
        edit(ids, actionName: target == .none ? "Clear Color Label" : "Set Color Label to \(target.title)") { photo in
            photo.label = target
            if target == .none { photo.labelText = nil }
        }
        announce(.label(target))
    }

    func setFlag(_ flag: PhotoFlag, for ids: [NSManagedObjectID]) {
        guard !photos(ids).isEmpty else { return }
        edit(ids, actionName: "Set Flag") { $0.photoFlag = flag }
        announce(.flag(flag))
    }
}
