import SwiftUI

@main
struct ObdDashApp: App {
    @StateObject private var store: AppStore
    @StateObject private var obd: OBDManager

    init() {
        let store = AppStore()
        _store = StateObject(wrappedValue: store)
        _obd = StateObject(wrappedValue: OBDManager(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(obd)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case dashboard, dpf, trips, errors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "Cruscotto"
        case .dpf: return "FAP"
        case .trips: return "Viaggi"
        case .errors: return "Errori"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "speedometer"
        case .dpf: return "smoke"
        case .trips: return "map"
        case .errors: return "exclamationmark.triangle"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var obd: OBDManager
    @State private var tab: AppTab = .dashboard
    @State private var showSettings = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if obd.hasDevice {
                Group {
                    switch tab {
                    case .dashboard: DashboardView(tab: $tab, showSettings: $showSettings)
                    case .dpf: DPFView()
                    case .trips: TripsView()
                    case .errors: ErrorsView()
                    }
                }
                TabBar(tab: $tab)
            } else {
                NavigationStack { DeviceListView() }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}

/// Floating, translucent tab bar.
struct TabBar: View {
    @Binding var tab: AppTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.symbol).font(.system(size: 20, weight: .medium))
                        Text(item.title).font(.system(size: 10, weight: tab == item ? .semibold : .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .foregroundStyle(tab == item ? Theme.accent : Color(white: 0.78))
                    .background(Color.white.opacity(tab == item ? 0.1 : 0), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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
                Text("Inserisci il lettore nella presa OBD, accendi il quadro, avvia la ricerca e tocca il lettore. L'app se lo ricorda e si ricollega da sola.")
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
                                .foregroundStyle(looksLikeOBD(device.name) ? Theme.green : Theme.secondary)
                            Text(device.name).foregroundStyle(.white)
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("Prova con dati dimostrativi") { obd.startDemo() }
            } footer: {
                Text("Mostra valori finti per vedere l'app senza l'auto. Si esce da Impostazioni > Cambia lettore.")
            }
        }
        .navigationTitle("OBD Dash")
    }

    private func looksLikeOBD(_ name: String) -> Bool {
        let n = name.uppercased()
        return ["OBD", "ELM", "VGATE", "VLINK", "V-LINK", "KONNWEI", "ICAR"].contains { n.contains($0) }
    }
}
