import Foundation

/// A persisted peripheral identity. CoreBluetooth peripherals are intentionally not persisted.
public struct ScaleDevice: Codable, Equatable, Identifiable, Sendable {
    public let identifier: String
    public var name: String
    public var lastSeen: Date?
    public var epochMode: BS444EpochMode?

    public init(
        identifier: String,
        name: String,
        lastSeen: Date? = nil,
        epochMode: BS444EpochMode? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.lastSeen = lastSeen
        self.epochMode = epochMode
    }

    public var id: String { identifier }
}
