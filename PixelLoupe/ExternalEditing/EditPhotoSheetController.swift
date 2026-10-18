import AppKit
import SwiftUI

/// What the Edit Photo sheet decides.
@Observable
final class EditPhotoSheetModel {
    var choice = ExternalEditMode.copyWithAdjustments
    var settings: ExternalEditorSettings
    /// Open in Other Application: the app is picked here.
    let choosesApplication: Bool
    /// Whether any photo can send a plain copy or the original (images other than raw files).
    let offersChoice: Bool
    /// Whether some photos (raw files, virtual copies) always send a copy with adjustments.
    let hasFixedPhotos: Bool
    /// Whether any photo that asks has PixelLoupe edits, which Edit a Copy and Edit Original leave out.
    let hasAdjustments: Bool
    let photoCount: Int

    init(settings: ExternalEditorSettings, choosesApplication: Bool, photos: [Photo]) {
        self.settings = settings
        self.choosesApplication = choosesApplication
        let asking = photos.filter(PhotoEditing.asksWhatToEdit)
        offersChoice = !asking.isEmpty
        hasFixedPhotos = asking.count < photos.count
        hasAdjustments = asking.contains { !$0.adjustments.isDefault }
        photoCount = photos.count
    }

    var title: String {
        if choosesApplication { return "Open in Other Application" }
        return "Edit Photo with \(settings.applicationName ?? "External Editor")"
    }

    var canEdit: Bool { settings.applicationPath != nil }
}

/// Lightroom's Edit Photo dialog, as a sheet: what to send for photos that aren't raw files (a copy
/// with PixelLoupe's adjustments, a plain copy, or the original), and the copy's file options. Open
/// in Other Application also picks the app here.
final class EditPhotoSheetController: NSWindowController {
    let model: EditPhotoSheetModel
    /// Called with the model for Edit, or nil for Cancel.
    var onFinish: ((EditPhotoSheetModel?) -> Void)?

    init(model: EditPhotoSheetModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.identifier = NSUserInterfaceItemIdentifier("editPhotoSheet")
        super.init(window: window)
        let view = EditPhotoSheetView(model: model) { [weak self] edit in
            guard let self else { return }
            onFinish?(edit ? self.model : nil)
        }
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func finish(edit: Bool) {
        onFinish?(edit ? model : nil)
    }
}

struct EditPhotoSheetView: View {
    @Bindable var model: EditPhotoSheetModel
    let finish: (Bool) -> Void
    @State private var showsFileOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title)
                .font(.headline)

            if model.choosesApplication {
                Form {
                    ExternalApplicationRow(path: $model.settings.applicationPath, identifier: "other")
                }
            }

            if model.offersChoice {
                Text("What to Edit")
                    .font(.subheadline.weight(.semibold))
                Picker("What to Edit", selection: $model.choice) {
                    ForEach(ExternalEditMode.allCases, id: \.self) { mode in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                            Text(mode.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("editModePicker")

                if model.choice != .copyWithAdjustments, model.hasAdjustments {
                    Label("PixelLoupe adjustments won’t be included.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("editAdjustmentsWarning")
                }
                if model.hasFixedPhotos {
                    Text("Raw photos and virtual copies are always edited as a copy with PixelLoupe adjustments.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DisclosureGroup("Copy File Options", isExpanded: $showsFileOptions) {
                Form {
                    ExternalEditorFields(settings: $model.settings, identifier: "sheet", showsApplication: false)
                }
                .padding(.top, 6)
            }
            .disabled(model.offersChoice && !model.hasFixedPhotos && model.choice == .original)
            .accessibilityIdentifier("copyFileOptions")

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { finish(false) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("editCancelButton")
                Button(model.choosesApplication ? "Open" : "Edit") { finish(true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canEdit)
                    .accessibilityIdentifier("editButton")
            }
        }
        .padding(20)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
