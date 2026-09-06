import Foundation

struct UsageResult {
    var windows: [QuotaWindow]
    var plan: String?
    var manualResets: Int?
}

enum UsageError: Error, CustomStringConvertible {
    case unauthorized
    /// Status code plus the first bytes of the body, for the debugger; the body never reaches the log.
    case http(Int, String)
    case badPayload

    var description: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .http(let code, _): "http \(code)"
        case .badPayload: "bad payload"
        }
    }
}

enum UsageClient {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ any: Any?) -> Date? {
        if let s = any as? String { return iso.date(from: s) ?? isoPlain.date(from: s) }
        if let n = any as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        return nil
    }

    // MARK: Claude

    /// Same call Claude Code's /usage command makes.
    static func claude(_ creds: ClaudeCredentials) async throws -> UsageResult {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(code) else { throw UsageError.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.badPayload }
        DebugLog.shape("claude-usage", root)
        let windows = parseClaude(root)
        guard !windows.isEmpty else { throw UsageError.badPayload }
        return UsageResult(windows: windows, plan: creds.planLabel, manualResets: nil)
    }

    /// Windows from the /api/oauth/usage body. Pure, so the schemas can be tested with fixtures.
    static func parseClaude(_ root: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []

        // Current schema: a `limits` array, one entry per window, with the model-scoped week
        // carrying its model's display name. This is what Claude Code's /usage renders.
        if let limits = root["limits"] as? [[String: Any]], !limits.isEmpty {
            var session: QuotaWindow?, scoped: [QuotaWindow] = [], all: QuotaWindow?
            for (i, l) in limits.enumerated() {
                guard let pct = l["percent"] as? Double else { continue }
                let kind = (l["kind"] as? String) ?? ""
                let reset = parseDate(l["resets_at"])
                switch kind {
                case "session":
                    session = QuotaWindow(id: "session", label: "Session", usedPercent: pct, resetsAt: reset, secondary: false)
                case "weekly_all":
                    all = QuotaWindow(id: "weekly_all", label: "Week, all models", usedPercent: pct, resetsAt: reset, secondary: true)
                default:
                    var name = kind == "weekly_scoped" ? "model" : kind
                    if let scope = l["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                       let dn = model["display_name"] as? String, !dn.isEmpty { name = dn }
                    scoped.append(QuotaWindow(id: "scoped-\(i)", label: "Week, \(name)", usedPercent: pct, resetsAt: reset, secondary: false))
                }
            }
            windows = [session].compactMap { $0 } + scoped + [all].compactMap { $0 }
        }

        // Older schema fallback.
        if windows.isEmpty {
            let order: [(String, String, Bool)] = [
                ("five_hour", "Session", false),
                ("seven_day_opus", "Week, Opus", false),
                ("seven_day_sonnet", "Week, Sonnet", false),
                ("seven_day", "Week, all models", true),
            ]
            for (key, label, secondary) in order {
                guard let w = root[key] as? [String: Any], let util = w["utilization"] as? Double else { continue }
                windows.append(QuotaWindow(id: key, label: label, usedPercent: util, resetsAt: parseDate(w["resets_at"]), secondary: secondary))
            }
        }
        return windows
    }

    // MARK: Codex

    private static let codexBase = URL(string: "https://chatgpt.com/backend-api")!

    private static func codexRequest(_ path: String, _ creds: CodexCredentials, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: codexBase.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        if let acct = creds.accountId { req.setValue(acct, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    static func codex(_ creds: CodexCredentials) async throws -> UsageResult {
        let (data, resp) = try await session.data(for: codexRequest("wham/usage", creds))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(code) else { throw UsageError.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.badPayload }
        DebugLog.shape("codex-usage", root)
        var result = parseCodex(root, fallbackPlan: creds.planLabel)
        guard !result.windows.isEmpty else { throw UsageError.badPayload }
        if result.manualResets == nil { result.manualResets = try? await codexManualResets(creds) }
        return result
    }

    /// Windows, plan and reset credits from the wham/usage body. Pure, tested with fixtures.
    /// `now` anchors windows that only carry `reset_after_seconds`.
    static func parseCodex(_ root: [String: Any], fallbackPlan: String?, now: Date = Date()) -> UsageResult {
        let limits = (root["rate_limit"] ?? root["rate_limits"]) as? [String: Any] ?? root
        var windows: [QuotaWindow] = []
        for (key, secondary) in [("primary_window", false), ("secondary_window", true), ("primary", false), ("secondary", true)] {
            guard let w = limits[key] as? [String: Any], let used = w["used_percent"] as? Double else { continue }
            if windows.contains(where: { $0.id == (secondary ? "secondary" : "primary") }) { continue }
            let seconds = (w["limit_window_seconds"] as? Double) ?? ((w["window_minutes"] as? Double).map { $0 * 60 }) ?? 0
            let label: String
            switch seconds {
            case 0: label = secondary ? "Weekly" : "Limit"
            case ..<(6 * 3600): label = "5-hour"
            case ..<(2 * 86400): label = "Daily"
            default: label = "Weekly"
            }
            var reset: Date? = parseDate(w["reset_at"] ?? w["resets_at"])
            if reset == nil, let after = w["reset_after_seconds"] as? Double { reset = now.addingTimeInterval(after) }
            windows.append(QuotaWindow(id: secondary ? "secondary" : "primary", label: label, usedPercent: used, resetsAt: reset, secondary: secondary))
        }
        // Feature-specific limits (e.g. a model-specific pool) show up only once they are in use.
        if let extras = root["additional_rate_limits"] as? [[String: Any]] {
            for extra in extras {
                guard let rl = extra["rate_limit"] as? [String: Any] else { continue }
                let name = (extra["limit_name"] as? String) ?? (extra["metered_feature"] as? String) ?? "Extra"
                for (key, tag) in [("primary_window", "5h"), ("secondary_window", "wk")] {
                    guard let w = rl[key] as? [String: Any], let used = w["used_percent"] as? Double, used > 0 else { continue }
                    let seconds = (w["limit_window_seconds"] as? Double) ?? 0
                    var reset: Date? = parseDate(w["reset_at"])
                    if reset == nil, let after = w["reset_after_seconds"] as? Double { reset = now.addingTimeInterval(after) }
                    windows.append(QuotaWindow(id: "extra-\(name)-\(tag)", label: "\(name) \(seconds < 6 * 3600 ? "5h" : "week")", usedPercent: used, resetsAt: reset, secondary: true))
                }
            }
        }

        var plan = fallbackPlan
        if let p = root["plan_type"] as? String, !p.isEmpty {
            plan = CodexCredentials(planType: p).planLabel
        }
        var resets: Int? = nil
        if let rc = root["rate_limit_reset_credits"] as? [String: Any] {
            resets = (rc["available_count"] as? Int) ?? (rc["available_count"] as? Double).map(Int.init)
        }
        return UsageResult(windows: windows, plan: plan, manualResets: resets)
    }

    /// Codex exposes a small number of manual rate-limit resets per period.
    /// The payload shape isn't documented, so read it leniently.
    static func codexManualResets(_ creds: CodexCredentials) async throws -> Int? {
        let (data, resp) = try await session.data(for: codexRequest("wham/rate-limit-reset-credits", creds))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        DebugLog.shape("codex-reset-credits", root)
        for key in ["available_count", "available", "remaining", "count"] {
            if let n = root[key] as? Int { return n }
            if let n = root[key] as? Double { return Int(n) }
        }
        if let nested = root["credits"] as? [String: Any] {
            for key in ["available", "remaining", "balance"] {
                if let n = nested[key] as? Int { return n }
                if let n = nested[key] as? Double { return Int(n) }
            }
        }
        return nil
    }

    // MARK: Grok

    /// Grok Build (xai-org/grok-build) is open source; these are the calls behind its /usage
    /// command: the credits config from the CLI proxy, and the live tier from /user.
    // Trailing slash matters: relative paths replace the last segment of a base without one.
    private static let grokBase = URL(string: "https://cli-chat-proxy.grok.com/v1/")!
    private static let grokClientVersion = "1.0.13"

    private static func grokRequest(_ pathAndQuery: String, _ creds: GrokCredentials) -> URLRequest {
        var req = URLRequest(url: URL(string: pathAndQuery, relativeTo: grokBase)!.absoluteURL)
        req.setValue("Bearer \(creds.key)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        if let id = creds.userId { req.setValue(id, forHTTPHeaderField: "x-userid") }
        req.setValue(grokClientVersion, forHTTPHeaderField: "x-grok-client-version")
        req.setValue("interactive", forHTTPHeaderField: "x-grok-client-mode")
        return req
    }

    static func grok(_ creds: GrokCredentials) async throws -> UsageResult {
        let (data, resp) = try await session.data(for: grokRequest("billing?format=credits", creds))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(code) else { throw UsageError.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.badPayload }
        DebugLog.shape("grok-billing", root)
        var result = parseGrok(root)
        guard !result.windows.isEmpty else { throw UsageError.badPayload }
        result.plan = (try? await grokTier(creds)) ?? nil
        return result
    }

    /// The one window Grok meters: `config.creditUsagePercent` of the weekly or monthly
    /// allowance, reset at `currentPeriod.end`. The backend omits zero-valued fields, so a
    /// missing percent with a period present means 0.
    static func parseGrok(_ root: [String: Any]) -> UsageResult {
        guard let config = root["config"] as? [String: Any] else { return UsageResult(windows: [], plan: nil, manualResets: nil) }
        let period = config["currentPeriod"] as? [String: Any] ?? [:]
        let type = (period["type"] as? String) ?? ""
        var used = (config["creditUsagePercent"] as? Double) ?? 0
        if config["creditUsagePercent"] == nil,
           let spent = (config["used"] as? [String: Any])?["val"] as? Double,
           let limit = (config["monthlyLimit"] as? [String: Any])?["val"] as? Double, limit > 0 {
            used = spent / limit * 100
        }
        let reset = parseDate(period["end"] ?? config["billingPeriodEnd"])
        guard config["creditUsagePercent"] != nil || reset != nil else { return UsageResult(windows: [], plan: nil, manualResets: nil) }
        let (id, label) = type.contains("MONTHLY") ? ("grok-month", "Monthly limit") : ("grok-week", "Weekly limit")
        let window = QuotaWindow(id: id, label: label, usedPercent: min(100, max(0, used)), resetsAt: reset, secondary: false)
        return UsageResult(windows: [window], plan: nil, manualResets: nil)
    }

    /// Live subscription tier, only present with `include=subscription`.
    static func grokTier(_ creds: GrokCredentials) async throws -> String? {
        let (data, resp) = try await session.data(for: grokRequest("user?include=subscription", creds))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        DebugLog.shape("grok-user", root)
        return (root["subscriptionTier"] as? String).flatMap(grokTierLabel)
    }

    /// Backend tier names ("XPremium", "SuperGrokHeavy") as the CLI displays them.
    static func grokTierLabel(_ tier: String) -> String? {
        let t = tier.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        switch t {
        case "XPremiumPlus", "x_premium_plus": return "X Premium+"
        case "XPremium", "x_premium": return "X Premium"
        case "XBasic", "x_basic": return "X Basic"
        case "SuperGrokHeavy": return "SuperGrok Heavy"
        case "SuperGrokLite": return "SuperGrok Lite"
        default: return t
        }
    }

    static func codexConsumeReset(_ creds: CodexCredentials) async throws {
        var req = codexRequest("wham/rate-limit-reset-credits/consume", creds, method: "POST")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 || code == 403 { throw UsageError.unauthorized }
        guard (200..<300).contains(code) else { throw UsageError.http(code, String(decoding: data.prefix(200), as: UTF8.self)) }
    }
}

/// Writes the *shape* of a JSON payload (keys, value types, numbers and short enums; never
/// tokens or ids) to ~/Library/Logs/VibeJuice so undocumented endpoints can be mapped.
enum DebugLog {
    static func redactedForTest(_ v: Any) -> Any { redact(v) }

    static func shape(_ name: String, _ json: Any) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VibeJuice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: redact(json), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: dir.appendingPathComponent("\(name).json"), options: .atomic)
    }

    static func redact(_ v: Any) -> Any {
        switch v {
        case let d as [String: Any]: return d.mapValues { redact($0) }
        case let a as [Any]: return a.map { redact($0) }
        // Keep short enum-like values (plan names, window kinds); mask ids, dates and anything
        // that looks like an address.
        case let s as String: return s.count <= 24 && !s.contains("-") && !s.contains("@") ? s : "<string \(s.count)>"
        default: return v
        }
    }
}
