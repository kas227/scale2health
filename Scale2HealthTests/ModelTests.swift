import Foundation
import XCTest
@testable import Scale2Health

final class ModelTests: XCTestCase {
    func testDeviceStoreRoundTripsSelectedDevice() {
        let suiteName = "Scale2HealthTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = DeviceStore(defaults: defaults)
        let device = ScaleDevice(
            identifier: "ABC",
            name: "013197123456",
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000),
            epochMode: .from2010
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
