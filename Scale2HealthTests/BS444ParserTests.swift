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

    func testWikiPacketFixturesMatchTheDocumentedSchema() throws {
        let weight = Data([
            0x1D, 0x80, 0x25, 0x00, 0xFE, 0x80, 0x0F, 0xF4, 0x0D,
            0x6A, 0x17, 0x00, 0xFF, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00
        ])
        let feature = Data([
            0x6F, 0x80, 0x0F, 0xF4, 0x0D, 0x01, 0x21, 0x0C,
            0x57, 0xF1, 0xE3, 0xF1, 0x5B, 0xF1, 0x23, 0xF0, 0x00, 0x00, 0x00
        ])
        var decoder = BS444TimestampDecoder(mode: .from2010)
        let weightResult = try BS444Parser.parseWeight(weight, now: now, timestampDecoder: &decoder)
        let featureResult = try BS444Parser.parseFeature(feature)

        XCTAssertEqual(weightResult.weightKg, 96.0, accuracy: 0.0001)
        XCTAssertEqual(weightResult.sourceUnit, .kilograms)
        XCTAssertEqual(weightResult.userID, 1)
        XCTAssertEqual(featureResult.userID, 1)
        XCTAssertEqual(featureResult.bodyFatPercent ?? -1, 34.3, accuracy: 0.0001)
        XCTAssertEqual(featureResult.bodyWaterPercent ?? -1, 48.3, accuracy: 0.0001)
        XCTAssertEqual(featureResult.musclePercent ?? -1, 34.7, accuracy: 0.0001)
        XCTAssertEqual(featureResult.boneMassKg ?? -1, 3.5, accuracy: 0.0001)
    }

    func testLiveUserOnePacketPairMatchesDisplayedMeasurement() throws {
        let weight = Data([
            0x1D, 0x5A, 0x1E, 0x00, 0xFE, 0x81, 0x14, 0x56, 0x1F,
            0x0C, 0x28, 0x00, 0xFF, 0x01, 0x09, 0x00, 0x00, 0x00, 0x00
        ])
        let feature = Data([
            0x6F, 0x81, 0x14, 0x56, 0x1F, 0x01, 0xFC, 0x06, 0x9D,
            0xF0, 0x79, 0xF2, 0xAE, 0xF1, 0x23, 0xF0, 0x00, 0x00, 0x00
        ])
        var session = BS444Session(epochMode: .from2010)

        XCTAssertTrue(try session.receiveWeight(
            weight,
            now: Date(timeIntervalSince1970: 1_788_039_049)
        ).isEmpty)
        let measurement = try session.receiveFeature(
            feature,
            now: Date(timeIntervalSince1970: 1_788_039_049)
        ).first

        XCTAssertEqual(measurement?.timestamp, Date(timeIntervalSince1970: 1_788_039_041))
        XCTAssertEqual(measurement?.weightKg ?? -1, 77.7, accuracy: 0.0001)
        XCTAssertEqual(measurement?.sourceWeightUnit, .kilograms)
        XCTAssertEqual(measurement?.scaleUserID, 1)
        XCTAssertEqual(measurement?.bodyFatPercent ?? -1, 15.7, accuracy: 0.0001)
        XCTAssertEqual(measurement?.bodyWaterPercent ?? -1, 63.3, accuracy: 0.0001)
        XCTAssertEqual(measurement?.musclePercent ?? -1, 43.0, accuracy: 0.0001)
        XCTAssertEqual(measurement?.boneMassKg ?? -1, 3.5, accuracy: 0.0001)
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

    func testWeightUnitFlagsAreNormalizedToKilograms() throws {
        var decoder = BS444TimestampDecoder(mode: .unix)
        let pounds = try BS444Parser.parseWeight(
            weightPacket(weightRaw: 16_000, timestamp: 1_700_000_000, unit: .pounds),
            now: now,
            timestampDecoder: &decoder
        )
        let stones = try BS444Parser.parseWeight(
            weightPacket(weightRaw: 16_000, timestamp: 1_700_000_000, unit: .stonesAndPounds),
            now: now,
            timestampDecoder: &decoder
        )

        XCTAssertEqual(pounds.sourceUnit, .pounds)
        XCTAssertEqual(pounds.weightKg, 72.5747792, accuracy: 0.0000001)
        XCTAssertEqual(stones.sourceUnit, .stonesAndPounds)
        XCTAssertEqual(stones.weightKg, pounds.weightKg, accuracy: 0.0000001)

        var invalid = [UInt8](weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000))
        invalid[0] = 0x60
        XCTAssertThrowsError(
            try BS444Parser.parseWeight(Data(invalid), now: now, timestampDecoder: &decoder)
        ) { error in
            XCTAssertEqual(error as? BS444ParseError, .unsupportedWeightUnit(3))
        }
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
            try BS444Parser.parseFeature(Data(repeating: 0, count: 18))
        ) { error in
            XCTAssertEqual(error as? BS444ParseError, .insufficientData(expected: 19, actual: 18))
        }
        var decoder = BS444TimestampDecoder()
        XCTAssertThrowsError(
            try BS444Parser.parseWeight(Data(repeating: 0, count: 18), now: now, timestampDecoder: &decoder)
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

        XCTAssertTrue(try session.receiveWeight(Data(weight.prefix(4)), now: now).isEmpty)
        XCTAssertTrue(try session.receiveWeight(Data(weight.dropFirst(4)), now: now).isEmpty)
        XCTAssertTrue(try session.receiveFeature(Data(feature.prefix(8)), now: now).isEmpty)
        let measurement = try session.receiveFeature(Data(feature.dropFirst(8)), now: now).first

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

        XCTAssertTrue(try session.receiveWeight(zeroWeight, now: now).isEmpty)
        XCTAssertTrue(try session.receiveFeature(feature, now: now).isEmpty)
    }

    func testSessionAcceptsFeatureBeforeWeight() throws {
        var session = BS444Session(epochMode: .unix)
        let weight = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000)
        let feature = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1)

        XCTAssertTrue(try session.receiveFeature(feature, now: now).isEmpty)
        XCTAssertEqual(try session.receiveWeight(weight, now: now).count, 1)
    }

    func testSessionCarriesMatchingScaleUserAndRejectsMismatches() throws {
        var matchingSession = BS444Session(epochMode: .unix)
        let userOneWeight = weightPacket(
            weightRaw: 7_234,
            timestamp: 1_700_000_000,
            userID: 1
        )
        let userOneFeature = featurePacket(
            fat: 23.4,
            water: 55.6,
            muscle: 40.2,
            bone: 3.1,
            userID: 1
        )
        XCTAssertTrue(try matchingSession.receiveWeight(userOneWeight, now: now).isEmpty)
        let matching = try matchingSession.receiveFeature(userOneFeature, now: now).first
        XCTAssertEqual(matching?.scaleUserID, 1)

        var mismatchingSession = BS444Session(epochMode: .unix)
        XCTAssertTrue(try mismatchingSession.receiveWeight(userOneWeight, now: now).isEmpty)
        XCTAssertTrue(try mismatchingSession.receiveFeature(
            featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1, userID: 2),
            now: now
        ).isEmpty)
    }

    func testSessionUsesLatestLiveWeightWhenFeaturesArriveLater() throws {
        var session = BS444Session(epochMode: .unix)
        let transientWeight = weightPacket(weightRaw: 1_100, timestamp: 1_700_000_000)
        let finalWeight = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_001)
        let feature = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1)

        XCTAssertTrue(try session.receiveWeight(transientWeight, now: now).isEmpty)
        XCTAssertTrue(try session.receiveWeight(finalWeight, now: now).isEmpty)
        let measurement = try session.receiveFeature(feature, now: now).first

        XCTAssertEqual(measurement?.weightKg ?? -1, 72.34, accuracy: 0.0001)
        XCTAssertEqual(measurement?.timestamp, Date(timeIntervalSince1970: 1_700_000_001))
    }

    func testSessionDoesNotLoseCompletedPairWhenBatchEndsWithPendingFrame() throws {
        var session = BS444Session(epochMode: .unix)
        let firstFeature = featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1)
        let firstWeight = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000)
        let secondWeight = weightPacket(weightRaw: 7_235, timestamp: 1_700_000_001)
        let secondFeature = featurePacket(fat: 23.5, water: 55.7, muscle: 40.3, bone: 3.2)

        XCTAssertTrue(try session.receiveFeature(firstFeature, now: now).isEmpty)
        let completed = try session.receiveWeight(firstWeight + secondWeight, now: now)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.weightKg ?? -1, 72.34, accuracy: 0.0001)

        let remaining = try session.receiveFeature(secondFeature, now: now)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.weightKg ?? -1, 72.35, accuracy: 0.0001)
    }

    func testTimestampDecoderCorrectsLegacyEpoch() {
        var decoder = BS444TimestampDecoder(mode: .unix)
        let legacyRaw = UInt32(1_700_000_000 - Int64(BS444Protocol.scaleEpochOffset))
        let result = decoder.decode(raw: legacyRaw, now: now)

        XCTAssertEqual(result.mode, .from2010)
        XCTAssertEqual(result.date, now)
        XCTAssertEqual(decoder.mode, .from2010)
    }

    private func weightPacket(
        weightRaw: UInt16,
        timestamp: UInt32,
        unit: BS444WeightUnit = .kilograms,
        userID: UInt8? = nil
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: BS444Protocol.weightFrameLength)
        bytes[0] = unit.rawValue << 5
        bytes[1] = UInt8(truncatingIfNeeded: weightRaw)
        bytes[2] = UInt8(truncatingIfNeeded: weightRaw >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: timestamp)
        bytes[6] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[7] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[8] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[13] = userID ?? 0xFF
        return Data(bytes)
    }

    private func featurePacket(
        fat: Double,
        water: Double,
        muscle: Double,
        bone: Double,
        highBits: UInt16 = 0,
        userID: UInt8? = nil
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: BS444Protocol.featureFrameLength)
        bytes[5] = userID ?? 0xFF
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
