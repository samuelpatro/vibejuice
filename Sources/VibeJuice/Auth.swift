import Foundation
import CryptoKit
import Security

// MARK: - Credential views over a payload

struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?
    let rateLimitTier: String?

    /// payload = {"claudeAiOauth": {...}, "oauthAccount": {...}}
    init?(payload: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        accessToken = token
        expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        subscriptionType = oauth["subscriptionType"] as? String
        rateLimitTier = oauth["rateLimitTier"] as? String
    }

    var planLabel: String? {
        let tier = (rateLimitTier ?? "").lowercased()
        let sub = (subscriptionType ?? "").lowercased()
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        if sub.isEmpty { return nil }
        return sub.prefix(1).uppercased() + sub.dropFirst()
    }
}

struct CodexCredentials {
    let accessToken: String
    let accountId: String?
    let email: String?
    let planType: String?
    let renewsAt: Date?

    /// payload = the full auth.json
    init?(payload: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        accessToken = access
        accountId = tokens["account_id"] as? String
        var mail: String?, plan: String?, until: Date?
        if let idToken = tokens["id_token"] as? String, let claims = JWT.payload(idToken) {
            mail = claims["email"] as? String
            let auth = claims["https://api.openai.com/auth"] as? [String: Any]
            plan = auth?["chatgpt_plan_type"] as? String
            if let s = auth?["chatgpt_subscription_active_until"] as? String {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                until = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
            }
        }
        email = mail
        planType = plan
        renewsAt = until
    }

    init(planType: String?) { accessToken = ""; accountId = nil; email = nil; self.planType = planType; renewsAt = nil }

    var planLabel: String? {
        guard let p = planType?.lowercased(), !p.isEmpty else { return nil }
        switch p {
        case "prolite", "pro_lite", "pro-lite": return "Pro 5x"
        case "pro": return "Pro 20x"
        case "plus": return "Plus"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return p.prefix(1).uppercased() + p.dropFirst()
        }
    }
}

// MARK: - Main login slots (what the CLIs actually read)

struct MainLogin {
    let email: String
    let payload: Data
}

enum ClaudeMain {
    static let service = "Claude Code-credentials"
    static let configFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")

    static func read() -> MainLogin? {
        guard let data = Keychain.read(service: service, account: NSUserName()),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        let config = readConfig()
        let account = config["oauthAccount"] as? [String: Any] ?? [:]
        guard let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        let payload = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth, "oauthAccount": account])
        guard let payload else { return nil }
        return MainLogin(email: email, payload: payload)
    }

    /// Replaces the main login the way /login does: Keychain item plus oauthAccount in ~/.claude.json.
    static func write(_ payload: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let oauth = root["claudeAiOauth"] else { throw AuthError.badPayload }
        let item = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try Keychain.writeViaSecurityCLI(service: service, account: NSUserName(), value: String(decoding: item, as: UTF8.self))
        var config = readConfig()
        if let account = root["oauthAccount"] as? [String: Any], !account.isEmpty {
            config["oauthAccount"] = account
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configFile, options: .atomic)
    }

    private static func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return root
    }

    /// Logins created earlier under CLAUDE_CONFIG_DIR profiles (~/.claude-profiles/<name>).
    static func readProfile(_ dir: URL) -> MainLogin? {
        let normalized = dir.path.precomposedStringWithCanonicalMapping
        let hex = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let data = Keychain.read(service: "Claude Code-credentials-\(hex.prefix(8))", account: NSUserName()),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let cfg = try? Data(contentsOf: dir.appendingPathComponent(".claude.json")),
              let cfgRoot = try? JSONSerialization.jsonObject(with: cfg) as? [String: Any],
              let account = cfgRoot["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String,
              let payload = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth, "oauthAccount": account])
        else { return nil }
        return MainLogin(email: email, payload: payload)
    }
}

enum CodexMain {
    static let authFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")

    static func read() -> MainLogin? {
        guard let data = try? Data(contentsOf: authFile),
              let creds = CodexCredentials(payload: data), let email = creds.email else { return nil }
        return MainLogin(email: email, payload: data)
    }

    static func write(_ payload: Data) throws {
        guard CodexCredentials(payload: payload) != nil else { throw AuthError.badPayload }
        try payload.write(to: authFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
    }

    static func readProfile(_ dir: URL) -> MainLogin? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("auth.json")),
              let creds = CodexCredentials(payload: data), let email = creds.email else { return nil }
        return MainLogin(email: email, payload: data)
    }
}

enum AuthError: Error { case badPayload, keychain(String) }

// MARK: - Vault: every saved login, owned by this app

enum Vault {
    static let service = "dev.samuel.vibejuice.vault"
    private static let indexFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VibeJuice/accounts.json")

