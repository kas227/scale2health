import Foundation
import XCTest
@testable import Scale2Health

final class BS444ParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testUUIDsUseBluetoothBaseUUID() {
        XCTAssertEqual(BS444Protocol.serviceUUID.uuidString, "000078B2-0000-1000-8000-00805F9B34FB")
        XCTAssertEqual(BS444Protocol.weightCharacteristicUUID.uuidString, "00008A21-0000-1000-8000-00805F9B34FB")
        XCTAssertEqual(BS444Protocol.featureCharacteristicUUID.uuidString, "00008A22-0000-1000-8000-00805F9B34FB")
        XCTAssertEqual(BS444Protocol.commandCharacteristicUUID.uuidString, "00008A81-0000-1000-8000-00805F9B34FB")
    }

    func testKnownDeviceNamesAndServiceAreRecognized() {
        XCTAssertEqual(
            BS444Protocol.support(for: "013197123456")?.variant,
            .bs444OrBs440
        )
        XCTAssertEqual(
            BS444Protocol.support(for: "0203B123456")?.variant,
            .bs430
        )
        XCTAssertEqual(
            BS444Protocol.support(for: "unknown", advertisedServices: [BS444Protocol.serviceUUID])?.variant,
            .bs44x
        )
        XCTAssertNil(BS444Protocol.support(for: "not a scale"))
        XCTAssertEqual(BS444Protocol.predictedEpochMode(for: "013198ABC"), .from2010)
        XCTAssertEqual(BS444Protocol.predictedEpochMode(for: "0203bABC"), .unix)
    }

    func testTimeCommandUsesUnixEpoch() {
        let command = BS444Protocol.timeCommand(date: now, epochMode: .unix)
        XCTAssertEqual(Array(command), [0x02, 0x00, 0xF1, 0x53, 0x65])
    }

    func testTimeCommandUses2010Epoch() {
        let command = BS444Protocol.timeCommand(date: now, epochMode: .from2010)
        let expected = UInt32(1_700_000_000 - Int64(BS444Protocol.scaleEpochOffset))
        XCTAssertEqual(command.first, 0x02)
        XCTAssertEqual(Array(command.dropFirst()), [
            UInt8(truncatingIfNeeded: expected),
            UInt8(truncatingIfNeeded: expected >> 8),
            UInt8(truncatingIfNeeded: expected >> 16),
            UInt8(truncatingIfNeeded: expected >> 24)
        ])
    }

    func testWeightPacketDecodesWeightAndTimestamp() throws {
        var decoder = BS444TimestampDecoder()
        let packet = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000)
        let result = try BS444Parser.parseWeight(packet, now: now, timestampDecoder: &decoder)

        XCTAssertEqual(result.weightKg, 72.34, accuracy: 0.0001)
        XCTAssertEqual(result.timestamp, now)
        XCTAssertEqual(result.epochMode, .unix)
        XCTAssertEqual(decoder.mode, .unix)
    }

    func testFeaturePacketMasksFlagsAndTreatsZeroAsAbsent() throws {
        let packet = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1, highBits: 0x8000)
        let result = try BS444Parser.parseFeature(packet)

        XCTAssertEqual(result.bodyFatPercent ?? -1, 23.4, accuracy: 0.0001)
        XCTAssertEqual(result.bodyWaterPercent ?? -1, 55.6, accuracy: 0.0001)
        XCTAssertEqual(result.musclePercent ?? -1, 40.2, accuracy: 0.0001)
        XCTAssertEqual(result.boneMassKg ?? -1, 3.1, accuracy: 0.0001)

        let empty = try BS444Parser.parseFeature(featurePacket(fat: 0, water: 0, muscle: 0, bone: 0))
        XCTAssertNil(empty.bodyFatPercent)
        XCTAssertNil(empty.bodyWaterPercent)
        XCTAssertNil(empty.musclePercent)
        XCTAssertNil(empty.boneMassKg)
    }

    func testShortPacketsAreRejected() {
        XCTAssertThrowsError(
            try BS444Parser.parseFeature(Data(repeating: 0, count: 15))
        ) { error in
            XCTAssertEqual(error as? BS444ParseError, .insufficientData(expected: 16, actual: 15))
        }
        var decoder = BS444TimestampDecoder()
        XCTAssertThrowsError(
            try BS444Parser.parseWeight(Data(repeating: 0, count: 8), now: now, timestampDecoder: &decoder)
        )
    }

    func testFrameBufferReassemblesFragmentsAndMultipleFrames() {
        var buffer = BS444FrameBuffer(frameLength: 3)
        XCTAssertTrue(buffer.append(Data([1])).isEmpty)
        XCTAssertEqual(buffer.append(Data([2, 3, 4, 5, 6])).map(Array.init), [[1, 2, 3], [4, 5, 6]])
        XCTAssertTrue(buffer.append(Data()).isEmpty)
    }

    func testSessionPublishesOnlyAfterWeightAndFeatureAreJoined() throws {
        var session = BS444Session(epochMode: .unix)
        let weight = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000)
        let feature = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1)

        XCTAssertNil(try session.receiveWeight(Data(weight.prefix(4)), now: now))
        XCTAssertNil(try session.receiveWeight(Data(weight.dropFirst(4)), now: now))
        XCTAssertNil(try session.receiveFeature(Data(feature.prefix(8)), now: now))
        let measurement = try session.receiveFeature(Data(feature.dropFirst(8)), now: now)

        XCTAssertEqual(measurement?.weightKg ?? -1, 72.34, accuracy: 0.0001)
        XCTAssertEqual(measurement?.bodyFatPercent ?? -1, 23.4, accuracy: 0.0001)
        XCTAssertEqual(measurement?.bodyWaterPercent ?? -1, 55.6, accuracy: 0.0001)
        XCTAssertEqual(measurement?.musclePercent ?? -1, 40.2, accuracy: 0.0001)
        XCTAssertEqual(measurement?.boneMassKg ?? -1, 3.1, accuracy: 0.0001)
    }

    func testZeroWeightDoesNotBecomeAMeasurement() throws {
        var session = BS444Session(epochMode: .unix)
        let zeroWeight = weightPacket(weightRaw: 0, timestamp: 1_700_000_000)
        let feature = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1)

        XCTAssertNil(try session.receiveWeight(zeroWeight, now: now))
        XCTAssertNil(try session.receiveFeature(feature, now: now))
    }

    func testSessionAcceptsFeatureBeforeWeight() throws {
        var session = BS444Session(epochMode: .unix)
        let weight = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000)
        let feature = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1)

        XCTAssertNil(try session.receiveFeature(feature, now: now))
        XCTAssertNotNil(try session.receiveWeight(weight, now: now))
    }

    func testTimestampDecoderCorrectsLegacyEpoch() {
        var decoder = BS444TimestampDecoder(mode: .unix)
        let legacyRaw = UInt32(1_700_000_000 - Int64(BS444Protocol.scaleEpochOffset))
        let result = decoder.decode(raw: legacyRaw, now: now)

        XCTAssertEqual(result.mode, .from2010)
        XCTAssertEqual(result.date, now)
        XCTAssertEqual(decoder.mode, .from2010)
    }

    private func weightPacket(weightRaw: UInt16, timestamp: UInt32) -> Data {
        var bytes = [UInt8](repeating: 0, count: BS444Protocol.weightFrameLength)
        bytes[1] = UInt8(truncatingIfNeeded: weightRaw)
        bytes[2] = UInt8(truncatingIfNeeded: weightRaw >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: timestamp)
        bytes[6] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[7] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[8] = UInt8(truncatingIfNeeded: timestamp >> 24)
        return Data(bytes)
    }

    private func featurePacket(
        fat: Double,
        water: Double,
        muscle: Double,
        bone: Double,
        highBits: UInt16 = 0
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: BS444Protocol.featureFrameLength)
        put(UInt16(fat * 10) | highBits, in: &bytes, offset: 8)
        put(UInt16(water * 10) | highBits, in: &bytes, offset: 10)
        put(UInt16(muscle * 10) | highBits, in: &bytes, offset: 12)
        put(UInt16(bone * 10) | highBits, in: &bytes, offset: 14)
        return Data(bytes)
    }

    private func put(_ value: UInt16, in bytes: inout [UInt8], offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
