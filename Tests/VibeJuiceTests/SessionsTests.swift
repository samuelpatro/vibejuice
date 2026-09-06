import Foundation
import Testing
@testable import VibeJuice

@Suite struct SessionsParsingTests {
    @Test func parsesPsParentLine() {
        let r = Sessions.parseParent("  20200 /Users/samuel/.local/bin/claude\n")
        #expect(r?.ppid == 20200)
        #expect(r?.command == "/Users/samuel/.local/bin/claude")
        #expect(Sessions.parseParent("")?.ppid == nil)
        #expect(Sessions.parseParent("garbage line")?.ppid == nil)
    }

    @Test func appNameFromBundlePath() {
        #expect(Sessions.appName(fromCommandPath: "/Applications/cmux.app/Contents/MacOS/cmux") == "cmux")
        #expect(Sessions.appName(fromCommandPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty") == "Ghostty")
        #expect(Sessions.appName(fromCommandPath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == "Terminal")
        #expect(Sessions.appName(fromCommandPath: "-/bin/zsh") == nil)
        #expect(Sessions.appName(fromCommandPath: "/usr/bin/login") == nil)
    }
}

@Suite struct TerminalTests {
    @Test func choosesTheHostWhenInstalledElseFirstInstalled() {
        let only = { (app: String) in app == "Ghostty" || app == "Terminal" }
        #expect(Terminal.choose(host: "Ghostty", installed: only) == "Ghostty")
        #expect(Terminal.choose(host: "cmux", installed: only) == "Ghostty")
        #expect(Terminal.choose(host: "Zed", installed: only) == "Ghostty")
        #expect(Terminal.choose(host: nil, installed: only) == "Ghostty")
        #expect(Terminal.choose(host: nil, installed: { _ in false }) == "Terminal")
        #expect(Terminal.choose(host: "cmux", installed: { _ in true }) == "cmux")
    }

    @Test func shellLineQuotesTheFolder() {
        #expect(Terminal.shellLine("claude --continue", cwd: "/Users/x/my project") == "cd '/Users/x/my project' && claude --continue; exec zsh -l")
        #expect(Terminal.quoted("it's") == "'it'\\''s'")
        #expect(Terminal.escaped("say \"hi\" \\ bye") == "say \\\"hi\\\" \\\\ bye")
    }
}
