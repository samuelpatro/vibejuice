import Foundation
import UserNotifications

/// A notification that is due. `id` is stable per account and reset window, so each one is
/// sent once and the decision is a pure function of the accounts and what was already sent.
struct Alert: Equatable {
    let id: String
    let title: String
    let body: String
}

enum Alerts {
    static let tokenMaxKey = "tokenMaxNotified"
    static let lowQuotaKey = "lowQuotaNotified"

    /// Tokenmax: a weekly window under 50% used whose reset is within 24 hours.
    static func tokenMax(_ accounts: [Account], seen: [String], now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        for a in accounts {
            guard let n = a.tokenMax(now: now) else { continue }
            let id = "\(a.id)|\(n.key)"
            guard !seen.contains(id), !out.contains(where: { $0.id == id }) else { continue }
            out.append(Alert(id: id,
                             title: "Use it before it resets",
                             body: "\(a.provider.title) \(a.displayName): weekly window resets in \(n.hours) h with \(Int(n.window.usedPercent.rounded()))% used."))
        }
        return out
    }

    /// An active account under 10% left on any window. Spent accounts are left to auto-switch,
    /// which has its own notification.
    static func lowQuota(_ accounts: [Account], seen: [String], now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        for a in accounts where a.isActive && !a.spent {
            guard let w = a.status.windows.filter({ $0.leftPercent <= 10 }).min(by: { $0.leftPercent < $1.leftPercent }) else { continue }
            let id = "\(a.id)|\(w.id)|\(Int(w.resetsAt?.timeIntervalSince1970 ?? 0))"
            guard !seen.contains(id), !out.contains(where: { $0.id == id }) else { continue }
            let reset = w.resetsAt.map { ", resets \(Relative.text(to: $0, now: now))" } ?? ""
            out.append(Alert(id: id,
                             title: "\(a.provider.tool) is running low",
                             body: "\(a.displayName): \(Int(w.leftPercent.rounded()))% left on \(w.label)\(reset). Switch accounts to keep going."))
        }
        return out
    }

    /// The sent list to persist: existing ids plus the new ones, oldest dropped past `limit`.
    /// Returns a plain Array because UserDefaults rejects any other sequence type at runtime.
    static func remember(_ existing: [String], sent: [Alert], limit: Int = 200) -> [String] {
        var list = existing
        for a in sent where !list.contains(a.id) { list.append(a.id) }
        return Array(list.suffix(limit))
    }
}

enum Notifier {
    static func post(_ alert: Alert) { post(title: alert.title, body: alert.body) }

    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
