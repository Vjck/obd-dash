import SwiftUI

private let dayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "it_IT")
    f.dateFormat = "d MMMM, HH:mm"
    return f
}()

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "it_IT")
    f.dateFormat = "HH:mm"
    return f
}()

private func minutes(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min"
}

// MARK: - FAP

struct DPFView: View {
    @EnvironmentObject private var obd: OBDManager
    @EnvironmentObject private var store: AppStore

    private var temperature: Double? { obd.data.dpfTemp ?? obd.data.egt }
    private var hasData: Bool { obd.isAvailable(.dpf) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "FAP", subtitle: "Filtro antiparticolato") { EmptyView() }

                VStack(alignment: .leading, spacing: 6) {
                    Text(obd.regenSince == nil ? "Nessuna rigenerazione in corso" : "Rigenerazione in corso")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(obd.regenSince == nil ? Theme.green : Theme.accent)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(temperature.map { fmt($0) } ?? "–")
                            .font(Theme.rounded(56, .bold))
                            .tracking(-1.5)
                            .monospacedDigit()
                        Text("°C").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.secondary)
                    }
                    if let since = obd.regenSince {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Non spegnere il motore · in corso da \(minutes(Int(context.date.timeIntervalSince(since))))")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.secondary)
                        }
                    } else {
                        Text("Temperatura allo scarico")
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .card(radius: 28)

                VStack(spacing: 0) {
                    InfoRow(title: "Temperatura FAP", value: obd.data.dpfTemp.map { "\(fmt($0)) °C" } ?? "–")
                    Divider()
                    InfoRow(title: "Temperatura gas di scarico", value: obd.data.egt.map { "\(fmt($0)) °C" } ?? "–")
                    Divider()
                    InfoRow(title: "Pressione differenziale", value: obd.data.dpfDeltaP.map { "\(fmt($0 * 10)) mbar" } ?? "–")
                    Divider()
                    InfoRow(title: "Dall'ultima rigenerazione",
                            value: store.regens.isEmpty ? "–" : "\(fmt(store.kmSinceRegen)) km")
                }
                .padding(.horizontal, 16)
                .card()

                if !hasData {
                    Text("La centralina non fornisce i dati del FAP con i comandi standard. Servono i comandi specifici Opel: mandami il log da Impostazioni per aggiungerli.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 16)
                }

                SectionLabel(text: "Rigenerazioni", trailing: averageInterval)
                if store.regens.isEmpty {
                    Text("Nessuna rigenerazione registrata. L'app le riconosce quando lo scarico resta sopra i 550 °C per più di un minuto, con il lettore collegato.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .card()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.regens.prefix(20).enumerated()), id: \.element.id) { index, regen in
                            if index > 0 { Divider() }
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dayFormatter.string(from: regen.start)).font(.system(size: 16))
                                    Text("\(minutes(regen.seconds)) · dopo \(fmt(regen.kmSincePrevious)) km")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Text(regen.completed ? "Completata" : "Interrotta")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(regen.completed ? Theme.green : Theme.secondary)
                            }
                            .frame(minHeight: 60)
                        }
                    }
                    .padding(.horizontal, 16)
                    .card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
    }

    private var averageInterval: String? {
        let done = store.regens.filter { $0.kmSincePrevious > 1 }
        guard done.count >= 2 else { return nil }
        let avg = done.map(\.kmSincePrevious).reduce(0, +) / Double(done.count)
        return "in media ogni \(fmt(avg)) km"
    }
}

// MARK: - Viaggi

