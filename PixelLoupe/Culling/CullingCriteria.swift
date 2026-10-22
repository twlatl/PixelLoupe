import CoreData
import Foundation

/// What the Assisted Culling panel splits photos by (RAW-71): Select criteria a photo must pass and Reject
/// criteria it must not hit. A photo that fails any checked Select criterion or hits any checked Reject criterion
/// is a Reject; every other analyzed photo is a Select. App-wide, saved in user defaults.
///
/// The rules exist twice: as Swift (`failures(_:)`, for one photo) and as a Core Data predicate (`rejectPredicate`,
/// for the grid and counts). The tests check they agree.
nonisolated struct CullingCriteria: Equatable, Codable, Sendable {
    /// Eyes at least this open (`Photo.cullEyesOpenMin`, 0–1) are open.
    static let openEyes = 0.65
    /// Eyes less open than this are closed. Between the two they're ambiguous.
    static let closedEyes = 0.35

    var subjectFocus = true
    /// The least subject focus a Select has, 0 (Soft) to 1 (Sharp).
    var subjectFocusMinimum = 0.5
    var eyeFocus = true
    var eyeFocusMinimum = 0.5
    /// Photos without eyes fail Eye Focus.
    var eyeFocusNeedsEyes = false
    var eyesOpen = true
    /// Photos without eyes fail Eyes Open.
    var eyesOpenNeedsEyes = false
    /// Photos whose eyes are neither clearly open nor clearly closed, or whose people disagree, pass Eyes Open.
    var selectsAmbiguousEyes = false
    var exposureIssues = true
    var misfires = true
    var documents = true

    init() {}

    init(from decoder: Decoder) throws {
        // Criteria added later are missing from settings saved before them.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CullingCriteria()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        subjectFocus = try value(.subjectFocus, defaults.subjectFocus)
        subjectFocusMinimum = try value(.subjectFocusMinimum, defaults.subjectFocusMinimum)
        eyeFocus = try value(.eyeFocus, defaults.eyeFocus)
        eyeFocusMinimum = try value(.eyeFocusMinimum, defaults.eyeFocusMinimum)
        eyeFocusNeedsEyes = try value(.eyeFocusNeedsEyes, defaults.eyeFocusNeedsEyes)
        eyesOpen = try value(.eyesOpen, defaults.eyesOpen)
        eyesOpenNeedsEyes = try value(.eyesOpenNeedsEyes, defaults.eyesOpenNeedsEyes)
        selectsAmbiguousEyes = try value(.selectsAmbiguousEyes, defaults.selectsAmbiguousEyes)
        exposureIssues = try value(.exposureIssues, defaults.exposureIssues)
        misfires = try value(.misfires, defaults.misfires)
        documents = try value(.documents, defaults.documents)
    }

    // MARK: Saving

    private static let key = "AssistedCullingCriteria"

    static var saved: CullingCriteria {
        get {
            guard let data = Defaults.store.data(forKey: key) else { return CullingCriteria() }
            return (try? JSONDecoder().decode(CullingCriteria.self, from: data)) ?? CullingCriteria()
        }
        set { Defaults.store.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    // MARK: One photo

    /// A criterion a photo can be rejected by, in the panel's order.
    enum Criterion: CaseIterable, Sendable {
        case subjectFocus, eyeFocus, eyesOpen, exposureIssues, misfires, documents

        var title: String {
            switch self {
            case .subjectFocus: "Subject Focus"
            case .eyeFocus: "Eye Focus"
            case .eyesOpen: "Eyes Open"
            case .exposureIssues: "Exposure Issues"
            case .misfires: "Misfires"
            case .documents: "Documents"
            }
        }
    }

    enum Verdict: Equatable, Sendable {
        case select
        /// The criteria that reject it, in the panel's order.
        case reject([Criterion])
    }

    /// Whether the scores are a Select or a Reject, or nil when the photo hasn't been analyzed (by this version of
    /// the analyzer).
    @MainActor func verdict(for photo: Photo) -> Verdict? {
        guard photo.cullVersion == CullingAnalyzer.version else { return nil }
        let failures = failures(CullingScores(photo))
        return failures.isEmpty ? .select : .reject(failures)
    }

    /// The checked criteria `scores` fail or hit.
    func failures(_ scores: CullingScores) -> [Criterion] {
        var failures: [Criterion] = []
        let hasEyes = scores.eyesOpenMin >= 0
        if subjectFocus, scores.subjectFocus >= 0, scores.subjectFocus < subjectFocusMinimum {
            failures.append(.subjectFocus)
        }
        if eyeFocus, (scores.eyeFocus >= 0 && scores.eyeFocus < eyeFocusMinimum) || (eyeFocusNeedsEyes && !hasEyes) {
            failures.append(.eyeFocus)
        }
        if eyesOpen {
            let fails = if !hasEyes {
                eyesOpenNeedsEyes
            } else if selectsAmbiguousEyes {
                // Only when everyone's eyes are clearly closed.
                scores.eyesOpenMax < Self.closedEyes
            } else {
                scores.eyesOpenMin < Self.openEyes
            }
            if fails { failures.append(.eyesOpen) }
        }
        if exposureIssues, scores.exposureIssue { failures.append(.exposureIssues) }
        if misfires, scores.misfire { failures.append(.misfires) }
        if documents, scores.document { failures.append(.documents) }
        return failures
    }

    // MARK: Predicates

    /// Photos scored by this version of the analyzer; the rest are unanalyzed.
    static var analyzedPredicate: NSPredicate {
        NSPredicate(format: "cullVersion == %d", CullingAnalyzer.version)
    }

    /// Analyzed photos that fail or hit a checked criterion; the same rules as `failures(_:)`.
    var rejectPredicate: NSPredicate {
        var rejects: [NSPredicate] = []
        if subjectFocus {
            rejects.append(NSPredicate(format: "cullSubjectFocus >= 0 AND cullSubjectFocus < %lf", subjectFocusMinimum))
        }
        if eyeFocus {
            var eye = [NSPredicate(format: "cullEyeFocus >= 0 AND cullEyeFocus < %lf", eyeFocusMinimum)]
            if eyeFocusNeedsEyes { eye.append(NSPredicate(format: "cullEyesOpenMin < 0")) }
            rejects.append(NSCompoundPredicate(orPredicateWithSubpredicates: eye))
        }
        if eyesOpen {
            var eyes = [selectsAmbiguousEyes
                ? NSPredicate(format: "cullEyesOpenMin >= 0 AND cullEyesOpenMax < %lf", Self.closedEyes)
                : NSPredicate(format: "cullEyesOpenMin >= 0 AND cullEyesOpenMin < %lf", Self.openEyes)]
            if eyesOpenNeedsEyes { eyes.append(NSPredicate(format: "cullEyesOpenMin < 0")) }
            rejects.append(NSCompoundPredicate(orPredicateWithSubpredicates: eyes))
        }
        if exposureIssues { rejects.append(NSPredicate(format: "cullExposureIssue == YES")) }
        if misfires { rejects.append(NSPredicate(format: "cullMisfire == YES")) }
        if documents { rejects.append(NSPredicate(format: "cullDocument == YES")) }
        let any = rejects.isEmpty ? NSPredicate(value: false) : NSCompoundPredicate(orPredicateWithSubpredicates: rejects)
        return NSCompoundPredicate(andPredicateWithSubpredicates: [Self.analyzedPredicate, any])
    }

    /// Analyzed photos that pass every checked criterion.
    var selectPredicate: NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            Self.analyzedPredicate, NSCompoundPredicate(notPredicateWithSubpredicate: rejectPredicate),
        ])
    }
}

extension CullingScores {
    /// The scores stored on `photo`.
    @MainActor init(_ photo: Photo) {
        self.init()
        subjectFocus = photo.cullSubjectFocus
        eyeFocus = photo.cullEyeFocus
        eyesOpenMin = photo.cullEyesOpenMin
        eyesOpenMax = photo.cullEyesOpenMax
        faceCount = Int(photo.cullFaceCount)
        exposureIssue = photo.cullExposureIssue
        misfire = photo.cullMisfire
        document = photo.cullDocument
        quality = photo.cullQuality
        focusPending = photo.cullFocusPending
    }
}

/// The Assisted Culling panel's Review (RAW-71): the grid shows only the source's Selects or Rejects by
/// `criteria`, on top of the Library Filter bar. All is no review.
nonisolated struct CullingReview: Equatable, Sendable {
    enum Kind: Int, Sendable {
        case selects, rejects
    }

    var kind: Kind
    var criteria: CullingCriteria

    var predicate: NSPredicate {
        kind == .selects ? criteria.selectPredicate : criteria.rejectPredicate
    }
}
