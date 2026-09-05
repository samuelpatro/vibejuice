<p align="center"><img src="docs/icon.png" width="128" alt="VibeJuice icon"></p>

<h1 align="center">VibeJuice</h1>

<p align="center">Switch Claude Code, Codex and Grok accounts in one click. Keep coding.</p>

<p align="center"><img src="docs/preview.png" width="900" alt="VibeJuice popover in the menu bar"></p>

VibeJuice is a menu bar switcher for your AI coding accounts. When the account you are on runs out of juice, pick another one and keep going. No sign-out, no `/login` dance, no config editing. Every new `claude`, `codex` or `grok` you start uses the account you picked, exactly as if you had logged in with it.

The quota meters are there so you know when to switch, not the other way round. Each account shows its session, weekly and per-model windows with reset times, and auto-switch can flip to the account with the most headroom the moment the active one hits a limit.

No proxy. Nothing sits between the CLI and the API. Each login is kept in the app's own Keychain vault and copied into the place the CLI reads from when you pick it. Quota comes from the same endpoints the CLIs call for `/usage`.

## Install

Requires macOS 26 or newer and at least one of Claude Code, Codex CLI or Grok CLI already signed in.

**Homebrew**

```sh
brew install --cask samuelpatro/vibejuice/vibejuice
```

**Download**

Grab `VibeJuice-<version>.dmg` from [Releases](https://github.com/samuelpatro/vibejuice/releases), open it, drag VibeJuice to Applications. The build is not notarized, so the first launch needs right-click > Open. Homebrew handles that for you.

**From source** (needs Xcode 26)

```sh
git clone https://github.com/samuelpatro/vibejuice.git
cd vibejuice
scripts/make-signing-cert.sh   # once: self-signed identity so Keychain permission sticks across builds
scripts/bundle.sh              # builds build/VibeJuice.app and opens it
```

The app appears as a drop icon in the menu bar with one colored dot per provider. To keep it around, add it to System Settings > General > Login Items.

`scripts/bundle.sh --no-open` builds without launching. `swift run` runs it straight from the package during development. `scripts/release.sh <version>` builds a DMG, publishes a GitHub release and updates the cask.

## Accounts

The account currently signed in to each CLI is picked up automatically. To add another one, press **+** in its section. Terminal opens with `claude auth login` or `codex login`, you sign in, and on the next refresh the new login sits next to the old one.

Click a row to switch. Sessions already running keep their account until you restart them. Right-click a row to refresh it, spend a Codex manual reset, or forget it.

**Auto-switch** (in the … menu) moves to the account with the most headroom as soon as the active one hits a limit, and posts a notification.

## What the numbers mean

- **Claude**: the same windows `/usage` prints. Session is the 5-hour limit, Week is all models, and the model-scoped week is labeled with the model name Anthropic reports. Percent is used, the row shows how much is left.
- **Codex**: the weekly limit, the plan (Pro 5x, Pro 20x, Plus, Team), the renewal date, and how many manual resets remain.
- **Grok**: accounts and switching only for now. Grok has no known usage endpoint, see [#1](https://github.com/samuelpatro/vibejuice/issues/1).
- Only the active account's token is refreshed by its CLI. An inactive account shows "Token expired" once its access token lapses. Switch to it and start the CLI once to refresh it.

## Development

- `~/Library/Logs/VibeJuice/app.log` records load steps with status codes only.
- `~/Library/Logs/VibeJuice/*-usage.json` holds the shape of provider responses, keys and numbers, no tokens.
- `open --env VIBEJUICE_DEBUG_WINDOW=1 build/VibeJuice.app` also shows the popover as a normal window.
- `scripts/make-icon.swift` draws the icon; `prototype-dashboard.html` is the original design prototype.
