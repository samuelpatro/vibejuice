import Foundation
import AppKit
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var notice: String?
    /// Sessions that were running when the login changed; they keep the old account until restarted.
    @Published var pendingRestart: PendingRestart?
    @Published var autoSwitch: Bool = UserDefaults.standard.bool(forKey: "autoSwitch") {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch"); if autoSwitch { autoSwitchIfNeeded() } }
    }

    private var timer: Timer?
    private var noticeTask: Task<Void, Never>?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func accounts(for provider: Provider) -> [Account] {
        accounts.filter { $0.provider == provider }.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.email.lowercased() < b.email.lowercased()
        }
    }

    func activeAccount(for provider: Provider) -> Account? {
        accounts.first { $0.provider == provider && $0.isActive }
    }

    // MARK: Load

    /// Captures whatever is signed in right now into the vault, then lists the vault.
    /// The main login is the source of truth for tokens because the CLI refreshes them there.
    func reload() {
        Log.line("reload start")
        var activeEmail: [Provider: String] = [:]
        if let main = ClaudeMain.read() { Vault.save(.claude, email: main.email, payload: main.payload); activeEmail[.claude] = main.email.lowercased() }
        else { Log.line("claude main: none") }
        if let main = CodexMain.read() { Vault.save(.codex, email: main.email, payload: main.payload); activeEmail[.codex] = main.email.lowercased() }
        else { Log.line("codex main: none") }
        if let main = GrokMain.read() { Vault.save(.grok, email: main.email, payload: main.payload); activeEmail[.grok] = main.email.lowercased() }
        else { Log.line("grok main: none") }

        var next: [Account] = []
        for (provider, email, payload) in Vault.list() {
            var a = accounts.first { $0.id == Account.id(provider, email) } ?? Account(provider: provider, email: email, payload: payload)
            a.payload = payload
            a.isActive = activeEmail[provider] == email.lowercased()
            if a.plan == nil {
                switch provider {
                case .claude: a.plan = ClaudeCredentials(payload: payload)?.planLabel
                case .codex: a.plan = CodexCredentials(payload: payload)?.planLabel
                case .grok: a.plan = nil
                }
            }
            if provider == .codex { a.renewsAt = CodexCredentials(payload: payload)?.renewsAt }
            next.append(a)
        }
        accounts = next
        Log.line("reload done accounts=\(next.count) active=\(activeEmail.count)")
        Task { await refreshAll() }
    }

    func refreshAll() async {
        guard !refreshing else { return }
        refreshing = true
        await withTaskGroup(of: Void.self) { group in
            for a in accounts { group.addTask { await self.refresh(a.id) } }
        }
        refreshing = false
        lastRefresh = Date()
        if autoSwitch { autoSwitchIfNeeded() }
        notifyTokenMax()
    }

    /// One notification per account per reset window when the tokenmax nudge appears.
    private func notifyTokenMax() {
        let key = "tokenMaxNotified"
        var seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        for a in accounts {
            guard let n = a.tokenMax else { continue }
            let id = "\(a.id)|\(n.key)"
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            Notifier.post(title: "Use it before it resets",
                          body: "\(a.provider.title) \(a.displayName): weekly window resets in \(n.hours) h with \(Int(n.window.usedPercent.rounded()))% used.")
        }
        UserDefaults.standard.set(Array(seen).suffix(200), forKey: key)
    }

    func refresh(_ id: String) async {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts[idx]
        let result: Result<UsageResult, Error>
        switch account.provider {
        case .claude:
            guard let creds = ClaudeCredentials(payload: account.payload) else { update(id) { $0.status = .error("Unreadable login") }; return }
            if let exp = creds.expiresAt, exp < Date() { update(id) { $0.status = .expired; $0.plan = creds.planLabel }; return }
            do { result = .success(try await UsageClient.claude(creds)) } catch { result = .failure(error) }
        case .codex:
            guard let creds = CodexCredentials(payload: account.payload) else { update(id) { $0.status = .error("Unreadable login") }; return }
            do { result = .success(try await UsageClient.codex(creds)) } catch { result = .failure(error) }
        case .grok:
            // No known usage endpoint yet (see issue #1): show the account, report expiry only.
            guard let creds = GrokCredentials(payload: account.payload) else { update(id) { $0.status = .error("Unreadable login") }; return }
            update(id) { $0.status = (creds.expiresAt.map { $0 < Date() } ?? false) ? .expired : .noData; $0.updatedAt = Date() }
            return
        }
        update(id) { a in
            switch result {
            case .success(let r):
                a.status = .ok(r.windows)
                if let p = r.plan { a.plan = p }
                a.manualResets = r.manualResets
                a.updatedAt = Date()
            case .failure(let e):
                Log.line("refresh \(a.provider.rawValue) failed: \(e)")
                if case UsageError.unauthorized = e { a.status = .expired }
                else if case UsageError.http(let code, _) = e { a.status = .error("HTTP \(code)") }
                else { a.status = .error((e as? URLError)?.localizedDescription ?? "Request failed") }
            }
        }
    }

    private func update(_ id: String, _ body: (inout Account) -> Void) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        body(&accounts[idx])
    }

    // MARK: Switching

    /// Same effect as running /login and picking this account: the main login changes,
    /// every new `claude` / `codex` uses it. Running sessions keep theirs until restarted.
    func activate(_ account: Account) {
        guard !account.isActive else { return }
        // Save the live state of the account we're leaving; the CLI may have refreshed its token.
        let live: MainLogin? = switch account.provider {
            case .claude: ClaudeMain.read()
            case .codex: CodexMain.read()
            case .grok: GrokMain.read()
        }
        if let main = live { Vault.save(account.provider, email: main.email, payload: main.payload) }
        do {
            switch account.provider {
            case .claude: try ClaudeMain.write(account.payload)
            case .codex: try CodexMain.write(account.payload)
            case .grok: try GrokMain.write(account.payload)
            }
        } catch {
            show("Switch failed: \(error)")
            return
        }
        reload()
        let running = runningSessionList(account.provider)
        pendingRestart = running.isEmpty ? nil : PendingRestart(provider: account.provider, account: account.displayName, sessions: running)
        show("\(account.provider.tool) is now signed in as \(account.displayName)."
             + (running.isEmpty ? "" : " \(running.count) running session\(running.count == 1 ? "" : "s") still use the old account."))
    }

    /// Quits the sessions that predate the switch and reopens each one in its folder with the
    /// provider's resume command, so the conversation continues under the new account.
    func dismissRestart() {
        pendingRestart = nil
        notice = nil
    }

    func restartPendingSessions() {
        guard let pending = pendingRestart else { return }
        pendingRestart = nil
        noticeTask?.cancel(); notice = nil
        for session in pending.sessions {
            kill(session.pid, SIGTERM)
        }
        // Give the CLIs a moment to flush their transcripts before relaunching.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            for session in pending.sessions {
                if kill(session.pid, 0) == 0 { kill(session.pid, SIGKILL) }
                let dir = session.cwd.replacingOccurrences(of: "'", with: "'\\''")
                Terminal.run("cd '\(dir)' && \(pending.provider.resumeCommand)")
            }
            show("Restarted \(pending.sessions.count) \(pending.provider.tool) session\(pending.sessions.count == 1 ? "" : "s") as \(pending.account).")
        }
    }

    /// When the active account is spent, move to the account with the most headroom.
    func autoSwitchIfNeeded() {
        for p in Provider.allCases {
            guard let current = activeAccount(for: p), current.spent else { continue }
            let candidates = accounts(for: p).filter { !$0.spent && $0.headroom != nil && $0.id != current.id }
            guard let best = candidates.max(by: { ($0.headroom ?? 0) < ($1.headroom ?? 0) }) else { continue }
            activate(best)
            Notifier.post(title: "\(p.tool) switched account",
                          body: "\(current.displayName) hit its limit. Signed in as \(best.displayName). Restart open sessions to pick it up.")
        }
    }

    func forget(_ account: Account) {
        guard !account.isActive else { show("Sign in to another account first, then forget this one."); return }
        Vault.delete(account.provider, email: account.email)
        accounts.removeAll { $0.id == account.id }
        show("Forgot \(account.displayName).")
    }

    func consumeReset(_ account: Account) async {
        guard account.provider == .codex, let creds = CodexCredentials(payload: account.payload) else { return }
        do {
            try await UsageClient.codexConsumeReset(creds)
            show("Reset requested for \(account.displayName).")
            await refresh(account.id)
        } catch {
            show("Reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: Adding

    /// Snapshot the current login, then let the CLI's own sign-in replace it.
    /// The next reload captures the new account into the vault automatically.
    func addAccount(_ provider: Provider) {
        reload()
        Terminal.run("cd ~ && \(provider.loginCommand)")
        show("Sign in to the other \(provider.title) account in Terminal, then hit refresh here.")
    }

    func open(_ provider: Provider) {
        Terminal.run("cd ~ && \(provider.binary)")
    }

    func runningSessions(_ provider: Provider) -> Int { runningSessionList(provider).count }

    /// Running CLI processes for a provider with their working directories (via lsof).
    func runningSessionList(_ provider: Provider) -> [RunningSession] {
        let pids = shell("/usr/bin/pgrep", ["-x", provider.binary]).split(separator: "\n").compactMap { Int32($0) }
        // The CLIs spawn helper processes with the same name; keep only the top-level ones.
        let pidSet = Set(pids)
        let tops = pids.filter { pid in
            let ppid = Int32(shell("/bin/ps", ["-o", "ppid=", "-p", "\(pid)"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return !pidSet.contains(ppid)
        }
        return tops.map { pid in
            let out = shell("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
            let cwd = out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? NSHomeDirectory()
            return RunningSession(pid: pid, cwd: cwd)
        }
    }

    private func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Notice

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            // Keep the notice up while a restart offer is attached to it.
            if !Task.isCancelled && pendingRestart == nil { notice = nil }
        }
    }
}

enum Notifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

enum Terminal {
    static func run(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        if let s = NSAppleScript(source: script) {
            var err: NSDictionary?
            s.executeAndReturnError(&err)
        }
    }
}
