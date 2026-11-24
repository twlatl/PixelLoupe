import SwiftUI

/// Catalog Settings ▸ Metadata (RAW-268): whether files made from photos carry their develop settings.
/// whether duplicates are found (RAW-292), and when Develop history is cleared automatically (RAW-309).
struct CatalogMetadataSettingsView: View {
    let store: CatalogStore
    @State private var settings: CatalogSettings

    init(store: CatalogStore) {
        self.store = store
        _settings = State(initialValue: store.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
        GroupBox("Editing") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Include Develop Settings in metadata inside JPEG, TIFF, PNG and PSD files",
                       isOn: $settings.includesDevelopSettingsInExports)
                    .accessibilityIdentifier("includeDevelopSettingsToggle")
                Text("Files exported, published, edited in another app or written for a web gallery carry the photo's develop settings, which Lightroom and Camera Raw can read. When this is off, they carry none.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("History") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Automatically clear history:", selection: Binding(
                    get: { settings.historyCleanup }, set: { settings.chooseHistoryCleanup($0) }
                )) {
                    ForEach(CatalogSettings.HistoryCleanup.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .accessibilityIdentifier("historyCleanupPicker")
                Text("Each photo's Develop history is cleared as the catalog opens. Photos keep their current settings and snapshots. Cleared history can't be restored.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("History last cleared: \(lastCleared)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lastHistoryCleanup")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("Duplicate Detection") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Automatically detect duplicates for all photos", isOn: $settings.detectsDuplicates)
                    .accessibilityIdentifier("detectDuplicatesToggle")
                Text("Each photo's original is read in the background, and photos whose files are identical appear in Duplicates, in the Catalog section of the sidebar. Nothing is removed. Reading a large catalog's originals takes a while.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .onChange(of: settings) { _, settings in store.settings = settings }
    }

    private var lastCleared: String {
        settings.lastHistoryCleanup?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }
}
