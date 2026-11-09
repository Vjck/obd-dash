import CoreBluetooth
import Foundation

/// A Bluetooth LE device found during a scan.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
}

/// Step 1: scans for nearby Bluetooth LE devices so we can check
/// that the ELM327 reader is visible from the iPhone.
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []

    private var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        devices.removeAll()
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.stopScan()
        }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    var stateDescription: String {
        switch state {
        case .poweredOn: return "Bluetooth attivo"
        case .poweredOff: return "Bluetooth spento"
        case .unauthorized: return "Permesso Bluetooth negato (Impostazioni > OBD Dash)"
        case .unsupported: return "Bluetooth LE non supportato"
        case .resetting: return "Bluetooth in riavvio…"
        default: return "Stato Bluetooth sconosciuto"
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if central.state != .poweredOn { isScanning = false }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Senza nome"
        let device = DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        // Named devices first, then by signal strength.
        devices.sort { lhs, rhs in
            let lNamed = lhs.name != "Senza nome"
            let rNamed = rhs.name != "Senza nome"
            if lNamed != rNamed { return lNamed }
            return lhs.rssi > rhs.rssi
        }
    }
}
