import Foundation

/// What the Assisted Culling Info panel says about one photo (RAW-71): its verdict by the panel's criteria, what
/// rejected it, and the scores behind that. Every value is "—" when the photo hasn't been analyzed.
nonisolated struct CullingInfo: Equatable, Sendable {
    enum Row: String, CaseIterable, Sendable {
        case verdict = "Verdict"
        case rejectedBy = "Rejected By"
        case subjectFocus = "Subject Focus"
        case eyeFocus = "Eye Focus"
        case eyesOpen = "Eyes Open"
        case faces = "Faces"
        case exposure = "Exposure"
        case misfire = "Misfire"
        case document = "Document"
    }

    static let none = "—"

    private(set) var values: [Row: String] = [:]
    var verdict: CullingCriteria.Verdict?
    /// Why values are missing or incomplete, if they are.
    var note: String?

    subscript(row: Row) -> String { values[row] ?? Self.none }

    /// Nothing to show: no photo.
    init(note: String? = "No photo selected.") {
        self.note = note
    }

    /// `scores` of an analyzed photo, judged by `criteria`; `isOffline` when neither its original nor a Smart Preview
    /// can be read now.
    init(scores: CullingScores, criteria: CullingCriteria, isOffline: Bool) {
        let failures = criteria.failures(scores)
        verdict = failures.isEmpty ? .select : .reject(failures)
        values[.verdict] = failures.isEmpty ? "Select" : "Reject"
        values[.rejectedBy] = failures.isEmpty ? Self.none : failures.map(\.title).formatted(.list(type: .and))
        let hasEyes = scores.eyesOpenMin >= 0
        let unmeasured = scores.focusPending ? "Not measured yet" : "Unknown"
        values[.subjectFocus] = Self.score(scores.subjectFocus) ?? unmeasured
        values[.eyeFocus] = !hasEyes ? "No eyes detected" : Self.score(scores.eyeFocus) ?? unmeasured
        values[.eyesOpen] = !hasEyes ? "No eyes detected" : Self.eyes(least: scores.eyesOpenMin, most: scores.eyesOpenMax)
        values[.faces] = scores.faceCount.formatted()
        values[.exposure] = scores.exposureIssue ? "Issue" : "OK"
        values[.misfire] = scores.misfire ? "Yes" : "No"
        values[.document] = scores.document ? "Yes" : "No"
        if scores.focusPending {
            note = isOffline
                ? "The original is offline, so focus will be measured when it or a Smart Preview is available."
                : "Focus will be measured shortly."
        }
    }

    /// A 0–1 score as 0–100, or nil when unknown.
    private static func score(_ value: Double) -> String? {
        value < 0 ? nil : "\(Int((value * 100).rounded())) / 100"
    }

    /// The panel's Eyes Open bands: everyone's open, everyone's closed, or something in between.
    private static func eyes(least: Double, most: Double) -> String {
        if least >= CullingCriteria.openEyes { return "Open" }
        if most < CullingCriteria.closedEyes { return "Closed" }
        if least < CullingCriteria.closedEyes, most >= CullingCriteria.openEyes { return "Some closed" }
        return "Ambiguous"
    }
}

extension CullingInfo {
    /// What to show for `photo` (nil: no photo selected).
    @MainActor init(photo: Photo?, criteria: CullingCriteria, status: PhotoSourceStatus?) {
        guard let photo else { self.init(); return }
        let isOffline = status == .missing
        if photo.isVideo {
            self.init(note: "Videos aren't analyzed.")
        } else if photo.cullVersion != CullingAnalyzer.version {
            self.init(note: photo.cullVersion == 0
                ? "Not analyzed yet. Click Analyze in Assisted Culling."
                : "Analyzed by a different version of PixelLoupe. Click Analyze in Assisted Culling.")
        } else {
            self.init(scores: CullingScores(photo), criteria: criteria, isOffline: isOffline)
        }
    }
}
