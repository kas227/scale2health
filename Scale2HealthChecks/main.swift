import Foundation
import Scale2HealthCore

@discardableResult
func check(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    return true
}

let now = Date(timeIntervalSince1970: 1_700_000_000)
check(BS444Protocol.support(for: "013197123456")?.variant == .bs444OrBs440, "known BS444 name")
check(BS444Protocol.support(for: "0203B123456")?.variant == .bs430, "known BS430 name")
check(BS444Protocol.support(for: "unknown", advertisedServices: [BS444Protocol.serviceUUID])?.variant == .bs44x, "service-based support")
check(BS444Protocol.support(for: "not a scale") == nil, "unrelated device rejection")
check(Array(BS444Protocol.timeCommand(date: now, epochMode: .unix)) == [0x02, 0x00, 0xF1, 0x53, 0x65], "Unix clock command")

func weightPacket(weightRaw: UInt16, timestamp: UInt32) -> Data {
    var bytes = [UInt8](repeating: 0, count: BS444Protocol.weightFrameLength)
    bytes[1] = UInt8(truncatingIfNeeded: weightRaw)
    bytes[2] = UInt8(truncatingIfNeeded: weightRaw >> 8)
    bytes[5] = UInt8(truncatingIfNeeded: timestamp)
    bytes[6] = UInt8(truncatingIfNeeded: timestamp >> 8)
    bytes[7] = UInt8(truncatingIfNeeded: timestamp >> 16)
    bytes[8] = UInt8(truncatingIfNeeded: timestamp >> 24)
    return Data(bytes)
}

func featurePacket(fat: UInt16, water: UInt16, muscle: UInt16, bone: UInt16) -> Data {
    var bytes = [UInt8](repeating: 0, count: BS444Protocol.featureFrameLength)
    for (offset, value) in [(8, fat), (10, water), (12, muscle), (14, bone)] {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    return Data(bytes)
}

var decoder = BS444TimestampDecoder()
let weight = try BS444Parser.parseWeight(
    weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000),
    now: now,
    timestampDecoder: &decoder
)
check(weight.weightKg == 72.34, "weight decoding")
check(weight.timestamp == now, "timestamp decoding")
check(weight.epochMode == .unix, "Unix epoch detection")

let feature = try BS444Parser.parseFeature(
    featurePacket(fat: 0x80EA, water: 556, muscle: 402, bone: 31)
)
check(feature.bodyFatPercent == 23.4, "fat decoding")
check(feature.bodyWaterPercent == 55.6, "water decoding")
check(feature.musclePercent == 40.2, "muscle decoding")
check(feature.boneMassKg == 3.1, "bone decoding")

var session = BS444Session(epochMode: .unix)
let weightFirstPart = try session.receiveWeight(Data(weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000).prefix(4)), now: now)
check(weightFirstPart == nil, "partial weight buffering")
let weightSecondPart = try session.receiveWeight(Data(weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000).dropFirst(4)), now: now)
check(weightSecondPart == nil, "weight waits for feature")
let measurement = try session.receiveFeature(featurePacket(fat: 234, water: 556, muscle: 402, bone: 31), now: now)
check(measurement?.weightKg == 72.34, "session aggregation")
check(measurement?.bodyFatPercent == 23.4, "session body composition")

var buffer = BS444FrameBuffer(frameLength: 3)
check(buffer.append(Data([1])).isEmpty, "buffer holds incomplete frame")
check(buffer.append(Data([2, 3, 4, 5, 6])).count == 2, "buffer emits multiple frames")

do {
    var invalidDecoder = BS444TimestampDecoder()
    _ = try BS444Parser.parseWeight(
        Data(repeating: 0, count: 8),
        now: now,
        timestampDecoder: &invalidDecoder
    )
    check(false, "short weight packet rejection")
} catch let error as BS444ParseError {
    check(error == .insufficientData(expected: 9, actual: 8), "short weight packet error")
} catch {
    check(false, "short weight packet error type")
}

var zeroSession = BS444Session(epochMode: .unix)
let zeroWeightResult = try zeroSession.receiveWeight(
    weightPacket(weightRaw: 0, timestamp: 1_700_000_000),
    now: now
)
check(zeroWeightResult == nil, "zero weight is not published")
let zeroFeatureResult = try zeroSession.receiveFeature(
    featurePacket(fat: 234, water: 556, muscle: 402, bone: 31),
    now: now
)
check(zeroFeatureResult == nil, "zero weight remains ignored")

let dedupeDefaults = UserDefaults(suiteName: "Scale2HealthCoreChecks.\(UUID().uuidString)")!
let deduplicator = MeasurementDeduplicator(defaults: dedupeDefaults)
check(!deduplicator.contains(measurement!), "new measurement is accepted")
deduplicator.remember(measurement!)
check(deduplicator.contains(measurement!), "duplicate measurement is detected")

var legacyDecoder = BS444TimestampDecoder(mode: .unix)
let legacyRaw = UInt32(1_700_000_000 - Int64(BS444Protocol.scaleEpochOffset))
check(legacyDecoder.decode(raw: legacyRaw, now: now).mode == .from2010, "legacy epoch correction")

print("Scale2Health core checks passed")
