cask "vibejuice" do
  version "0.1.0"
  sha256 "9d0c676ffc42ce5f1117804f43509a410abd3fee5f39e391f8d6355733f60282"

  url "https://github.com/samuelpatro/homebrew-tap/releases/download/v#{version}/VibeJuice-#{version}.dmg"
  name "VibeJuice"
  desc "Menu bar quota meter and account switcher for Claude Code and Codex CLI"
  homepage "https://github.com/samuelpatro/vibejuice"

  depends_on macos: :tahoe

  app "VibeJuice.app"

  zap trash: [
    "~/Library/Application Support/VibeJuice",
    "~/Library/Logs/VibeJuice",
    "~/Library/Preferences/dev.samuel.vibejuice.plist",
  ]
end
