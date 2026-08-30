import Foundation

/// Prevents repeated history dumps from writing the same scale record more than once.
public final class MeasurementDeduplicator {
    private let defaults: UserDefaults
    private let key: String
    private let capacity: Int

    public init(
        defaults: UserDefaults = .standard,
        key: String = "recentMeasurementFingerprints",
        capacity: Int = 512
    ) {
        self.defaults = defaults
        self.key = key
        self.capacity = max(1, capacity)
    }

    public func fingerprint(for measurement: BodyMeasurement, sourceDeviceIdentifier: String? = nil) -> String {
        let timestamp = measurement.rawTimestamp.map(String.init)
            ?? String(Int64(measurement.timestamp.timeIntervalSince1970.rounded()))
        let weight = measurement.rawWeight.map(String.init) ?? String(measurement.weightKg)
        return [
            "v2",
            sourceDeviceIdentifier ?? "-",
            String(timestamp),
            measurement.scaleUserID.map { String($0) } ?? "-",
            weight
        ].joined(separator: "|")
    }

    public func contains(_ measurement: BodyMeasurement, sourceDeviceIdentifier: String? = nil) -> Bool {
        let values = recentFingerprints
        return values.contains(fingerprint(for: measurement, sourceDeviceIdentifier: sourceDeviceIdentifier))
            || values.contains(previousFingerprint(for: measurement))
            || values.contains(legacyFingerprint(for: measurement))
    }

    public func remember(_ measurement: BodyMeasurement, sourceDeviceIdentifier: String? = nil) {
        let value = fingerprint(for: measurement, sourceDeviceIdentifier: sourceDeviceIdentifier)
        let previousValue = previousFingerprint(for: measurement)
        let legacyValue = legacyFingerprint(for: measurement)
        var values = recentFingerprints.filter { $0 != value && $0 != previousValue && $0 != legacyValue }
        values.append(value)
        defaults.set(Array(values.suffix(capacity)), forKey: key)
    }

    /// Fingerprint format used before history records were namespaced per scale.
    private func previousFingerprint(for measurement: BodyMeasurement) -> String {
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
