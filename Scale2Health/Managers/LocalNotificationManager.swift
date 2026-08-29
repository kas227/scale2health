import Combine
import Foundation
import UIKit
import UserNotifications

@MainActor
final class LocalNotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case provisional
        case denied
        case failed(String)

        var title: String {
            switch self {
            case .notDetermined: return "Notifications not enabled"
            case .authorized: return "Notifications enabled"
            case .provisional: return "Notifications enabled quietly"
            case .denied: return "Notifications denied"
            case let .failed(message): return "Notification error: \(message)"
            }
        }
    }

    /// A shared thread groups background sync notifications into one stack in Notification Center.
    static let measurementThreadIdentifier = "background-health-sync"

    @Published private(set) var authorizationState: AuthorizationState = .notDetermined
    @Published private(set) var deliveryError: String?

    private let center: UNUserNotificationCenter
    private var latestSchedulingRequestIdentifier: String?

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            let state = Self.authorizationState(for: settings.authorizationStatus)
            Task { @MainActor [weak self] in
                self?.authorizationState = state
            }
        }
    }

    func requestAuthorization() {
        deliveryError = nil
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.authorizationState = .failed(error.localizedDescription)
                } else {
                    self.refreshAuthorization()
                }
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func notifyMeasurementSaved() {
        let request = Self.measurementSavedRequest()
        latestSchedulingRequestIdentifier = request.identifier
        deliveryError = nil
        center.add(request) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self,
                      self.latestSchedulingRequestIdentifier == request.identifier else {
                    return
                }
                self.deliveryError = error?.localizedDescription
            }
        }
    }

    static func measurementSavedRequest(
        identifier: UUID = UUID()
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Apple Health updated"
        content.body = "A scale measurement received in the background was synced successfully."
        content.sound = .default
        content.threadIdentifier = measurementThreadIdentifier
        content.summaryArgument = "measurement"
        content.summaryArgumentCount = 1

        // Unique identifiers preserve every notification; the shared thread groups them.
        return UNNotificationRequest(
            identifier: "\(measurementThreadIdentifier).\(identifier.uuidString)",
            content: content,
            trigger: nil
        )
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A background-received measurement may finish saving after the app becomes active.
        completionHandler([.banner, .list, .sound])
    }

    private static func authorizationState(
        for status: UNAuthorizationStatus
    ) -> AuthorizationState {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized:
            return .authorized
        case .provisional, .ephemeral:
            return .provisional
        case .denied:
            return .denied
        @unknown default:
            return .notDetermined
        }
    }
}
