import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    let bluetooth: BluetoothManager
    let healthKit: HealthKitManager
    let notifications: LocalNotificationManager

    @Published private(set) var lastSavedMeasurement: BodyMeasurement?
    @Published private(set) var healthKitMessage: String?
    @Published private(set) var syncSavedCount = 0
    @Published private(set) var syncDuplicateCount = 0

    private var managerCancellables = Set<AnyCancellable>()
    private var syncGeneration = 0

    init(
        bluetooth: BluetoothManager? = nil,
        healthKit: HealthKitManager? = nil,
        notifications: LocalNotificationManager? = nil
    ) {
        let resolvedBluetooth = bluetooth ?? BluetoothManager()
        let resolvedHealthKit = healthKit ?? HealthKitManager()
        let resolvedNotifications = notifications ?? LocalNotificationManager()
        self.bluetooth = resolvedBluetooth
        self.healthKit = resolvedHealthKit
        self.notifications = resolvedNotifications

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
        resolvedNotifications.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.objectWillChange.send()
                }
            }
            .store(in: &managerCancellables)

        resolvedBluetooth.onSyncStarted = { [weak self] in
            self?.syncGeneration += 1
            self?.syncSavedCount = 0
            self?.syncDuplicateCount = 0
            self?.healthKitMessage = "Checking scale history..."
        }
        resolvedBluetooth.onMeasurement = { [weak self] measurement, sourceDeviceIdentifier in
            // BluetoothManager invokes this callback synchronously on its main queue, so this
            // records delivery context before the async HealthKit save can change app state.
            let receivedInBackground = UIApplication.shared.applicationState == .background
            let generation = self?.syncGeneration
            Task { @MainActor [weak self] in
                await self?.receive(
                    measurement,
                    sourceDeviceIdentifier: sourceDeviceIdentifier,
                    syncGeneration: generation,
                    receivedInBackground: receivedInBackground
                )
            }
        }

        // CoreBluetooth restoration can deliver data before the SwiftUI view task runs.
        resolvedHealthKit.refreshAuthorization()
        resolvedNotifications.refreshAuthorization()
    }

    func start() {
        bluetooth.start()
    }

    func updateScenePhase(_ phase: ScenePhase) {
        if phase == .active {
            notifications.refreshAuthorization()
        }
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
                // This is an explicit foreground replay after authorization, not a new
                // background Bluetooth delivery.
                await receive(
                    latestMeasurement,
                    sourceDeviceIdentifier: bluetooth.selectedDevice?.identifier,
                    syncGeneration: syncGeneration,
                    receivedInBackground: false
                )
            }
        }
    }

    func requestNotificationAuthorization() {
        notifications.requestAuthorization()
    }

    func openNotificationSettings() {
        notifications.openSettings()
    }

    func clearHealthKitMessage() {
        healthKitMessage = nil
    }

    private func receive(
        _ measurement: BodyMeasurement,
        sourceDeviceIdentifier: String? = nil,
        syncGeneration measurementGeneration: Int? = nil,
        receivedInBackground: Bool
    ) async {
        guard HealthKitManager.writesEnabled else {
            healthKitMessage = "HealthKit writes are paused while BS444 measurements are being verified."
            return
        }
        guard healthKit.authorizationState == .authorized else {
            healthKitMessage = "Allow Health access to save the latest measurement."
            return
        }
        do {
            let didSave = try await healthKit.save(
                measurement,
                sourceDeviceIdentifier: sourceDeviceIdentifier
            )
            if measurementGeneration == nil || measurementGeneration == syncGeneration {
                lastSavedMeasurement = measurement
                if didSave {
                    syncSavedCount += 1
                } else {
                    syncDuplicateCount += 1
                }
                healthKitMessage = "Scale history: \(syncSavedCount) saved, \(syncDuplicateCount) already synced."
            }
            if didSave && receivedInBackground {
                notifications.notifyMeasurementSaved()
            }
        } catch {
            if measurementGeneration == nil || measurementGeneration == syncGeneration {
                healthKitMessage = error.localizedDescription
            }
        }
    }
}
