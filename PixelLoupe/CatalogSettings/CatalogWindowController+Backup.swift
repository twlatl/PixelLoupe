import AppKit
import SwiftUI

/// Backing the catalog up as PixelLoupe quits (Catalog Settings ▸ Backups, RAW-269).
extension CatalogWindowController {
    /// When a backup is due, asks on a sheet whether to make one and, once it's made or skipped, calls `completion` with
    /// whether to go on quitting. Returns false, without calling `completion`, when no backup is due.
    func backUpBeforeQuittingIfDue(completion: @escaping (Bool) -> Void) -> Bool {
        let settings = store.settings
        let folder = settings.backupFolder(forCatalogAt: store.packageURL)
        let last = CatalogBackup.backups(of: CatalogBackup.catalogName(of: store.packageURL), in: folder).first?.date
        guard CatalogBackup.isDue(settings.backupSchedule, lastBackup: last),
              let window, window.attachedSheet == nil, let content = window.contentViewController else { return false }
        window.makeKeyAndOrderFront(nil)

        let run = BackupRun()
        var sheet: NSViewController?
        let view = BackupSheetView(
            catalogName: store.name, folder: folder, run: run, testsIntegrity: settings.testsBackupIntegrity,
            onSkip: {
                sheet?.dismiss(nil)
                completion(true)
            },
            onBackUp: { [weak self] testsIntegrity in
                guard let self else { return completion(true) }
                store.settings.testsBackupIntegrity = testsIntegrity
                backUp(testsIntegrity: testsIntegrity, run: run) { succeeded in
                    sheet?.dismiss(nil)
                    completion(succeeded || self.quitsAfterFailedBackup(run.error))
                }
            }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = "Back Up Catalog"
        sheet = hosting
        content.presentAsSheet(hosting)
        return true
    }

    private func backUp(testsIntegrity: Bool, run: BackupRun, completion: @escaping (Bool) -> Void) {
        // What's in memory goes into the copy.
        saveSelection()
        store.save()
        let package = store.packageURL, settings = store.settings
        run.phase = .copying
        Task {
            do {
                _ = try await CatalogBackup.backUp(
                    package, to: settings.backupFolder(forCatalogAt: package), testsIntegrity: testsIntegrity,
                    keeping: settings.backupsToKeep
                ) { phase in Task { @MainActor in run.phase = phase } }
                store.settings.backupDidFinish()
                completion(true)
            } catch {
                run.error = error
                completion(false)
            }
        }
    }

    /// Says why the backup failed; returns whether to quit anyway.
    private func quitsAfterFailedBackup(_ error: (any Error)?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = error?.localizedDescription ?? "The catalog couldn't be backed up."
        alert.informativeText = (error as? LocalizedError)?.failureReason ?? ""
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Don’t Quit")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// The state of a backup started from the quit sheet.
@Observable
final class BackupRun {
    var phase: CatalogBackup.Phase?
    var error: (any Error)?
}

/// Back Up Catalog: shown as PixelLoupe quits when a backup is due.
struct BackupSheetView: View {
    let catalogName: String
    let folder: URL
    let run: BackupRun
    @State var testsIntegrity: Bool
    let onSkip: () -> Void
    let onBackUp: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Back up “\(catalogName)”?")
                .font(.headline)
            Text("The catalog is backed up to \(folder.path(percentEncoded: false)). Previews aren't included; they're built again when needed.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Test integrity before backing up", isOn: $testsIntegrity)
                .disabled(run.phase != nil)
                .accessibilityIdentifier("testBackupIntegrityToggle")
            if let phase = run.phase {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(phase.rawValue + 1), total: Double(CatalogBackup.Phase.allCases.count))
                    Text(phase.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("backupProgress")
            }
            HStack {
                Spacer()
                Button("Skip This Time", action: onSkip)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("skipBackupButton")
                Button("Back Up") { onBackUp(testsIntegrity) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("backUpButton")
            }
            .disabled(run.phase != nil)
        }
        .padding(20)
        .frame(width: 420)
    }
}
