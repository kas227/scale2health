import Foundation

public enum BS444ParseError: Error, Equatable, CustomStringConvertible {
    case insufficientData(expected: Int, actual: Int)
    case unsupportedWeightUnit(UInt8)

    public var description: String {
        switch self {
        case let .insufficientData(expected, actual):
            return "BS444 packet is too short (expected at least \(expected) bytes, got \(actual))"
        case let .unsupportedWeightUnit(value):
            return "BS444 packet uses unsupported weight unit flag \(value)"
        }
    }
}

public struct BS444WeightPacket: Equatable, Sendable {
    public let weightKg: Double
    public let sourceUnit: BS444WeightUnit
    public let userID: UInt8?
    public let timestamp: Date
    public let rawTimestamp: UInt32
    public let epochMode: BS444EpochMode
}

public struct BS444FeaturePacket: Equatable, Sendable {
    public let userID: UInt8?
    public let bodyFatPercent: Double?
    public let bodyWaterPercent: Double?
    public let musclePercent: Double?
    public let boneMassKg: Double?
}

/// Converts scale timestamps while correcting the legacy 2010 epoch used by BS444/BS440.
public struct BS444TimestampDecoder: Sendable {
    public private(set) var mode: BS444EpochMode?
    private let proximity: TimeInterval

    public init(mode: BS444EpochMode? = nil, proximity: TimeInterval = 90 * 24 * 60 * 60) {
        self.mode = mode
        self.proximity = proximity
    }

    public mutating func decode(raw: UInt32, now: Date) -> (date: Date, mode: BS444EpochMode) {
        let rawSeconds = TimeInterval(raw)
        let unixDate = Date(timeIntervalSince1970: rawSeconds)
        let from2010Date = Date(timeIntervalSince1970: rawSeconds + TimeInterval(BS444Protocol.scaleEpochOffset))
        let nowInterval = now.timeIntervalSince1970
        let unixIsNear = abs(unixDate.timeIntervalSince1970 - nowInterval) <= proximity
        let from2010IsNear = abs(from2010Date.timeIntervalSince1970 - nowInterval) <= proximity

        let selected: BS444EpochMode
        switch mode {
        case .unix:
            selected = !unixIsNear && from2010IsNear ? .from2010 : .unix
        case .from2010:
            selected = !from2010IsNear && unixIsNear ? .unix : .from2010
        case nil:
            if unixIsNear {
                selected = .unix
            } else if from2010IsNear {
                selected = .from2010
            } else {
                selected = .unix
            }
        }

        mode = selected
        let date = selected == .unix ? unixDate : from2010Date
        return (date, selected)
    }
}

/// Fixed-size buffering is sufficient for these notifications and also handles ATT fragments in tests.
public struct BS444FrameBuffer: Sendable {
    public let frameLength: Int
    private var storage = Data()
    private let maximumBufferedFrames: Int

    public init(frameLength: Int, maximumBufferedFrames: Int = 4) {
        precondition(frameLength > 0)
        precondition(maximumBufferedFrames > 0)
        self.frameLength = frameLength
        self.maximumBufferedFrames = maximumBufferedFrames
    }

    public mutating func append(_ fragment: Data) -> [Data] {
        guard !fragment.isEmpty else { return [] }
        storage.append(fragment)
        let maximumBytes = frameLength * maximumBufferedFrames
        if storage.count > maximumBytes {
            storage = Data(storage.suffix(maximumBytes))
        }

        var frames: [Data] = []
        while storage.count >= frameLength {
            frames.append(Data(storage.prefix(frameLength)))
            storage.removeFirst(frameLength)
        }
        return frames
    }

    public mutating func reset() {
        storage.removeAll(keepingCapacity: true)
    }
}

public enum BS444Parser {
    public static func parseWeight(
        _ data: Data,
        now: Date,
        timestampDecoder: inout BS444TimestampDecoder
    ) throws -> BS444WeightPacket {
        guard data.count >= BS444Protocol.weightFrameLength else {
            throw BS444ParseError.insufficientData(
                expected: BS444Protocol.weightFrameLength,
                actual: data.count
            )
        }

        let rawUnit = (data[0] >> 5) & 0x03
        guard let sourceUnit = BS444WeightUnit(rawValue: rawUnit) else {
            throw BS444ParseError.unsupportedWeightUnit(rawUnit)
        }
        let rawWeight = littleEndianUInt16(data, offset: 1)
        let rawTimestamp = littleEndianUInt32(data, offset: 5)
        let decodedTime = timestampDecoder.decode(raw: rawTimestamp, now: now)
        return BS444WeightPacket(
            weightKg: weightInKilograms(rawWeight, unit: sourceUnit),
            sourceUnit: sourceUnit,
            userID: decodeUserID(data[13]),
            timestamp: decodedTime.date,
            rawTimestamp: rawTimestamp,
            epochMode: decodedTime.mode
        )
    }

