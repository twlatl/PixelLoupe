import AppKit
import SwiftUI

/// Lightroom's Synchronize Folder dialog: import new photos, remove missing ones, re-read changed
/// files. The counts fill in once the folder has been looked at.
@Observable
final class SynchronizeFolderModel {
    let folderName: String
    /// Nil while the folder is being looked at.
    var plan: FolderSync.Plan?
    var importsNew = true
    var showsImportDialog = false
    var removesMissing = true
    var scansMetadata = true

    @ObservationIgnored var onSynchronize: ((SynchronizeFolderModel) -> Void)?
    @ObservationIgnored var onShowMissing: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?

    init(folderName: String) {
        self.folderName = folderName
    }

    var newCount: Int? { plan?.newFiles.count }
    var missingCount: Int? { plan?.missing.count }

    /// Whether Synchronize would do anything.
    var canSynchronize: Bool {
        guard let plan else { return false }
        return (importsNew && !plan.newFiles.isEmpty) || (removesMissing && !plan.missing.isEmpty)
            || (scansMetadata && !plan.changed.isEmpty)
    }
}

struct SynchronizeFolderView: View {
    @Bindable var model: SynchronizeFolderModel

    private func count(_ value: Int?) -> String {
        value.map { " (\($0.formatted()))" } ?? " (…)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Synchronize Folder “\(model.folderName)”")
                .font(.headline)
                .padding(.bottom, 14)
            HStack(alignment: .top, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Synchronizing keeps your PixelLoupe catalog up to date with the latest changes you may have made to your photos in other applications.")
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                    Toggle("Import new photos" + count(model.newCount), isOn: $model.importsNew)
                        .disabled(model.newCount == 0)
                        .accessibilityIdentifier("syncImportNew")
                    Toggle("Show import dialog before importing", isOn: $model.showsImportDialog)
                        .disabled(!model.importsNew || model.newCount == 0)
                        .padding(.leading, 20)
                        .accessibilityIdentifier("syncShowImport")
                    Toggle("Remove missing photos from catalog" + count(model.missingCount), isOn: $model.removesMissing)
                        .disabled(model.missingCount == 0)
                        .accessibilityIdentifier("syncRemoveMissing")
                    Toggle("Scan for metadata updates", isOn: $model.scansMetadata)
                        .accessibilityIdentifier("syncScanMetadata")
                    if model.plan == nil {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Looking at the folder")
                    }
                }
                .toggleStyle(.checkbox)
            }
            HStack {
                Button("Show Missing Photos") { model.onShowMissing?() }
                    .disabled((model.missingCount ?? 0) == 0)
                Spacer()
                Button("Cancel", role: .cancel) { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("Synchronize") { model.onSynchronize?(model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSynchronize)
                    .accessibilityIdentifier("syncSynchronize")
            }
            .padding(.top, 24)
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// The Export as Catalog save panel's options (Lightroom's, without Smart Previews, which
/// PixelLoupe doesn't make).
final class ExportCatalogAccessory: NSView {
    let copiesFilesCheckbox = NSButton(checkboxWithTitle: "Export negative files", target: nil, action: nil)
    let previewsCheckbox = NSButton(checkboxWithTitle: "Include available previews", target: nil, action: nil)

    init(photoCount: Int) {
        super.init(frame: .zero)
        let summary = NSTextField(labelWithString: "Exporting a catalog with \(photoCount.formatted()) photo\(photoCount == 1 ? "" : "s").")
        copiesFilesCheckbox.state = .on
        copiesFilesCheckbox.toolTip = "Copies the photos’ files next to the new catalog. Otherwise it refers to the files where they are."
        previewsCheckbox.state = .on
        let checks = NSStackView(views: [copiesFilesCheckbox, previewsCheckbox])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 6
        let stack = NSStackView(views: [summary, checks])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var options: CatalogExporter.Options {
        CatalogExporter.Options(copiesFiles: copiesFilesCheckbox.state == .on, includesPreviews: previewsCheckbox.state == .on)
    }
}
