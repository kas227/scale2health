import Combine
import CoreBluetooth
import Foundation

final class BluetoothManager: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case unavailable
        case idle
        case scanning
        case connecting
        case discovering
        case ready
        case receiving
        case failed(String)

        var title: String {
            switch self {
            case .unavailable: return "Bluetooth unavailable"
            case .idle: return "Ready"
            case .scanning: return "Scanning for BS444"
            case .connecting: return "Connecting"
            case .discovering: return "Preparing scale"
            case .ready: return "Connected"
            case .receiving: return "Receiving measurement"
            case let .failed(message): return "Error: \(message)"
            }
        }
    }

    @Published private(set) var state: ConnectionState = .unavailable
    @Published private(set) var discoveredDevices: [ScaleDevice] = []
    @Published private(set) var selectedDevice: ScaleDevice?
    @Published private(set) var latestMeasurement: BodyMeasurement?
    @Published private(set) var logs: [String] = []

    var onMeasurement: ((BodyMeasurement) -> Void)?

    private let store: DeviceStore
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var currentPeripheral: CBPeripheral?
    private var activeSession: BS444Session?
    private var weightCharacteristic: CBCharacteristic?
    private var featureCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var requiredNotifications = Set<CBUUID>()
    private var enabledNotifications = Set<CBUUID>()
    private var didInitialize = false
    private var userRequestedDisconnect = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var scanTimeoutWorkItem: DispatchWorkItem?

    init(store: DeviceStore = DeviceStore()) {
        self.store = store
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.scale2health.bluetooth"]
        )
    }

    deinit {
        reconnectWorkItem?.cancel()
        scanTimeoutWorkItem?.cancel()
    }

    func start() {
        guard central.state == .poweredOn else {
            state = .unavailable
            return
        }

        if let saved = store.load(), let identifier = UUID(uuidString: saved.identifier) {
            selectedDevice = saved
            let restored = central.retrievePeripherals(withIdentifiers: [identifier])
            if let peripheral = restored.first {
                connect(to: peripheral, device: saved)
                return
            }
        }
        startScanning()
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            state = .unavailable
            return
        }
        reconnectWorkItem?.cancel()
        scanTimeoutWorkItem?.cancel()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        state = .scanning
        appendLog("Started BLE scan")

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .idle
            self.appendLog("Stopped BLE scan after 30 seconds")
        }
        scanTimeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    func stopScanning() {
        scanTimeoutWorkItem?.cancel()
        scanTimeoutWorkItem = nil
        central.stopScan()
        if state == .scanning {
            state = currentPeripheral == nil ? .idle : .ready
        }
    }

    func connect(to device: ScaleDevice) {
        guard let identifier = UUID(uuidString: device.identifier) else {
            state = .failed("Invalid peripheral identifier")
            return
        }
        guard let peripheral = peripherals[identifier]
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first else {
            state = .failed("Scale is no longer discoverable")
            return
        }
        connect(to: peripheral, device: device)
    }

    func disconnect() {
        stopScanning()
        reconnectWorkItem?.cancel()
        userRequestedDisconnect = true
        if let peripheral = currentPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        resetConnection()
        state = .idle
        appendLog("Disconnected")
    }

    func clearSavedDevice() {
        disconnect()
        store.clear()
        selectedDevice = nil
        discoveredDevices = []
    }

    func setUserIDFilter(_ userID: UInt8?) {
        guard var saved = selectedDevice else { return }
        let normalized = userID.flatMap { (1...8).contains($0) ? $0 : nil }
        saved.userIDFilter = normalized
        selectedDevice = saved
        if let index = discoveredDevices.firstIndex(where: {
            $0.identifier.caseInsensitiveCompare(saved.identifier) == .orderedSame
        }) {
            discoveredDevices[index].userIDFilter = normalized
        }
        store.save(saved)
        if let latestMeasurement,
           let normalized,
           latestMeasurement.scaleUserID != normalized {
            self.latestMeasurement = nil
        }
        appendLog(normalized.map { "Accepting scale user \($0) only" } ?? "Accepting every scale user")
    }

    private func connect(to peripheral: CBPeripheral, device: ScaleDevice) {
        userRequestedDisconnect = false
        stopScanning()
        reconnectWorkItem?.cancel()
        scanTimeoutWorkItem?.cancel()
        selectedDevice = device
        store.save(device)
        peripherals[peripheral.identifier] = peripheral
        currentPeripheral = peripheral
        activeSession = BS444Session(
            epochMode: device.epochMode ?? BS444Protocol.predictedEpochMode(for: device.name)
        )
        didInitialize = false
        requiredNotifications.removeAll()
        enabledNotifications.removeAll()
        state = .connecting
        appendLog("Connecting to \(device.name) (\(device.identifier))")
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    private func configureConnectedPeripheral(_ peripheral: CBPeripheral) {
        currentPeripheral = peripheral
        peripheral.delegate = self
        state = .discovering
        appendLog("Connected; discovering BS444 service")
        peripheral.discoverServices([CBUUID(string: BS444Protocol.serviceUUID.uuidString)])
    }

    private func discoverCharacteristics(on peripheral: CBPeripheral, service: CBService) {
        let uuids = [
            BS444Protocol.weightCharacteristicUUID,
            BS444Protocol.featureCharacteristicUUID,
            BS444Protocol.commandCharacteristicUUID,
            BS444Protocol.optionalCharacteristicUUID
        ].map { CBUUID(string: $0.uuidString) }
        peripheral.discoverCharacteristics(uuids, for: service)
    }

    private func maybeInitialize() {
        guard !didInitialize,
              let peripheral = currentPeripheral,
              let commandCharacteristic,
              let weightCharacteristic,
              let featureCharacteristic,
              enabledNotifications.isSuperset(of: requiredNotifications) else {
            return
        }

        didInitialize = true
        let mode = activeSession?.epochMode
            ?? selectedDevice.flatMap { BS444Protocol.predictedEpochMode(for: $0.name) }
            ?? .unix
        let command = BS444Protocol.timeCommand(date: Date(), epochMode: mode)
        peripheral.writeValue(command, for: commandCharacteristic, type: .withResponse)
        state = .ready
        appendLog("Enabled weight (\(weightCharacteristic.uuid)) and feature (\(featureCharacteristic.uuid)) notifications")
        appendLog("Sent clock command for \(mode.rawValue) epoch: \(hex(command))")
    }

    private func handle(_ measurement: BodyMeasurement) {
        state = .ready
        if var saved = selectedDevice {
            saved.lastSeen = Date()
            saved.epochMode = activeSession?.epochMode ?? saved.epochMode
            selectedDevice = saved
            store.save(saved)
        }

        if let userIDFilter = selectedDevice?.userIDFilter,
           measurement.scaleUserID != userIDFilter {
            let receivedUser = measurement.scaleUserID.map(String.init) ?? "unassigned"
            appendLog("Ignored measurement for scale user \(receivedUser); filter is user \(userIDFilter)")
            return
        }

        latestMeasurement = measurement
        let user = measurement.scaleUserID.map { "user \($0)" } ?? "unassigned user"
        appendLog("Decoded measurement: \(measurement.weightKg) kg from \(measurement.sourceWeightUnit.label), \(user), at \(measurement.timestamp)")
        onMeasurement?(measurement)
    }

    private func resetConnection() {
        currentPeripheral?.delegate = nil
        currentPeripheral = nil
        activeSession?.reset()
        activeSession = nil
        weightCharacteristic = nil
        featureCharacteristic = nil
        commandCharacteristic = nil
        requiredNotifications.removeAll()
        enabledNotifications.removeAll()
        didInitialize = false
    }

    private func scheduleReconnect() {
        guard store.load() != nil, central.state == .poweredOn else { return }
        reconnectWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.start()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: workItem)
        appendLog("Scheduled one controlled reconnect attempt")
    }

    private func record(_ device: ScaleDevice) {
        if let index = discoveredDevices.firstIndex(where: { $0.identifier == device.identifier }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
        discoveredDevices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appendLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 100 {
            logs.removeFirst(logs.count - 100)
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func advertisedUUIDs(from advertisementData: [String: Any]) -> [UUID] {
        let values = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        return values.compactMap { value in
            if let uuid = UUID(uuidString: value.uuidString) {
                return uuid
            }
            let compact = value.uuidString.replacingOccurrences(of: "-", with: "")
            guard let shortValue = UInt32(compact, radix: 16) else { return nil }
            if compact.count <= 4 {
                return UUID(uuidString: String(format: "0000%04X-0000-1000-8000-00805F9B34FB", shortValue))
            }
            return UUID(uuidString: String(format: "%08X-0000-1000-8000-00805F9B34FB", shortValue))
        }
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .idle
            appendLog("Bluetooth powered on")
            if currentPeripheral == nil {
                start()
            }
        case .poweredOff:
            state = .unavailable
            appendLog("Bluetooth is powered off")
        case .unauthorized:
            state = .failed("Bluetooth permission denied")
        case .unsupported:
            state = .failed("Bluetooth is not supported")
        case .resetting:
            state = .unavailable
        case .unknown:
            state = .unavailable
        @unknown default:
            state = .unavailable
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        willRestoreState dict: [String: Any]
    ) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        appendLog("CoreBluetooth restored \(restored.count) peripheral(s)")
        guard let saved = store.load(),
              let peripheral = restored.first(where: { $0.identifier.uuidString.caseInsensitiveCompare(saved.identifier) == .orderedSame }) else {
            return
        }
        peripherals[peripheral.identifier] = peripheral
        selectedDevice = saved
        activeSession = BS444Session(
            epochMode: saved.epochMode ?? BS444Protocol.predictedEpochMode(for: saved.name)
        )
        if peripheral.state == .connected {
            configureConnectedPeripheral(peripheral)
        } else {
            currentPeripheral = peripheral
            state = .connecting
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (advertisedName?.isEmpty == false ? advertisedName : nil)
            ?? peripheral.name
            ?? "Unnamed BS44x"
        let services = advertisedUUIDs(from: advertisementData)
        guard BS444Protocol.support(for: name, advertisedServices: services) != nil else { return }

        peripherals[peripheral.identifier] = peripheral
        let saved = store.load()
        let isSavedDevice = saved?.identifier.caseInsensitiveCompare(peripheral.identifier.uuidString) == .orderedSame
        let device = ScaleDevice(
            identifier: peripheral.identifier.uuidString,
            name: name,
            lastSeen: Date(),
            epochMode: isSavedDevice
                ? saved?.epochMode
                : BS444Protocol.predictedEpochMode(for: name),
            userIDFilter: isSavedDevice ? saved?.userIDFilter : nil
        )
        record(device)
        appendLog("Found \(name) (RSSI \(RSSI), services: \(services.map { $0.uuidString }.joined(separator: ", ")))")

        if saved?.identifier.caseInsensitiveCompare(device.identifier) == .orderedSame {
            connect(to: peripheral, device: device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        configureConnectedPeripheral(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let shouldReconnect = !userRequestedDisconnect
        userRequestedDisconnect = false
        appendLog("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        resetConnection()
        state = .failed(error?.localizedDescription ?? "Connection failed")
        if shouldReconnect {
            scheduleReconnect()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard currentPeripheral?.identifier == peripheral.identifier || currentPeripheral == nil else { return }
        let shouldReconnect = !userRequestedDisconnect
        userRequestedDisconnect = false
        appendLog("Disconnected: \(error?.localizedDescription ?? "no error")")
        resetConnection()
        state = .idle
        if shouldReconnect {
            scheduleReconnect()
        }
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            appendLog("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: BS444Protocol.serviceUUID.uuidString)
        }) else {
            state = .failed("BS444 service not found")
            appendLog("BS444 service not found")
            return
        }
        appendLog("Found BS444 service")
        discoverCharacteristics(on: peripheral, service: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            state = .failed(error.localizedDescription)
            appendLog("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        guard let characteristics = service.characteristics else {
            state = .failed("No BS444 characteristics found")
            return
        }

        weightCharacteristic = characteristics.first {
            $0.uuid == CBUUID(string: BS444Protocol.weightCharacteristicUUID.uuidString)
        }
        featureCharacteristic = characteristics.first {
            $0.uuid == CBUUID(string: BS444Protocol.featureCharacteristicUUID.uuidString)
        }
        commandCharacteristic = characteristics.first {
            $0.uuid == CBUUID(string: BS444Protocol.commandCharacteristicUUID.uuidString)
        }
        let optional = characteristics.first {
            $0.uuid == CBUUID(string: BS444Protocol.optionalCharacteristicUUID.uuidString)
        }

        guard let weightCharacteristic, let featureCharacteristic, commandCharacteristic != nil else {
            state = .failed("Incomplete BS444 GATT service")
            appendLog("Missing required BS444 characteristic")
            return
        }

        requiredNotifications = [weightCharacteristic.uuid, featureCharacteristic.uuid]
        peripheral.setNotifyValue(true, for: weightCharacteristic)
        peripheral.setNotifyValue(true, for: featureCharacteristic)
        if let optional {
            peripheral.setNotifyValue(true, for: optional)
        }
        appendLog("Requested characteristic indications")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            appendLog("Notification setup for \(characteristic.uuid) failed: \(error.localizedDescription)")
            if requiredNotifications.contains(characteristic.uuid) {
                state = .failed(error.localizedDescription)
            }
            return
        }
        if characteristic.isNotifying {
            enabledNotifications.insert(characteristic.uuid)
        } else {
            enabledNotifications.remove(characteristic.uuid)
        }
        maybeInitialize()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            appendLog("Write to \(characteristic.uuid) failed: \(error.localizedDescription)")
        } else {
            appendLog("Clock command acknowledged")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            appendLog("Read from \(characteristic.uuid) failed: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        appendLog("RX \(characteristic.uuid): \(hex(data))")
        guard var activeSession else { return }

        do {
            let measurements: [BodyMeasurement]
            switch characteristic.uuid {
            case CBUUID(string: BS444Protocol.weightCharacteristicUUID.uuidString):
                measurements = try activeSession.receiveWeight(data, now: Date())
            case CBUUID(string: BS444Protocol.featureCharacteristicUUID.uuidString):
                measurements = try activeSession.receiveFeature(data, now: Date())
            default:
                return
            }
            self.activeSession = activeSession
            for measurement in measurements {
                handle(measurement)
            }
        } catch {
            self.activeSession = activeSession
            appendLog("Ignoring malformed BS444 packet: \(error)")
        }
    }
}
