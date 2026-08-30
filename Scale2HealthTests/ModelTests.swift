import Foundation
import UserNotifications
import XCTest
@testable import Scale2Health

final class ModelTests: XCTestCase {
    @MainActor
    func testBackgroundSyncNotificationsStackWithoutReplacingEachOther() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = LocalNotificationManager.measurementSavedRequest(identifier: firstID)
        let second = LocalNotificationManager.measurementSavedRequest(identifier: secondID)

        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertEqual(
            first.content.threadIdentifier,
            LocalNotificationManager.measurementThreadIdentifier
        )
        XCTAssertEqual(second.content.threadIdentifier, first.content.threadIdentifier)
        XCTAssertEqual(first.content.title, "Apple Health updated")
        XCTAssertNil(first.trigger)
    }

    func testDeviceStoreRoundTripsSelectedDevice() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = DeviceStore(defaults: defaults)
        let device = ScaleDevice(
            identifier: "ABC",
            name: "013197123456",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            epochMode: .from2010,
            userIDFilter: 3
        )

        store.save(device)
        XCTAssertEqual(store.load(), device)
        store.clear()
        XCTAssertNil(store.load())
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDeduplicatorAcceptsThenRejectsSameMeasurement() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let deduplicator = MeasurementDeduplicator(defaults: defaults)
        let measurement = BodyMeasurement(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            weightKg: 72.34,
            bodyFatPercent: 23.4,
            bodyWaterPercent: 55.6,
            musclePercent: 40.2,
            boneMassKg: 3.1
        )

        XCTAssertFalse(deduplicator.contains(measurement))
        deduplicator.remember(measurement)
        XCTAssertTrue(deduplicator.contains(measurement))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDeduplicatorDistinguishesScaleUsers() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let deduplicator = MeasurementDeduplicator(defaults: defaults)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let userOne = BodyMeasurement(timestamp: timestamp, weightKg: 72.34, scaleUserID: 1)
        let userTwo = BodyMeasurement(timestamp: timestamp, weightKg: 72.34, scaleUserID: 2)

        deduplicator.remember(userOne)
        XCTAssertTrue(deduplicator.contains(userOne))
        XCTAssertFalse(deduplicator.contains(userTwo))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDeduplicatorDistinguishesScalesAndIgnoresCompositionChanges() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let deduplicator = MeasurementDeduplicator(defaults: defaults)
        let first = BodyMeasurement(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            weightKg: 72.34,
            rawTimestamp: 437_696_000,
            rawWeight: 7_234,
            scaleUserID: 1
        )
        let completed = BodyMeasurement(
            timestamp: first.timestamp,
            weightKg: first.weightKg,
            rawTimestamp: first.rawTimestamp,
            rawWeight: first.rawWeight,
            scaleUserID: 1,
            bodyFatPercent: 23.4
        )

        deduplicator.remember(first, sourceDeviceIdentifier: "scale-a")
        XCTAssertTrue(deduplicator.contains(completed, sourceDeviceIdentifier: "scale-a"))
        XCTAssertFalse(deduplicator.contains(completed, sourceDeviceIdentifier: "scale-b"))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDeduplicatorRecognizesAndMigratesLegacyFingerprint() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let key = "fingerprints"
        let deduplicator = MeasurementDeduplicator(defaults: defaults, key: key)
        let measurement = BodyMeasurement(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            weightKg: 72.34,
            scaleUserID: 1,
            bodyFatPercent: 23.4,
            bodyWaterPercent: 55.6,
            musclePercent: 40.2,
            boneMassKg: 3.1
        )
        defaults.set(["1700000000|72.34|23.4|55.6|40.2|3.1"], forKey: key)

        XCTAssertTrue(deduplicator.contains(measurement))
        deduplicator.remember(measurement)
        XCTAssertEqual(defaults.stringArray(forKey: key), [deduplicator.fingerprint(for: measurement)])
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDeduplicatorRetainsOnlyConfiguredCapacity() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let deduplicator = MeasurementDeduplicator(defaults: defaults, capacity: 2)
        let first = BodyMeasurement(timestamp: Date(timeIntervalSince1970: 1), weightKg: 1)
        let second = BodyMeasurement(timestamp: Date(timeIntervalSince1970: 2), weightKg: 2)
        let third = BodyMeasurement(timestamp: Date(timeIntervalSince1970: 3), weightKg: 3)

        deduplicator.remember(first)
        deduplicator.remember(second)
        deduplicator.remember(third)

        XCTAssertFalse(deduplicator.contains(first))
        XCTAssertTrue(deduplicator.contains(second))
        XCTAssertTrue(deduplicator.contains(third))
        defaults.removePersistentDomain(forName: suiteName)
    }
}
