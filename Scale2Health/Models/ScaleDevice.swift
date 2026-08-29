import Foundation

/// A persisted peripheral identity. CoreBluetooth peripherals are intentionally not persisted.
public struct ScaleDevice: Codable, Equatable, Identifiable, Sendable {
    public let identifier: String
    public var name: String
    public var lastSeen: Date?
    public var epochMode: BS444EpochMode?
    /// Nil accepts every scale user; 1...8 restricts delivery to that scale user slot.
    public var userIDFilter: UInt8?

    public init(
        identifier: String,
        name: String,
        lastSeen: Date? = nil,
        epochMode: BS444EpochMode? = nil,
        userIDFilter: UInt8? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.lastSeen = lastSeen
        self.epochMode = epochMode
        self.userIDFilter = userIDFilter
    }

    public var id: String { identifier }
}
