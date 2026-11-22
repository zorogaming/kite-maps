import ActivityKit
import Foundation
import VelaCore

/**
 * Keeps the lock screen's next turn up to date during a drive. Only asks the system to redraw when
 * what's shown changes (the distance moves in steps), and never more than every two seconds.
 */
@MainActor
final class LiveTurn {
    static let shared = LiveTurn()
    private var activity: Any?
    private var last: Any?
    private var lastAt = Date.distantPast

    func start(_ n: Navigator) {
        end()
        NavLink.shared.update(n)
        guard #available(iOS 16.2, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled, n.route.mode == .drive else { return }
        let state = Self.state(n)
        do {
            activity = try Activity.request(attributes: NavActivityAttributes(destination: n.destination.name),
                                            content: ActivityContent(state: state, staleDate: nil))
            last = state
            lastAt = Date()
        } catch {
            activity = nil
        }
    }

    func update(_ n: Navigator) {
        NavLink.shared.update(n)
        guard #available(iOS 16.2, *), let a = activity as? Activity<NavActivityAttributes> else { return }
        let state = Self.state(n)
        guard state != last as? NavActivityAttributes.ContentState, Date().timeIntervalSince(lastAt) >= 2 || state.arrived else { return }
        last = state
        lastAt = Date()
        Task { await a.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))) }
    }

    func end() {
        NavLink.shared.update(nil)
        guard #available(iOS 16.2, *) else { return }
        if let a = activity as? Activity<NavActivityAttributes> {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
        activity = nil
        last = nil
        // One left over from a drive the app was closed during.
        for a in Activity<NavActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    @available(iOS 16.2, *)
    private static func state(_ n: Navigator) -> NavActivityAttributes.ContentState {
        let m = n.nextManeuver
        let left = n.progress?.remainingSeconds ?? n.route.durationSeconds
        return NavActivityAttributes.ContentState(
            symbol: m.map { maneuverSymbol($0.type) } ?? "arrow.up",
            distance: n.progress.map { Fmt.distance($0.distanceToNext) } ?? "",
            instruction: n.arrived ? "You've arrived" : InstructionBanner.headline(m),
            road: n.arrived ? nil : m?.road,
            arrival: Fmt.arrival(left),
            arrived: n.arrived)
    }
}
