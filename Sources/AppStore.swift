import Foundation
import SwiftUI

/// A value the dashboard can show in a tile. Speed and rpm are always shown.
enum Metric: String, CaseIterable, Codable, Identifiable {
    case fuelInstant, fuelAverage, boost, coolant, battery, dpf
    case range, ambient, load, intakeTemp, fuelLevel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fuelInstant: return "Consumo istantaneo"
        case .fuelAverage: return "Consumo medio"
        case .boost: return "Turbo"
        case .coolant: return "Liquido"
        case .battery: return "Batteria"
        case .dpf: return "FAP"
        case .range: return "Autonomia"
        case .ambient: return "Temperatura esterna"
        case .load: return "Carico motore"
        case .intakeTemp: return "Aria aspirata"
        case .fuelLevel: return "Livello carburante"
        }
    }

    static let defaultEnabled: Set<Metric> = [.fuelInstant, .fuelAverage, .boost, .coolant, .battery, .dpf]
}

struct Trip: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date
    var km: Double = 0
    var litres: Double = 0
    var maxSpeed: Int = 0

    var consumption: Double? {
        km > 0.3 && litres > 0 ? litres / km * 100 : nil
    }
}

struct Regen: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var seconds: Int
    var kmSincePrevious: Double
    var completed: Bool
}

/// Settings and history, saved on the phone.
@MainActor
final class AppStore: ObservableObject {
    @Published var order: [Metric] { didSet { persist() } }
    @Published var enabled: Set<Metric> { didSet { persist() } }
    @Published var tankLitres: Double { didSet { persist() } }
    @Published var fuelCalibration: Double { didSet { persist() } }
    @Published var trips: [Trip]
    @Published var regens: [Regen]
    @Published var totalLitres: Double
    @Published var totalKm: Double
    @Published var kmSinceRegen: Double

    private struct Persisted: Codable {
        var order: [Metric]
        var enabled: [Metric]
        var tankLitres: Double
        var fuelCalibration: Double
        var trips: [Trip]
        var regens: [Regen]
        var totalLitres: Double
        var totalKm: Double
        var kmSinceRegen: Double
    }

    private static let key = "appStore.v1"

    init() {
        var saved: Persisted?
        if let raw = UserDefaults.standard.data(forKey: Self.key) {
            saved = try? JSONDecoder().decode(Persisted.self, from: raw)
        }
        var order = saved?.order ?? Metric.allCases
        for m in Metric.allCases where !order.contains(m) { order.append(m) }
        self.order = order
        self.enabled = saved.map { Set($0.enabled) } ?? Metric.defaultEnabled
        self.tankLitres = saved?.tankLitres ?? 45
        self.fuelCalibration = saved?.fuelCalibration ?? 1.0
        self.trips = saved?.trips ?? []
        self.regens = saved?.regens ?? []
        self.totalLitres = saved?.totalLitres ?? 0
        self.totalKm = saved?.totalKm ?? 0
        self.kmSinceRegen = saved?.kmSinceRegen ?? 0
    }

    var visibleMetrics: [Metric] { order.filter { enabled.contains($0) } }

    func persist() {
        let p = Persisted(order: order, enabled: Array(enabled), tankLitres: tankLitres,
                          fuelCalibration: fuelCalibration, trips: trips, regens: regens,
                          totalLitres: totalLitres, totalKm: totalKm, kmSinceRegen: kmSinceRegen)
        if let raw = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(raw, forKey: Self.key)
        }
    }

    func upsert(_ trip: Trip) {
        if let i = trips.firstIndex(where: { $0.id == trip.id }) {
            trips[i] = trip
        } else {
            trips.insert(trip, at: 0)
            if trips.count > 200 { trips.removeLast(trips.count - 200) }
        }
    }

    func addRegen(_ regen: Regen) {
        regens.insert(regen, at: 0)
        if regens.count > 100 { regens.removeLast(regens.count - 100) }
        persist()
    }

    func resetAverage() {
        totalLitres = 0
        totalKm = 0
        persist()
    }
}
