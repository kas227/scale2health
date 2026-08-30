import Foundation

/// A BS444 measurement normalized to the units used by the app.
public struct BodyMeasurement: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let weightKg: Double
    /// Raw protocol values used to identify a weighing across repeated history dumps.
    public let rawTimestamp: UInt32?
    public let rawWeight: UInt16?
    /// User slot selected by the scale (1...8), or nil for an unassigned measurement.
    public let scaleUserID: UInt8?
    /// Unit encoded by the scale; weightKg is always normalized to kilograms.
    public let sourceWeightUnit: BS444WeightUnit
    public let bodyFatPercent: Double?
    public let bodyWaterPercent: Double?
    /// The BS444 feature packet reports muscle as a percentage, not a mass.
    public let musclePercent: Double?
    public let boneMassKg: Double?

    public init(
        timestamp: Date,
        weightKg: Double,
        rawTimestamp: UInt32? = nil,
        rawWeight: UInt16? = nil,
        scaleUserID: UInt8? = nil,
        sourceWeightUnit: BS444WeightUnit = .kilograms,
        bodyFatPercent: Double? = nil,
        bodyWaterPercent: Double? = nil,
        musclePercent: Double? = nil,
        boneMassKg: Double? = nil
    ) {
        self.timestamp = timestamp
        self.weightKg = weightKg
        self.rawTimestamp = rawTimestamp
        self.rawWeight = rawWeight
        self.scaleUserID = scaleUserID
        self.sourceWeightUnit = sourceWeightUnit
        self.bodyFatPercent = bodyFatPercent
        self.bodyWaterPercent = bodyWaterPercent
        self.musclePercent = musclePercent
        self.boneMassKg = boneMassKg
    }

    public var hasBodyComposition: Bool {
        bodyFatPercent != nil || bodyWaterPercent != nil || musclePercent != nil || boneMassKg != nil
    }
}
