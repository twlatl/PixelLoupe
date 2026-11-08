import SwiftUI

/// Catalog Settings ▸ Metadata (RAW-268): whether files made from photos carry their develop settings.
/// Duplicate Detection (RAW-292) joins it.
struct CatalogMetadataSettingsView: View {
    let store: CatalogStore
    @State private var settings: CatalogSettings

    init(store: CatalogStore) {
        self.store = store
        _settings = State(initialValue: store.settings)
    }

    var body: some View {
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
        .onChange(of: settings) { _, settings in store.settings = settings }
    }
}
