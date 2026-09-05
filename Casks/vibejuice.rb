cask "vibejuice" do
  version "0.2.0"
  sha256 "2373151cc924c422e7cdd30f04022bf8bd052d8a9550ad625cda9c576d859d0c"

  url "https://github.com/samuelpatro/vibejuice/releases/download/v#{version}/VibeJuice-#{version}.dmg"
  name "VibeJuice"
  desc "One-click account switcher for Claude Code, Codex CLI and Grok CLI"
  homepage "https://github.com/samuelpatro/vibejuice"

  depends_on macos: :tahoe

  app "VibeJuice.app"

  zap trash: [
    "~/Library/Application Support/VibeJuice",
    "~/Library/Logs/VibeJuice",
    "~/Library/Preferences/dev.samuel.vibejuice.plist",
  ]
end
