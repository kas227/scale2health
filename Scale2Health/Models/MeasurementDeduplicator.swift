import Foundation

/// Prevents the same scale timestamp/value tuple from being written repeatedly after
/// duplicate notifications or a reconnect. Only a small recent history is retained.
public final class MeasurementDeduplicator {
    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int

    public init(
        defaults: UserDefaults = .standard,
        key: String = "recentMeasurementFingerprints",
        capacity: Int = 32
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = max(1, capacity)
    }

    public func fingerprint(for measurement: BodyMeasurement) -> String {
        let timestamp = Int64(measurement.timestamp.timeIntervalSince1970.rounded())
        return [
            String(timestamp),
            String(measurement.weightKg),
            optionalPart(measurement.bodyFatPercent),
            optionalPart(measurement.bodyWaterPercent),
            optionalPart(measurement.musclePercent),
            optionalPart(measurement.boneMassKg)
        ].joined(separator: "|")
    }

    public func contains(_ measurement: BodyMeasurement) -> Bool {
        recentFingerprints.contains(fingerprint(for: measurement))
    }

    public func remember(_ measurement: BodyMeasurement) {
        let value = fingerprint(for: measurement)
        var values = recentFingerprints.filter { $0 != value }
        values.append(value)
        defaults.set(Array(values.suffix(capacity)), forKey: key)
    }

    private var recentFingerprints: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    private func optionalPart(_ value: Double?) -> String {
        value.map { String($0) } ?? "-"
    }
}
