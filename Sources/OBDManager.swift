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
    var rpm: Int?
    var coolant: Int?        // °C
    var intakeTemp: Int?     // °C
    var ambient: Int?        // °C
    var load: Int?           // %
    var boost: Double?       // bar, relative to atmosphere
    var voltage: Double?     // V, measured by the adapter
    var fuelLevel: Double?   // %
    var fuelRate: Double?    // l/h, already calibrated
    var dpfTemp: Double?     // °C
    var dpfDeltaP: Double?   // kPa
    var egt: Double?         // °C
    var mil: Bool?           // engine warning light
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
        case .initializing: return "Inizializzazione…"
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

struct DTC: Identifiable, Equatable {
    let code: String
    let pending: Bool
    var id: String { code + (pending ? "-p" : "") }
}

/// Talks to an ELM327 adapter over Bluetooth LE and polls OBD II PIDs.
@MainActor
final class OBDManager: NSObject, ObservableObject {
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var hasDevice = false
    @Published private(set) var isDemo = false
    @Published private(set) var connectedName: String?
    @Published private(set) var protocolName: String?
    @Published private(set) var supported: Set<Int> = []
    @Published private(set) var data = LiveData()
    @Published private(set) var trip: Trip?
    @Published private(set) var regenSince: Date?
    @Published private(set) var dtcs: [DTC] = []
    @Published private(set) var dtcReadAt: Date?
    @Published private(set) var dtcBusy = false
    @Published private(set) var log: [String] = []
    /// First lines after each connection (services, setup, supported PIDs): never rotated out.
    @Published private(set) var headLog: [String] = []
    @Published private(set) var scanProgress: Double?
    @Published private(set) var scanResults: [String] = UserDefaults.standard.stringArray(forKey: "scanResults") ?? []

    private let store: AppStore
    private var central: CBCentralManager!
    private var discovered: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var servicesPending = 0
    private var scanID = UUID()

    private var rxBuffer = ""
    private var pending: CheckedContinuation<String, Error>?
    private var requestID = UUID()
    private var quietReply = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private var pollTask: Task<Void, Never>?
    private var failures: [String: Int] = [:]
    private var baroKPa = 101.0
    private var maf: Double?
    private var lambda: Double?
    private var rawFuelRate: Double?
    private var lastSample: Date?
    private var lastPersist = Date()
    private var hotSince: Date?
    private var coolSince: Date?
    private var regenKm = 0.0
    private var capturingHead = false
    private var scanTask: Task<Void, Never>?

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

