import AppKit
import Observation
import SwiftUI

/// What the web gallery window's sidebar edits, and the pages that follow from it.
@Observable
final class WebGalleryModel {
    var settings: WebGallerySettings {
        didSet {
            guard settings != oldValue else { return }
            settings.remember(in: defaults)
            onChange?()
        }
    }
    let photoCount: Int

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(photoCount: Int, defaults: UserDefaults = Defaults.store) {
        self.photoCount = photoCount
        self.defaults = defaults
        settings = WebGallerySettings.remembered(in: defaults)
    }

    var pages: WebGalleryPages {
        WebGalleryPages(photoCount: photoCount, photosPerPage: settings.photosPerPage)
    }

    /// The image size slider: right is larger photos, so fewer columns.
    var imageSize: Double {
        get { Double(WebGallerySettings.columnRange.upperBound + WebGallerySettings.columnRange.lowerBound - settings.columns) }
        set {
            let columns = WebGallerySettings.columnRange.upperBound + WebGallerySettings.columnRange.lowerBound - Int(newValue.rounded())
            settings.columns = min(max(columns, WebGallerySettings.columnRange.lowerBound), WebGallerySettings.columnRange.upperBound)
        }
    }
}

/// The web gallery window's right sidebar: the text, colors, pages and photos.
struct WebGalleryPanel: View {
    @Bindable var model: WebGalleryModel

    /// Switches follow Monochrome Mode, like the rest of the app.
    private var switchTint: Color {
        AppSettings.shared.isMonochrome ? Color(nsColor: Accent.monochrome) : .accentColor
    }

    private func color(_ keyPath: WritableKeyPath<WebGallerySettings, WebGallerySettings.Color>) -> Binding<Color> {
        Binding {
            Color(nsColor: model.settings[keyPath: keyPath].nsColor)
        } set: { color in
            model.settings[keyPath: keyPath] = WebGallerySettings.Color(NSColor(color))
        }
    }

    var body: some View {
        Form {
            Section("Text") {
                TextField("Headline", text: $model.settings.headline, prompt: Text("None"))
                    .accessibilityIdentifier("webGalleryHeadline")
                TextField("Description", text: $model.settings.description, prompt: Text("None"), axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("webGalleryDescription")
            }
            Section("Colors") {
                ColorPicker("Text Color", selection: color(\.textColor), supportsOpacity: false)
                    .accessibilityIdentifier("webGalleryTextColor")
                ColorPicker("Background Color", selection: color(\.backgroundColor), supportsOpacity: false)
                    .accessibilityIdentifier("webGalleryBackgroundColor")
            }
            Section("Page") {
                Picker("Photos per Page", selection: $model.settings.photosPerPage) {
                    ForEach(WebGallerySettings.photosPerPageChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                .accessibilityIdentifier("webGalleryPhotosPerPage")
                Toggle("Page Numbers", isOn: $model.settings.showsPageNumbers)
                    .tint(switchTint)
                    .help("Shows numbered links to the pages between Previous and Next")
                    .accessibilityIdentifier("webGalleryPageNumbers")
            }
            Section("Photos") {
                LabeledContent("Image Size") {
                    Slider(value: $model.imageSize,
                           in: Double(WebGallerySettings.columnRange.lowerBound)...Double(WebGallerySettings.columnRange.upperBound),
                           step: 1) {
                        Text("Image Size")
                    } minimumValueLabel: {
                        Image(systemName: "photo").imageScale(.small).accessibilityHidden(true)
                    } maximumValueLabel: {
                        Image(systemName: "photo").imageScale(.large).accessibilityHidden(true)
                    }
                    .labelsHidden()
                    .help("Up to \(model.settings.columns) across; fewer on a narrow screen")
                    .accessibilityValue("\(model.settings.columns) across")
                    .accessibilityIdentifier("webGalleryImageSize")
                }
                Text(model.pages.summary)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("webGallerySummary")
                Toggle("Image Border", isOn: $model.settings.showsBorder)
                    .tint(switchTint)
                    .accessibilityIdentifier("webGalleryBorder")
                Toggle("Shadow", isOn: $model.settings.showsShadow)
                    .tint(switchTint)
                    .accessibilityIdentifier("webGalleryShadow")
                Toggle("Image Caption", isOn: $model.settings.showsCaption)
                    .tint(switchTint)
                    .accessibilityIdentifier("webGalleryCaption")
                if model.settings.showsCaption {
                    Picker("Caption", selection: $model.settings.captionField) {
                        ForEach(WebGallerySettings.CaptionField.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("webGalleryCaptionField")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
