import CryptoKit
import Foundation

/// Gets an expired Claude login refreshed without VibeJuice ever calling an OAuth server: the CLI
/// does it. For an inactive login the payload is staged where a throwaway Claude Code config dir
/// looks for it, one minimal headless request runs so Claude Code refreshes and stores the new
/// tokens, and the result is read back and the staging removed. For the active login the CLI is
/// simply run against its own store.
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

    /// The Keychain item Claude Code 2.1.263 reads when CLAUDE_CONFIG_DIR is set:
    /// "Claude Code-credentials-" plus the first 8 hex digits of sha256(dir), dir NFC-normalized.
    static func service(forConfigDir dir: String) -> String {
        let hex = SHA256.hash(data: Data(dir.precomposedStringWithCanonicalMapping.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
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
    static func claude(payload: Data) throws -> Data {
        guard let bin = claudeBinary() else { throw Failure.noCLI }
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let oauth = root["claudeAiOauth"] else { throw AuthError.badPayload }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeJuice/refresh/\(UUID().uuidString)").path
            .precomposedStringWithCanonicalMapping
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: dir) }

        let service = service(forConfigDir: dir), account = NSUserName()
        let item = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        try Keychain.write(service: service, account: account, value: String(decoding: item, as: UTF8.self))
        defer { Keychain.delete(service: service, account: account) }

        var config: [String: Any] = ["hasCompletedOnboarding": true]
        if let acct = root["oauthAccount"] { config["oauthAccount"] = acct }
        try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: dir).appendingPathComponent(".claude.json"))

        try run(bin, cwd: dir, env: ["CLAUDE_CONFIG_DIR": dir])

        guard let fresh = Keychain.read(service: service, account: account),
              let freshRoot = try? JSONSerialization.jsonObject(with: fresh) as? [String: Any],
              let freshOauth = freshRoot["claudeAiOauth"] as? [String: Any],
              let exp = freshOauth["expiresAt"] as? Double, exp / 1000 > Date().timeIntervalSince1970 else {
            throw Failure.notRefreshed
        }
        let before = (oauth as? [String: Any])?["accessToken"] as? String
        Log.line("token refresh renewed=\(before != freshOauth["accessToken"] as? String) expires=\(Date(timeIntervalSince1970: exp / 1000))")
        var merged = root
        merged["claudeAiOauth"] = freshOauth
        return try JSONSerialization.data(withJSONObject: merged)
    }

    /// Refreshes the active login in place: a throwaway config dir (so none of the user's hooks,
    /// plugins or MCP servers load) with CLAUDE_SECURESTORAGE_CONFIG_DIR empty, which makes
    /// Claude Code use its default "Claude Code-credentials" item. The next scan picks it up.
    static func claudeActive(payload: Data) throws {
        guard let bin = claudeBinary() else { throw Failure.noCLI }
        let root = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any]) ?? [:]
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VibeJuice/refresh/\(UUID().uuidString)").path
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: dir) }
        var config: [String: Any] = ["hasCompletedOnboarding": true]
        if let acct = root["oauthAccount"] { config["oauthAccount"] = acct }
        try JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: dir).appendingPathComponent(".claude.json"))
        try run(bin, cwd: dir, env: ["CLAUDE_CONFIG_DIR": dir, "CLAUDE_SECURESTORAGE_CONFIG_DIR": ""])
    }

    private static func run(_ bin: String, cwd: String, env: [String: String], timeout: TimeInterval = 90) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let err = Pipe()
        p.standardOutput = Pipe()
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            throw Failure.cliFailed("Claude Code took too long")
        }
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        Log.line("token refresh claude exit=\(p.terminationStatus)")
        guard p.terminationStatus == 0 else {
            throw Failure.cliFailed(stderr.split(separator: "\n").last.map(String.init) ?? "")
        }
    }
}
