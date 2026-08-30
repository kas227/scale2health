import Combine
import Foundation
import HealthKit

@MainActor
final class HealthKitManager: ObservableObject {
    /// Emergency kill switch for HealthKit writes if packet validation regresses.
    static let writesEnabled = true

    enum AuthorizationState: Equatable {
        case unavailable
        case notDetermined
        case requesting
        case authorized
        case denied
        case failed(String)

        var title: String {
            switch self {
            case .unavailable: return "HealthKit unavailable"
            case .notDetermined: return "Health access not requested"
            case .requesting: return "Requesting Health access"
            case .authorized: return "Health access granted"
            case .denied: return "Health access denied"
            case let .failed(message): return "Health error: \(message)"
            }
        }
    }

    enum HealthKitError: LocalizedError {
        case unavailable
        case noSamples
        case saveFailed(Error)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "HealthKit is not available on this device."
            case .noSamples: return "The measurement contains no HealthKit-supported values."
            case let .saveFailed(error): return error.localizedDescription
            }
        }
    }

    @Published private(set) var authorizationState: AuthorizationState

    private let healthStore: HKHealthStore
    private let deduplicator: MeasurementDeduplicator
    private let bodyMassType: HKQuantityType?
    private let bodyFatType: HKQuantityType?
    private var inFlightFingerprints = Set<String>()

    init(
        healthStore: HKHealthStore = HKHealthStore(),
        deduplicator: MeasurementDeduplicator = MeasurementDeduplicator()
    ) {
        self.healthStore = healthStore
        self.deduplicator = deduplicator
        bodyMassType = HKObjectType.quantityType(forIdentifier: .bodyMass)
        bodyFatType = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage)
        authorizationState = HKHealthStore.isHealthDataAvailable() ? .notDetermined : .unavailable
    }

    func refreshAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }
        guard let bodyMassType else {
            authorizationState = .denied
            return
        }
        switch healthStore.authorizationStatus(for: bodyMassType) {
        case .sharingAuthorized:
            authorizationState = .authorized
        case .sharingDenied:
            authorizationState = .denied
        case .notDetermined:
            authorizationState = .notDetermined
        @unknown default:
            authorizationState = .notDetermined
        }
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationState = .unavailable
            return
        }
        authorizationState = .requesting
        var types = Set<HKSampleType>()
        if let bodyMassType { types.insert(bodyMassType) }
        if let bodyFatType { types.insert(bodyFatType) }

        do {
            try await healthStore.requestAuthorization(toShare: types, read: [])
            if let bodyMassType {
                authorizationState = healthStore.authorizationStatus(for: bodyMassType) == .sharingAuthorized
                    ? .authorized
                    : .denied
            } else {
                authorizationState = .denied
            }
        } catch {
            authorizationState = .failed(error.localizedDescription)
        }
    }

    func save(
        _ measurement: BodyMeasurement,
        sourceDeviceIdentifier: String? = nil
    ) async throws -> Bool {
        guard Self.writesEnabled else { return false }
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitError.unavailable }
        let fingerprint = deduplicator.fingerprint(
            for: measurement,
            sourceDeviceIdentifier: sourceDeviceIdentifier
        )
        guard !deduplicator.contains(
            measurement,
            sourceDeviceIdentifier: sourceDeviceIdentifier
        ), !inFlightFingerprints.contains(fingerprint) else {
            return false
        }
        inFlightFingerprints.insert(fingerprint)
        defer { inFlightFingerprints.remove(fingerprint) }

        var samples: [HKObject] = []
        if let bodyMassType,
           healthStore.authorizationStatus(for: bodyMassType) == .sharingAuthorized {
            let quantity = HKQuantity(
                unit: HKUnit.gramUnit(with: .kilo),
                doubleValue: measurement.weightKg
            )
            samples.append(HKQuantitySample(
                type: bodyMassType,
                quantity: quantity,
                start: measurement.timestamp,
                end: measurement.timestamp
            ))
        }
        if let bodyFatType,
           healthStore.authorizationStatus(for: bodyFatType) == .sharingAuthorized,
           let bodyFatPercent = measurement.bodyFatPercent {
            let quantity = HKQuantity(
                unit: HKUnit.percent(),
                doubleValue: bodyFatPercent / 100.0
            )
            samples.append(HKQuantitySample(
                type: bodyFatType,
                quantity: quantity,
                start: measurement.timestamp,
                end: measurement.timestamp
            ))
        }
        guard !samples.isEmpty else { throw HealthKitError.noSamples }

        do {
            try await save(samples)
            deduplicator.remember(
                measurement,
                sourceDeviceIdentifier: sourceDeviceIdentifier
            )
            return true
        } catch {
            throw HealthKitError.saveFailed(error)
        }
    }

    private func save(_ samples: [HKObject]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HealthKitError.noSamples)
                }
            }
        }
    }
}
