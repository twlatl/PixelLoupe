import SwiftUI

/// Bridges the selected module between AppKit and the SwiftUI mode picker.
@Observable
final class ModeSelection {
    var mode: AppMode = .library
    var onSelect: (AppMode) -> Void = { _ in }
}

/// Library/Develop switcher for the toolbar.
struct ModePicker: View {
    var selection: ModeSelection

    var body: some View {
        CapsulePicker(
            options: AppMode.allCases, selected: selection.mode, title: \.title,
            identifier: { "mode.\($0.title)" }, onSelect: selection.onSelect)
    }
}

/// A toolbar switcher between a few options (Library/Develop, the import window's Copy/Add). The
/// selected option is a Liquid Glass capsule tinted with the system accent color that slides between
/// the options. With `isSelected` it can show several options selected (the Library Filter's modes),
/// and `.small` frames it in a glass capsule of its own, for use outside the toolbar.
struct CapsulePicker<Value: Hashable & Sendable>: View {
    enum Size {
        /// In the toolbar, whose pill frames it.
        case regular
        /// In a bar of small controls, in a glass capsule of its own.
        case small
    }

    let options: [Value]
    let isSelected: (Value) -> Bool
    let title: (Value) -> String
    let identifier: (Value) -> String
    let onSelect: (Value) -> Void
    /// Options shown dimmed because they aren't available, with why (a tooltip). They can still be
    /// chosen, for whoever shows the reason.
    var unavailable: [Value: String] = [:]
    var size = Size.regular
    var help: (Value) -> String = { _ in "" }
    @Namespace private var namespace

    init(
        options: [Value], selected: Value, title: @escaping (Value) -> String,
        identifier: @escaping (Value) -> String, onSelect: @escaping (Value) -> Void,
        unavailable: [Value: String] = [:]
    ) {
        self.init(options: options, isSelected: { $0 == selected }, title: title, identifier: identifier,
                  onSelect: onSelect, unavailable: unavailable)
    }

    init(
        options: [Value], isSelected: @escaping (Value) -> Bool, title: @escaping (Value) -> String,
        identifier: @escaping (Value) -> String, onSelect: @escaping (Value) -> Void,
        unavailable: [Value: String] = [:], size: Size = .regular, help: @escaping (Value) -> String = { _ in "" }
    ) {
        self.options = options
        self.isSelected = isSelected
        self.title = title
        self.identifier = identifier
        self.onSelect = onSelect
        self.unavailable = unavailable
        self.size = size
        self.help = help
    }

    /// The selected option's capsule: the accent color, or gray in Monochrome Mode.
    private var isMonochrome: Bool { AppSettings.shared.isMonochrome }

    private var selectedTint: Color {
        AppSettings.shared.isMonochrome ? Color(nsColor: Accent.monochrome) : .accentColor
    }

    var body: some View {
        let small = size == .small
        let picker = GlassEffectContainer(spacing: small ? 2 : 4) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let isSelected = isSelected(option)
                    Button {
                        onSelect(option)
                    } label: {
                        Text(title(option))
                            .font(.system(size: small ? 11 : 13, weight: .medium))
                            // Never truncated, however narrow the toolbar makes the picker.
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, small ? 10 : 14)
                            .padding(.vertical, small ? 3 : 5)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    // Dimmed but still clickable, so choosing it can say why it isn't available.
                    .opacity(unavailable[option] != nil ? 0.45 : 1)
                    .help(unavailable[option] ?? help(option))
                    // Monochrome Mode wants the exact color (black in Light Mode); a glass tint is translucent.
                    .background(isSelected && isMonochrome ? Capsule().fill(selectedTint) : nil)
                    .glassEffect(isSelected && !isMonochrome ? .regular.tint(selectedTint).interactive() : .identity, in: .capsule)
                    .glassEffectID(option, in: namespace)
                    .accessibilityIdentifier(identifier(option))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            // Breathing room between the selected capsule and the pill around the picker.
            .padding(.horizontal, small ? 3 : 6)
            .padding(.vertical, small ? 3 : 5)
        }
        Group {
            if small {
                picker.glassEffect(.regular, in: .capsule)
            } else {
                picker
            }
        }
        .fixedSize()
        .animation(.smooth(duration: 0.25), value: options.map(isSelected))
    }
}
