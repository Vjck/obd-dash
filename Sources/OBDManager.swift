import CoreBluetooth
import Foundation

/// A Bluetooth LE device found during a scan.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// Latest values read from the car. nil means "not read yet" or "not supported".
struct LiveData: Equatable {
    var speed: Int?          // km/h
    var rpm: Int?            // giri/min
    var coolant: Int?        // °C
    var intakeTemp: Int?     // °C
    var load: Int?           // %
    var boost: Double?       // bar, relative to atmosphere
    var voltage: Double?     // V, measured by the adapter
    var updatedAt: Date?
}

enum ConnectionState: Equatable {
    case idle
    case connecting
    case initializing
    case connected
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Non collegato"
        case .connecting: return "Collegamento al lettore…"
        case .initializing: return "Inizializzazione ELM327…"
        case .connected: return "Collegato"
        case .failed(let reason): return reason
        }
    }
}

enum OBDError: Error {
    case notConnected
    case timeout
    case noData
}

/// Talks to an ELM327 adapter over Bluetooth LE and polls standard OBD II PIDs.
/// Everything runs on the main queue (CoreBluetooth delegate queue and the polling task).
final class OBDManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var connectedName: String?
    @Published private(set) var protocolName: String?
    @Published private(set) var data = LiveData()
    @Published private(set) var log: [String] = []

    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var servicesPending = 0

    private var rxBuffer = ""
    private var pending: CheckedContinuation<String, Error>?
    private var requestID = UUID()
    private var pollTask: Task<Void, Never>?
    private var baroKPa = 101.0
    private var pidFailures: [String: Int] = [:]

    private static let lastDeviceKey = "lastDeviceID"

    /// Known ELM327 BLE services, in order of preference.
    private static let preferredServices: [CBUUID] = [
        CBUUID(string: "FFF0"),
        CBUUID(string: "FFE0"),
        CBUUID(string: "18F0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"),
    ]
    /// Standard services that never carry the serial link.
    private static let ignoredServices: Set<CBUUID> = [
        CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F"),
    ]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var bluetoothDescription: String {
        switch bluetoothState {
        case .poweredOn: return "Bluetooth attivo"
        case .poweredOff: return "Bluetooth spento"
        case .unauthorized: return "Permesso Bluetooth negato (Impostazioni > OBD Dash)"
        case .unsupported: return "Bluetooth LE non supportato"
        case .resetting: return "Bluetooth in riavvio…"
        default: return "Stato Bluetooth sconosciuto"
        }
    }

    var hasSavedDevice: Bool { UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil }

    // MARK: - Scan and connect

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        let id = UUID()
        scanID = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.scanID == id else { return }
            self.stopScan()
        }
    }
    private var scanID = UUID()

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice) {
        guard let p = discovered[device.id] else { return }
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.lastDeviceKey)
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p
        p.delegate = self
        connectedName = p.name
        connection = .connecting
        appendLog("Collegamento a \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
    }

    /// Reconnects to the last used adapter. CoreBluetooth waits until it is in range.
    private func reconnectSavedDevice() {
        guard peripheral == nil,
              let s = UserDefaults.standard.string(forKey: Self.lastDeviceKey),
              let id = UUID(uuidString: s),
              let p = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return }
        connect(p)
    }

    /// Disconnects and forgets the adapter, so a different one can be chosen.
    func disconnectAndForget() {
        UserDefaults.standard.removeObject(forKey: Self.lastDeviceKey)
        stopPolling()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetLink()
        connection = .idle
    }

    private func resetLink() {
        peripheral = nil
        txChar = nil
        rxChar = nil
        connectedName = nil
        protocolName = nil
        rxBuffer = ""
        failPending(OBDError.notConnected)
    }

    // MARK: - ELM327 commands

    /// Sends one command and returns the adapter's reply (text before the '>' prompt).
    func send(_ command: String, timeout: TimeInterval = 4) async throws -> String {
        guard let p = peripheral, let tx = txChar else { throw OBDError.notConnected }
        failPending(OBDError.timeout)
        rxBuffer = ""
        appendLog("> \(command)")
        let id = UUID()
        requestID = id
        return try await withCheckedThrowingContinuation { cont in
            pending = cont
            let type: CBCharacteristicWriteType =
                tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(Data((command + "\r").utf8), for: tx, type: type)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.requestID == id, self.pending != nil else { return }
                self.appendLog("! timeout per \(command)")
                self.failPending(OBDError.timeout)
            }
        }
    }

    private func failPending(_ error: Error) {
        if let c = pending {
            pending = nil
            c.resume(throwing: error)
        }
    }

    private func handleIncoming(_ text: String) {
        rxBuffer += text
        guard let prompt = rxBuffer.firstIndex(of: ">") else { return }
        let reply = String(rxBuffer[..<prompt])
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "SEARCHING..." }
            .joined(separator: "\n")
        rxBuffer = String(rxBuffer[rxBuffer.index(after: prompt)...])
        appendLog("< \(reply.replacingOccurrences(of: "\n", with: " | "))")
        if let c = pending {
            pending = nil
            c.resume(returning: reply)
        }
    }

    /// Mode 01 request; returns the data bytes after "41 <pid>".
    func query(_ pid: String, timeout: TimeInterval = 4) async throws -> [UInt8] {
        let reply = try await send("01" + pid, timeout: timeout)
        return try Self.parse(reply, prefix: "41" + pid)
    }

    static func parse(_ reply: String, prefix: String) throws -> [UInt8] {
        for rawLine in reply.uppercased().split(separator: "\n") {
            let line = rawLine.replacingOccurrences(of: " ", with: "")
            guard let r = line.range(of: prefix) else { continue }
            let hex = Array(line[r.upperBound...])
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < hex.count, let b = UInt8(String(hex[i...i + 1]), radix: 16) {
                bytes.append(b)
                i += 2
            }
            if !bytes.isEmpty { return bytes }
        }
        throw OBDError.noData
    }

    private func initializeAdapter() async {
        connection = .initializing
        do {
            _ = try? await send("ATZ", timeout: 5)
            try? await Task.sleep(nanoseconds: 800_000_000)
            for cmd in ["ATE0", "ATL0", "ATS0", "ATH0", "ATAT1", "ATSP0"] {
                _ = try await send(cmd)
            }
            let first = try await send("0100", timeout: 20)
            if first.contains("UNABLE") || first.contains("NO DATA") || first.contains("ERROR") {
                connection = .failed("L'auto non risponde: accendi il quadro e riprova")
                return
            }
            protocolName = try? await send("ATDP")
            if let b = try? await query("33"), let kPa = b.first, kPa > 50 {
                baroKPa = Double(kPa)
            }
            pidFailures = [:]
            connection = .connected
            startPolling()
        } catch {
            connection = .failed("Il lettore non risponde. Scollegalo e riprova.")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTask = Task { @MainActor [weak self] in
            var cycle = 0
            var consecutiveTimeouts = 0
            while !Task.isCancelled {
                guard let self else { return }
                // Speed and rpm every cycle, the slower values in rotation.
                var pids = ["0D", "0C"]
                let slow = ["05", "0B", "04", "0F", "RV"]
                pids.append(slow[cycle % slow.count])
                for pid in pids where !Task.isCancelled {
                    if (self.pidFailures[pid] ?? 0) >= 3 { continue }
                    do {
                        try await self.read(pid)
                        consecutiveTimeouts = 0
                        self.pidFailures[pid] = 0
                    } catch OBDError.timeout {
                        consecutiveTimeouts += 1
                    } catch OBDError.notConnected {
                        return
                    } catch {
                        self.pidFailures[pid, default: 0] += 1
                    }
                }
                if consecutiveTimeouts >= 6 {
                    self.connection = .failed("Il lettore ha smesso di rispondere")
                    return
                }
                cycle += 1
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func read(_ pid: String) async throws {
        var d = data
        switch pid {
        case "RV":
            let reply = try await send("ATRV")
            let number = reply.filter { "0123456789.".contains($0) }
            guard let v = Double(number) else { throw OBDError.noData }
            d.voltage = v
        default:
            let b = try await query(pid)
            switch pid {
            case "0D": d.speed = Int(b[0])
            case "0C":
                guard b.count >= 2 else { throw OBDError.noData }
                d.rpm = (Int(b[0]) * 256 + Int(b[1])) / 4
            case "05": d.coolant = Int(b[0]) - 40
            case "0F": d.intakeTemp = Int(b[0]) - 40
            case "04": d.load = Int((Double(b[0]) * 100 / 255).rounded())
            case "0B": d.boost = max(0, (Double(b[0]) - baroKPa) / 100)
            default: break
            }
        }
        d.updatedAt = Date()
        data = d
    }

    // MARK: - Log

    func appendLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        log.append("\(f.string(from: Date())) \(line)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }
}

// MARK: - CBCentralManagerDelegate

extension OBDManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            reconnectSavedDevice()
        } else {
            isScanning = false
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discovered[peripheral.identifier] = peripheral
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Senza nome"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i] = device
        } else {
            devices.append(device)
        }
        devices.sort { a, b in
            let an = a.name != "Senza nome", bn = b.name != "Senza nome"
            if an != bn { return an }
            return a.rssi > b.rssi
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        appendLog("Collegato, cerco i servizi")
        connectedName = peripheral.name
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        appendLog("! collegamento fallito: \(error?.localizedDescription ?? "?")")
        resetLink()
        connection = .failed("Collegamento fallito, riprova")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        appendLog("Scollegato \(error?.localizedDescription ?? "")")
        stopPolling()
        let wasActive = connection != .idle
        resetLink()
        guard wasActive else { return }
        connection = .failed("Lettore scollegato, riprovo…")
        // Wait for the adapter to come back (e.g. engine restarted).
        connect(peripheral)
    }
}

// MARK: - CBPeripheralDelegate

extension OBDManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        appendLog("Servizi: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        servicesPending = services.count
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        appendLog("  \(service.uuid.uuidString): " + chars.map { $0.uuid.uuidString }.joined(separator: ", "))
        servicesPending -= 1
        guard servicesPending == 0 else { return }
        chooseCharacteristics(peripheral)
    }

    private func chooseCharacteristics(_ peripheral: CBPeripheral) {
        let services = peripheral.services ?? []
        let ordered = Self.preferredServices.compactMap { uuid in services.first { $0.uuid == uuid } }
            + services.filter { !Self.preferredServices.contains($0.uuid) && !Self.ignoredServices.contains($0.uuid) }
        for s in ordered {
            let chars = s.characteristics ?? []
            let rx = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let tx = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            if let rx, let tx {
                rxChar = rx
                txChar = tx
                appendLog("Uso servizio \(s.uuid.uuidString): RX \(rx.uuid.uuidString), TX \(tx.uuid.uuidString)")
                peripheral.setNotifyValue(true, for: rx)
                return
            }
        }
        connection = .failed("Questo dispositivo non sembra un lettore OBD")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == rxChar else { return }
        if let error {
            connection = .failed("Errore Bluetooth: \(error.localizedDescription)")
            return
        }
        Task { @MainActor [weak self] in await self?.initializeAdapter() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == rxChar, let value = characteristic.value else { return }
        handleIncoming(String(decoding: value, as: UTF8.self))
    }
}
