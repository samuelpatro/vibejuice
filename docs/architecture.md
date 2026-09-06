# Architecture

One Swift package, one executable target, no dependencies. Files in `Sources/VibeJuice`:

| File | Owns | Talks to |
| --- | --- | --- |
| `Models.swift` | `Provider` (plus `Provider.visible`), `Account`, `QuotaWindow`, `AutoSwitch`, restart value types, `Version`, `Relative` | nothing (pure) |
| `Auth.swift` | Credential parsers, the three CLIs' main login slots (`ClaudeMain`, `CodexMain`, `GrokMain`), the `Vault`, `Keychain` via `/usr/bin/security`, `Logins` (serialized scan and switch, the scan also asks `Installed`), `Log` | Keychain, `~/.claude.json`, `~/.codex`, `~/.grok`, `zsh -lc` for the PATH |
| `Usage.swift` | `UsageClient` requests plus the pure `parseClaude`, `parseCodex` and `parseGrok`, `DebugLog` shape dumps | `api.anthropic.com`, `chatgpt.com`, `cli-chat-proxy.grok.com` |
| `Refresh.swift` | `TokenRefresh`: runs Claude Code headless so it renews an expired token, staging inactive logins under a throwaway `CLAUDE_CONFIG_DIR` | Claude Code binary, Keychain |
| `Alerts.swift` | `Alert`, which notifications are due (pure), `Notifier` | UserNotifications |
| `Shell.swift` | `Shell.run` and `Shell.launch`, the only place a child process is spawned: drained pipes, stdin, timeout with kill, always reaped | any binary |
| `Sessions.swift` | Running CLI processes, host terminal detection, restart, `Terminal` launchers, `Installed` CLI detection | `pgrep`, `ps`, `lsof`, cmux CLI, `open`, AppleScript |
| `Store.swift` | UI state and orchestration (`@Observable`, main actor) | everything above |
| `Views.swift` | Popover, rows, controls, About | `Store` |
| `VibeJuiceApp.swift` | Scenes, menu bar label and icon, crash logging | `Store` |

## Rules that keep it working

**Nothing blocks the main actor.** `Logins.scan`, `Logins.activate` and the vault edits run on one serial queue, so a switch and the scan that follows can never interleave, and the popover never waits on a `security` call. `TokenRefresh` has its own serial queue, so a 90 second CLI run never parks a cooperative thread. Process scans, terminal launches and session restarts run in detached tasks; `Log.line` hands the file write to a utility queue. Usage requests carry a 15 second request and 30 second resource timeout.

**Nothing raises inside an async function.** An Objective-C exception thrown from Foundation (for example handing `UserDefaults` a non property-list value) unwinds through Swift async frames without running `defer`, which once left `refreshing` stuck at `true` forever. Persisted values are built by pure functions that return plain arrays, and `refreshAll` guards on the flag and clears it in `defer`.

**Time is a parameter.** `tokenMax(now:)`, `Alerts.*(now:)`, `Relative.text(to:now:)` and `parseCodex(now:)` take the clock, so the rules are tested at fixed instants.

**The panel draws no background of its own.** The `MenuBarExtra` window already renders Liquid Glass in its frame (a backdrop and SDF layer, the same surface Control Center uses), so any material or glass added in SwiftUI is invisible on top of it. Controls are interactive glass with a hairline rim (`GlassControl`), row highlights are plain tinted shapes.

**Controls are tap targets, not `Button`s.** SwiftUI's button gesture crashes on macOS 26 inside a menu bar window when the label re-renders mid-press. Every clickable thing gets the `tapTarget(label, shape:)` modifier, which supplies the hit area, the tap, and the VoiceOver button trait and label in one place; only `Menu` items are real buttons. Controls are deliberately not focusable: a menu bar popover is not a tabbable surface, and focus would land on the first control every time it opens. Reduce Motion pauses the refresh spinner and the notice animation, Increase Contrast strengthens the glass tint.

**Usage endpoints are not hammered.** Automatic refreshes (launch, timer, wake) skip accounts fetched within the last minute (`Store.due`); only a click forces one. A call that arrives during a running pass is folded into one more pass instead of being dropped. A 429 keeps the last good meters rather than blanking the row.

**Secrets stay off the command line and out of the log.** `Keychain.write` feeds the value to `security -i` on stdin rather than argv whenever it fits in one interactive line (about 4 KB, which covers every Claude token and staging item); a Codex payload with its JWTs is longer and goes through argv, visible to that user's own processes for a few milliseconds. `security -i` stderr echoes the command, so write failures report only the exit status. `Log.line` gets status codes and error cases only; `UsageError` prints without the response body, `DebugLog.redact` masks anything long, dashed or address-like before a payload shape is written.

**The refresh spinner drives itself.** `RefreshButton` is a `TimelineView` that reads `store.refreshing` every frame, so it starts and stops regardless of whether the popover re-renders.

## Credential flow

`Logins.scan` copies each CLI's current login into the vault (Keychain item `dev.samuel.vibejuice.vault`, account `provider:email`, index at `~/Library/Application Support/VibeJuice/accounts.json`) and lists the vault. `Logins.activate` snapshots the login being left, then writes the chosen payload into the CLI's own slot: the `Claude Code-credentials` Keychain item plus `oauthAccount` in `~/.claude.json`, `auth.json` or the `Codex Auth` Keychain item depending on `cli_auth_credentials_store`, `~/.grok/auth.json`. VibeJuice never talks to an OAuth server; only the CLIs refresh tokens. For an expired Claude login, `TokenRefresh` stages the payload in the Keychain item Claude Code derives from a custom `CLAUDE_CONFIG_DIR` (`Claude Code-credentials-` plus the first 8 hex digits of sha256 of the directory), runs `claude -p` once with that directory (not `--bare`, which skips the credential lookup), reads the renewed item back into the vault and deletes the staging. The staging directory is derived from the account, and `TokenRefresh.sweep` removes any directory and item left by a crash at the next launch; a CLI that overruns its 90 seconds is terminated and reaped before cleanup runs. The active login is refreshed by pointing the same throwaway config dir at Claude Code's default Keychain item (`CLAUDE_SECURESTORAGE_CONFIG_DIR` empty). Vault writes throw: a switch is aborted if the login being left cannot be snapshotted, and a forget that fails puts the account back.
