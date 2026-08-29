import Foundation

/// Small UserDefaults-backed store for the one selected scale supported by the MVP.
public final class DeviceStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "selectedScale") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> ScaleDevice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ScaleDevice.self, from: data)
    }

    public func save(_ device: ScaleDevice) {
        guard let data = try? JSONEncoder().encode(device) else { return }
        defaults.set(data, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
