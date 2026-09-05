cask "vibejuice" do
  version "0.1.0"
  sha256 "d27879cffc0af7660581cc8c88151f66c38b905de0ecc9273108b06fafde7ed6"

  url "https://github.com/samuelpatro/homebrew-tap/releases/download/v#{version}/VibeJuice-#{version}.zip"
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
