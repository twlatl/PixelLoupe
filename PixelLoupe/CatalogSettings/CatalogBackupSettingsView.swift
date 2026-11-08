import AppKit
import SwiftUI

/// Catalog Settings ▸ Backups (RAW-269): where backups go, how often PixelLoupe offers one as it quits, how many are
/// kept, and the backups made so far (see ``CatalogBackup``).
struct CatalogBackupSettingsView: View {
    let store: CatalogStore
    @State private var settings: CatalogSettings
    /// Found in the backup folder off the main thread; nil until then.
    @State private var backups: [CatalogBackup.Entry]?
    @State private var selection = Set<CatalogBackup.Entry.ID>()
    @State private var confirmsDelete = false
    /// Bumped to look in the folder again.
    @State private var scan = 0

    init(store: CatalogStore) {
        self.store = store
        _settings = State(initialValue: store.settings)
    }

    private var folder: URL { settings.backupFolder(forCatalogAt: store.packageURL) }
    private var catalogName: String { CatalogBackup.catalogName(of: store.packageURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Information") {
                Form {
                    LabeledContent("Backup Folder:") {
                        HStack(alignment: .firstTextBaseline) {
                            Text(folder.path(percentEncoded: false))
                                .textSelection(.enabled)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .accessibilityIdentifier("backupFolder")
                            Spacer()
                            Button("Choose…", action: chooseFolder)
                                .accessibilityLabel("Choose the backup folder")
                                .accessibilityIdentifier("chooseBackupFolderButton")
                        }
                    }
                    Picker("Back Up Catalog:", selection: Binding(
                        get: { settings.backupSchedule }, set: { settings.chooseBackupSchedule($0) }
                    )) {
                        ForEach(CatalogSettings.BackupSchedule.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("backupSchedulePicker")
                    LabeledContent("Keep the Last:") {
                        HStack(spacing: 6) {
                            TextField("Backups", value: $settings.backupsToKeep, format: .number)
                                .labelsHidden()
                                .frame(width: 50)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Number of backups to keep")
                                .accessibilityIdentifier("backupsToKeepField")
                            Stepper("Backups to keep", value: $settings.backupsToKeep, in: 1...999)
                                .labelsHidden()
                            Text("backups")
                        }
                    }
                    LabeledContent("Number of Backups:") {
                        Text(backups.map { "\($0.count)" } ?? "…").accessibilityIdentifier("backupCount")
                    }
                    LabeledContent("Last Backup:") {
                        Text(lastBackup).accessibilityIdentifier("lastBackup")
                    }
                    LabeledContent("Total Backup Size:") {
                        Text(backups.map { Self.formatted($0.reduce(0) { $0 + $1.size }) } ?? "Calculating…")
                            .accessibilityIdentifier("totalBackupSize")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Backups") {
                VStack(alignment: .leading, spacing: 8) {
                    Table(backups ?? [], selection: $selection) {
                        TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                            .width(min: 120, ideal: 140)
                        TableColumn("Path") { entry in
                            Text(entry.url.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.url.path(percentEncoded: false))
                        }
                        TableColumn("Size") { Text(Self.formatted($0.size)).monospacedDigit() }
                            .width(min: 60, ideal: 70)
                    }
                    .frame(height: 150)
                    .accessibilityIdentifier("backupsTable")
                    HStack {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting(selected.map(\.url))
                        }
                        .disabled(selection.isEmpty)
                        .accessibilityIdentifier("showBackupInFinderButton")
                        Button("Delete…") { confirmsDelete = true }
                            .disabled(selection.isEmpty)
                            .accessibilityIdentifier("deleteBackupsButton")
                    }
                }
                .padding(8)
            }
        }
        .onChange(of: settings) { _, settings in store.settings = settings }
        .task(id: "\(folder.path(percentEncoded: false))#\(scan)") {
            let folder = folder, name = catalogName
            backups = await Self.backups(of: name, in: folder)
            selection.formIntersection(Set((backups ?? []).map(\.id)))
        }
        .alert(deleteTitle, isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
                CatalogBackup.delete(selected)
                selection = []
                scan += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The backup files are deleted from the disk. This can't be undone.")
        }
    }

    private var selected: [CatalogBackup.Entry] { (backups ?? []).filter { selection.contains($0.id) } }

    private var deleteTitle: String {
        selected.count == 1 ? "Delete this backup?" : "Delete \(selected.count) backups?"
    }

    private var lastBackup: String {
        guard let backups else { return "…" }
        return backups.first?.date.formatted(date: .abbreviated, time: .shortened) ?? "None"
    }

    @concurrent private static func backups(of name: String, in folder: URL) async -> [CatalogBackup.Entry] {
        CatalogBackup.backups(of: name, in: folder)
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Backup Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        // The default folder is stored as no choice, so it follows the catalog if it moves.
        let defaultPath = CatalogSettings().backupFolder(forCatalogAt: store.packageURL).path(percentEncoded: false)
        settings.backupFolderPath = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL == URL(filePath: defaultPath, directoryHint: .isDirectory).standardizedFileURL ? nil : path
    }
}
