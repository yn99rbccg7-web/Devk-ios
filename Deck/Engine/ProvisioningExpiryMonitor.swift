import Foundation
import UserNotifications

/// Monitors the app's own provisioning profile expiry and notifies the user
/// before the 7-day free Apple ID certificate dies.
///
/// Free Apple ID signatures expire every 7 days. This reads the embedded
/// provisioning profile (always present in a signed IPA), extracts the
/// expiration date, and schedules local notifications at 2 days and 1 day
/// before expiry so the user can re-sign before the app stops launching.
///
/// No network, no Apple ID, no external service — pure local plist parsing.
final class ProvisioningExpiryMonitor {

    static let shared = ProvisioningExpiryMonitor()

    private let center = UNUserNotificationCenter.current()
    private let notifiedKey = "deck.expiry.notified.v1"

    private init() {}

    // MARK: - Expiry date extraction

    /// Returns the provisioning profile's expiration date, or nil if unreadable
    /// (e.g. unsigned dev build with no embedded profile).
    func expiryDate() -> Date? {
        guard let profilePath = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let profileData = try? Data(contentsOf: URL(fileURLWithPath: profilePath)) else {
            return nil
        }
        // .mobileprovision is a PKCS#7 (DER) wrapper around a plist payload.
        // Scan for the plist start — either XML or binary.
        let xmlMarker = Data("<?xml".utf8)
        let bplistMarker = Data("bplist".utf8)
        let start: Data.Index?
        if let r = profileData.range(of: xmlMarker) {
            start = r.lowerBound
        } else if let r = profileData.range(of: bplistMarker) {
            start = r.lowerBound
        } else {
            start = nil
        }
        guard let plistStart = start else { return nil }
        let plistData = Data(profileData[plistStart...])
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let expiry = plist["ExpirationDate"] as? Date else {
            return nil
        }
        return expiry
    }

    /// Days remaining until the provisioning profile expires. Nil if unknown.
    func daysRemaining() -> Int? {
        guard let expiry = expiryDate() else { return nil }
        let seconds = expiry.timeIntervalSinceNow
        guard seconds > 0 else { return 0 }
        return Int(ceil(seconds / 86400))
    }

    /// Short human-readable status, e.g. "5 days" or "expired".
    func statusString() -> String {
        guard let days = daysRemaining() else { return "unknown (no embedded profile)" }
        if days <= 0 { return "EXPIRED — re-sign required" }
        if days == 1 { return "1 day — re-sign tomorrow" }
        return "\(days) days"
    }

    // MARK: - Notification scheduling

    /// Call on launch and on foreground. Schedules (or reschedules) the
    /// 2-day and 1-day warnings. Idempotent — safe to call repeatedly.
    func scheduleExpiryWarnings() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            guard granted, let self = self else { return }
            self.scheduleWarningsIfNeeded()
        }
    }

    private func scheduleWarningsIfNeeded() {
        guard let expiry = expiryDate() else { return }
        let now = Date()

        // Cancel any previously scheduled warnings to avoid duplicates.
        center.removePendingNotificationRequests(withIdentifiers: ["deck.expiry.2day", "deck.expiry.1day"])

        let warnings: [(id: String, days: Double, title: String, body: String)] = [
            ("deck.expiry.2day", 2,
             "Deck signature expires in 2 days",
             "Re-sign the Deck IPA before it stops launching. Open your sideloading tool and refresh."),
            ("deck.expiry.1day", 1,
             "Deck signature expires tomorrow",
             "Last chance — re-sign the Deck IPA today or it won't open tomorrow."),
        ]

        for w in warnings {
            let fireDate = expiry.addingTimeInterval(-w.days * 86400)
            guard fireDate > now else { continue } // already past, skip

            let content = UNMutableNotificationContent()
            content.title = w.title
            content.body = w.body
            content.sound = .default

            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let req = UNNotificationRequest(identifier: w.id, content: content, trigger: trigger)
            center.add(req)
        }
    }

    // MARK: - Agent tool surface

    /// Called by the agent loop's `sig_status` tool.
    func toolReport() -> String {
        let status = statusString()
        if let expiry = expiryDate() {
            let fmt = ISO8601DateFormatter()
            return "Signature: \(status) (expires \(fmt.string(from: expiry)))"
        }
        return "Signature: \(status)"
    }
}
