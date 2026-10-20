import AppKit
import Observation
import SwiftUI

/// What the contact sheet window's sidebar edits, and the layout that follows from it.
@Observable
final class ContactSheetModel {
    var settings: ContactSheetSettings {
        didSet {
            guard settings != oldValue else { return }
            layout = ContactSheetLayout(settings: settings, photoCount: photoCount)
            settings.remember(in: defaults)
            onChange?()
        }
    }
    private(set) var layout: ContactSheetLayout
    let photoCount: Int
    /// While the PDF is written: how much is done (0…1).
    var progress: Double?

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored var onGenerate: (() -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    init(photoCount: Int, defaults: UserDefaults = Defaults.store) {
        self.photoCount = photoCount
        self.defaults = defaults
        let settings = ContactSheetSettings.remembered(in: defaults)
        self.settings = settings
        layout = ContactSheetLayout(settings: settings, photoCount: photoCount)
    }

    /// The image size slider: right is larger photos, so fewer columns.
    var imageSize: Double {
        get { Double(ContactSheetSettings.columnRange.upperBound + ContactSheetSettings.columnRange.lowerBound - settings.columns) }
        set {
            let columns = ContactSheetSettings.columnRange.upperBound + ContactSheetSettings.columnRange.lowerBound - Int(newValue.rounded())
            settings.columns = min(max(columns, ContactSheetSettings.columnRange.lowerBound), ContactSheetSettings.columnRange.upperBound)
        }
    }
}

/// The contact sheet window's right sidebar: the text, colors, layout and options, and Generate.
struct ContactSheetPanel: View {
    @Bindable var model: ContactSheetModel

    /// Switches follow Monochrome Mode, like the rest of the app.
    private var switchTint: Color {
        AppSettings.shared.isMonochrome ? Color(nsColor: Accent.monochrome) : .accentColor
    }

    private func color(_ keyPath: WritableKeyPath<ContactSheetSettings, ContactSheetSettings.Color>) -> Binding<Color> {
        Binding {
            Color(nsColor: model.settings[keyPath: keyPath].nsColor)
        } set: { color in
            model.settings[keyPath: keyPath] = ContactSheetSettings.Color(NSColor(color))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Text") {
                    TextField("Headline", text: $model.settings.headline, prompt: Text("None"))
                        .accessibilityIdentifier("contactSheetHeadline")
                    TextField("Description", text: $model.settings.description, prompt: Text("None"), axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("contactSheetDescription")
                }
                Section("Colors") {
                    ColorPicker("Text Color", selection: color(\.textColor), supportsOpacity: false)
                        .accessibilityIdentifier("contactSheetTextColor")
                    ColorPicker("Background Color", selection: color(\.backgroundColor), supportsOpacity: false)
                        .accessibilityIdentifier("contactSheetBackgroundColor")
                }
                Section("Page") {
                    Picker("Page Size", selection: $model.settings.pageSize) {
                        ForEach(ContactSheetSettings.PageSize.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("contactSheetPageSize")
                    Picker("Orientation", selection: $model.settings.orientation) {
                        Text("Portrait").tag(ContactSheetSettings.Orientation.portrait)
                        Text("Landscape").tag(ContactSheetSettings.Orientation.landscape)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("contactSheetOrientation")
                    Toggle("Page Numbers", isOn: $model.settings.showsPageNumbers)
                        .tint(switchTint)
                        .accessibilityIdentifier("contactSheetPageNumbers")
                }
                Section("Photos") {
                    LabeledContent("Image Size") {
                        Slider(value: $model.imageSize,
                               in: Double(ContactSheetSettings.columnRange.lowerBound)...Double(ContactSheetSettings.columnRange.upperBound),
                               step: 1) {
                            Text("Image Size")
                        } minimumValueLabel: {
                            Image(systemName: "photo").imageScale(.small).accessibilityHidden(true)
                        } maximumValueLabel: {
                            Image(systemName: "photo").imageScale(.large).accessibilityHidden(true)
                        }
                        .labelsHidden()
                        .accessibilityValue(model.layout.summary)
                        .accessibilityIdentifier("contactSheetImageSize")
                    }
                    Text(model.layout.summary)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("contactSheetSummary")
                    Toggle("Image Border", isOn: $model.settings.showsBorder)
                        .tint(switchTint)
                        .accessibilityIdentifier("contactSheetBorder")
                    Toggle("Shadow", isOn: $model.settings.showsShadow)
                        .tint(switchTint)
                        .accessibilityIdentifier("contactSheetShadow")
                    Toggle("Image Caption", isOn: $model.settings.showsCaption)
                        .tint(switchTint)
                        .accessibilityIdentifier("contactSheetCaption")
                    if model.settings.showsCaption {
                        Picker("Caption", selection: $model.settings.captionField) {
                            ForEach(ContactSheetSettings.CaptionField.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .accessibilityIdentifier("contactSheetCaptionField")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.progress != nil)

            Divider()
            footer
                .padding(16)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let progress = model.progress {
            HStack {
                ProgressView(value: progress)
                    .accessibilityLabel("Generating PDF")
                    .accessibilityIdentifier("contactSheetProgress")
                Button("Cancel") { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("contactSheetCancel")
            }
        } else {
            Button {
                model.onGenerate?()
            } label: {
                Text("Generate…").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .help("Saves the contact sheet as a PDF")
            .accessibilityIdentifier("contactSheetGenerate")
        }
    }
}
