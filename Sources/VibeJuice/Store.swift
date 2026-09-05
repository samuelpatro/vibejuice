import Foundation
import AppKit
import UserNotifications

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var refreshing = false
    @Published var lastRefresh: Date?
    @Published var notice: String?
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
        let running = runningSessions(account.provider)
        show("\(account.provider.tool) is now signed in as \(account.displayName)."
             + (running > 0 ? " \(running) running session\(running == 1 ? "" : "s") keep the old account until restarted." : ""))
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

    func runningSessions(_ provider: Provider) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", provider.binary]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return 0 }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").count
    }

    // MARK: Notice

    func show(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { notice = nil }
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
