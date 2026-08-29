import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let bluetooth: BluetoothManager
    let healthKit: HealthKitManager

    @Published private(set) var lastSavedMeasurement: BodyMeasurement?
    @Published private(set) var healthKitMessage: String?

    init(
        bluetooth: BluetoothManager? = nil,
        healthKit: HealthKitManager? = nil
    ) {
        let resolvedBluetooth = bluetooth ?? BluetoothManager()
        let resolvedHealthKit = healthKit ?? HealthKitManager()
        self.bluetooth = resolvedBluetooth
        self.healthKit = resolvedHealthKit
        resolvedBluetooth.onMeasurement = { [weak self] measurement in
            Task { @MainActor [weak self] in
                await self?.receive(measurement)
            }
        }
    }

    func start() {
        bluetooth.start()
    }

    func requestHealthKitAuthorization() {
        Task { await healthKit.requestAuthorization() }
    }

    func clearHealthKitMessage() {
        healthKitMessage = nil
    }

    private func receive(_ measurement: BodyMeasurement) async {
        do {
            let didSave = try await healthKit.save(measurement)
            lastSavedMeasurement = measurement
            healthKitMessage = didSave
                ? "Saved supported values to Apple Health."
                : "Duplicate measurement skipped."
        } catch {
            healthKitMessage = error.localizedDescription
        }
    }
}
