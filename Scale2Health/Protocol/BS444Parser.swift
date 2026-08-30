// Portions of the BS44x protocol implementation are adapted from openScale's
// MedisanaBs44xHandler, Copyright (C) 2025 olie.xdev, licensed GPL-3.0-or-later.
// Modified for Scale2Health in 2026 and distributed under GPL-3.0-only.
// See LICENSE and THIRD_PARTY_NOTICES.md.

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
    public let rawWeight: UInt16
    public let weightKg: Double
    public let sourceUnit: BS444WeightUnit
    public let userID: UInt8?
    public let timestamp: Date
    public let rawTimestamp: UInt32
    public let epochMode: BS444EpochMode
}

public struct BS444FeaturePacket: Equatable, Sendable {
    public let userID: UInt8?
    public let rawTimestamp: UInt32
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
        let earliestSupported = TimeInterval(BS444Protocol.scaleEpochOffset)
        let latestSupported = nowInterval + 24 * 60 * 60
        let unixIsPlausible = (earliestSupported...latestSupported).contains(unixDate.timeIntervalSince1970)
        let from2010IsPlausible = (earliestSupported...latestSupported).contains(from2010Date.timeIntervalSince1970)

        let selected: BS444EpochMode
        switch mode {
        case .unix:
            selected = (!unixIsPlausible && from2010IsPlausible) || (!unixIsNear && from2010IsNear)
                ? .from2010
                : .unix
        case .from2010:
            selected = (!from2010IsPlausible && unixIsPlausible) || (!from2010IsNear && unixIsNear)
                ? .unix
                : .from2010
        case nil:
            if unixIsPlausible && !from2010IsPlausible {
                selected = .unix
            } else if from2010IsPlausible && !unixIsPlausible {
                selected = .from2010
            } else if unixIsNear {
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
            rawWeight: rawWeight,
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
            rawTimestamp: littleEndianUInt32(data, offset: 1),
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

/// Joins live and historical notifications by their protocol identity. History dumps can contain
/// all weight frames before all feature frames, so notification order is not a safe correlation key.
public struct BS444Session: Sendable {
    private struct MeasurementKey: Hashable, Sendable {
        let userID: UInt8?
        let rawTimestamp: UInt32
    }

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
    private var pendingWeights: [MeasurementKey: PendingWeight] = [:]
    private var pendingFeatures: [MeasurementKey: PendingFeature] = [:]
    private let pairingWindow: TimeInterval
    private let maximumPendingRecords: Int

    public init(
        epochMode: BS444EpochMode? = nil,
        pairingWindow: TimeInterval = 60,
        maximumPendingRecords: Int = 64
    ) {
        self.timestampDecoder = BS444TimestampDecoder(mode: epochMode)
        self.pairingWindow = pairingWindow
        self.maximumPendingRecords = max(1, maximumPendingRecords)
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
            let key = MeasurementKey(userID: packet.userID, rawTimestamp: packet.rawTimestamp)
            pendingWeights[key] = PendingWeight(packet: packet, receivedAt: now)
            trimPendingRecords()
            if let measurement = makeMeasurementIfReady(for: key, now: now) {
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
            let key = MeasurementKey(userID: packet.userID, rawTimestamp: packet.rawTimestamp)
            pendingFeatures[key] = PendingFeature(packet: packet, receivedAt: now)
            trimPendingRecords()
            if let measurement = makeMeasurementIfReady(for: key, now: now) {
                measurements.append(measurement)
            }
        }
        return measurements
    }

    public mutating func reset() {
        weightBuffer.reset()
        featureBuffer.reset()
        pendingWeights.removeAll(keepingCapacity: true)
        pendingFeatures.removeAll(keepingCapacity: true)
    }

    private mutating func expireStaleData(at date: Date) {
        pendingWeights = pendingWeights.filter { date.timeIntervalSince($0.value.receivedAt) <= pairingWindow }
        pendingFeatures = pendingFeatures.filter { date.timeIntervalSince($0.value.receivedAt) <= pairingWindow }
    }

    private mutating func trimPendingRecords() {
        while pendingWeights.count > maximumPendingRecords,
              let oldest = pendingWeights.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
            pendingWeights.removeValue(forKey: oldest)
        }
        while pendingFeatures.count > maximumPendingRecords,
              let oldest = pendingFeatures.min(by: { $0.value.receivedAt < $1.value.receivedAt })?.key {
            pendingFeatures.removeValue(forKey: oldest)
        }
    }

    private mutating func makeMeasurementIfReady(for key: MeasurementKey, now: Date) -> BodyMeasurement? {
        guard let pendingWeight = pendingWeights[key], pendingFeatures[key] != nil else { return nil }
        pendingWeights.removeValue(forKey: key)
        let pendingFeature = pendingFeatures.removeValue(forKey: key)!
        guard pendingWeight.packet.weightKg > 0, pendingWeight.packet.rawTimestamp != 0 else {
            return nil
        }
        let earliestSupportedDate = Date(timeIntervalSince1970: TimeInterval(BS444Protocol.scaleEpochOffset))
        guard pendingWeight.packet.timestamp >= earliestSupportedDate,
              pendingWeight.packet.timestamp <= now.addingTimeInterval(24 * 60 * 60) else {
            return nil
        }
        let measurement = BodyMeasurement(
            timestamp: pendingWeight.packet.timestamp,
            weightKg: pendingWeight.packet.weightKg,
            rawTimestamp: pendingWeight.packet.rawTimestamp,
            rawWeight: pendingWeight.packet.rawWeight,
            scaleUserID: pendingWeight.packet.userID,
            sourceWeightUnit: pendingWeight.packet.sourceUnit,
            bodyFatPercent: pendingFeature.packet.bodyFatPercent,
            bodyWaterPercent: pendingFeature.packet.bodyWaterPercent,
            musclePercent: pendingFeature.packet.musclePercent,
            boneMassKg: pendingFeature.packet.boneMassKg
        )
        return measurement
    }
}
