// Portions of the BS44x protocol implementation are adapted from openScale's
// MedisanaBs44xHandler, Copyright (C) 2025 olie.xdev, licensed GPL-3.0-or-later.
// Modified for Scale2Health in 2026 and distributed under GPL-3.0-only.
// See LICENSE and THIRD_PARTY_NOTICES.md.

import Foundation

public enum BS444EpochMode: String, Codable, Equatable, Sendable {
    case unix
    case from2010
}

/// Unit selected on the scale and encoded in bits 5...6 of the weight flags byte.
public enum BS444WeightUnit: UInt8, Codable, Equatable, Sendable {
    case kilograms = 0
    case pounds = 1
    case stonesAndPounds = 2

    public var label: String {
        switch self {
        case .kilograms: return "kg"
        case .pounds: return "lb"
        case .stonesAndPounds: return "st:lb"
        }
    }
}

public struct BS444DeviceSupport: Equatable, Sendable {
    public enum Variant: String, Equatable, Sendable {
        case bs430 = "Medisana BS430"
        case bs444OrBs440 = "Medisana BS444/BS440"
        case bs44x = "Medisana BS44x"
    }

    public let variant: Variant
    public let hasBodyComposition: Bool
    public let hasTimeSync: Bool

    public init(
        variant: Variant,
        hasBodyComposition: Bool = true,
        hasTimeSync: Bool = true
    ) {
        self.variant = variant
        self.hasBodyComposition = hasBodyComposition
        self.hasTimeSync = hasTimeSync
    }
}

/// Constants and stateless commands from openScale's MedisanaBs44xHandler.
public enum BS444Protocol {
    public static let serviceUUID = UUID(uuidString: "000078B2-0000-1000-8000-00805F9B34FB")!
    public static let weightCharacteristicUUID = UUID(uuidString: "00008A21-0000-1000-8000-00805F9B34FB")!
    public static let featureCharacteristicUUID = UUID(uuidString: "00008A22-0000-1000-8000-00805F9B34FB")!
    public static let commandCharacteristicUUID = UUID(uuidString: "00008A81-0000-1000-8000-00805F9B34FB")!
    public static let optionalCharacteristicUUID = UUID(uuidString: "00008A82-0000-1000-8000-00805F9B34FB")!

    public static let weightFrameLength = 19
    public static let featureFrameLength = 19
    public static let scaleEpochOffset: UInt64 = 1_262_304_000

    /// The scale's clock command is 0x02 followed by a little-endian UInt32 timestamp.
    public static func timeCommand(date: Date, epochMode: BS444EpochMode) -> Data {
        let unixSeconds = max(0, Int64(date.timeIntervalSince1970.rounded(.down)))
        let scaleSeconds: UInt64
        switch epochMode {
        case .unix:
            scaleSeconds = UInt64(unixSeconds)
        case .from2010:
            scaleSeconds = UInt64(max(0, unixSeconds - Int64(scaleEpochOffset)))
        }

        let value = UInt32(clamping: scaleSeconds)
        return Data([
            0x02,
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24)
        ])
    }

    /// Matches openScale's name and service heuristics without requiring a BLE framework.
    public static func support(for name: String, advertisedServices: [UUID] = []) -> BS444DeviceSupport? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasService = advertisedServices.contains(serviceUUID)
        let isKnownName = normalized.hasPrefix("013197") ||
            normalized.hasPrefix("013198") ||
            normalized.hasPrefix("0202b6") ||
            normalized.hasPrefix("0203b")

        guard isKnownName || hasService else { return nil }
        if normalized.hasPrefix("0203b") {
            return BS444DeviceSupport(variant: .bs430)
        }
        if normalized.hasPrefix("013197") ||
            normalized.hasPrefix("013198") ||
            normalized.hasPrefix("0202b6") {
            return BS444DeviceSupport(variant: .bs444OrBs440)
        }
        return BS444DeviceSupport(variant: .bs44x)
    }

    public static func predictedEpochMode(for name: String) -> BS444EpochMode? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("0203b") { return .unix }
        if normalized.hasPrefix("013197") ||
            normalized.hasPrefix("013198") ||
            normalized.hasPrefix("0202b6") {
            return .from2010
        }
        return nil
    }
}
