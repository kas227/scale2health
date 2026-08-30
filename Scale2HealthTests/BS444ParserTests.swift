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
        XCTAssertEqual(featureResult.rawTimestamp, 0x0DF40F80)
        XCTAssertEqual(featureResult.bodyFatPercent ?? -1, 34.3, accuracy: 0.0001)
        XCTAssertEqual(featureResult.bodyWaterPercent ?? -1, 48.3, accuracy: 0.0001)
        XCTAssertEqual(featureResult.musclePercent ?? -1, 34.7, accuracy: 0.0001)
        XCTAssertEqual(featureResult.boneMassKg ?? -1, 3.5, accuracy: 0.0001)
    }

    func testSyntheticPacketPairMatchesDocumentedSchema() throws {
        // This fixture is generated from the documented field layout. It is not a capture
        // from a person or a physical scale.
        let weight = Data([
            0x1D, 0x2B, 0x20, 0x00, 0xFE, 0x00, 0xB6, 0x16, 0x1A,
            0x00, 0x00, 0x00, 0xFF, 0x03, 0x09, 0x00, 0x00, 0x00, 0x00
        ])
        let feature = Data([
            0x6F, 0x00, 0xB6, 0x16, 0x1A, 0x03, 0x08, 0x07,
            0xF6, 0xF0, 0x1E, 0xF2, 0x83, 0xF1, 0x20, 0xF0, 0x00, 0x00, 0x00
        ])
        var session = BS444Session(epochMode: .from2010)

        XCTAssertTrue(try session.receiveWeight(weight, now: now).isEmpty)
        let measurement = try session.receiveFeature(feature, now: now).first

        XCTAssertEqual(measurement?.timestamp, now)
        XCTAssertEqual(measurement?.weightKg ?? -1, 82.35, accuracy: 0.0001)
        XCTAssertEqual(measurement?.sourceWeightUnit, .kilograms)
        XCTAssertEqual(measurement?.scaleUserID, 3)
        XCTAssertEqual(measurement?.bodyFatPercent ?? -1, 24.6, accuracy: 0.0001)
        XCTAssertEqual(measurement?.bodyWaterPercent ?? -1, 54.2, accuracy: 0.0001)
        XCTAssertEqual(measurement?.musclePercent ?? -1, 38.7, accuracy: 0.0001)
        XCTAssertEqual(measurement?.boneMassKg ?? -1, 3.2, accuracy: 0.0001)
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
        let feature = featurePacket(
            fat: 23.4,
            water: 55.6,
            muscle: 40.2,
            bone: 3.1,
            timestamp: 1_700_000_001
        )

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
        let secondFeature = featurePacket(
            fat: 23.5,
            water: 55.7,
            muscle: 40.3,
            bone: 3.2,
            timestamp: 1_700_000_001
        )

        XCTAssertTrue(try session.receiveFeature(firstFeature, now: now).isEmpty)
        let completed = try session.receiveWeight(firstWeight + secondWeight, now: now)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.weightKg ?? -1, 72.34, accuracy: 0.0001)

        let remaining = try session.receiveFeature(secondFeature, now: now)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.weightKg ?? -1, 72.35, accuracy: 0.0001)
    }

    func testSessionPairsHistoricalDumpByUserAndTimestamp() throws {
        var session = BS444Session(epochMode: .unix)
        let weights = (0..<30).map { index in
            weightPacket(
                weightRaw: UInt16(7_000 + index),
                timestamp: UInt32(1_699_999_900 + index),
                userID: 1
            )
        }

        for weight in weights {
            XCTAssertTrue(try session.receiveWeight(weight, now: now).isEmpty)
        }

        var measurements: [BodyMeasurement] = []
        for index in (0..<30).reversed() {
            measurements += try session.receiveFeature(
                featurePacket(
                    fat: Double(200 + index) / 10,
                    water: 55,
                    muscle: 40,
                    bone: 3,
                    timestamp: UInt32(1_699_999_900 + index),
                    userID: 1
                ),
                now: now
            )
        }

        XCTAssertEqual(measurements.count, 30)
        XCTAssertEqual(Set(measurements.compactMap(\.rawTimestamp)).count, 30)
        XCTAssertTrue(measurements.allSatisfy { $0.scaleUserID == 1 })
    }

    func testSessionDoesNotCrossPairDifferentTimestamps() throws {
        var session = BS444Session(epochMode: .unix)
        let weight = weightPacket(weightRaw: 7_234, timestamp: 1_700_000_000, userID: 1)
        let wrongFeature = featurePacket(
            fat: 23.4,
            water: 55.6,
            muscle: 40.2,
            bone: 3.1,
            timestamp: 1_699_999_999,
            userID: 1
        )

        XCTAssertTrue(try session.receiveWeight(weight, now: now).isEmpty)
        XCTAssertTrue(try session.receiveFeature(wrongFeature, now: now).isEmpty)
    }

    func testTimestampDecoderCorrectsLegacyEpoch() {
        var decoder = BS444TimestampDecoder(mode: .unix)
        let legacyRaw = UInt32(1_700_000_000 - Int64(BS444Protocol.scaleEpochOffset))
        let result = decoder.decode(raw: legacyRaw, now: now)

        XCTAssertEqual(result.mode, .from2010)
        XCTAssertEqual(result.date, now)
        XCTAssertEqual(decoder.mode, .from2010)
    }

    func testTimestampDecoderDetectsOldHistoryByPlausibleEpoch() {
        var decoder = BS444TimestampDecoder()
        let oldDate = Date(timeIntervalSince1970: 1_500_000_000)
        let raw = UInt32(oldDate.timeIntervalSince1970 - TimeInterval(BS444Protocol.scaleEpochOffset))
        let result = decoder.decode(raw: raw, now: now)

        XCTAssertEqual(result.mode, .from2010)
        XCTAssertEqual(result.date, oldDate)
    }

    func testSessionRejectsZeroTimestamp() throws {
        var session = BS444Session(epochMode: .from2010)
        XCTAssertTrue(try session.receiveWeight(
            weightPacket(weightRaw: 7_234, timestamp: 0, userID: 1),
            now: now
        ).isEmpty)
        XCTAssertTrue(try session.receiveFeature(
            featurePacket(fat: 23.4, water: 55.6, muscle: 40.2, bone: 3.1, timestamp: 0, userID: 1),
            now: now
        ).isEmpty)
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
        timestamp: UInt32 = 1_700_000_000,
        userID: UInt8? = nil
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: BS444Protocol.featureFrameLength)
        bytes[1] = UInt8(truncatingIfNeeded: timestamp)
        bytes[2] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: timestamp >> 24)
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
