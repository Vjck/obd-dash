import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var obd: OBDManager

    var body: some View {
        NavigationStack {
            Group {
                if obd.connection == .idle && !obd.hasSavedDevice {
                    DeviceListView()
                } else {
                    DashboardView()
                }
            }
        }
    }
}

struct DeviceListView: View {
    @EnvironmentObject private var obd: OBDManager

    var body: some View {
        List {
            Section {
                Label(obd.bluetoothDescription, systemImage: "antenna.radiowaves.left.and.right")
                Button {
                    obd.isScanning ? obd.stopScan() : obd.startScan()
                } label: {
                    Label(obd.isScanning ? "Ferma ricerca" : "Cerca lettore OBD",
                          systemImage: obd.isScanning ? "stop.circle" : "magnifyingglass")
                }
                .disabled(obd.bluetoothState != .poweredOn)
            } footer: {
                Text("Inserisci il lettore nella presa OBD, accendi il quadro, avvia la ricerca e tocca il lettore per collegarti. L'app se lo ricorda e si ricollega da sola.")
            }

            Section("Dispositivi trovati (\(obd.devices.count))") {
                if obd.devices.isEmpty {
                    Text(obd.isScanning ? "Ricerca in corso…" : "Nessun dispositivo")
                        .foregroundStyle(.secondary)
                }
                ForEach(obd.devices) { device in
                    Button {
                        obd.connect(device)
                    } label: {
                        HStack {
                            Image(systemName: looksLikeOBD(device.name) ? "car.fill" : "dot.radiowaves.right")
                                .foregroundStyle(looksLikeOBD(device.name) ? .green : .secondary)
                            Text(device.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("OBD Dash")
    }

    private func looksLikeOBD(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["OBD", "ELM", "VGATE", "VLINK", "V-LINK", "KONNWEI", "ICAR"].contains { n.contains($0) }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var obd: OBDManager
    @State private var showLog = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusBar

                VStack(spacing: 0) {
                    Text(obd.data.speed.map(String.init) ?? "–")
                        .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                    Text("km/h").font(.title3).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                LazyVGrid(columns: columns, spacing: 12) {
                    MetricCard(title: "Giri", value: obd.data.rpm.map(String.init), unit: "rpm",
                               symbol: "speedometer")
                    MetricCard(title: "Turbo", value: obd.data.boost.map { String(format: "%.2f", $0) }, unit: "bar",
                               symbol: "wind")
                    MetricCard(title: "Liquido", value: obd.data.coolant.map(String.init), unit: "°C",
                               symbol: "thermometer.medium", warn: (obd.data.coolant ?? 0) >= 105)
                    MetricCard(title: "Aria aspirata", value: obd.data.intakeTemp.map(String.init), unit: "°C",
                               symbol: "thermometer.low")
                    MetricCard(title: "Carico motore", value: obd.data.load.map(String.init), unit: "%",
                               symbol: "engine.combustion")
                    MetricCard(title: "Batteria", value: obd.data.voltage.map { String(format: "%.1f", $0) }, unit: "V",
                               symbol: "minus.plus.batteryblock",
                               warn: (obd.data.voltage ?? 13) < 11.8)
                }
            }
            .padding()
        }
        .navigationTitle(obd.connectedName ?? "OBD Dash")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Log") { showLog = true }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Scollega", role: .destructive) { obd.disconnectAndForget() }
            }
        }
        .sheet(isPresented: $showLog) { LogView() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(obd.connection.label).font(.subheadline)
            Spacer()
            if let p = obd.protocolName {
                Text(p).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var statusColor: Color {
        switch obd.connection {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .gray
        default: return .orange
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String?
    let unit: String
    let symbol: String
    var warn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "–")
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(warn ? .red : .primary)
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct LogView: View {
    @EnvironmentObject private var obd: OBDManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(obd.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(obd.log.count - 1, anchor: .bottom) }
            }
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Copia") { UIPasteboard.general.string = obd.log.joined(separator: "\n") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Chiudi") { dismiss() }
                }
            }
        }
    }
}
