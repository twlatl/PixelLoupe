import CoreData
import Foundation
import ImageIO
import Vision

/// Auto Stack (RAW-71): groups photos taken one after another into stacks, by the time between them or by how
/// alike they look. Photos are taken in capture-time order, and a photo joins the stack of the one before it when
/// it's close enough; only runs of two or more become stacks.
nonisolated enum AutoStacking {
    enum Method: Int, CaseIterable, Sendable {
        case captureTime, similarity

        var title: String {
            switch self {
            case .captureTime: "By Capture Time"
            case .similarity: "By Visual Similarity"
            }
        }
    }

    /// The gaps the Capture Time slider offers, in seconds.
    static let gapRange: ClosedRange<Double> = 1...3600
    static let defaultGap: TimeInterval = 60

    /// Feature-print distances: the most alike two photos need to be at Strict and Loose. Measured on the sample
    /// library: an exposure bracket is about 0.13, the same subject posed again 0.2, the same party from another
    /// spot 0.28, and a different scene or the same product from another side 0.3 and over.
    static let strictDistance = 0.08
    static let looseDistance = 0.45

    /// The distance two photos may be apart at `strictness` (0 Loose to 1 Strict).
    static func threshold(strictness: Double) -> Double {
        let strictness = strictness.clamped(to: 0...1)
        return looseDistance * (1 - strictness) + strictDistance * strictness
    }

    /// Runs of photos that each join the one before: `joins[i]` says whether photo `i` joins photo `i - 1`
    /// (`joins[0]` is ignored). Only runs of two or more are returned, as indices.
    static func groups(joining joins: [Bool]) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        for (index, joins) in joins.enumerated() {
            if index > 0, joins {
                current.append(index)
            } else {
                if current.count >= 2 { groups.append(current) }
                current = [index]
            }
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    /// Whether each photo was taken within `gap` of the one before.
    static func joins(dates: [Date], gap: TimeInterval) -> [Bool] {
        dates.indices.map { index in
            index > 0 && abs(dates[index].timeIntervalSince(dates[index - 1])) <= gap
        }
    }

    /// Whether each photo looks like the one before: `distances[i]` is photo `i`'s distance to photo `i - 1`, nil
    /// when either couldn't be measured.
    static func joins(distances: [Double?], strictness: Double) -> [Bool] {
        let threshold = threshold(strictness: strictness)
        return distances.map { $0.map { $0 <= threshold } ?? false }
    }

    /// The distance from each image to the one before (nil for the first, and where an image couldn't be read),
    /// from Vision feature prints of the thumbnails at `urls`. `progress` is told how many are done.
    @concurrent
    static func distances(_ urls: [URL], progress: @escaping @MainActor @Sendable (Int) -> Void) async -> [Double?] {
        var distances: [Double?] = []
        var previous: FeaturePrintObservation?
        for (index, url) in urls.enumerated() {
            if Task.isCancelled { return [] }
            let print = await featurePrint(of: url)
            distances.append(print.flatMap { print in previous.flatMap { try? print.distance(to: $0) } })
            previous = print
            await progress(index + 1)
        }
        return distances
    }

    private static func featurePrint(of url: URL) async -> FeaturePrintObservation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try? await GenerateImageFeaturePrintRequest().perform(on: image)
    }
}

extension AutoStacking {
    /// The photo to put on top of a stack: the best Select by Vision's aesthetics score, else the best photo
    /// analyzed, else the first (earliest).
    @MainActor static func top(of photos: [Photo], criteria: CullingCriteria) -> Photo? {
        let analyzed = photos.filter { $0.cullVersion == CullingAnalyzer.version && $0.cullQuality >= 0 }
        guard !analyzed.isEmpty else { return photos.first }
        let selects = analyzed.filter { criteria.verdict(for: $0) == .select }
        return (selects.isEmpty ? analyzed : selects).max { $0.cullQuality < $1.cullQuality }
    }
}

extension PhotoEditing {
    /// Makes each group of photos (in capture-time order) a stack, its best photo on top (see
    /// `AutoStacking.top(of:criteria:)`), as one undoable step. Stacks are left open so every photo stays in sight.
    /// Returns the number of stacks made.
    @discardableResult
    func autoStack(_ groups: [[NSManagedObjectID]], criteria: CullingCriteria) -> Int {
        let context = store.viewContext
        var made = 0
        for group in groups {
            let members = photos(group).filter { $0.stack == nil }
            guard members.count >= 2, let top = AutoStacking.top(of: members, criteria: criteria) else { continue }
            let stack = PhotoStack(context: context)
            stack.isCollapsed = false
            for photo in members { photo.stack = stack }
            stack.renumber([top] + members.filter { $0 !== top })
            made += 1
        }
        guard made > 0 else { return 0 }
        context.processPendingChanges()
        context.undoManager?.setActionName("Auto Stack")
        store.save()
        return made
    }
}
