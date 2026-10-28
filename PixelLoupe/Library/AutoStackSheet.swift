import AppKit
import CoreData
import SwiftUI

/// The Auto Stack sheet (RAW-71): stack the photos by capture time or by visual similarity, showing how many
/// stacks that makes as the slider moves. The method and both sliders are remembered, app-wide.
@Observable
final class AutoStackModel {
    /// The photos to stack, not in a stack yet, in capture-time order.
    let photoIDs: [NSManagedObjectID]
    let dates: [Date]
    /// Whether they're the selected photos (rather than the source's).
    let isSelection: Bool

    var method: AutoStacking.Method {
        didSet {
            Defaults.store.set(method.rawValue, forKey: Self.methodKey)
            if method == .similarity { onNeedsDistances?() }
        }
    }
    /// The Capture Time slider, 0–1 on a log scale over `AutoStacking.gapRange`.
    var gapPosition: Double {
        didSet { Defaults.store.set(gap, forKey: Self.gapKey) }
    }
    /// The Visual Similarity slider: 0 Loose to 1 Strict.
    var strictness: Double {
        didSet { Defaults.store.set(strictness, forKey: Self.strictnessKey) }
    }
    /// Each photo's distance to the one before; nil until measured.
    var distances: [Double?]?
    /// Photos measured so far, while measuring.
    var measured = 0

    @ObservationIgnored var onStack: ((AutoStackModel) -> Void)?
    @ObservationIgnored var onCancel: (() -> Void)?
    /// Visual Similarity was chosen and the photos haven't been compared yet.
    @ObservationIgnored var onNeedsDistances: (() -> Void)?

    private static let methodKey = "AutoStackMethod"
    private static let gapKey = "AutoStackGap"
    private static let strictnessKey = "AutoStackStrictness"

    init(photoIDs: [NSManagedObjectID], dates: [Date], isSelection: Bool) {
        self.photoIDs = photoIDs
        self.dates = dates
        self.isSelection = isSelection
        method = AutoStacking.Method(rawValue: Defaults.store.integer(forKey: Self.methodKey)) ?? .captureTime
        let gap = Defaults.store.object(forKey: Self.gapKey) as? Double ?? AutoStacking.defaultGap
        gapPosition = Self.position(ofGap: gap)
        strictness = Defaults.store.object(forKey: Self.strictnessKey) as? Double ?? 0.5
    }

    var gap: TimeInterval {
        let range = AutoStacking.gapRange
        return exp(log(range.lowerBound) + (log(range.upperBound) - log(range.lowerBound)) * gapPosition).rounded()
    }

    static func position(ofGap gap: TimeInterval) -> Double {
        let range = AutoStacking.gapRange
        return ((log(gap.clamped(to: range)) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)))
    }

    var gapTitle: String {
        Duration.seconds(gap).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 2))
    }

    /// The stacks the current settings make, as indices into `photoIDs`; nil while photos are being compared.
    var groups: [[Int]]? {
        switch method {
        case .captureTime: AutoStacking.groups(joining: AutoStacking.joins(dates: dates, gap: gap))
        case .similarity: distances.map { AutoStacking.groups(joining: AutoStacking.joins(distances: $0, strictness: strictness)) }
        }
    }

    var summary: String {
        guard let groups else {
            return "Comparing photos… \(measured.formatted()) of \(photoIDs.count.formatted())"
        }
        guard !groups.isEmpty else { return "No photos are close enough to stack." }
        let photos = groups.reduce(0) { $0 + $1.count }
        return "Makes \(groups.count.formatted()) stack\(groups.count == 1 ? "" : "s") from \(photos.formatted()) photos."
    }

    var canStack: Bool { !(groups ?? []).isEmpty }

    var title: String {
        let photos = "\(photoIDs.count.formatted()) \(isSelection ? "selected " : "")photo\(photoIDs.count == 1 ? "" : "s")"
        return "Auto Stack \(photos)"
    }
}

struct AutoStackView: View {
    @Bindable var model: AutoStackModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title)
                .font(.headline)
            Text("Photos taken one after another become a stack, its best photo on top. Photos already in a stack are left alone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Stack", selection: $model.method) {
                ForEach(AutoStacking.Method.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityIdentifier("autoStackMethod")
            Group {
                switch model.method {
                case .captureTime:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Time between photos: \(model.gapTitle)")
                        HStack {
                            Text("1 s")
                            MonochromeSliderView(value: $model.gapPosition, range: 0...1, label: "Time between photos", identifier: "autoStackGap")
                            Text("1 h")
                        }
                    }
                case .similarity:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("How alike photos must look")
                        HStack {
                            Text("Loose")
                            MonochromeSliderView(value: $model.strictness, range: 0...1, label: "How alike photos must look", identifier: "autoStackStrictness")
                            Text("Strict")
                        }
                        .disabled(model.distances == nil)
                    }
                }
            }
            .padding(.leading, 20)
            HStack(spacing: 8) {
                if model.groups == nil {
                    ProgressView(value: Double(model.measured), total: Double(max(1, model.photoIDs.count)))
                        .frame(width: 120)
                }
                Text(model.summary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityIdentifier("autoStackSummary")
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Button("Stack") { model.onStack?(model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canStack)
                    .accessibilityIdentifier("autoStackStack")
            }
            .padding(.top, 6)
        }
        .padding(20)
        .frame(width: 420)
    }
}
