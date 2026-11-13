import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var obd: OBDManager
    @EnvironmentObject private var store: AppStore
    @Binding var tab: AppTab
    @Binding var showSettings: Bool

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        let metrics = store.visibleMetrics
        let side = Array(metrics.prefix(2))
        let rest = Array(metrics.dropFirst(2))

        ScrollView {
            VStack(spacing: 12) {
                PageHeader(title: "Cruscotto", subtitle: subtitle, dot: obd.statusColor) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Theme.card, in: Circle())
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel("Impostazioni")
                }

                CarHero()

                HStack(spacing: 12) {
                    SpeedGauge(speed: obd.data.speed, rpm: obd.data.rpm)
                    VStack(spacing: 12) {
                        ForEach(side) { tile($0).frame(maxHeight: .infinity) }
                    }
                }
                .frame(height: 170)

                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(rest) { tile($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
    }

    private var subtitle: String {
        switch obd.connection {
        case .connected: return "\(obd.connectedName ?? "Lettore") · Collegato"
        default: return obd.connection.label
        }
    }

    @ViewBuilder
    private func tile(_ metric: Metric) -> some View {
        let shown = obd.display(metric)
        if metric == .dpf {
            Button {
                tab = .dpf
            } label: {
                MetricTile(title: metric.title, value: shown.value, unit: shown.unit, chevron: true)
            }
            .buttonStyle(PressStyle())
        } else {
            MetricTile(title: metric.title, value: shown.value, unit: shown.unit,
                       highlight: metric == .fuelInstant)
        }
    }
}

/// The car on a black stage with a red glow underneath.
struct CarHero: View {
    var body: some View {
        ZStack {
            Ellipse()
                .fill(Theme.accent.opacity(0.32))
                .frame(width: 260, height: 70)
                .blur(radius: 26)
                .offset(y: 66)
            Ellipse()
                .trim(from: 0, to: 0.5)
                .stroke(Theme.accent.opacity(0.7), lineWidth: 1.5)
                .frame(width: 310, height: 88)
                .offset(y: 76)
            Image("Corsa")
                .resizable()
                .scaledToFit()
                .blendMode(.screen)
                .accessibilityHidden(true)
        }
        .frame(height: 230)
        .frame(maxWidth: .infinity)
    }
}

struct SpeedGauge: View {
    let speed: Int?
    let rpm: Int?

    private var fraction: Double { min(Double(speed ?? 0) / 220, 1) }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Theme.track, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * fraction)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(.spring(response: 0.4, dampingFraction: 1), value: fraction)
            VStack(spacing: 0) {
                Text(speed.map(String.init) ?? "–")
                    .font(Theme.rounded(58, .bold))
                    .tracking(-1.5)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("km/h")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            VStack {
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(rpm.map(String.init) ?? "–").font(Theme.rounded(15)).monospacedDigit()
                    Text("rpm").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(17)
        .frame(width: 170, height: 170)
        .card(radius: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Velocità \(speed ?? 0) chilometri orari, \(rpm ?? 0) giri")
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    var highlight = false
    var chevron = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(white: 0.56))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(Theme.rounded(28))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(highlight ? Theme.accent : .white)
                Text(unit)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity)
        .card()
    }
}
