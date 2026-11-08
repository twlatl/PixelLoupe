import AppKit
import SwiftUI

/// Catalog Settings ▸ Previews (RAW-267): the size and quality of Standard previews, a limit on how much space
/// they take, and how large the preview caches are.
struct CatalogPreviewSettingsView: View {
    let store: CatalogStore
    @State private var settings: CatalogSettings
    /// Worked out off the main thread; nil until then.
    @State private var sizes: Sizes?
    private let autoPixelSize = CatalogStore.autoPreviewPixelSize()

    struct Sizes: Equatable {
        /// Standard previews and thumbnails.
        var previewCache: Int64
        var smartPreviews: Int64
    }

    init(store: CatalogStore) {
        self.store = store
        _settings = State(initialValue: store.settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Preview Cache") {
                Form {
                    LabeledContent("Total Size:") {
                        Text(Self.formatted(sizes?.previewCache)).accessibilityIdentifier("previewCacheSize")
                    }
                    Picker("Standard Preview Size:", selection: $settings.standardPreviewSize) {
                        ForEach(CatalogSettings.PreviewSize.allCases) { size in
                            Text(size == .auto ? "Auto (\(autoPixelSize) pixels)" : "\(size.rawValue) pixels").tag(size)
                        }
                    }
                    .accessibilityIdentifier("standardPreviewSizePicker")
                    Picker("Preview Quality:", selection: $settings.previewQuality) {
                        ForEach(CatalogSettings.PreviewQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("previewQualityPicker")
                    Text("Previews already built keep showing at their old size and quality until they're next viewed, when they're built again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Preview Storage Management") {
                Form {
                    LabeledContent("Limit Preview Cache Size:") {
                        HStack(spacing: 6) {
                            TextField("No limit", value: $settings.previewCacheLimitGB, format: .number.precision(.fractionLength(0...1)))
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .accessibilityLabel("Maximum preview cache size in gigabytes")
                                .accessibilityIdentifier("previewCacheLimitField")
                            Text("GB")
                        }
                    }
                    Text("When Standard previews take more than this, those viewed least recently are removed. Thumbnails and Smart Previews are never removed. Leave it empty for no limit.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Smart Previews") {
                Form {
                    LabeledContent("Total Size:") {
                        Text(Self.formatted(sizes?.smartPreviews)).accessibilityIdentifier("smartPreviewsSize")
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: settings) { _, settings in store.settings = settings }
        .task { await refreshSizes() }
        .onReceive(NotificationCenter.default.publisher(for: StandardPreviewStore.didChangeNotification, object: store.standardPreviews)) { _ in
            Task { await refreshSizes() }
        }
    }

    private func refreshSizes() async {
        sizes = await Self.sizes(of: store.packageURL)
    }

    private static func formatted(_ bytes: Int64?) -> String {
        bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Calculating…"
    }

    /// The preview cache (Standard previews and thumbnails) and Smart Previews, measured on disk.
    @concurrent static func sizes(of package: URL) async -> Sizes {
        let files = FileManager.default
        return Sizes(
            previewCache: files.sizeOfDirectory(at: CatalogPackage.standardPreviewsURL(in: package))
                + files.sizeOfDirectory(at: CatalogPackage.thumbnailsURL(in: package)),
            smartPreviews: files.sizeOfDirectory(at: CatalogPackage.smartPreviewsURL(in: package))
        )
    }
}
