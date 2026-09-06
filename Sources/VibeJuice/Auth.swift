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

struct GrokCredentials {
    let key: String
    let userId: String?
    let email: String?
    let name: String?
    let expiresAt: Date?

    /// payload = the full ~/.grok/auth.json: one entry per issuer, keyed by issuer::client id.
    init?(payload: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let entry = root.values.compactMap({ $0 as? [String: Any] }).first(where: { ($0["key"] as? String)?.isEmpty == false }),
              let key = entry["key"] as? String else { return nil }
        self.key = key
        userId = entry["user_id"] as? String
        email = entry["email"] as? String
        name = entry["first_name"] as? String
        if let s = entry["expires_at"] as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        } else { expiresAt = nil }
    }
}

// MARK: - Main login slots (what the CLIs actually read)

struct MainLogin: Sendable {
    let email: String
    let payload: Data
}

/// The three CLIs' main login slots plus the vault, read and written as a unit. All calls run on
/// one serial queue, so a switch and a scan can never interleave and a scan always sees the
/// state after the write that preceded it.
enum Logins {
    struct Entry: Sendable { let provider: Provider; let email: String; let payload: Data }
    struct Scan: Sendable { let vault: [Entry]; let active: [Provider: String]; let installed: Set<Provider> }

    private static let queue = DispatchQueue(label: "dev.samuel.vibejuice.logins", qos: .userInitiated)

    /// Saves each CLI's current login into the vault, then lists the vault.
    static func scan() async -> Scan {
        await withCheckedContinuation { c in queue.async { c.resume(returning: scanNow()) } }
    }

    /// Snapshots the login being left (its CLI may have refreshed the token), then installs
    /// `payload` as the main login, the way /login would.
    static func activate(_ provider: Provider, payload: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                if let main = readMain(provider) { Vault.save(provider, email: main.email, payload: main.payload) }
                do { try writeMain(provider, payload); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Vault edits go through the same queue so they never interleave with a scan.
    static func forget(_ provider: Provider, email: String) {
        queue.async { Vault.delete(provider, email: email) }
    }

    static func restore(_ provider: Provider, email: String, payload: Data) {
        queue.async { Vault.save(provider, email: email, payload: payload) }
    }

    static func scanNow() -> Scan {
        Log.line("reload start")
        var active: [Provider: String] = [:]
        for p in Provider.allCases {
            if let main = readMain(p) {
                Vault.save(p, email: main.email, payload: main.payload)
                active[p] = main.email.lowercased()
            } else {
                Log.line("\(p.rawValue) main: none")
            }
        }
        let vault = Vault.list().map { Entry(provider: $0.0, email: $0.1, payload: $0.2) }
        return Scan(vault: vault, active: active, installed: Installed.detect())
    }

    static func readMain(_ p: Provider) -> MainLogin? {
        switch p { case .claude: ClaudeMain.read(); case .codex: CodexMain.read(); case .grok: GrokMain.read() }
    }

    static func writeMain(_ p: Provider, _ payload: Data) throws {
        switch p { case .claude: try ClaudeMain.write(payload); case .codex: try CodexMain.write(payload); case .grok: try GrokMain.write(payload) }
    }

    static func planLabel(_ p: Provider, _ payload: Data) -> String? {
        switch p {
        case .claude: ClaudeCredentials(payload: payload)?.planLabel
        case .codex: CodexCredentials(payload: payload)?.planLabel
        case .grok: nil
        }
    }
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
        try Keychain.write(service: service, account: NSUserName(), value: String(decoding: item, as: UTF8.self))
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
}

/// Codex keeps its login in CODEX_HOME/auth.json by default. With `cli_auth_credentials_store`
/// set to "keyring" or "auto" in config.toml it lives in the Keychain instead, as a generic
/// password with service "Codex Auth" and account "cli|<sha256 of the home path>". Auto mode
/// reads the Keychain first and falls back to the file, and saving to the Keychain deletes
/// the file, so writes mirror that.
enum CodexMain {
    static let home: URL = {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty { return URL(fileURLWithPath: env) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }()
    static let authFile = home.appendingPathComponent("auth.json")
    static let keychainService = "Codex Auth"

    enum StoreMode: String { case file, keyring, auto, ephemeral }

    static var storeMode: StoreMode {
        guard let text = try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8) else { return .file }
        return storeMode(fromConfig: text)
    }

    /// `cli_auth_credentials_store = "keyring"  # comment` -> .keyring; anything else -> .file.
    static func storeMode(fromConfig toml: String) -> StoreMode {
        for line in toml.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("cli_auth_credentials_store") else { continue }
            let raw = t.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            let value = raw.split(separator: "#").first.map(String.init) ?? ""
            return StoreMode(rawValue: value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased()) ?? .file
        }
        return .file
    }

    static var keychainAccount: String { keychainAccount(forHome: home) }

    /// Same key Codex derives: "cli|" plus the first 16 hex digits of SHA-256 over the canonical home path.
    static func keychainAccount(forHome home: URL) -> String {
        let canonical = home.resolvingSymlinksInPath().path
        let hex = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "cli|" + String(hex.prefix(16))
    }

    static func read() -> MainLogin? {
        let data: Data?
        switch storeMode {
        case .file: data = try? Data(contentsOf: authFile)
        case .keyring: data = Keychain.read(service: keychainService, account: keychainAccount)
        case .auto: data = Keychain.read(service: keychainService, account: keychainAccount) ?? (try? Data(contentsOf: authFile))
        case .ephemeral: data = nil
        }
        guard let data, let creds = CodexCredentials(payload: data), let email = creds.email else { return nil }
        return MainLogin(email: email, payload: data)
    }

    static func write(_ payload: Data) throws {
        guard CodexCredentials(payload: payload) != nil else { throw AuthError.badPayload }
        switch storeMode {
        case .keyring, .auto:
            try Keychain.write(service: keychainService, account: keychainAccount, value: String(decoding: payload, as: UTF8.self))
            try? FileManager.default.removeItem(at: authFile)
        case .file, .ephemeral:
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try payload.write(to: authFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
        }
    }
}

enum GrokMain {
    static let authFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/auth.json")

    static func read() -> MainLogin? {
        guard let data = try? Data(contentsOf: authFile),
              let creds = GrokCredentials(payload: data), let email = creds.email else { return nil }
        return MainLogin(email: email, payload: data)
    }

    static func write(_ payload: Data) throws {
        guard GrokCredentials(payload: payload) != nil else { throw AuthError.badPayload }
        try payload.write(to: authFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path)
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

    static func delete(service: String, account: String) {
        let r = run(["delete-generic-password", "-a", account, "-s", service])
        Log.line("keychain.delete \(service) status=\(r.status)")
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
