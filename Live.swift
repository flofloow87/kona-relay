import ActivityKit
import Foundation

/// Activité en direct (écran verrouillé + Dynamic Island) pendant un trajet ou une recharge
enum Live {
    static var current: Activity<KonaActivityAttributes>? { Activity<KonaActivityAttributes>.activities.first }

    static func start(_ title: String, _ st: KonaActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, current == nil else { return }
        _ = try? Activity.request(attributes: KonaActivityAttributes(title: title),
                                  content: .init(state: st, staleDate: Date().addingTimeInterval(900)))
    }

    static func update(_ st: KonaActivityAttributes.ContentState) {
        guard let a = current else { return }
        Task { await a.update(.init(state: st, staleDate: Date().addingTimeInterval(900))) }
    }

    static func end() {
        for a in Activity<KonaActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .default) }
        }
    }
}
