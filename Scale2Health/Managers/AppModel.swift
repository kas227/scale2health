import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let bluetooth: BluetoothManager
    let healthKit: HealthKitManager

    @Published private(set) var lastSavedMeasurement: BodyMeasurement?
    @Published private(set) var healthKitMessage: String?

    private var managerCancellables = Set<AnyCancellable>()

    init(
        bluetooth: BluetoothManager? = nil,
        healthKit: HealthKitManager? = nil
    ) {
        let resolvedBluetooth = bluetooth ?? BluetoothManager()
        let resolvedHealthKit = healthKit ?? HealthKitManager()
        self.bluetooth = resolvedBluetooth
        self.healthKit = resolvedHealthKit

        resolvedBluetooth.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &managerCancellables)
        resolvedHealthKit.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &managerCancellables)

        resolvedBluetooth.onMeasurement = { [weak self] measurement in
            Task { @MainActor [weak self] in
                await self?.receive(measurement)
            }
        }
    }

    func start() {
        healthKit.refreshAuthorization()
        bluetooth.start()
    }

    func requestHealthKitAuthorization() {
        guard HealthKitManager.writesEnabled else {
            healthKitMessage = "HealthKit writes are paused while BS444 measurements are being verified."
            return
        }
        Task {
            await healthKit.requestAuthorization()
            if healthKit.authorizationState == .authorized,
               let latestMeasurement = bluetooth.latestMeasurement {
                await receive(latestMeasurement)
            }
        }
    }

    func clearHealthKitMessage() {
        healthKitMessage = nil
    }

    private func receive(_ measurement: BodyMeasurement) async {
        guard HealthKitManager.writesEnabled else {
            healthKitMessage = "HealthKit writes are paused while BS444 measurements are being verified."
            return
        }
        guard healthKit.authorizationState == .authorized else {
            healthKitMessage = "Allow Health access to save the latest measurement."
            return
        }
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
