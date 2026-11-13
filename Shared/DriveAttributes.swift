import ActivityKit
import Foundation

/// Data shown by the Live Activity (CarPlay, Lock Screen, Dynamic Island).
struct DriveAttributes: ActivityAttributes {
    struct Item: Codable, Hashable {
        var title: String
        var value: String
        var unit: String
    }

    struct ContentState: Codable, Hashable {
        var speed: Int
        var rpm: Int
        var items: [Item]
        /// Minutes since a DPF regeneration started, nil when none is running.
        var regenMinutes: Int?
    }

    var carName: String
}
