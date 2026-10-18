import AppKit
import SwiftUI

/// Settings ▸ Displays: the connected displays drawn as they're arranged; click one to put the
/// secondary window on it. The highlighted display is where the secondary window goes.
struct DisplaysSettingsView: View {
    @Bindable private var settings = SecondaryDisplaySettings.shared
    @State private var displays = DisplayInfo.connected()
    @State private var mainWindowDisplay = Self.currentMainWindowDisplay()

    static let arrangementSize = CGSize(width: 520, height: 220)

    private var target: DisplayInfo? {
        SecondaryDisplay.target(among: displays, preferred: settings.preferredDisplayID, mainWindowDisplay: mainWindowDisplay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose monitor for secondary window")
            arrangement
            Text(displays.count > 1
                 ? "The secondary window (Window ▸ Secondary Display, ⌘F11) opens on the highlighted display."
                 : "Connect a second display to use a secondary window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("displaysHint")
        }
        .padding(20)
        .frame(width: Self.arrangementSize.width + 40)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays = DisplayInfo.connected()
            mainWindowDisplay = Self.currentMainWindowDisplay()
        }
        .onAppear { mainWindowDisplay = Self.currentMainWindowDisplay() }
    }

    private var arrangement: some View {
        let frames = SecondaryDisplay.layout(displays, in: Self.arrangementSize)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
            ForEach(displays) { display in
                if let frame = frames[display.id] {
                    monitor(display, isTarget: display.id == target?.id)
                        .frame(width: frame.width - 4, height: frame.height - 4)
                        .offset(x: frame.minX + 2, y: frame.minY + 2)
                }
            }
        }
        .frame(width: Self.arrangementSize.width, height: Self.arrangementSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Display arrangement")
    }

    private func monitor(_ display: DisplayInfo, isTarget: Bool) -> some View {
        Button {
            settings.preferredDisplayID = display.id
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isTarget ? Color(nsColor: Accent.color) : Color(nsColor: .tertiaryLabelColor))
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(isTarget ? Color.white : Color(nsColor: .separatorColor), lineWidth: isTarget ? 3 : 1)
                VStack(spacing: 2) {
                    Text(display.name)
                        .font(.caption.weight(.medium))
                    if display.id == mainWindowDisplay {
                        Text("Main window")
                            .font(.caption2)
                    }
                }
                .foregroundStyle(isTarget ? Color.white : Color.primary)
                .multilineTextAlignment(.center)
                .padding(4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(displays.count < 2)
        .accessibilityLabel(display.id == mainWindowDisplay ? "\(display.name), main window" : display.name)
        .accessibilityAddTraits(isTarget ? .isSelected : [])
        .accessibilityIdentifier("display-\(display.id)")
    }

    /// The display showing the catalog window, marked "Main window".
    private static func currentMainWindowDisplay() -> String? {
        NSApp.windows.first { $0.identifier?.rawValue == "catalogWindow" && $0.isVisible }?.screen?.displayUUID
    }
}
