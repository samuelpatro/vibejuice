import Foundation
import Testing
@testable import VibeJuice

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3600) }
private func window(_ id: String, _ label: String, used: Double, resets: Date? = nil, secondary: Bool = false) -> QuotaWindow {
    QuotaWindow(id: id, label: label, usedPercent: used, resetsAt: resets, secondary: secondary)
}
private func account(_ provider: Provider = .claude, _ email: String = "a@b.c", windows: [QuotaWindow], active: Bool = false) -> Account {
    var a = Account(provider: provider, email: email, payload: Data())
    a.status = .ok(windows)
    a.isActive = active
    return a
}

@Suite struct VersionTests {
    @Test func compares() {
        #expect(Version.isNewer("0.3.8", than: "0.3.7"))
        #expect(Version.isNewer("0.10.0", than: "0.9.9"))
        #expect(Version.isNewer("1.0", than: "0.99.99"))
        #expect(!Version.isNewer("0.3.8", than: "0.3.8"))
        #expect(!Version.isNewer("0.3", than: "0.3.0"))
        #expect(!Version.isNewer("0.3.7", than: "0.3.8"))
    }

    @Test func stripsTagPrefix() {
        #expect(Version.number(fromTag: "v0.3.8") == "0.3.8")
        #expect(Version.number(fromTag: "0.3.8") == "0.3.8")
    }
}

@Suite struct RelativeTests {
    @Test func future() {
        #expect(Relative.text(to: hours(-1), now: now) == "now")
        #expect(Relative.text(to: now.addingTimeInterval(30), now: now) == "in 1 min")
        #expect(Relative.text(to: now.addingTimeInterval(25 * 60), now: now) == "in 25 min")
        #expect(Relative.text(to: hours(3.4), now: now) == "in 3 h")
        #expect(Relative.text(to: hours(35), now: now) == "in 35 h")
        #expect(Relative.text(to: hours(6 * 24), now: now) == "in 6 days")
    }

    @Test func past() {
        #expect(Relative.text(from: now.addingTimeInterval(-10), now: now) == "just now")
        #expect(Relative.text(from: now.addingTimeInterval(-5 * 60), now: now) == "5 min ago")
        #expect(Relative.text(from: hours(-17), now: now) == "17 h ago")
    }
}

@Suite struct AccountTests {
    @Test func shortNameCutsAtFifteen() {
        #expect(account(.claude, "sixteen.chars@xy", windows: []).shortName == "sixteen.chars@xy")
        #expect(account(.claude, "seventeen.chars@x", windows: []).shortName == "seventeen.chars…")
        #expect(account(.claude, "alex", windows: []).shortName == "alex")
    }

    @Test func idIsProviderAndLowercasedEmail() {
        #expect(Account.id(.codex, "Alex@Example.com") == "codex:alex@example.com")
        #expect(account(.grok, "X@Y.Z", windows: []).id == "grok:x@y.z")
    }

    @Test func headroomIsSmallestLeft() {
        let a = account(windows: [window("session", "Session", used: 14), window("weekly_all", "Week, all models", used: 3)])
        #expect(a.headroom == 86)
        #expect(!a.spent)
        #expect(account(windows: []).headroom == nil)
    }

    @Test func spentWhenAnyWindowExhausted() {
        let a = account(windows: [window("session", "Session", used: 99.6, resets: hours(2)), window("weekly_all", "Week, all models", used: 40, resets: hours(48))])
        #expect(a.spent)
        #expect(a.headroom == 0)
        #expect(a.soonestReset == hours(2))
        #expect(a.nextReset == hours(2))
    }

    @Test func tokenMaxNeedsWeeklyUnderHalfResettingWithinADay() {
        let due = account(windows: [window("scoped-0", "Week, Fable", used: 31, resets: hours(8.6))])
        #expect(due.tokenMax(now: now)?.hours == 9)
        #expect(due.tokenMax(now: now)?.window.id == "scoped-0")

        let tooUsed = account(windows: [window("weekly_all", "Week, all models", used: 50, resets: hours(8))])
        #expect(tooUsed.tokenMax(now: now) == nil)

        let tooFar = account(windows: [window("weekly_all", "Week, all models", used: 10, resets: hours(25))])
        #expect(tooFar.tokenMax(now: now) == nil)

        let notWeekly = account(windows: [window("session", "Session", used: 10, resets: hours(2))])
        #expect(notWeekly.tokenMax(now: now) == nil)

        let passed = account(windows: [window("weekly_all", "Week, all models", used: 10, resets: hours(-1))])
        #expect(passed.tokenMax(now: now) == nil)
    }

