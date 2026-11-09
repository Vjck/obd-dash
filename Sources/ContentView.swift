import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var ble: BLEManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(ble.stateDescription, systemImage: "antenna.radiowaves.left.and.right")
                    Button {
                        ble.isScanning ? ble.stopScan() : ble.startScan()
                    } label: {
                        Label(
                            ble.isScanning ? "Ferma ricerca" : "Cerca lettore OBD",
                            systemImage: ble.isScanning ? "stop.circle" : "magnifyingglass"
                        )
                    }
                    .disabled(ble.state != .poweredOn)
                } footer: {
                    Text("Inserisci il lettore nella presa OBD, accendi il quadro e avvia la ricerca. Il lettore di solito si chiama OBDII, OBDBLE, Vgate o simile.")
                }

                Section("Dispositivi trovati (\(ble.devices.count))") {
                    if ble.devices.isEmpty {
                        Text(ble.isScanning ? "Ricerca in corso…" : "Nessun dispositivo")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(ble.devices) { device in
                        HStack {
                            Image(systemName: looksLikeOBD(device.name) ? "car.fill" : "dot.radiowaves.right")
                                .foregroundStyle(looksLikeOBD(device.name) ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(device.name)
                                Text(device.id.uuidString)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("OBD Dash")
        }
    }

    private func looksLikeOBD(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["OBD", "ELM", "VGATE", "VLINK", "IOS-VLINK", "KONNWEI", "V-LINK"].contains { n.contains($0) }
    }
}
