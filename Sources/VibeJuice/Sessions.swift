import Foundation

/// Running CLI sessions and how to reopen them. Everything here shells out (pgrep, ps, lsof,
/// terminal launchers), so callers run it off the main actor; the parsing helpers are pure.
enum Sessions {
    /// Top-level CLI processes for a provider with their working directories and host terminal.
    static func running(for provider: Provider) -> [RunningSession] {
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
            return RunningSession(pid: pid, cwd: cwd, terminal: hostApp(of: pid))
        }
    }

    /// Walks up the parent chain until an app bundle shows up (…/cmux.app/Contents/MacOS/cmux)
    /// and returns its name, so a restarted session reopens in the terminal it came from.
    static func hostApp(of pid: Int32) -> String? {
        var current = pid
        for _ in 0..<12 {
            let line = shell("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(current)"])
            guard let (parent, command) = parseParent(line) else { return nil }
            if let app = appName(fromCommandPath: command) { return app }
            guard parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    /// One `ps -o ppid=,comm=` line: leading padded ppid, then the command path.
    static func parseParent(_ line: String) -> (ppid: Int32, command: String)? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let gap = t.firstIndex(of: " "), let ppid = Int32(t[..<gap]) else { return nil }
        return (ppid, t[gap...].trimmingCharacters(in: .whitespaces))
    }

    /// "/Applications/cmux.app/Contents/MacOS/cmux" -> "cmux"; nil for plain executables.
    static func appName(fromCommandPath path: String) -> String? {
        guard let range = path.range(of: ".app/Contents/MacOS/") else { return nil }
        return path[..<range.lowerBound].split(separator: "/").last.map(String.init)
    }

    /// Quits the sessions that predate a switch and reopens each one in its folder with the
    /// provider's resume command, so the conversation continues under the new account.
    @MainActor static func restart(_ pending: PendingRestart) async {
        for session in pending.sessions { kill(session.pid, SIGTERM) }
        // Give the CLIs a moment to flush their transcripts before relaunching.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        for session in pending.sessions {
            if kill(session.pid, 0) == 0 { kill(session.pid, SIGKILL) }
            Terminal.run(pending.provider.resumeCommand, cwd: session.cwd, host: session.terminal)
        }
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Opens a new terminal window or workspace that runs `command` in `cwd`, then leaves a shell
/// open. `host` is the app that hosted the session being restarted, so it reopens where it was.
/// Unknown or missing hosts fall back to the first installed of cmux, Ghostty, iTerm, Terminal.
enum Terminal {
    static let order = ["cmux", "Ghostty", "iTerm", "Terminal"]
    private static let cmuxCLI = ["/Applications/cmux.app/Contents/Resources/bin/cmux", "/opt/homebrew/bin/cmux", "/usr/local/bin/cmux"]
        .first { FileManager.default.fileExists(atPath: $0) }

    private static func installed(_ app: String) -> Bool {
        switch app {
        case "cmux": cmuxCLI != nil
        case "Ghostty": FileManager.default.fileExists(atPath: "/Applications/Ghostty.app")
        case "iTerm": FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
        default: app == "Terminal"
        }
    }

    /// Picks the host when it is known and installed, else the first installed in `order`.
    static func choose(host: String?, installed: (String) -> Bool) -> String {
        host.flatMap { order.contains($0) && installed($0) ? $0 : nil } ?? order.first(where: installed) ?? "Terminal"
    }

    /// The shell line every launcher runs: cd into the folder, run the command, keep a shell.
    static func shellLine(_ command: String, cwd: String) -> String {
        "cd \(quoted(cwd)) && \(command); exec zsh -l"
    }

    static func run(_ command: String, cwd: String, host: String? = nil) {
        let app = choose(host: host, installed: installed)
        let full = shellLine(command, cwd: cwd)
        Log.line("terminal: \(app) runs \(command) in \(cwd)")
        switch app {
        case "cmux":
            launch(cmuxCLI!, ["workspace", "create", "--cwd", cwd, "--command", "zsh -lc \(quoted(full))"])
        case "Ghostty":
            launch("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", "zsh", "-lc", full])
        case "iTerm":
            script("""
                tell application "iTerm"
                    activate
                    set w to (create window with default profile)
                    tell current session of w to write text "\(escaped(full))"
                end tell
                """, app)
        default:
            script("""
                tell application "Terminal"
                    activate
                    do script "\(escaped(full))"
                end tell
                """, app)
        }
    }

    /// POSIX single-quoting: safe for any path or command as one shell word.
    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    /// Escapes a string for use inside an AppleScript double-quoted literal.
    static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func script(_ source: String, _ app: String) {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { Log.line("terminal: \(app) script failed: \(err[NSAppleScript.errorMessage] ?? err)") }
    }

    private static func launch(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { Log.line("terminal: launch failed: \(error)") }
    }
}