    private static let legacyService = "dev.samuel.quotabench.vault"
    private static let legacyIndexFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/QuotaBench/accounts.json")

    private static func readIndex() -> [String] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: indexFile.path), fm.fileExists(atPath: legacyIndexFile.path) {
            try? fm.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: legacyIndexFile, to: indexFile)
        }
        guard let data = try? Data(contentsOf: indexFile),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    private static func writeIndex(_ list: [String]) {
        try? FileManager.default.createDirectory(at: indexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(Set(list)).sorted()) { try? data.write(to: indexFile, options: .atomic) }
    }

    /// Lists vault item names by attributes only (no data, so no permission dialog) and merges
    /// them into the index. Items still stored under the app's previous name are moved over.
    static func syncIndexWithKeychain() {
        var names: [String] = []
        for svc in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let items = result as? [[String: Any]] else { continue }
            let found = items.compactMap { $0[kSecAttrAccount as String] as? String }
            if svc == legacyService {
                for name in found {
                    guard let data = Keychain.read(service: legacyService, account: name) else { continue }
                    try? Keychain.write(service: service, account: name, value: String(decoding: data, as: UTF8.self))
                    Keychain.delete(service: legacyService, account: name)
                    Log.line("vault.migrate \(name.prefix(6))… ok")
                }
            }
            names += found
        }
        writeIndex(readIndex() + names)
    }

    /// Account names live in a small index file; the credential blobs live in the Keychain.
    static func list() -> [(Provider, String, Data)] {
        syncIndexWithKeychain()
        let names = readIndex()
        Log.line("vault.list count=\(names.count)")
        return names.compactMap { acct in
            guard let sep = acct.firstIndex(of: ":"),
                  let provider = Provider(rawValue: String(acct[..<sep])),
                  let data = Keychain.read(service: service, account: acct) else { return nil }
            return (provider, String(acct[acct.index(after: sep)...]), data)
        }
    }

    static func save(_ provider: Provider, email: String, payload: Data) {
        let account = "\(provider.rawValue):\(email.lowercased())"
        do {
            try Keychain.write(service: service, account: account, value: String(decoding: payload, as: UTF8.self))
            writeIndex(readIndex() + [account])
            Log.line("vault.save \(provider.rawValue) ok")
        } catch {
            Log.line("vault.save \(provider.rawValue) failed: \(error)")
        }
    }

    static func delete(_ provider: Provider, email: String) {
        let account = "\(provider.rawValue):\(email.lowercased())"
        Keychain.delete(service: service, account: account)
        writeIndex(readIndex().filter { $0 != account })
    }
}

// MARK: - Helpers

/// Every Keychain operation goes through /usr/bin/security. Claude Code creates its item with that
/// tool, so the tool is on the item's access list and reads never show the permission dialog,
/// even after Claude Code rewrites the item on a token refresh.
enum Keychain {
    static func read(service: String, account: String) -> Data? {
        let r = run(["find-generic-password", "-a", account, "-s", service, "-w"])
        Log.line("keychain.read \(service) status=\(r.status) bytes=\(r.stdout.count)")
        guard r.status == 0 else { return nil }
        var text = String(decoding: r.stdout, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        // `-w` prints values that aren't plain text as hex; JSON is plain, but handle both.
        if !text.hasPrefix("{"), let hex = Data(hex: text) { return hex }
        return Data(text.utf8)
    }

    /// Update in place when the item exists (no access-list change, so no dialog); create it with
    /// /usr/bin/security on the access list when it doesn't. Passing `-T` on an update rewrites
    /// the access list and that is what triggers the permission dialog every time.
    static func write(service: String, account: String, value: String) throws {
        let exists = run(["find-generic-password", "-a", account, "-s", service]).status == 0
        let args = exists
            ? ["add-generic-password", "-U", "-a", account, "-s", service, "-w", value]
            : ["add-generic-password", "-a", account, "-s", service, "-w", value, "-T", "/usr/bin/security"]
        let r = run(args)
        if r.status != 0 {
            throw AuthError.keychain(String(decoding: r.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func writeViaSecurityCLI(service: String, account: String, value: String) throws {
        try write(service: service, account: account, value: value)
    }

    static func delete(service: String, account: String) {
        _ = run(["delete-generic-password", "-a", account, "-s", service])
    }

    private static func run(_ args: [String]) -> (status: Int32, stdout: Data, stderr: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, o, e)
    }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            bytes.append(b)
            i += 2
        }
        self.init(bytes)
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Append-only diagnostics, status codes and counts only.
enum Log {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/VibeJuice/app.log")
    static func line(_ text: String) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stamp = Date().formatted(.dateTime.hour().minute().second())
        let data = Data("\(stamp) \(text)\n".utf8)
        if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: file) }
    }
}