    public static func parseFeature(_ data: Data) throws -> BS444FeaturePacket {
        guard data.count >= BS444Protocol.featureFrameLength else {
            throw BS444ParseError.insufficientData(
                expected: BS444Protocol.featureFrameLength,
                actual: data.count
            )
        }

        return BS444FeaturePacket(
            userID: decodeUserID(data[5]),
            bodyFatPercent: positiveOrNil(decode12BitTenth(data, offset: 8)),
            bodyWaterPercent: positiveOrNil(decode12BitTenth(data, offset: 10)),
            musclePercent: positiveOrNil(decode12BitTenth(data, offset: 12)),
            boneMassKg: positiveOrNil(decode12BitTenth(data, offset: 14))
        )
    }

    private static func weightInKilograms(_ rawWeight: UInt16, unit: BS444WeightUnit) -> Double {
        let scalar = Double(rawWeight) / 100.0
        switch unit {
        case .kilograms:
            return scalar
        case .pounds, .stonesAndPounds:
            // Stone mode still carries one imperial scalar, so it is normalized as total pounds.
            return scalar * 0.453_592_37
        }
    }

    private static func decodeUserID(_ rawValue: UInt8) -> UInt8? {
        (1...8).contains(rawValue) ? rawValue : nil
    }

    private static func positiveOrNil(_ value: Double) -> Double? {
        value > 0 ? value : nil
    }

    private static func decode12BitTenth(_ data: Data, offset: Int) -> Double {
        Double(littleEndianUInt16(data, offset: offset) & 0x0FFF) / 10.0
    }

    private static func littleEndianUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}

/// Joins weight and feature notifications. The scale normally sends weight first, but feature-first
/// ordering is accepted so the parser remains useful with buffered/replayed notifications.
public struct BS444Session: Sendable {
    private struct PendingWeight: Sendable {
        let packet: BS444WeightPacket
        let receivedAt: Date
    }

    private struct PendingFeature: Sendable {
        let packet: BS444FeaturePacket
        let receivedAt: Date
    }

    private var weightBuffer = BS444FrameBuffer(frameLength: BS444Protocol.weightFrameLength)
    private var featureBuffer = BS444FrameBuffer(frameLength: BS444Protocol.featureFrameLength)
    private var timestampDecoder: BS444TimestampDecoder
    private var pendingWeight: PendingWeight?
    private var pendingFeature: PendingFeature?
    private let pairingWindow: TimeInterval

    public init(epochMode: BS444EpochMode? = nil, pairingWindow: TimeInterval = 10) {
        self.timestampDecoder = BS444TimestampDecoder(mode: epochMode)
        self.pairingWindow = pairingWindow
    }

    public var epochMode: BS444EpochMode? { timestampDecoder.mode }

    public mutating func receiveWeight(_ fragment: Data, now: Date) throws -> [BodyMeasurement] {
        expireStaleData(at: now)
        var measurements: [BodyMeasurement] = []
        for frame in weightBuffer.append(fragment) {
            let packet = try BS444Parser.parseWeight(
                frame,
                now: now,
                timestampDecoder: &timestampDecoder
            )
            pendingWeight = PendingWeight(packet: packet, receivedAt: now)
            if let measurement = makeMeasurementIfReady() {
                measurements.append(measurement)
            }
        }
        return measurements
    }

    public mutating func receiveFeature(_ fragment: Data, now: Date) throws -> [BodyMeasurement] {
        expireStaleData(at: now)
        var measurements: [BodyMeasurement] = []
        for frame in featureBuffer.append(fragment) {
            let packet = try BS444Parser.parseFeature(frame)
            pendingFeature = PendingFeature(packet: packet, receivedAt: now)
            if let measurement = makeMeasurementIfReady() {
                measurements.append(measurement)
            }
        }
        return measurements
    }

    public mutating func reset() {
        weightBuffer.reset()
        featureBuffer.reset()
        pendingWeight = nil
        pendingFeature = nil
    }

    private mutating func expireStaleData(at date: Date) {
        if let pendingWeight, date.timeIntervalSince(pendingWeight.receivedAt) > pairingWindow {
            self.pendingWeight = nil
        }
        if let pendingFeature, date.timeIntervalSince(pendingFeature.receivedAt) > pairingWindow {
            self.pendingFeature = nil
        }
    }

    private mutating func makeMeasurementIfReady() -> BodyMeasurement? {
        guard let pendingWeight, let pendingFeature else { return nil }
        guard pendingWeight.packet.weightKg > 0 else {
            self.pendingWeight = nil
            return nil
        }
        guard pendingWeight.packet.userID == pendingFeature.packet.userID else {
            // Never combine body composition from one scale user with another user's weight.
            self.pendingWeight = nil
            self.pendingFeature = nil
            return nil
        }
        let measurement = BodyMeasurement(
            timestamp: pendingWeight.packet.timestamp,
            weightKg: pendingWeight.packet.weightKg,
            scaleUserID: pendingWeight.packet.userID,
            sourceWeightUnit: pendingWeight.packet.sourceUnit,
            bodyFatPercent: pendingFeature.packet.bodyFatPercent,
            bodyWaterPercent: pendingFeature.packet.bodyWaterPercent,
            musclePercent: pendingFeature.packet.musclePercent,
            boneMassKg: pendingFeature.packet.boneMassKg
        )
        self.pendingWeight = nil
        self.pendingFeature = nil
        return measurement
    }
}
