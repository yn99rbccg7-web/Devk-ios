import ActivityKit
import Foundation

/// Owns the persistent Deck Live Activity (the "floating pill"):
/// Dynamic Island + Lock Screen presence with tap-to-open chat.
/// Same iOS system as the device-monitor widget.
@MainActor
final class LiveDeck {
    static let shared = LiveDeck()
    private var activity: Activity<DeckAttributes>?
    private init() {}

    /// Start the pill if it isn't already running (also re-attaches after
    /// the app restarts, since activities outlive the app process).
    func ensureRunning() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity != nil { return }
        if let existing = Activity<DeckAttributes>.activities.first {
            activity = existing
            return
        }
        do {
            activity = try Activity.request(
                attributes: DeckAttributes(),
                content: ActivityContent(
                    state: DeckAttributes.ContentState(status: "ready", line: "Tap Chat to talk"),
                    staleDate: nil))
        } catch {
            activity = nil
        }
    }

    func update(status: String, line: String) {
        ensureRunning()
        guard let activity else { return }
        let content = ActivityContent(
            state: DeckAttributes.ContentState(status: status, line: String(line.prefix(120))),
            staleDate: nil)
        Task { await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
