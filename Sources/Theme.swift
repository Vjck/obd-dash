import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.271, blue: 0.227)      // #FF453A
    static let card = Color(red: 0.11, green: 0.11, blue: 0.118)        // #1C1C1E
    static let track = Color(red: 0.173, green: 0.173, blue: 0.18)      // #2C2C2E
    static let secondary = Color(red: 0.63, green: 0.63, blue: 0.66)    // #A1A1A8
    static let green = Color(red: 0.19, green: 0.82, blue: 0.345)       // #30D158

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Formats a number the Italian way (decimal comma).
func fmt(_ value: Double, _ decimals: Int = 0) -> String {
    String(format: "%.\(decimals)f", locale: Locale(identifier: "it_IT"), value)
}

extension View {
    func card(radius: CGFloat = 22) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Instant feedback on touch-down.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    var dot: Color?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                HStack(spacing: 7) {
                    if let dot {
                        Circle().fill(dot).frame(width: 8, height: 8)
                    }
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

/// One row of an inset grouped list.
struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 16))
            Spacer(minLength: 12)
            Text(value).font(.system(size: 16)).foregroundStyle(Theme.secondary).monospacedDigit()
        }
        .frame(minHeight: 48)
    }
}

struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased()).font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing { Text(trailing).font(.system(size: 13)) }
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }
}

extension OBDManager {
    /// Text shown in a dashboard tile for a metric.
    func display(_ metric: Metric) -> (value: String, unit: String) {
        func text(_ v: Double?, _ decimals: Int, _ unit: String) -> (String, String) {
            (v.map { fmt($0, decimals) } ?? "–", unit)
        }
        switch metric {
        case .fuelInstant:
            guard let c = instantConsumption else { return ("–", "l/100 km") }
            return (fmt(c.value, 1), c.unit)
        case .fuelAverage: return text(averageConsumption, 1, "l/100 km")
        case .boost: return text(data.boost, 2, "bar")
        case .coolant: return text(data.coolant.map(Double.init), 0, "°C")
        case .battery: return text(data.voltage, 1, "V")
        case .dpf: return text(data.dpfTemp ?? data.egt, 0, "°C")
        case .range: return text(rangeKm, 0, "km")
        case .ambient: return text(data.ambient.map(Double.init), 0, "°C")
        case .load: return text(data.load.map(Double.init), 0, "%")
        case .intakeTemp: return text(data.intakeTemp.map(Double.init), 0, "°C")
        case .fuelLevel: return text(data.fuelLevel, 0, "%")
        }
    }

    var statusColor: Color {
        switch connection {
        case .connected: return Theme.green
        case .failed: return Theme.accent
        case .idle: return .gray
        default: return .orange
        }
    }
}
