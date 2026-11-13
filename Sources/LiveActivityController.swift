import ActivityKit
import Foundation

/// Starts, updates and ends the Live Activity that CarPlay and the Lock Screen show.
@MainActor
final class LiveActivityController {
    private var activity: Activity<DriveAttributes>?
    private var lastPush = Date.distantPast
    private var retryAfter = Date.distantPast
    private var updating = false
    /// Set when the person swipes the activity away: do not bring it back until the next connection.
    private var dismissedByUser = false

    init() {
        // Remove activities left over from a previous run of the app.
        Task {
            for old in Activity<DriveAttributes>.activities {
                await old.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Call often: it sends at most one update every two seconds.
    func push(_ state: DriveAttributes.ContentState, carName: String) {
        let now = Date()
        guard !updating, !dismissedByUser, now.timeIntervalSince(lastPush) >= 2 else { return }
        lastPush = now
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(90))
        if let current = activity {
            if current.activityState == .dismissed || current.activityState == .ended {
                activity = nil
                dismissedByUser = true
                return
            }
            updating = true
            Task {
                await current.update(content)
                self.updating = false
            }
        } else if now >= retryAfter, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                activity = try Activity.request(attributes: DriveAttributes(carName: carName),
                                                content: content, pushType: nil)
            } catch {
                // Starting only works while the app is on screen: try again later.
                retryAfter = now.addingTimeInterval(10)
            }
        }
    }

    func end() {
        dismissedByUser = false
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    var isRunning: Bool { activity != nil }
}
