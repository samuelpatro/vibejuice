import Foundation
import Testing
@testable import VibeJuice

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
private func account(_ email: String, windows: [QuotaWindow], active: Bool = false, provider: Provider = .claude) -> Account {
    var a = Account(provider: provider, email: email, payload: Data())
    a.status = .ok(windows)
    a.isActive = active
    return a
}

@Suite struct AlertsTests {
    @Test func tokenMaxOncePerWindow() {
        let a = account("alex", windows: [QuotaWindow(id: "weekly_all", label: "Week, all models", usedPercent: 31, resetsAt: hours(9), secondary: true)])
        let first = Alerts.tokenMax([a], seen: [], now: now)
        #expect(first.count == 1)
        #expect(first[0].title == "Use it before it resets")
        #expect(first[0].body.contains("resets in 9 h with 31% used"))
        // Already sent for this window: nothing more.
        #expect(Alerts.tokenMax([a], seen: [first[0].id], now: now).isEmpty)
        // A later reset window is a new alert.
        let later = account("alex", windows: [QuotaWindow(id: "weekly_all", label: "Week, all models", usedPercent: 31, resetsAt: hours(24 * 7 + 9), secondary: true)])
        #expect(Alerts.tokenMax([later], seen: [first[0].id], now: hours(24 * 7)).count == 1)
    }

    @Test func lowQuotaOnlyForActiveUnspentAccounts() {
        let low = [QuotaWindow(id: "session", label: "Session", usedPercent: 92, resetsAt: hours(3), secondary: false)]
        #expect(Alerts.lowQuota([account("a", windows: low, active: true)], seen: [], now: now).count == 1)
        #expect(Alerts.lowQuota([account("a", windows: low, active: false)], seen: [], now: now).isEmpty)

        let spent = [QuotaWindow(id: "session", label: "Session", usedPercent: 100, resetsAt: hours(3), secondary: false)]
        #expect(Alerts.lowQuota([account("a", windows: spent, active: true)], seen: [], now: now).isEmpty)

        let fine = [QuotaWindow(id: "session", label: "Session", usedPercent: 89, resetsAt: hours(3), secondary: false)]
        #expect(Alerts.lowQuota([account("a", windows: fine, active: true)], seen: [], now: now).isEmpty)
    }

    @Test func lowQuotaBodyAndDedup() {
        let w = [
            QuotaWindow(id: "session", label: "Session", usedPercent: 93, resetsAt: hours(3), secondary: false),
            QuotaWindow(id: "weekly_all", label: "Week, all models", usedPercent: 95, resetsAt: hours(40), secondary: true),
        ]
        let due = Alerts.lowQuota([account("alex", windows: w, active: true, provider: .codex)], seen: [], now: now)
        #expect(due.count == 1)
        #expect(due[0].title == "Codex CLI is running low")
        #expect(due[0].body == "alex: 5% left on Week, all models, resets in 2 days. Switch accounts to keep going.")
        #expect(Alerts.lowQuota([account("alex", windows: w, active: true, provider: .codex)], seen: [due[0].id], now: now).isEmpty)
    }

    @Test func rememberKeepsOrderDedupesAndBounds() {
        let sent = [Alert(id: "b", title: "", body: ""), Alert(id: "a", title: "", body: ""), Alert(id: "c", title: "", body: "")]
        #expect(Alerts.remember(["a"], sent: sent) == ["a", "b", "c"])
        #expect(Alerts.remember(["x", "y", "z"], sent: sent, limit: 4) == ["z", "b", "a", "c"])
        // The persisted value must be a plain Array so UserDefaults accepts it.
        let value: Any = Alerts.remember([], sent: sent)
        #expect(value is [String])
    }
}
