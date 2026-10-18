import Foundation

/// Lightroom's preset Amount: a preset applied at 0–200%, between the photo's settings before it (0%)
/// and with it (100%), and past it.
///
/// Every setting is interpolated from the two encoded settings, so new settings are covered without
/// listing them: numbers go between (and beyond) the two values; on/off settings, names and lists
/// whose length differs (curves with other points) switch at 50%.
nonisolated enum PresetAmount {
    static let range: ClosedRange<Double> = 0...2

    static func settings(before: PhotoAdjustments, full: PhotoAdjustments, amount: Double) -> PhotoAdjustments {
        let t = amount.clamped(to: range)
        if t == 1 { return full }
        if t == 0 { return before }
        let encoder = JSONEncoder()
        guard let a = try? JSONSerialization.jsonObject(with: encoder.encode(before)),
              let b = try? JSONSerialization.jsonObject(with: encoder.encode(full)),
              let data = try? JSONSerialization.data(withJSONObject: mix(a, b, t)),
              let result = try? JSONDecoder().decode(PhotoAdjustments.self, from: data) else { return t < 0.5 ? before : full }
        return result
    }

    private static func mix(_ a: Any, _ b: Any, _ t: Double) -> Any {
        switch (a, b) {
        case let (x as NSNumber, y as NSNumber) where !isBool(x) && !isBool(y):
            let value = x.doubleValue + (y.doubleValue - x.doubleValue) * t
            // Whole numbers (seeds, counts, styles) stay whole.
            return isInteger(x) && isInteger(y) ? NSNumber(value: (value).rounded()) : NSNumber(value: value)
        case let (x as [String: Any], y as [String: Any]):
            var result: [String: Any] = [:]
            for key in Set(x.keys).union(y.keys) {
                switch (x[key], y[key]) {
                case let (left?, right?): result[key] = mix(left, right, t)
                case let (left?, nil): if t < 0.5 { result[key] = left }
                case let (nil, right?): if t >= 0.5 { result[key] = right }
                default: break
                }
            }
            return result
        case let (x as [Any], y as [Any]) where x.count == y.count:
            return zip(x, y).map { mix($0, $1, t) }
        default:
            return t < 0.5 ? a : b
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func isInteger(_ number: NSNumber) -> Bool {
        !CFNumberIsFloatType(number) && number.doubleValue == number.doubleValue.rounded()
    }
}
