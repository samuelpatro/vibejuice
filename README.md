<p align="center"><img src="docs/icon.png" width="128" alt="VibeJuice icon"></p>

<h1 align="center">VibeJuice</h1>

<p align="center">How much juice is left in each of your Claude Code and Codex accounts, and one click to switch.</p>

<p align="center"><img src="docs/preview.png" width="900" alt="VibeJuice popover in the menu bar"></p>

VibeJuice is a macOS menu bar app. It lists every Claude Code and Codex CLI account you have signed in on this Mac, shows the quota windows for each one (session, weekly, per model) with reset times, and lets you switch the active account the same way `/login` does. After a switch, every new `claude` or `codex` you start uses that account.

No proxy. Nothing sits between the CLI and the API. Each login is kept in the app's own Keychain vault and copied into the place the CLI reads from when you pick it. Quota comes from the same endpoints the CLIs call for `/usage`.

## Install

Requirements: macOS 26 or newer, Xcode 26 (for the Swift toolchain), and Claude Code or Codex CLI already signed in.

```sh
git clone https://github.com/samuelpatro/vibejuice.git
cd vibejuice
scripts/make-signing-cert.sh   # once: self-signed identity so Keychain permission sticks across builds
scripts/bundle.sh              # builds build/VibeJuice.app and opens it
```

The app appears as a drop icon in the menu bar with one colored dot per provider. To keep it around, drag `build/VibeJuice.app` into `/Applications` and add it to System Settings > General > Login Items.

`scripts/bundle.sh --no-open` builds without launching. `swift run` runs it straight from the package during development.

## Accounts

The account currently signed in to each CLI is picked up automatically. To add another one, press **+** in its section. Terminal opens with `claude auth login` or `codex login`, you sign in, and on the next refresh the new login sits next to the old one.

Click a row to switch. Sessions already running keep their account until you restart them. Right-click a row to refresh it, spend a Codex manual reset, or forget it.

**Auto-switch** (in the … menu) moves to the account with the most headroom as soon as the active one hits a limit, and posts a notification.

## What the numbers mean

- **Claude**: the same windows `/usage` prints. Session is the 5-hour limit, Week is all models, and the model-scoped week is labeled with the model name Anthropic reports. Percent is used, the row shows how much is left.
- **Codex**: the weekly limit, the plan (Pro 5x, Pro 20x, Plus, Team), the renewal date, and how many manual resets remain.
- Only the active account's token is refreshed by its CLI. An inactive account shows "Token expired" once its access token lapses. Switch to it and start the CLI once to refresh it.

## Development

- `~/Library/Logs/VibeJuice/app.log` records load steps with status codes only.
- `~/Library/Logs/VibeJuice/*-usage.json` holds the shape of provider responses, keys and numbers, no tokens.
- `open --env VIBEJUICE_DEBUG_WINDOW=1 build/VibeJuice.app` also shows the popover as a normal window.
- `scripts/make-icon.swift` draws the icon; `prototype-dashboard.html` is the original design prototype.
