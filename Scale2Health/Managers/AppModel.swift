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

    private var managerCancellables = Set<AnyCancellable>()

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

        resolvedBluetooth.onMeasurement = { [weak self] measurement in
            // BluetoothManager invokes this callback synchronously on its main queue, so this
            // records delivery context before the async HealthKit save can change app state.
            let receivedInBackground = UIApplication.shared.applicationState == .background
            Task { @MainActor [weak self] in
                await self?.receive(
                    measurement,
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
                await receive(latestMeasurement, receivedInBackground: false)
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
            let didSave = try await healthKit.save(measurement)
            lastSavedMeasurement = measurement
            healthKitMessage = didSave
                ? "Saved supported values to Apple Health."
                : "Duplicate measurement skipped."
            if didSave && receivedInBackground {
                notifications.notifyMeasurementSaved()
            }
        } catch {
            healthKitMessage = error.localizedDescription
        }
    }
}
