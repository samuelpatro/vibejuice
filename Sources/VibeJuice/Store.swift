import Foundation
import AppKit
import ServiceManagement

/// UI state and orchestration for the popover. Keychain and file IO (`Logins`), process scans
/// (`Sessions`) and usage requests (`UsageClient`) all run off the main actor; only their
/// results land here, so the popover never stalls on a `security` call or an `lsof`.
@MainActor
@Observable
final class Store {
    var accounts: [Account] = []
    var refreshing = false
    var lastRefresh: Date?
    var notice: String?
    /// Sessions that were running when the login changed; they keep the old account until restarted.
    var pendingRestart: PendingRestart?
    var autoSwitch: Bool = UserDefaults.standard.bool(forKey: "autoSwitch") {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch"); if autoSwitch { autoSwitchIfNeeded() } }
    }
    /// Shows the smallest active headroom as text next to the menu bar glass.
    var showPercent: Bool = UserDefaults.standard.bool(forKey: "showPercent") {
        didSet { UserDefaults.standard.set(showPercent, forKey: "showPercent") }
    }
    /// Newer GitHub release than the running build, if any.
    var update: Update?
    /// Whether this app is registered as a login item. Stored so the menu toggle updates.
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    /// The login most recently forgotten, kept while its notice is up so it can be restored.
    var undoable: Account?

    struct Update { let version: String; let url: URL }

