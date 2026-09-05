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
    /// Providers without a known usage endpoint show accounts and switching only.
    var hasUsage: Bool { self != .grok }
    /// Reopens the most recent session in the current folder after a restart.
    var resumeCommand: String {
        switch self { case .claude: "claude --continue"; case .codex: "codex resume --last"; case .grok: "grok --continue" }
    }
}

struct RunningSession: Identifiable {
    let pid: Int32
    let cwd: String
    var id: Int32 { pid }
}

struct PendingRestart {
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
    var isWeekly: Bool { label.hasPrefix("Week") || label == "Weekly" || id.contains("week") }
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

    /// Smallest headroom across windows, 0 when any window is spent.
    var headroom: Double? {
        let w = status.windows
        guard !w.isEmpty else { return nil }
        return w.map(\.leftPercent).min()
    }

    var spent: Bool { status.windows.contains { $0.exhausted } }

    /// Tokenmax: a weekly window under 50% used whose reset is within 24 hours. Whatever is
    /// left vanishes at reset, so this is the moment to use it. Same rule as the statusline nudge.
    var tokenMax: TokenMaxNudge? {
        let now = Date()
        return status.windows
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
