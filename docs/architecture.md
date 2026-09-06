# Architecture

One Swift package, one executable target, no dependencies. Files in `Sources/VibeJuice`:

| File | Owns | Talks to |
| --- | --- | --- |
| `Models.swift` | `Provider`, `Account`, `QuotaWindow`, alert and restart value types, `Version`, `Relative` | nothing (pure) |
| `Auth.swift` | Credential parsers, the three CLIs' main login slots (`ClaudeMain`, `CodexMain`, `GrokMain`), the `Vault`, `Keychain` via `/usr/bin/security`, `Logins` (serialized scan and switch), `Log` | Keychain, `~/.claude.json`, `~/.codex`, `~/.grok` |
| `Usage.swift` | `UsageClient` requests plus the pure `parseClaude` and `parseCodex`, `DebugLog` shape dumps | `api.anthropic.com`, `chatgpt.com` |
| `Alerts.swift` | Which notifications are due (pure), `Notifier` | UserNotifications |
| `Sessions.swift` | Running CLI processes, host terminal detection, restart, `Terminal` launchers | `pgrep`, `ps`, `lsof`, cmux CLI, `open`, AppleScript |
| `Store.swift` | UI state and orchestration (`@Observable`, main actor) | everything above |
| `Views.swift` | Popover, rows, controls, About | `Store` |
| `VibeJuiceApp.swift` | Scenes, menu bar label and icon, crash logging | `Store` |

## Rules that keep it working

**Nothing blocks the main actor.** `Logins.scan` and `Logins.activate` run on one serial queue, so a switch and the scan that follows can never interleave, and the popover never waits on a `security` call. Process scans run in detached tasks. Usage requests carry a 15 second request and 30 second resource timeout.

**Nothing raises inside an async function.** An Objective-C exception thrown from Foundation (for example handing `UserDefaults` a non property-list value) unwinds through Swift async frames without running `defer`, which once left `refreshing` stuck at `true` forever. Persisted values are built by pure functions that return plain arrays, and `refreshAll` guards on the flag and clears it in `defer`.

**Time is a parameter.** `tokenMax(now:)`, `Alerts.*(now:)`, `Relative.text(to:now:)` and `parseCodex(now:)` take the clock, so the rules are tested at fixed instants.

**Controls are tap targets, not `Button`s.** SwiftUI's button gesture crashes on macOS 26 inside a menu bar window when the label re-renders mid-press. `Pill` and `IconCircle` are views with `onTapGesture`; only `Menu` items are real buttons.

**The refresh spinner drives itself.** `RefreshButton` is a `TimelineView` that reads `store.refreshing` every frame, so it starts and stops regardless of whether the popover re-renders.

## Credential flow

`Logins.scan` copies each CLI's current login into the vault (Keychain item `dev.samuel.vibejuice.vault`, account `provider:email`, index at `~/Library/Application Support/VibeJuice/accounts.json`) and lists the vault. `Logins.activate` snapshots the login being left, then writes the chosen payload into the CLI's own slot: the `Claude Code-credentials` Keychain item plus `oauthAccount` in `~/.claude.json`, `auth.json` or the `Codex Auth` Keychain item depending on `cli_auth_credentials_store`, `~/.grok/auth.json`. VibeJuice never talks to an OAuth server; only the CLIs refresh tokens.