    @Test func tokenMaxPicksTheEarliestReset() {
        let a = account(windows: [
            window("scoped-0", "Week, Fable", used: 20, resets: hours(20)),
            window("weekly_all", "Week, all models", used: 20, resets: hours(5), secondary: true),
        ])
        #expect(a.tokenMax(now: now)?.window.id == "weekly_all")
    }

    @Test func tokenMaxKeyIsWindowAndReset() {
        let n = TokenMaxNudge(window: window("weekly_all", "Week, all models", used: 1, resets: hours(1)), hours: 1)
        #expect(n.key == "weekly_all|\(Int(hours(1).timeIntervalSince1970))")
    }
}

@Suite struct QuotaWindowTests {
    @Test func weeklyHeuristics() {
        #expect(window("weekly_all", "Week, all models", used: 0).isWeekly)
        #expect(window("scoped-0", "Week, Fable", used: 0).isWeekly)
        #expect(window("secondary", "Weekly", used: 0).isWeekly)
        #expect(window("extra-x-wk", "x week", used: 0).isWeekly)
        #expect(!window("session", "Session", used: 0).isWeekly)
        #expect(!window("primary", "5-hour", used: 0).isWeekly)
    }

    @Test func leftAndExhausted() {
        #expect(window("s", "Session", used: 99.5).exhausted)
        #expect(!window("s", "Session", used: 99.4).exhausted)
        #expect(window("s", "Session", used: 120).leftPercent == 0)
        #expect(window("s", "Session", used: 25).leftPercent == 75)
    }
}

private func acct(_ p: Provider, _ email: String, used: Double? = nil, active: Bool = false, updated: Date? = nil) -> Account {
    var a = Account(provider: p, email: email, payload: Data())
    a.isActive = active
    a.updatedAt = updated
    if let used { a.status = .ok([QuotaWindow(id: "w", label: "Week", usedPercent: used, resetsAt: nil, secondary: false)]) }
    return a
}

@Suite struct VisibleProvidersTests {
    @Test func installedOrLoggedInShow() {
        #expect(Provider.visible(installed: [.claude], accounts: [acct(.grok, "g")]) == [.claude, .grok])
        #expect(Provider.visible(installed: [.claude, .codex, .grok], accounts: []) == Provider.allCases)
    }

    @Test func nothingAtAllShowsEverythingSoSignInIsPossible() {
        #expect(Provider.visible(installed: [], accounts: []) == Provider.allCases)
    }
}

@Suite struct AutoSwitchTests {
    @Test func movesFromSpentActiveToMostHeadroom() {
        let move = AutoSwitch.move(among: [acct(.claude, "a", used: 100, active: true), acct(.claude, "b", used: 60), acct(.claude, "c", used: 20)])
        #expect(move?.from.email == "a")
        #expect(move?.to.email == "c")
    }

    @Test func staysPutWhenActiveHasHeadroomOrNobodyElseDoes() {
        #expect(AutoSwitch.move(among: [acct(.claude, "a", used: 50, active: true), acct(.claude, "b", used: 0)]) == nil)
        #expect(AutoSwitch.move(among: [acct(.claude, "a", used: 100, active: true), acct(.claude, "b", used: 100)]) == nil)
        #expect(AutoSwitch.move(among: [acct(.claude, "a", used: 100, active: true), acct(.claude, "b")]) == nil)
    }
}

@Suite struct RefreshThrottleTests {
    @Test func automaticPassSkipsRecentlyFetched() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = acct(.claude, "fresh", updated: now.addingTimeInterval(-10))
        let stale = acct(.claude, "stale", updated: now.addingTimeInterval(-120))
        let never = acct(.claude, "never")
        #expect(Store.due([fresh, stale, never], force: false, now: now).map(\.email) == ["stale", "never"])
        #expect(Store.due([fresh, stale, never], force: true, now: now).count == 3)
    }
}
