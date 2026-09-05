import Foundation

enum Provider: String, CaseIterable, Identifiable, Codable {
    case claude, codex

    var id: String { rawValue }
    var title: String { self == .claude ? "Claude" : "Codex" }
    var tool: String { self == .claude ? "Claude Code" : "Codex CLI" }
    var binary: String { rawValue }
    /// Interactive sign-in that replaces the main login, same as /login inside the CLI.
    var loginCommand: String { self == .claude ? "claude auth login" : "codex login" }
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
}

enum AccountStatus {
    case loading
    case ok([QuotaWindow])
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

    /// Smallest headroom across windows, 0 when any window is spent.
    var headroom: Double? {
        let w = status.windows
        guard !w.isEmpty else { return nil }
        return w.map(\.leftPercent).min()
    }

    var spent: Bool { status.windows.contains { $0.exhausted } }
    var soonestReset: Date? { status.windows.compactMap { $0.exhausted ? $0.resetsAt : nil }.min() }
    var nextReset: Date? { status.windows.compactMap(\.resetsAt).min() }
}
