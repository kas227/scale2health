import Foundation

/// A BS444 measurement normalized to the units used by the app.
public struct BodyMeasurement: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let weightKg: Double
    public let bodyFatPercent: Double?
    public let bodyWaterPercent: Double?
    /// The BS444 feature packet reports muscle as a percentage, not a mass.
    public let musclePercent: Double?
    public let boneMassKg: Double?

    public init(
        timestamp: Date,
        weightKg: Double,
        bodyFatPercent: Double? = nil,
        bodyWaterPercent: Double? = nil,
        musclePercent: Double? = nil,
        boneMassKg: Double? = nil
    ) {
        self.timestamp = timestamp
        self.weightKg = weightKg
        self.bodyFatPercent = bodyFatPercent
        self.bodyWaterPercent = bodyWaterPercent
        self.musclePercent = musclePercent
        self.boneMassKg = boneMassKg
    }

    public var hasBodyComposition: Bool {
        bodyFatPercent != nil || bodyWaterPercent != nil || musclePercent != nil || boneMassKg != nil
    }
}
