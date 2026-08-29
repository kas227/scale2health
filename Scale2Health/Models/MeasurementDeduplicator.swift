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
            measurement.scaleUserID.map { String($0) } ?? "-",
            String(measurement.weightKg),
            optionalPart(measurement.bodyFatPercent),
            optionalPart(measurement.bodyWaterPercent),
            optionalPart(measurement.musclePercent),
            optionalPart(measurement.boneMassKg)
        ].joined(separator: "|")
    }

    public func contains(_ measurement: BodyMeasurement) -> Bool {
        let values = recentFingerprints
        return values.contains(fingerprint(for: measurement))
            || values.contains(legacyFingerprint(for: measurement))
    }

    public func remember(_ measurement: BodyMeasurement) {
        let value = fingerprint(for: measurement)
        let legacyValue = legacyFingerprint(for: measurement)
        var values = recentFingerprints.filter { $0 != value && $0 != legacyValue }
        values.append(value)
        defaults.set(Array(values.suffix(capacity)), forKey: key)
    }

    private var recentFingerprints: [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    /// Fingerprint format used before scale user IDs were decoded.
    private func legacyFingerprint(for measurement: BodyMeasurement) -> String {
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

    private func optionalPart(_ value: Double?) -> String {
        value.map { String($0) } ?? "-"
    }
}
