cask "vibejuice" do
  version "0.1.0"
  sha256 "2331d893eb1e0315e063868f90c2889518758eb2dfa4b1bcbde90bbc8ab0cad0"

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
