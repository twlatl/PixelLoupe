import SwiftUI

/// Lightroom's Copy Settings and Synchronize Settings dialog: a checkbox for every Develop setting,
/// grouped as in the Develop panel.
@Observable
final class DevelopSettingsDialogModel {
    enum Purpose: Equatable {
        case copy
        /// Synchronizing to this many other photos.
        case sync(photoCount: Int)
    }

    let purpose: Purpose
    var selection: Set<DevelopSetting>

    @ObservationIgnored var onFinish: ((Set<DevelopSetting>?) -> Void)?

    init(purpose: Purpose, selection: Set<DevelopSetting> = DevelopSetting.defaultSelection) {
        self.purpose = purpose
        self.selection = selection
    }

    var title: String {
        switch purpose {
        case .copy: "Copy Settings"
        case .sync: "Synchronize Settings"
        }
    }

    var actionTitle: String {
        switch purpose {
        case .copy: "Copy"
        case .sync: "Synchronize"
        }
    }

    var message: String {
        switch purpose {
        case .copy: "Choose the settings to copy. Paste Settings applies them to other photos."
        case .sync(let count):
            "Choose the settings to copy from the active photo to the \(count.formatted()) other selected photo\(count == 1 ? "" : "s")."
        }
    }

    func isOn(_ setting: DevelopSetting) -> Binding<Bool> {
        Binding(get: { self.selection.contains(setting) }, set: { on in
            if on { self.selection.insert(setting) } else { self.selection.remove(setting) }
        })
    }

    /// A group's checkbox: on when all of it is, and switches all of it.
    func isOn(_ group: DevelopSetting.Group) -> Binding<Bool> {
        Binding(get: { Set(group.settings).isSubset(of: self.selection) }, set: { on in
            if on { self.selection.formUnion(group.settings) } else { self.selection.subtract(group.settings) }
        })
    }

    func checkAll() { selection = Set(DevelopSetting.allCases) }
    func checkNone() { selection = [] }
}

struct DevelopSettingsDialogView: View {
    @Bindable var model: DevelopSettingsDialogModel

    /// The groups in two columns, split where the second column starts (Black & White).
    private var columns: [[DevelopSetting.Group]] {
        let split = DevelopSetting.groups.firstIndex { $0.title == "Black & White" } ?? DevelopSetting.groups.count / 2
        return [Array(DevelopSetting.groups[..<split]), Array(DevelopSetting.groups[split...])]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text(model.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 32) {
                ForEach(columns.indices, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(columns[column]) { group in
                            Toggle(isOn: model.isOn(group)) {
                                Text(group.title).fontWeight(group.settings.count > 1 ? .semibold : nil)
                            }
                            .accessibilityIdentifier("developSetting.group.\(group.title)")
                            if group.settings.count > 1 {
                                ForEach(group.settings, id: \.self) { setting in
                                    Toggle(setting.title, isOn: model.isOn(setting))
                                        .padding(.leading, 20)
                                        .accessibilityIdentifier("developSetting.\(setting.rawValue)")
                                }
                            }
                        }
                    }
                }
            }
            .toggleStyle(.checkbox)
            HStack {
                Button("Check All") { model.checkAll() }
                Button("Check None") { model.checkNone() }
                Spacer()
                Button("Cancel", role: .cancel) { model.onFinish?(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(model.actionTitle) { model.onFinish?(model.selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection.isEmpty)
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 520)
    }
}
