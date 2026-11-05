import SwiftUI

/// The Logo row in the contact sheet and web gallery sidebars: a small preview of the chosen logo,
/// Choose… (a PNG or JPEG, copied into ``LogoImages``) and Remove.
struct LogoPicker: View {
    @Binding var name: String?
    /// The prefix of the controls' accessibility identifiers ("contactSheet", "webGallery").
    let identifier: String
    let store: LogoImages

    @State private var isChoosing = false
    @State private var failure: String?

    var body: some View {
        LabeledContent("Logo") {
            HStack(spacing: 8) {
                if let name {
                    AsyncImage(url: store.url(named: name)) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(maxWidth: 80, maxHeight: 24)
                    .accessibilityHidden(true)
                }
                Button(name == nil ? "Choose…" : "Change…") { isChoosing = true }
                    .help("Shows a PNG or JPG image above the headline")
                    .accessibilityLabel(name == nil ? "Choose Logo" : "Change Logo")
                    .accessibilityIdentifier("\(identifier)LogoChoose")
                if name != nil {
                    Button("Remove") { name = nil }
                        .accessibilityLabel("Remove Logo")
                        .accessibilityIdentifier("\(identifier)LogoRemove")
                }
            }
        }
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: LogoImages.contentTypes) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                name = try store.importImage(from: url)
            } catch {
                failure = error.localizedDescription
            }
        }
        .alert("The logo couldn't be added.", isPresented: Binding { failure != nil } set: { if !$0 { failure = nil } }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }
}
