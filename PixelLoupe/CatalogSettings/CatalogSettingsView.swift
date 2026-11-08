import AppKit
import SwiftUI

/// Catalog Settings… (⌥⌘,): a sheet on the catalog window with one pane per category, chosen with the
/// segmented control at the top, as in Lightroom Classic's Catalog Settings (RAW-265).
struct CatalogSettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general = "General"
        case previews = "Previews"
        // Metadata (RAW-268) and Backups (RAW-269) join as they're built.

        var id: Self { self }
    }

    let store: CatalogStore
    let onDone: () -> Void
    @State private var pane = Pane.general

    var body: some View {
        VStack(spacing: 0) {
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("catalogSettingsPanePicker")
            .padding(.top, 20)

            Group {
                switch pane {
                case .general: CatalogGeneralSettingsView(packageURL: store.packageURL, info: store.info)
                case .previews: CatalogPreviewSettingsView(store: store)
                }
            }
            .padding(20)

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("catalogSettingsDoneButton")
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 520)
        .onExitCommand(perform: onDone)
    }
}

/// Catalog Settings ▸ General (RAW-266): where the catalog is, what it's called, when it was made and
/// how large its database is.
struct CatalogGeneralSettingsView: View {
    let packageURL: URL
    let info: CatalogInfo
    /// Worked out off the main thread when the pane appears; nil until then.
    @State private var size: Int64?

    var body: some View {
        GroupBox("Information") {
            Form {
                LabeledContent("Location:") {
                    HStack(alignment: .firstTextBaseline) {
                        Text(packageURL.deletingLastPathComponent().path(percentEncoded: false))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("catalogLocation")
                        Spacer()
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([packageURL]) }
                            .accessibilityLabel("Show the catalog in the Finder")
                            .accessibilityIdentifier("catalogShowInFinderButton")
                    }
                }
                LabeledContent("File Name:") {
                    Text(packageURL.lastPathComponent)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("catalogFileName")
                }
                LabeledContent("Created:") {
                    Text(info.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .accessibilityIdentifier("catalogCreated")
                }
                LabeledContent("Size:") {
                    Text(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…")
                        .accessibilityIdentifier("catalogSize")
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: packageURL) { size = await Self.databaseSize(of: packageURL) }
    }

    /// The catalog database's size: the SQLite store with its write-ahead log and shared memory files,
    /// and the package's settings files. Previews, thumbnails and Smart Previews aren't counted (the
    /// Previews pane shows those), as Lightroom Classic gives the size of the `.lrcat` alone.
    @concurrent static func databaseSize(of package: URL) async -> Int64 {
        let database = CatalogPackage.databaseURL(in: package).path(percentEncoded: false)
        let paths = [database, database + "-wal", database + "-shm"] + [
            CatalogPackage.infoURL(in: package), CatalogPackage.viewStateURL(in: package), CatalogPackage.settingsURL(in: package),
        ].map { $0.path(percentEncoded: false) }
        return paths.reduce(0) { $0 + (FileManager.default.sizeAndModificationDate(atPath: $1)?.size ?? 0) }
    }
}
