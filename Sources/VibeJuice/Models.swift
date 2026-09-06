import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, grok

    var id: String { rawValue }
    var title: String {
        switch self { case .claude: "Claude"; case .codex: "Codex"; case .grok: "Grok" }
    }
    var tool: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex CLI"; case .grok: "Grok CLI" }
    }
    var binary: String { rawValue }
    /// Interactive sign-in that replaces the main login, same as /login inside the CLI.
    var loginCommand: String {
        switch self { case .claude: "claude auth login"; case .codex: "codex login"; case .grok: "grok login" }
    }
    /// Claude Code checks its credential store before each request and adopts a changed login on
    /// its own (Claude Code 2.1.261: the change check clears the cached credentials when the
    /// Keychain item differs). Codex refuses to adopt a different account mid-session; Grok unknown.
    var adoptsLoginLive: Bool { self == .claude }
    /// Reopens the most recent session in the current folder after a restart.
    var resumeCommand: String {
        switch self { case .claude: "claude --continue"; case .codex: "codex resume --last"; case .grok: "grok --continue" }
    }
}

struct RunningSession: Identifiable, Sendable {
    let pid: Int32
    let cwd: String
    /// App hosting the session (cmux, Ghostty, iTerm, Terminal), nil when it could not be told.
    let terminal: String?
    var id: Int32 { pid }
}

struct PendingRestart: Sendable {
    let provider: Provider
    let account: String
    let sessions: [RunningSession]
}

struct QuotaWindow: Identifiable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    /// Secondary windows render dimmer, like the 7-day bar in the reference.
    let secondary: Bool

    var leftPercent: Double { max(0, 100 - usedPercent) }
    var exhausted: Bool { usedPercent >= 99.5 }
    /// "Week, …", "Weekly", Codex's "<pool> week" extras, or an id that says so.
    var isWeekly: Bool { label.lowercased().contains("week") || id.contains("week") || id.hasSuffix("-wk") }
}

struct TokenMaxNudge {
    let window: QuotaWindow
    let hours: Int
    var key: String { "\(window.id)|\(Int(window.resetsAt?.timeIntervalSince1970 ?? 0))" }
}

enum AccountStatus {
    case loading
    case ok([QuotaWindow])
    case noData
    case expired
    /// Claude Code is being run to refresh the expired token.
    case renewing
    case error(String)

    var windows: [QuotaWindow] {
        if case .ok(let w) = self { return w }
        return []
    }
}

/// One saved login. `payload` is the provider's own credential blob, stored in the app's
/// Keychain vault and copied into the main login slot when the account is activated.
struct Account: Identifiable {
    let provider: Provider
    let email: String
    var payload: Data
    var plan: String?
    var status: AccountStatus = .loading
    var manualResets: Int?
    var renewsAt: Date?
    var updatedAt: Date?
    var isActive = false

    static func id(_ provider: Provider, _ email: String) -> String { "\(provider.rawValue):\(email.lowercased())" }
    var id: String { Account.id(provider, email) }
    var displayName: String { email }
    /// Row label: first 15 characters, then an ellipsis. Full name lives in the tooltip.
    var shortName: String { email.count > 16 ? String(email.prefix(15)) + "…" : email }

    /// Smallest headroom across windows, 0 when any window is spent (a 99.6% window is "spent",
    /// not "0.4% left", and auto-switch and the menu bar glass rely on that).
    var headroom: Double? {
        let w = status.windows
        guard !w.isEmpty else { return nil }
        return spent ? 0 : w.map(\.leftPercent).min()
    }

    var spent: Bool { status.windows.contains { $0.exhausted } }

    /// Tokenmax: a weekly window under 50% used whose reset is within 24 hours. Whatever is
    /// left vanishes at reset, so this is the moment to use it. Same rule as the statusline nudge.
    var tokenMax: TokenMaxNudge? { tokenMax(now: Date()) }

    func tokenMax(now: Date) -> TokenMaxNudge? {
        status.windows
            .filter { $0.isWeekly && $0.usedPercent < 50 }
            .compactMap { w -> TokenMaxNudge? in
                guard let r = w.resetsAt else { return nil }
                let hours = r.timeIntervalSince(now) / 3600
                guard hours > 0, hours <= 24 else { return nil }
                return TokenMaxNudge(window: w, hours: Int(hours.rounded(.up)))
            }
            .min { $0.window.resetsAt! < $1.window.resetsAt! }
    }
    var soonestReset: Date? { status.windows.compactMap { $0.exhausted ? $0.resetsAt : nil }.min() }
    var nextReset: Date? { status.windows.compactMap(\.resetsAt).min() }
}

/// Dotted version strings, missing components count as zero: 0.3 == 0.3.0, 0.10 > 0.9.
enum Version {
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// "v0.3.8" or "0.3.8" -> "0.3.8".
    static func number(fromTag tag: String) -> String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
}

/// Short relative times for the popover: "in 3 h", "in 6 days", "12 min ago".
enum Relative {
    static func text(to date: Date, now: Date = Date()) -> String {
        let s = date.timeIntervalSince(now)
        if s <= 0 { return "now" }
        if s < 3600 { return "in \(max(1, Int(s / 60))) min" }
        if s < 36 * 3600 { return "in \(Int((s / 3600).rounded())) h" }
        return "in \(Int((s / 86400).rounded())) days"
    }

    static func text(from date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) min ago" }
        return "\(Int((s / 3600).rounded())) h ago"
    }
}
