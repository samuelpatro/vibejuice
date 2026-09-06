import CryptoKit
import Foundation

/// Gets an expired Claude login refreshed without VibeJuice ever calling an OAuth server: the CLI
/// does it. For an inactive login the payload is staged where a throwaway Claude Code config dir
/// looks for it, one minimal headless request runs so Claude Code refreshes and stores the new
/// tokens, and the result is read back and the staging removed. For the active login the same
/// throwaway config dir points at Claude Code's default Keychain item, so it refreshes in place.
/// Everything runs on one serial queue: two renewals never overlap, and no cooperative thread
/// is ever parked behind a child process.
enum TokenRefresh {
    enum Failure: LocalizedError {
        case noCLI
        case cliFailed(String)
        case notRefreshed

        var errorDescription: String? {
            switch self {
            case .noCLI: "Claude Code not found"
            case .cliFailed(let s): s.isEmpty ? "Claude Code exited with an error" : s
            case .notRefreshed: "Claude Code did not refresh the token"
            }
        }
    }

    private static let queue = DispatchQueue(label: "dev.samuel.vibejuice.refresh", qos: .userInitiated)
    static let stagingRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VibeJuice/refresh")

    /// The Keychain item Claude Code 2.1.263 reads when CLAUDE_CONFIG_DIR is set:
    /// "Claude Code-credentials-" plus the first 8 hex digits of sha256(dir), dir NFC-normalized.
    static func service(forConfigDir dir: String) -> String {
        let hex = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    /// One staging dir per account, so a leftover from a crash is found again by name.
    static func stagingDir(for accountId: String) -> String {
        let hex = SHA256.hash(data: Data(accountId.utf8)).map { String(format: "%02x", $0) }.joined()
        return stagingRoot.appendingPathComponent(String(hex.prefix(16))).path.precomposedStringWithCanonicalMapping
    }

    /// Where the CLI lives, without relying on the app's own minimal PATH.
    static func claudeBinary(home: String = NSHomeDirectory(), fm: FileManager = .default) -> String? {
        for p in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"] where fm.isExecutableFile(atPath: p) {
            return p
        }
        let found = Sessions.shell("/bin/zsh", ["-lc", "command -v claude"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? nil : found
    }

    /// The cheapest request that makes Claude Code exercise its token refresh. Not `--bare`:
    /// that mode skips the credential lookup and reports "Not logged in".
    static let arguments = ["-p", "Reply with ok.", "--model", "haiku"]

    /// Refreshes an inactive login and returns the payload with the new tokens.
    static func claude(payload: Data, accountId: String) async throws -> Data {
        try await onQueue { try claudeNow(payload: payload, accountId: accountId) }
    }

    /// Refreshes the active login in place; the next scan picks it up from the CLI's own store.
    static func claudeActive(payload: Data, accountId: String) async throws {
        try await onQueue { try claudeActiveNow(payload: payload, accountId: accountId) }
    }

    /// Removes staging left behind by a crash or force quit: every directory under the staging
    /// root and the Keychain item derived from it. Called once at launch.
    static func sweep() {
        queue.async {
            let fm = FileManager.default
            guard let dirs = try? fm.contentsOfDirectory(atPath: stagingRoot.path) else { return }
            for name in dirs {
                let dir = stagingRoot.appendingPathComponent(name).path.precomposedStringWithCanonicalMapping
                Keychain.delete(service: service(forConfigDir: dir), account: NSUserName())
                try? fm.removeItem(atPath: dir)
                Log.line("token refresh: swept stale staging")
            }
        }
    }

    private static func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { c.resume(with: Result(catching: work)) } }
    }

    private static func claudeNow(payload: Data, accountId: String) throws -> Data {
        guard let bin = claudeBinary() else { throw Failure.noCLI }
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { throw AuthError.badPayload }
        let dir = try stage(root, accountId: accountId)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let service = service(forConfigDir: dir), account = NSUserName()
        let item = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try Keychain.write(service: service, account: account, value: String(decoding: item, as: UTF8.self))
        defer { Keychain.delete(service: service, account: account) }

        try run(bin, cwd: dir, env: ["CLAUDE_CONFIG_DIR": dir])

        guard let fresh = Keychain.read(service: service, account: account),
              let freshRoot = try? JSONSerialization.jsonObject(with: fresh) as? [String: Any],
              let freshOauth = freshRoot["claudeAiOauth"] as? [String: Any],
              let exp = freshOauth["expiresAt"] as? Double, exp / 1000 > Date().timeIntervalSince1970 else {
            throw Failure.notRefreshed
        }
        Log.line("token refresh renewed=\(oauth["accessToken"] as? String != freshOauth["accessToken"] as? String) expires=\(Date(timeIntervalSince1970: exp / 1000))")
        var merged = root
        merged["claudeAiOauth"] = freshOauth
        return try JSONSerialization.data(withJSONObject: merged)
    }

    /// A throwaway config dir (so none of the user's hooks, plugins or MCP servers load) with
    /// CLAUDE_SECURESTORAGE_CONFIG_DIR empty, which makes Claude Code use its default
    /// "Claude Code-credentials" item.
    private static func claudeActiveNow(payload: Data, accountId: String) throws {
        guard let bin = claudeBinary() else { throw Failure.noCLI }
        let root = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        let dir = try stage(root, accountId: accountId)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try run(bin, cwd: dir, env: ["CLAUDE_CONFIG_DIR": dir, "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""])
    }

    /// Creates the staging dir with a `.claude.json` that skips onboarding and names the account.
    private static func stage(_ root: [String: Any], accountId: String) throws -> String {
        let fm = FileManager.default
        let dir = stagingDir(for: accountId)
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var config: [String: Any] = ["hasCompletedOnboarding": true]
        if let acct = root["oauthAccount"] { config["oauthAccount"] = acct }
        try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: dir).appendingPathComponent(".claude.json"))
        return dir
    }

    /// Runs the CLI to completion. On timeout the process is terminated, then killed, and always
    /// reaped before returning, so it can never write to the staging item after cleanup.
    private static func run(_ bin: String, cwd: String, env: [String: String]) throws {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        for (k, v) in env { environment[k] = v }
        let r = Shell.run(bin, arguments, cwd: cwd, env: environment, timeout: 90)
        Log.line("token refresh claude exit=\(r.status)\(r.timedOut ? " (timeout)" : "")")
        if r.timedOut { throw Failure.cliFailed("Claude Code took too long") }
        guard r.status == 0 else {
            let stderr = String(decoding: r.stderr, as: UTF8.self)
            throw Failure.cliFailed(stderr.split(separator: "\n").last.map { String($0.prefix(200)) } ?? "")
        }
    }
}