struct TripsView: View {
    @EnvironmentObject private var obd: OBDManager
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let past = store.trips.filter { $0.id != obd.trip?.id }

        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "Viaggi", subtitle: "Registrati con il lettore collegato") { EmptyView() }

                if let trip = obd.trip, obd.connection == .connected {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Viaggio in corso")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(fmt(trip.km, 1)).font(Theme.rounded(56, .bold)).tracking(-1.5).monospacedDigit()
                            Text("km").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.secondary)
                        }
                        Text(summary(trip)).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .card(radius: 28)
                }

                SectionLabel(text: "Storico")
                if past.isEmpty {
                    Text("Ancora nessun viaggio. Vengono salvati quelli più lunghi di 200 metri.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .card()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(past.prefix(50).enumerated()), id: \.element.id) { index, trip in
                            if index > 0 { Divider() }
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(dayFormatter.string(from: trip.start)).font(.system(size: 16))
                                    Text(summary(trip)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                Text("\(fmt(trip.km, 1)) km")
                                    .font(Theme.rounded(17))
                                    .monospacedDigit()
                            }
                            .frame(minHeight: 60)
                        }
                    }
                    .padding(.horizontal, 16)
                    .card()
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
    }

    private func summary(_ trip: Trip) -> String {
        var parts = [minutes(Int(trip.end.timeIntervalSince(trip.start)))]
        if let c = trip.consumption { parts.append("\(fmt(c, 1)) l/100 km") }
        if trip.maxSpeed > 0 { parts.append("max \(trip.maxSpeed) km/h") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Errori

struct ErrorsView: View {
    @EnvironmentObject private var obd: OBDManager
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                PageHeader(title: "Errori", subtitle: subtitle) {
                    Button {
                        Task { await obd.readDTCs() }
                    } label: {
                        Text(obd.dtcBusy ? "Leggo…" : "Rileggi")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 18)
                            .frame(height: 44)
                            .background(Theme.track, in: Capsule())
                    }
                    .buttonStyle(PressStyle())
                    .disabled(obd.dtcBusy || obd.connection != .connected)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(obd.dtcReadAt == nil ? "–" : "\(obd.dtcs.count)")
                        .font(Theme.rounded(56, .bold))
                        .tracking(-1.5)
                        .foregroundStyle(obd.dtcs.isEmpty ? .white : Theme.accent)
                    Text(obd.dtcs.count == 1 ? "codice memorizzato" : "codici memorizzati")
                        .font(.system(size: 20, weight: .semibold))
                    Text(milText).font(.system(size: 15)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .card(radius: 28)

                if !obd.dtcs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(obd.dtcs.enumerated()), id: \.element.id) { index, dtc in
                            if index > 0 { Divider() }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(dtc.code).font(.system(size: 17, weight: .semibold, design: .monospaced))
                                    Spacer()
                                    Text(dtc.pending ? "In attesa" : "Attivo")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(dtc.pending ? Theme.secondary : Theme.accent)
                                }
                                Text(DTCInfo.describe(dtc.code))
                                    .font(.system(size: 16))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 14)
                        }
                    }
                    .padding(.horizontal, 16)
                    .card()

                    Button {
                        confirmClear = true
                    } label: {
                        Text("Cancella codici")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .card()
                    }
                    .buttonStyle(PressStyle())
                    .confirmationDialog("Cancellare i codici di errore?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Cancella codici", role: .destructive) {
                            Task { await obd.clearDTCs() }
                        }
                        Button("Annulla", role: .cancel) {}
                    } message: {
                        Text("Spegne la spia motore e azzera i dati diagnostici. Fallo a motore spento e quadro acceso.")
                    }

                    Text("Se il guasto è ancora presente, il codice ricompare.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .task {
            if obd.dtcReadAt == nil { await obd.readDTCs() }
        }
    }

    private var subtitle: String {
        if obd.connection != .connected { return "Collega il lettore per leggere i codici" }
        guard let at = obd.dtcReadAt else { return "Non ancora letti" }
        return "Ultima lettura alle \(timeFormatter.string(from: at))"
    }

    private var milText: String {
        switch obd.data.mil {
        case .some(true): return "La spia motore è accesa"
        case .some(false): return "La spia motore è spenta"
        case .none: return "Stato della spia non disponibile"
        }
    }
}

// MARK: - Impostazioni

struct SettingsView: View {
    @EnvironmentObject private var obd: OBDManager
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Lettore OBD") {
                    LabeledContent("Lettore", value: obd.connectedName ?? "–")
                    LabeledContent("Stato", value: obd.connection.label)
                    Button("Cambia lettore", role: .destructive) {
                        obd.disconnectAndForget()
                        dismiss()
                    }
                }

                Section {
                    ForEach(store.order) { metric in
                        Toggle(isOn: binding(metric)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(metric.title)
                                if !obd.isAvailable(metric) {
                                    Text("Non fornito da questa auto")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tint(Theme.green)
                    }
                    .onMove { store.order.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Dati nel cruscotto")
                } footer: {
                    Text("Velocità e giri restano sempre visibili. I primi due dati stanno accanto al tachimetro. Tocca Modifica per cambiare l'ordine.")
                }

                Section {
                    Stepper("Serbatoio: \(Int(store.tankLitres)) l", value: $store.tankLitres, in: 20...100, step: 1)
                    Stepper("Correzione consumi: \(Int((store.fuelCalibration * 100).rounded())) %",
                            value: $store.fuelCalibration, in: 0.5...1.5, step: 0.01)
                    Button("Azzera consumo medio") { store.resetAverage() }
                } header: {
                    Text("Consumi")
                } footer: {
                    Text("Se dopo un pieno i litri reali sono diversi da quelli calcolati, regola la correzione. Esempio: reali 40 l, calcolati 36 l, imposta 111 %.")
                }

                Section("Diagnostica") {
                    NavigationLink("Log del lettore") { LogView() }
                }
            }
            .navigationTitle("Impostazioni")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Fine") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func binding(_ metric: Metric) -> Binding<Bool> {
        Binding(
            get: { store.enabled.contains(metric) },
            set: { isOn in
                if isOn {
                    store.enabled.insert(metric)
                } else {
                    store.enabled.remove(metric)
                }
            }
        )
    }
}

struct LogView: View {
    @EnvironmentObject private var obd: OBDManager

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(obd.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Copia") { UIPasteboard.general.string = obd.log.joined(separator: "\n") }
            }
        }
    }
}
