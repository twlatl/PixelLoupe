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
    /// The saved watermarks, for the Watermark pop-up.
    private(set) var watermarkNames: [String]
    /// While the gallery is written: how much is done (0…1).
    var progress: Double?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onGenerate: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var watermarkObserver: NSObjectProtocol?

    init(photoCount: Int, defaults: UserDefaults = Defaults.store, watermarks: WatermarkPresets = .shared) {
        self.photoCount = photoCount
        self.defaults = defaults
        let names = watermarks.all.map(\.name)
        watermarkNames = names
        var settings = WebGallerySettings.remembered(in: defaults)
        // A watermark deleted since is no watermark.
        if let name = settings.watermarkName, !names.contains(name) { settings.watermarkName = nil }
        self.settings = settings
        watermarkObserver = NotificationCenter.default.addObserver(
            forName: WatermarkPresets.didChangeNotification, object: watermarks, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.watermarksChanged(watermarks) }
        }
    }

    isolated deinit {
        if let watermarkObserver { NotificationCenter.default.removeObserver(watermarkObserver) }
    }

    private func watermarksChanged(_ watermarks: WatermarkPresets) {
        watermarkNames = watermarks.all.map(\.name)
        if let name = settings.watermarkName, !watermarkNames.contains(name) { settings.watermarkName = nil }
    }

    /// The JPEG Quality slider, kept on its steps.
    var jpegQuality: Double {
        get { settings.jpegQuality }
        set { settings.jpegQuality = WebGallerySettings.clampedQuality(newValue) }
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

/// The web gallery window's right sidebar: the text, colors, pages, photos, Head and Body, and output,
/// and Generate.
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
        VStack(spacing: 0) {
            form
                .disabled(model.progress != nil)
            Divider()
            footer
                .padding(16)
        }
    }

    private var form: some View {
        Form {
            Section("Text") {
                TextField("Headline", text: $model.settings.headline, prompt: Text("None"))
                    .accessibilityIdentifier("webGalleryHeadline")
                TextField("Description", text: $model.settings.description, prompt: Text("None"), axis: .vertical)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("webGalleryDescription")
                TextField("Email", text: $model.settings.email, prompt: Text("None"))
                    .autocorrectionDisabled()
                    .help("A link under the headline that opens the viewer's mail app, hidden from address harvesters")
                    .accessibilityIdentifier("webGalleryEmail")
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
            Section {
                CodeTextView(text: $model.settings.headHTML, accessibilityLabel: "Head")
                    .frame(height: 80)
                    .accessibilityIdentifier("webGalleryHead")
            } header: {
                Text("Head")
            } footer: {
                codeFooter(model.settings.headHTML, note: "Added at the end of every page's <head>, as typed. Not in the preview.",
                           identifier: "webGalleryHeadWarning")
            }
            Section {
                CodeTextView(text: $model.settings.bodyHTML, accessibilityLabel: "Body")
                    .frame(height: 80)
                    .accessibilityIdentifier("webGalleryBody")
            } header: {
                Text("Body")
            } footer: {
                codeFooter(model.settings.bodyHTML, note: "Added at the end of every page's <body>, as typed. Not in the preview.",
                           identifier: "webGalleryBodyWarning")
            }
            Section("Output") {
                Picker("Watermark", selection: $model.settings.watermarkName) {
                    Text("None").tag(String?.none)
                    if !model.watermarkNames.isEmpty { Divider() }
                    ForEach(model.watermarkNames, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .help("Drawn on the large images, not the thumbnails")
                .accessibilityIdentifier("webGalleryWatermark")
                LabeledContent("JPEG Quality") {
                    HStack {
                        Slider(value: $model.jpegQuality, in: WebGallerySettings.qualityRange, step: WebGallerySettings.qualityStep) {
                            Text("JPEG Quality")
                        }
                        .labelsHidden()
                        .accessibilityValue("\(Int(model.settings.jpegQuality)) percent")
                        .accessibilityIdentifier("webGalleryQuality")
                        Text("\(Int(model.settings.jpegQuality))%")
                            .monospacedDigit()
                            .frame(minWidth: 36, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                }
                .help("The generated images' quality; the preview doesn't change with it")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// What the Head or Body text is for, or a warning when it opens something it doesn't close.
    @ViewBuilder
    private func codeFooter(_ code: String, note: String, identifier: String) -> some View {
        if let unclosed = WebGalleryHTML.unclosed(in: code) {
            Label(unclosed.warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityIdentifier(identifier)
        } else {
            Text(note)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let progress = model.progress {
            HStack {
                ProgressView(value: progress)
                    .accessibilityLabel("Generating web gallery")
                    .accessibilityIdentifier("webGalleryProgress")
                Button("Cancel") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("webGalleryCancel")
            }
        } else {
            Button {
                model.onGenerate?()
            } label: {
                Text("Generate…").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("Saves the web gallery's pages and images into a folder")
            .accessibilityIdentifier("webGalleryGenerate")
        }
    }
}
