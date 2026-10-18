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
/// the options.
struct CapsulePicker<Value: Hashable & Sendable>: View {
    let options: [Value]
    let selected: Value
    let title: (Value) -> String
    let identifier: (Value) -> String
    let onSelect: (Value) -> Void
    /// Options shown but not available, with why (a tooltip).
    var unavailable: [Value: String] = [:]
    @Namespace private var namespace

    /// The selected option's capsule: the accent color, or gray in Monochrome Mode.
    private var isMonochrome: Bool { AppSettings.shared.isMonochrome }

    private var selectedTint: Color {
        AppSettings.shared.isMonochrome ? Color(nsColor: Accent.monochrome) : .accentColor
    }

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(options, id: \.self) { option in
                    let isSelected = selected == option
                    Button {
                        onSelect(option)
                    } label: {
                        Text(title(option))
                            .font(.system(size: 13, weight: .medium))
                            // Never truncated, however narrow the toolbar makes the picker.
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(unavailable[option] != nil)
                    .opacity(unavailable[option] != nil ? 0.45 : 1)
                    .help(unavailable[option] ?? "")
                    // Monochrome Mode wants the exact color (black in Light Mode); a glass tint is translucent.
                    .background(isSelected && isMonochrome ? Capsule().fill(selectedTint) : nil)
                    .glassEffect(isSelected && !isMonochrome ? .regular.tint(selectedTint).interactive() : .identity, in: .capsule)
                    .glassEffectID(option, in: namespace)
                    .accessibilityIdentifier(identifier(option))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            // Breathing room between the selected capsule and the toolbar's pill around the picker.
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
        .fixedSize()
        .animation(.smooth(duration: 0.25), value: selected)
    }
}