    init(store: AppStore) {
        self.store = store
        super.init()
        hasDevice = UserDefaults.standard.string(forKey: Self.lastDeviceKey) != nil
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

    // MARK: - Derived values

    /// Instant consumption: l/100 km while moving, l/h when (almost) stopped.
    var instantConsumption: (value: Double, unit: String)? {
        guard let rate = data.fuelRate else { return nil }
        let speed = Double(data.speed ?? 0)
        if speed >= 5 { return (min(rate / speed * 100, 99.9), "l/100 km") }
        return (rate, "l/h")
    }

    var averageConsumption: Double? {
        if isDemo { return 4.6 }
        return store.totalKm > 1 && store.totalLitres > 0 ? store.totalLitres / store.totalKm * 100 : nil
    }

    var rangeKm: Double? {
        guard let level = data.fuelLevel, let avg = averageConsumption, avg > 0.5 else { return nil }
        return level / 100 * store.tankLitres / avg * 100
    }

    func supports(_ pid: String) -> Bool {
        supported.isEmpty || supported.contains(Int(pid, radix: 16) ?? -1)
    }

    /// false only when the car is connected and has told us it lacks the needed PIDs.
    func isAvailable(_ metric: Metric) -> Bool {
        guard connection == .connected, !isDemo, !supported.isEmpty else { return true }
        let fuel = supports("5E") || supports("10")
        switch metric {
        case .fuelInstant, .fuelAverage: return fuel
        case .boost: return supports("0B")
        case .coolant: return supports("05")
        case .battery: return true
        case .dpf: return supports("7C") || supports("78")
        case .range: return fuel && supports("2F")
        case .ambient: return supports("46")
        case .load: return supports("04")
        case .intakeTemp: return supports("0F")
        case .fuelLevel: return supports("2F")
        }
    }

    // MARK: - Scan and connect

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil, options: nil)
        isScanning = true
        let id = UUID()
        scanID = id
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if self.scanID == id { self.stopScan() }
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice) {
        guard let p = discovered[device.id] else { return }
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.lastDeviceKey)
        hasDevice = true
        connect(p)
    }

    private func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p
        p.delegate = self
        connectedName = p.name
        connection = .connecting
        headLog = []
        capturingHead = true
        appendLog("Collegamento a \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
    }

    /// Reconnects to the last used adapter. CoreBluetooth waits until it is in range.
    private func reconnectSavedDevice() {
        guard peripheral == nil, !isDemo,
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
        finishSession()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        resetLink()
        isDemo = false
        hasDevice = false
        dtcs = []
        dtcReadAt = nil
        data = LiveData()
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

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Sends one command and returns the adapter's reply (text before the '>' prompt).
    /// Commands are serialised: only one is on the wire at a time.
    func send(_ command: String, timeout: TimeInterval = 4, quiet: Bool = false) async throws -> String {
        await acquire()
        defer { release() }
        guard let p = peripheral, let tx = txChar else { throw OBDError.notConnected }
        rxBuffer = ""
        quietReply = quiet
        if !quiet { appendLog("> \(command)") }
        let id = UUID()
        requestID = id
        return try await withCheckedThrowingContinuation { cont in
            pending = cont
            let type: CBCharacteristicWriteType =
                tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.writeValue(Data((command + "\r").utf8), for: tx, type: type)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard self.requestID == id, self.pending != nil else { return }
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
        if !quietReply { appendLog("< \(reply.replacingOccurrences(of: "\n", with: " | "))") }
        if let c = pending {
            pending = nil
            c.resume(returning: reply)
        }
    }

    /// Mode 01 request; returns the data bytes after "41 <pid>".
    func query(_ pid: String, timeout: TimeInterval = 4) async throws -> [UInt8] {
        let reply = try await send("01" + pid, timeout: timeout)
        guard let bytes = Self.payloads(reply, prefix: "41" + pid).first else { throw OBDError.noData }
        return bytes
    }

    /// Extracts the data bytes that follow `prefix` in each reply line.
    /// Handles multi-frame replies ("0: 41 78 ..", "1: ..") by joining the frames.
    nonisolated static func payloads(_ reply: String, prefix: String) -> [[UInt8]] {
        let lines = reply.uppercased().split(separator: "\n").map { $0.replacingOccurrences(of: " ", with: "") }
        func bytes(_ hex: Substring) -> [UInt8] {
            let chars = Array(hex)
            var out: [UInt8] = []
            var i = 0
            while i + 1 < chars.count, let b = UInt8(String(chars[i...i + 1]), radix: 16) {
                out.append(b)
                i += 2
            }
            return out
        }
        func isFrame(_ line: String) -> Bool {
            let c = Array(line)
            return c.count > 2 && c[1] == ":"
        }
        if lines.contains(where: isFrame) {
            let joined = lines.filter(isFrame).map { String($0.dropFirst(2)) }.joined()
            guard let r = joined.range(of: prefix) else { return [] }
            let b = bytes(joined[r.upperBound...])
            return b.isEmpty ? [] : [b]
        }
        var result: [[UInt8]] = []
        for line in lines {
            guard let r = line.range(of: prefix) else { continue }
            let b = bytes(line[r.upperBound...])
            if !b.isEmpty { result.append(b) }
        }
        return result
    }

    /// Decodes a mode 03/07 CAN payload: one count byte, then two bytes per code.
    nonisolated static func decodeDTCs(_ payload: [UInt8]) -> [String] {
        guard payload.count >= 3 else { return [] }
        let count = Int(payload[0])
        var codes: [String] = []
        var i = 1
        while i + 1 < payload.count, codes.count < max(count, 1) {
            let a = payload[i], b = payload[i + 1]
            i += 2
            if a == 0 && b == 0 { continue }
            let letter = ["P", "C", "B", "U"][Int(a >> 6)]
            codes.append(String(format: "%@%d%X%02X", letter, Int((a >> 4) & 0x3), Int(a & 0xF), Int(b)))
        }
        return codes
    }

    private func initializeAdapter() async {
        connection = .initializing
        do {
            _ = try? await send("ATZ", timeout: 5)
            try? await Task.sleep(nanoseconds: 800_000_000)
            for cmd in ["ATE0", "ATL0", "ATS0", "ATH0", "ATAT1", "ATSP0"] {
                _ = try await send(cmd)
            }

            // Ask the car which PIDs it supports (also wakes up the protocol search).
            var found: Set<Int> = []
            var base = 0
            while base <= 0x60 {
                let pid = String(format: "%02X", base)
                guard let reply = try? await send("01" + pid, timeout: base == 0 ? 20 : 5) else { break }
                let maps = Self.payloads(reply, prefix: "41" + pid).filter { $0.count >= 4 }
                if maps.isEmpty { break }
                var more = false
                for m in maps {
                    for i in 0..<32 where m[i / 8] & (UInt8(0x80) >> UInt8(i % 8)) != 0 {
                        found.insert(base + i + 1)
                        if i == 31 { more = true }
                    }
                }
                if !more { break }
                base += 0x20
            }
            guard !found.isEmpty else {
                connection = .failed("L'auto non risponde: accendi il quadro e riprova")
                return
            }
            supported = found
            appendLog("PID supportati: " + found.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))

            protocolName = try? await send("ATDP")
            if supports("33"), let b = try? await query("33"), let kPa = b.first, kPa > 50 {
                baroKPa = Double(kPa)
            }
            if supports("01"), let b = try? await query("01"), let a = b.first {
                data.mil = a & 0x80 != 0
            }
            failures = [:]
            connection = .connected
            startPolling()
        } catch {
            connection = .failed("Il lettore non risponde. Scollegalo e riprova.")
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        lastSample = nil
        capturingHead = false
        if trip == nil { trip = Trip(start: Date(), end: Date()) }
        let fuelPID: String? = supports("5E") ? "5E" : (supports("10") ? "10" : nil)
        let slow = ["05", "0B", "04", "0F", "46", "2F", "44", "7C", "7A", "78"].filter { supports($0) } + ["RV"]
        pollTask = Task {
            var cycle = 0
            var timeouts = 0
            while !Task.isCancelled {
                var pids = ["0D", "0C"]
                if let fuelPID { pids.append(fuelPID) }
                let alive = slow.filter { (self.failures[$0] ?? 0) < 3 }
                if !alive.isEmpty { pids.append(alive[cycle % alive.count]) }
                for pid in pids {
                    if Task.isCancelled { return }
                    if (self.failures[pid] ?? 0) >= 3 { continue }
                    do {
                        try await self.read(pid)
                        timeouts = 0
                        self.failures[pid] = 0
                    } catch OBDError.timeout {
                        timeouts += 1
                    } catch OBDError.notConnected {
                        return
                    } catch {
                        self.failures[pid, default: 0] += 1
                    }
                }
                if timeouts >= 6 {
                    self.connection = .failed("Il lettore ha smesso di rispondere")
                    return
                }
                self.integrate()
                cycle += 1
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func read(_ pid: String) async throws {
        if pid == "RV" {
            let reply = try await send("ATRV")
            guard let v = Double(reply.filter { "0123456789.".contains($0) }) else { throw OBDError.noData }
            data.voltage = v
            return
        }
        let b = try await query(pid)
        func need(_ n: Int) throws {
            if b.count < n { throw OBDError.noData }
        }
        func word(_ i: Int) -> Double { Double(Int(b[i]) * 256 + Int(b[i + 1])) }
        switch pid {
        case "0D": data.speed = Int(b[0])
        case "0C":
            try need(2)
            data.rpm = Int(word(0) / 4)
        case "05": data.coolant = Int(b[0]) - 40
        case "0F": data.intakeTemp = Int(b[0]) - 40
        case "46": data.ambient = Int(b[0]) - 40
        case "04": data.load = Int((Double(b[0]) * 100 / 255).rounded())
        case "0B": data.boost = max(0, (Double(b[0]) - baroKPa) / 100)
        case "2F": data.fuelLevel = Double(b[0]) * 100 / 255
        case "5E":
            try need(2)
            rawFuelRate = word(0) / 20
            updateFuel()
        case "10":
            try need(2)
            maf = word(0) / 100
            updateFuel()
        case "44":
            try need(2)
            let l = word(0) / 32768
            if l > 0.5 { lambda = l }
        case "7C":
            // DPF temperature, bank 1: support bits, then inlet and outlet.
            try need(5)
            var temps: [Double] = []
            if b[0] & 0x01 != 0 { temps.append(word(1) / 10 - 40) }
            if b[0] & 0x02 != 0 { temps.append(word(3) / 10 - 40) }
            guard let t = temps.max() else { throw OBDError.noData }
            data.dpfTemp = t
        case "7A":
            // DPF pressure, bank 1: support bits, then differential pressure (signed).
            try need(3)
            guard b[0] & 0x01 != 0 else { throw OBDError.noData }
            let raw = Int(b[1]) * 256 + Int(b[2])
            data.dpfDeltaP = Double(raw > 32767 ? raw - 65536 : raw) / 100
        case "78":
            // Exhaust gas temperature, bank 1: support bits, then up to four sensors.
            try need(3)
            var temps: [Double] = []
            for s in 0..<4 where b[0] & (UInt8(1) << UInt8(s)) != 0 && b.count >= 3 + s * 2 {
                temps.append(word(1 + s * 2) / 10 - 40)
            }
            guard let t = temps.max() else { throw OBDError.noData }
            data.egt = t
        default: break
        }
    }

    /// Fuel rate in l/h. Uses the car's own value when available, otherwise estimates
    /// it from the air flow (diesel: air mass / (14.5 × lambda), density 832 g/l).
    private func updateFuel() {
        var litresPerHour: Double?
        if let r = rawFuelRate {
            litresPerHour = r
        } else if let maf {
            let load = max(Double(data.load ?? 30) / 100, 0.15)
            let lam = lambda ?? min(max(0.6 / load, 1.2), 4)
            litresPerHour = maf / (14.5 * lam) * 3600 / 832
        }
        data.fuelRate = litresPerHour.map { $0 * store.fuelCalibration }
    }

    /// Adds the distance and fuel used since the previous sample to the trip and the totals.
    private func integrate() {
        let now = Date()
        defer { lastSample = now }
        guard !isDemo, let last = lastSample else { return }
        let dt = min(now.timeIntervalSince(last), 5)
        if (data.rpm ?? 0) > 0 {
            let dkm = Double(data.speed ?? 0) * dt / 3600
            let dl = (data.fuelRate ?? 0) * dt / 3600
            store.add(km: dkm, litres: data.fuelRate != nil ? dl : nil)
            if var t = trip {
                t.km += dkm
                t.litres += dl
                t.end = now
                t.maxSpeed = max(t.maxSpeed, data.speed ?? 0)
                trip = t
            }
        }
        updateRegen(now)
        if now.timeIntervalSince(lastPersist) > 20 {
            lastPersist = now
            saveTrip()
        }
    }

    private func saveTrip() {
        if let t = trip, t.km >= 0.2 { store.upsert(t) }
        store.persist()
    }

    /// A regeneration is assumed when the exhaust stays very hot for over a minute.
    private func updateRegen(_ now: Date) {
        guard let t = data.dpfTemp ?? data.egt else { return }
        if regenSince == nil {
            if t >= 550 {
                if hotSince == nil { hotSince = now }
                if let h = hotSince, now.timeIntervalSince(h) > 60 {
                    regenSince = h
                    regenKm = store.kmSinceRegen
                    store.kmSinceRegen = 0
                    coolSince = nil
                }
            } else {
                hotSince = nil
            }
        } else if t < 450 {
            if coolSince == nil { coolSince = now }
            if let c = coolSince, now.timeIntervalSince(c) > 30 { endRegen(interrupted: false) }
        } else {
            coolSince = nil
        }
    }

    private func endRegen(interrupted: Bool) {
        guard let s = regenSince else { return }
        let seconds = Int(Date().timeIntervalSince(s))
        store.addRegen(Regen(start: s, seconds: seconds, kmSincePrevious: regenKm,
                             completed: !interrupted && seconds >= 300))
        regenSince = nil
        hotSince = nil
        coolSince = nil
    }

    private func finishSession() {
        guard !isDemo else { return }
        if regenSince != nil { endRegen(interrupted: true) }
        hotSince = nil
        saveTrip()
        trip = nil
    }

    // MARK: - Trouble codes

    func readDTCs() async {
        if isDemo {
            dtcReadAt = Date()
            return
        }
        guard connection == .connected, !dtcBusy else { return }
        dtcBusy = true
        defer { dtcBusy = false }
        var found: [DTC] = []
        for (command, prefix, isPending) in [("03", "43", false), ("07", "47", true)] {
            guard let reply = try? await send(command, timeout: 6) else { continue }
            for payload in Self.payloads(reply, prefix: prefix) {
                for code in Self.decodeDTCs(payload) where !found.contains(where: { $0.code == code }) {
                    found.append(DTC(code: code, pending: isPending))
                }
            }
        }
        if let b = try? await query("01"), let a = b.first {
            data.mil = a & 0x80 != 0
        }
        dtcs = found
        dtcReadAt = Date()
    }

    func clearDTCs() async {
        if isDemo {
            dtcs = []
            data.mil = false
            return
        }
        guard connection == .connected else { return }
        _ = try? await send("04", timeout: 6)
        await readDTCs()
    }

    // MARK: - Demo

    /// Shows moving, made-up values so the interface can be tried without the car.
    func startDemo() {
        stopScan()
        isDemo = true
        hasDevice = true
        connectedName = "Demo"
        protocolName = "Dati dimostrativi"
        connection = .connected
        dtcs = [DTC(code: "P2463", pending: false), DTC(code: "P0401", pending: true)]
        dtcReadAt = Date()
        pollTask = Task {
            var t = 0.0
            while !Task.isCancelled {
                t += 0.25
                let speed = 70 + 35 * sin(t / 4)
                var d = LiveData()
                d.speed = Int(speed)
                d.rpm = Int(1400 + speed * 12 + 120 * sin(t))
                d.coolant = 89
                d.intakeTemp = 31
                d.ambient = 21
                d.load = Int(45 + 25 * sin(t / 3))
                d.boost = 0.9 + 0.4 * sin(t / 3)
                d.voltage = 14.1
                d.fuelLevel = 62
                d.fuelRate = 3.6 + 1.8 * sin(t / 3)
                d.dpfTemp = 312
                d.dpfDeltaP = 1.4
                d.egt = 298
                d.mil = !self.dtcs.isEmpty
                self.data = d
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // MARK: - Log

    func appendLog(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let entry = "\(f.string(from: Date())) \(line)"
        if capturingHead && headLog.count < 150 {
            headLog.append(entry)
            return
        }
        log.append(entry)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }

    var fullLog: [String] {
        headLog.isEmpty ? log : headLog + ["…"] + log
    }

    // MARK: - Search for manufacturer-specific data

    /// Identifier ranges (service 22) where Opel and Fiat-derived engine ECUs usually keep live data.
    private static let scanRanges: [ClosedRange<Int>] = [
        0x1800...0x19FF, 0x3800...0x38FF, 0x1000...0x17FF, 0x2000...0x24FF, 0x3000...0x33FF, 0x4000...0x45FF,
    ]

    /// Asks the engine ECU for every identifier in the ranges and keeps the ones it answers.
    /// Read-only: service 22 only reads values. Live polling is paused meanwhile.
    func startDataSearch() {
        guard connection == .connected, !isDemo, scanTask == nil else { return }
        stopPolling()
        scanResults = []
        scanProgress = 0
        scanTask = Task {
            let ids = Self.scanRanges.flatMap { Array($0) }
            var negative = 0, silent = 0
            let proto = (try? await self.send("ATDPN")) ?? "?"
            self.scanResults.append("Protocollo \(proto) · PID standard: "
                + self.supported.sorted().map { String(format: "%02X", $0) }.joined(separator: " "))
            if let last = proto.last, last == "6" || last == "8" {
                _ = try? await self.send("ATSH7E0")
                for (index, id) in ids.enumerated() {
                    if Task.isCancelled || self.peripheral == nil { break }
                    let did = String(format: "%04X", id)
                    if let reply = try? await self.send("22" + did, timeout: 3, quiet: true) {
                        if let bytes = Self.payloads(reply, prefix: "62" + did).first {
                            self.scanResults.append(did + ": " + bytes.map { String(format: "%02X", $0) }.joined())
                            UserDefaults.standard.set(self.scanResults, forKey: "scanResults")
                        } else if reply.replacingOccurrences(of: " ", with: "").contains("7F22") {
                            negative += 1
                        } else {
                            silent += 1
                        }
                    } else {
                        silent += 1
                    }
                    if index % 8 == 0 { self.scanProgress = Double(index) / Double(ids.count) }
                }
                _ = try? await self.send("ATSH7DF")
                self.scanResults.append("Fine · rifiutati \(negative), senza risposta \(silent)"
                    + (Task.isCancelled ? " · interrotta" : ""))
            } else {
                self.scanResults.append("Ricerca non possibile: protocollo non previsto")
            }
            UserDefaults.standard.set(self.scanResults, forKey: "scanResults")
            self.scanProgress = nil
            self.scanTask = nil
            if self.peripheral != nil, self.connection == .connected { self.startPolling() }
        }
    }

    func stopDataSearch() {
        scanTask?.cancel()
    }

    // MARK: - Bluetooth events (always delivered on the main queue)

    private func bluetoothStateChanged() {
        bluetoothState = central.state
        if central.state == .poweredOn {
            reconnectSavedDevice()
        } else {
            isScanning = false
        }
    }

    private func didDiscover(_ p: CBPeripheral, advertisedName: String?, rssi: Int) {
        discovered[p.identifier] = p
        let device = DiscoveredDevice(id: p.identifier, name: p.name ?? advertisedName ?? "Senza nome", rssi: rssi)
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

    private func didConnect(_ p: CBPeripheral) {
        appendLog("Collegato, cerco i servizi")
        connectedName = p.name
        p.discoverServices(nil)
    }

    private func didFailToConnect(_ message: String) {
        appendLog("! collegamento fallito: \(message)")
        resetLink()
        connection = .failed("Collegamento fallito, riprova")
    }

    private func didDisconnect(_ p: CBPeripheral, message: String) {
        appendLog("Scollegato \(message)")
        stopPolling()
        finishSession()
        let wasActive = connection != .idle
        resetLink()
        guard wasActive, !isDemo else { return }
        connection = .failed("Lettore scollegato, riprovo…")
        // Wait for the adapter to come back (e.g. engine restarted).
        connect(p)
    }

    private func didDiscoverServices(_ p: CBPeripheral) {
        let services = p.services ?? []
        appendLog("Servizi: " + services.map { $0.uuid.uuidString }.joined(separator: ", "))
        servicesPending = services.count
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    private func didDiscoverCharacteristics(_ p: CBPeripheral, service: CBService) {
        let chars = service.characteristics ?? []
        appendLog("  \(service.uuid.uuidString): " + chars.map { $0.uuid.uuidString }.joined(separator: ", "))
        servicesPending -= 1
        guard servicesPending == 0 else { return }
        let services = p.services ?? []
        let ordered = Self.preferredServices.compactMap { uuid in services.first { $0.uuid == uuid } }
            + services.filter { !Self.preferredServices.contains($0.uuid) && !Self.ignoredServices.contains($0.uuid) }
        for s in ordered {
            let cs = s.characteristics ?? []
            let rx = cs.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            let tx = cs.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            if let rx, let tx {
                rxChar = rx
                txChar = tx
                appendLog("Uso servizio \(s.uuid.uuidString): RX \(rx.uuid.uuidString), TX \(tx.uuid.uuidString)")
                p.setNotifyValue(true, for: rx)
                return
            }
        }
        connection = .failed("Questo dispositivo non sembra un lettore OBD")
    }

    private func didUpdateNotification(_ characteristic: CBCharacteristic, message: String?) {
        guard characteristic == rxChar else { return }
        if let message {
            connection = .failed("Errore Bluetooth: \(message)")
            return
        }
        Task { await self.initializeAdapter() }
    }

    private func didReceive(_ characteristic: CBCharacteristic) {
        guard characteristic == rxChar, let value = characteristic.value else { return }
        handleIncoming(String(decoding: value, as: UTF8.self))
    }
}

// MARK: - CoreBluetooth delegates

extension OBDManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { self.bluetoothStateChanged() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { self.didDiscover(peripheral, advertisedName: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { self.didConnect(peripheral) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "?"
        MainActor.assumeIsolated { self.didFailToConnect(message) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? ""
        MainActor.assumeIsolated { self.didDisconnect(peripheral, message: message) }
    }
}

extension OBDManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { self.didDiscoverServices(peripheral) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { self.didDiscoverCharacteristics(peripheral, service: service) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let message = error?.localizedDescription
        MainActor.assumeIsolated { self.didUpdateNotification(characteristic, message: message) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated { self.didReceive(characteristic) }
    }
}