    /// Automatic refreshes leave an account alone this long after its last fetch.
    static let minRefreshAge: TimeInterval = 60

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var updateTimer: Timer?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init() {
        reload()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        Task { await checkForUpdate() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkForUpdate() }
        }
    }

    func accounts(for provider: Provider) -> [Account] {
        accounts.filter { $0.provider == provider }.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            return a.email.lowercased() < b.email.lowercased()
        }
    }

    /// CLIs found on this Mac; every provider until the first scan reports.
    var installed: Set<Provider> = Set(Provider.allCases)

    /// Sections worth showing: a provider with a saved login or an installed CLI. With none of
    /// either, all three stay visible so there is still a way to sign in.
    var visibleProviders: [Provider] {
        let shown = Provider.allCases.filter { installed.contains($0) || !accounts(for: $0).isEmpty }
        return shown.isEmpty ? Provider.allCases : shown
    }

    func activeAccount(for provider: Provider) -> Account? {
        accounts.first { $0.provider == provider && $0.isActive }
    }

    // MARK: Load

    /// Captures whatever is signed in right now into the vault, lists the vault, then refreshes
    /// usage. Safe to call at any time; overlapping calls are harmless. Automatic reloads
    /// (launch, timer, wake) skip accounts refreshed within the last minute; a user's click
    /// (`force`) always fetches, so the usage endpoints are not hammered.
    func reload(force: Bool = false) {
        Task { await rescan(); await refreshAll(force: force) }
    }

    /// Reads the logins off the main actor and rebuilds `accounts`, keeping known usage.
    private func rescan() async {
        let scan = await Logins.scan()
        var next: [Account] = []
        for entry in scan.vault {
            var a = accounts.first { $0.id == Account.id(entry.provider, entry.email) }
                ?? Account(provider: entry.provider, email: entry.email, payload: entry.payload)
            a.payload = entry.payload
            a.isActive = scan.active[entry.provider] == entry.email.lowercased()
            if a.plan == nil { a.plan = Logins.planLabel(entry.provider, entry.payload) }
            if entry.provider == .codex { a.renewsAt = CodexCredentials(payload: entry.payload)?.renewsAt }
            next.append(a)
        }
        accounts = next
        installed = scan.installed
        Log.line("reload done accounts=\(next.count) active=\(scan.active.count) installed=\(scan.installed.map(\.rawValue).sorted())")
    }

    /// Refreshes every account. A call while one is already running is skipped, and `refreshing`
    /// is always cleared on exit, so the flag (and the spinner it drives) can never stick. Each
    /// request has a 30-second resource timeout, so this cannot hang across sleep.
    func refreshAll(force: Bool = false) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let due = accounts.filter { force || ($0.updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity) >= Store.minRefreshAge }
        Log.line("refresh start accounts=\(due.count)/\(accounts.count)")
        await withTaskGroup(of: Void.self) { group in
            for a in due { group.addTask { await self.refresh(a.id) } }
        }
        lastRefresh = Date()
        Log.line("refresh done")
        if autoSwitch { autoSwitchIfNeeded() }
        sendAlerts()
    }

    /// Posts the notifications that are due and records them so each goes out once.
    private func sendAlerts() {
        let defaults = UserDefaults.standard
        let seenTokenMax = defaults.stringArray(forKey: Alerts.tokenMaxKey) ?? []
        let seenLowQuota = defaults.stringArray(forKey: Alerts.lowQuotaKey) ?? []
        let dueTokenMax = Alerts.tokenMax(accounts, seen: seenTokenMax)
        let dueLowQuota = Alerts.lowQuota(accounts, seen: seenLowQuota)
        (dueTokenMax + dueLowQuota).forEach(Notifier.post)
        defaults.set(Alerts.remember(seenTokenMax, sent: dueTokenMax), forKey: Alerts.tokenMaxKey)
        defaults.set(Alerts.remember(seenLowQuota, sent: dueLowQuota), forKey: Alerts.lowQuotaKey)
    }

    func refresh(_ id: String) async {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        let account = accounts[idx]
        let result: Result<UsageResult, Error>
        switch account.provider {
        case .claude:
            guard let creds = ClaudeCredentials(payload: account.payload) else { update(id) { $0.status = .error("Unreadable login") }; return }
            if let exp = creds.expiresAt, exp < Date() { update(id) { $0.plan = creds.planLabel }; renewToken(account); return }
            do { result = .success(try await UsageClient.claude(creds)) } catch { result = .failure(error) }
        case .codex:
            guard let creds = CodexCredentials(payload: account.payload) else { update(id) { $0.status = .error("Unreadable login") }; return }
            do { result = .success(try await UsageClient.codex(creds)) } catch { result = .failure(error) }
        case .grok:
            guard let creds = GrokCredentials(payload: account.payload) else { update(id) { $0.status = .error("Unreadable login") }; return }
            if let exp = creds.expiresAt, exp < Date() { update(id) { $0.status = .expired }; return }
            do { result = .success(try await UsageClient.grok(creds)) } catch { result = .failure(error) }
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
                else if case UsageError.http(429, _) = e {
                    // Rate limited by the usage endpoint: keep the last good meters, they are
                    // still true, and let the throttle space out the next attempt.
                    if case .ok = a.status { a.updatedAt = Date() } else { a.status = .error("Rate limited, retrying later") }
                }
                else if case UsageError.http(let code, _) = e { a.status = .error("HTTP \(code)") }
                else { a.status = .error((e as? URLError)?.localizedDescription ?? "Request failed") }
            }
        }
    }

    // MARK: Token refresh

    @ObservationIgnored private var renewing: Set<String> = []
    @ObservationIgnored private var renewAttempts: [String: Date] = [:]

    /// Has Claude Code refresh an expired login (see `TokenRefresh`). Automatic attempts happen at
    /// most once an hour per account; `force` is the user's right-click.
    func renewToken(_ account: Account, force: Bool = false) {
        let id = account.id
        guard account.provider == .claude, !renewing.contains(id) else { return }
        guard force || renewAttempts[id].map({ Date().timeIntervalSince($0) > 3600 }) ?? true else {
            update(id) { $0.status = .expired }
            return
        }
        renewing.insert(id)
        renewAttempts[id] = Date()
        update(id) { $0.status = .renewing }
        Log.line("token refresh start active=\(account.isActive)")
        let payload = account.payload, active = account.isActive
        Task {
            let outcome: Result<Data?, Error> = await Task.detached {
                do {
                    if active { try TokenRefresh.claudeActive(payload: payload); return .success(nil) }
                    return .success(try TokenRefresh.claude(payload: payload))
                } catch { return .failure(error) }
            }.value
            renewing.remove(id)
            switch outcome {
            case .success(let fresh):
                if let fresh {
                    Logins.restore(account.provider, email: account.email, payload: fresh)
                    update(id) { $0.payload = fresh; $0.status = .loading }
                }
                await rescan()
                await refresh(id)
            case .failure(let e):
                Log.line("token refresh failed: \(e)")
                update(id) { $0.status = .expired }
                show("Couldn't refresh \(account.displayName): \(e.localizedDescription)")
            }
        }
    }

    private func update(_ id: String, _ body: (inout Account) -> Void) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        body(&accounts[idx])
    }

    // MARK: Switching

    /// Same effect as running /login and picking this account: the main login changes and
    /// every new `claude` / `codex` uses it. Claude Code sessions pick it up live; Codex and
    /// Grok sessions keep theirs until restarted, so those get a restart offer.
    func activate(_ account: Account) {
        guard !account.isActive else { return }
        Task {
            do { try await Logins.activate(account.provider, payload: account.payload) }
            catch { show("Switch failed: \(error)"); return }
            await rescan()
            let provider = account.provider
            let running = provider.adoptsLoginLive ? [] : await Task.detached { Sessions.running(for: provider) }.value
            pendingRestart = running.isEmpty ? nil : PendingRestart(provider: provider, account: account.displayName, sessions: running)
            let tail = provider.adoptsLoginLive
                ? " Running sessions switch on their next request."
                : running.isEmpty ? "" : " \(running.count) running session\(running.count == 1 ? "" : "s") still use the old account."
            show("\(provider.tool) is now signed in as \(account.displayName).\(tail)")
            await refreshAll()
        }
    }

    func dismissRestart() {
        pendingRestart = nil
        notice = nil
        undoable = nil
    }

    func restartPendingSessions() {
        guard let pending = pendingRestart else { return }
        pendingRestart = nil
        noticeTask?.cancel(); notice = nil
        Task {
            await Sessions.restart(pending)
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
                          body: "\(current.displayName) hit its limit. Signed in as \(best.displayName)."
                                + (p.adoptsLoginLive ? "" : " Restart open sessions to pick it up."))
        }
    }

    /// Removes a saved login. Undoable while the notice is up, so no confirmation dialog.
    func forget(_ account: Account) {
        guard !account.isActive else { show("Sign in to another account first, then forget this one."); return }
        accounts.removeAll { $0.id == account.id }
        Logins.forget(account.provider, email: account.email)
        show("Forgot \(account.displayName).")
        undoable = account
    }

    func undoForget() {
        guard let account = undoable else { return }
        Logins.restore(account.provider, email: account.email, payload: account.payload)
        accounts.append(account)
        show("Restored \(account.displayName).")
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
        Terminal.run(provider.loginCommand, cwd: NSHomeDirectory())
        show("Sign in to the other \(provider.title) account in the terminal, then hit refresh here.")
    }

    func open(_ provider: Provider) {
        Terminal.run(provider.binary, cwd: NSHomeDirectory())
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.line("login item: \(error)")
            show("Could not change the login item: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Updates

    /// Compares the latest GitHub release with the running version. Dev builds without a
    /// numeric version skip the check.
    func checkForUpdate() async {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              current.first?.isNumber == true else { return }
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/samuelpatro/vibejuice/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init) else { return }
        let latest = Version.number(fromTag: tag)
        update = Version.isNewer(latest, than: current) ? Update(version: latest, url: page) : nil
        Log.line("update check current=\(current) latest=\(latest)")
    }

    // MARK: Notice

    func show(_ text: String) {
        notice = text
        undoable = nil
        noticeTask?.cancel()
        noticeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            // Keep the notice up while a restart offer is attached to it.
            if !Task.isCancelled && pendingRestart == nil { notice = nil; undoable = nil }
        }
    }
}
