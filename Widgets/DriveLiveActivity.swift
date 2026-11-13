import ActivityKit
import SwiftUI
import WidgetKit

private let accent = Color(red: 1.0, green: 0.271, blue: 0.227)
private let secondary = Color(red: 0.63, green: 0.63, blue: 0.66)

private func rounded(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

@main
struct ObdDashWidgets: WidgetBundle {
    var body: some Widget {
        DriveLiveActivity()
    }
}

struct DriveLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DriveAttributes.self) { context in
            DriveActivityView(state: context.state)
                .activityBackgroundTint(Color.black)
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ValueCell(value: "\(context.state.speed)", unit: "km/h", title: nil, size: 30, color: .white)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ValueCell(value: "\(context.state.rpm)", unit: "rpm", title: nil, size: 30, color: accent)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let minutes = context.state.regenMinutes {
                        RegenLine(minutes: minutes)
                    } else {
                        HStack(spacing: 14) {
                            ForEach(Array(context.state.items.prefix(3).enumerated()), id: \.offset) { _, item in
                                ValueCell(value: item.value, unit: item.unit, title: item.title, size: 18, color: .white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            } compactLeading: {
                Text("\(context.state.speed)")
                    .font(rounded(15))
                    .monospacedDigit()
            } compactTrailing: {
                Text(context.state.regenMinutes == nil ? "\(context.state.rpm)" : "FAP")
                    .font(rounded(15))
                    .monospacedDigit()
                    .foregroundStyle(accent)
            } minimal: {
                Text("\(context.state.speed)")
                    .font(rounded(13))
                    .monospacedDigit()
            }
        }
        .supplementalActivityFamilies([.small])
    }
}

/// Picks the layout: small for CarPlay and Apple Watch, wide for the Lock Screen.
struct DriveActivityView: View {
    @Environment(\.activityFamily) private var family
    let state: DriveAttributes.ContentState

    var body: some View {
        switch family {
        case .small: SmallView(state: state)
        default: WideView(state: state)
        }
    }
}

private struct ValueCell: View {
    let value: String
    let unit: String
    let title: String?
    let size: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(rounded(size)).monospacedDigit().foregroundStyle(color)
                Text(unit).font(.system(size: max(size * 0.45, 10), weight: .medium)).foregroundStyle(secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if let title {
                Text(title)
                    .font(.system(size: max(size * 0.5, 10)))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

private struct RegenLine: View {
    let minutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rigenerazione FAP in corso")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
            Text("Non spegnere il motore · da \(minutes) min")
                .font(.system(size: 13))
                .foregroundStyle(secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

/// CarPlay and Apple Watch: four values, or the regeneration warning.
private struct SmallView: View {
    let state: DriveAttributes.ContentState

    var body: some View {
        Group {
            if let minutes = state.regenMinutes {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Rigenerazione FAP")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("Non spegnere il motore")
                        .font(.system(size: 15))
                    Text("In corso da \(minutes) min")
                        .font(.system(size: 13))
                        .foregroundStyle(secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let cells = Array(state.items.prefix(4))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        cell(cells, 0)
                        cell(cells, 1)
                    }
                    GridRow {
                        cell(cells, 2)
                        cell(cells, 3)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ cells: [DriveAttributes.Item], _ index: Int) -> some View {
        if index < cells.count {
            ValueCell(value: cells[index].value, unit: cells[index].unit, title: cells[index].title,
                      size: 22, color: index == 0 ? accent : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }
}

/// Lock Screen and notification banner.
private struct WideView: View {
    let state: DriveAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(state.speed)").font(rounded(44)).monospacedDigit()
                        Text("km/h").font(.system(size: 15, weight: .semibold)).foregroundStyle(secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(state.rpm)").font(rounded(15, .semibold)).monospacedDigit().foregroundStyle(accent)
                        Text("rpm").font(.system(size: 12, weight: .medium)).foregroundStyle(secondary)
                    }
                }
                let cells = Array(state.items.prefix(4))
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        cell(cells, 0)
                        cell(cells, 1)
                    }
                    GridRow {
                        cell(cells, 2)
                        cell(cells, 3)
                    }
                }
            }
            if let minutes = state.regenMinutes {
                RegenLine(minutes: minutes)
            }
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    @ViewBuilder
    private func cell(_ cells: [DriveAttributes.Item], _ index: Int) -> some View {
        if index < cells.count {
            ValueCell(value: cells[index].value, unit: cells[index].unit, title: cells[index].title,
                      size: 18, color: .white)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }
}
