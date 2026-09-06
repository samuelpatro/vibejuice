import Foundation
import Testing
@testable import VibeJuice

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func json(_ text: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
}

@Suite struct ClaudeParsingTests {
    @Test func limitsArraySchema() {
        let root = json("""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 6, "resets_at": "2027-01-10T00:00:00Z", "scope": {"model": {"display_name": "Fable 5"}}},
          {"kind": "session", "percent": 14, "resets_at": "2027-01-05T03:00:00Z"},
          {"kind": "weekly_all", "percent": 3, "resets_at": "2027-01-11T00:00:00Z"}
        ]}
        """)
        let w = UsageClient.parseClaude(root)
        #expect(w.map(\.id) == ["session", "scoped-0", "weekly_all"])
        #expect(w.map(\.label) == ["Session", "Week, Fable 5", "Week, all models"])
        #expect(w.map(\.usedPercent) == [14, 6, 3])
        #expect(w.map(\.secondary) == [false, false, true])
        #expect(w[0].resetsAt == ISO8601DateFormatter().date(from: "2027-01-05T03:00:00Z"))
    }

    @Test func scopedWithoutDisplayNameFallsBackToKind() {
        let w = UsageClient.parseClaude(json("""
        {"limits": [{"kind": "weekly_scoped", "percent": 1}, {"kind": "something_else", "percent": 2}]}
        """))
        #expect(w.map(\.label) == ["Week, model", "Week, something_else"])
    }

    @Test func legacySchemaFallback() {
        let w = UsageClient.parseClaude(json("""
        {"five_hour": {"utilization": 33, "resets_at": "2027-01-05T03:00:00Z"},
         "seven_day": {"utilization": 9},
         "seven_day_opus": {"utilization": 5}}
        """))
        #expect(w.map(\.id) == ["five_hour", "seven_day_opus", "seven_day"])
        #expect(w.map(\.secondary) == [false, false, true])
    }

    @Test func emptyWhenUnrecognised() {
        #expect(UsageClient.parseClaude(json("{\"limits\": []}")).isEmpty)
        #expect(UsageClient.parseClaude(json("{\"foo\": 1}")).isEmpty)
        // A limit without a percent is skipped, not a crash.
        #expect(UsageClient.parseClaude(json("{\"limits\": [{\"kind\": \"session\"}]}")).isEmpty)
    }
}

@Suite struct CodexParsingTests {
    @Test func windowsPlanAndResets() {
        let root = json("""
        {"plan_type": "prolite",
         "rate_limit": {
           "primary_window": {"used_percent": 22, "limit_window_seconds": 18000, "reset_after_seconds": 3600},
           "secondary_window": {"used_percent": 85, "limit_window_seconds": 604800, "reset_at": "2027-01-11T00:00:00Z"}
         },
         "rate_limit_reset_credits": {"available_count": 2}}
        """)
        let r = UsageClient.parseCodex(root, fallbackPlan: "Plus", now: now)
        #expect(r.windows.map(\.id) == ["primary", "secondary"])
        #expect(r.windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(r.windows[0].resetsAt == now.addingTimeInterval(3600))
        #expect(r.windows[1].resetsAt == ISO8601DateFormatter().date(from: "2027-01-11T00:00:00Z"))
        #expect(r.plan == "Pro 5x")
        #expect(r.manualResets == 2)
    }

    @Test func planFallsBackToCredentialsAndCreditsMayBeMissing() {
        let r = UsageClient.parseCodex(json("""
        {"rate_limits": {"primary": {"used_percent": 49, "window_minutes": 10080}}}
        """), fallbackPlan: "Pro 20x", now: now)
        #expect(r.plan == "Pro 20x")
        #expect(r.manualResets == nil)
        #expect(r.windows.map(\.label) == ["Weekly"])
    }

    @Test func windowLabelsByLength() {
        func label(seconds: Double) -> String {
            UsageClient.parseCodex(json("{\"rate_limit\": {\"primary_window\": {\"used_percent\": 1, \"limit_window_seconds\": \(seconds)}}}"), fallbackPlan: nil, now: now).windows[0].label
        }
        #expect(label(seconds: 18000) == "5-hour")
        #expect(label(seconds: 86400) == "Daily")
        #expect(label(seconds: 604800) == "Weekly")
    }

    @Test func extraLimitsOnlyWhenUsed() {
        let r = UsageClient.parseCodex(json("""
        {"rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 18000}},
         "additional_rate_limits": [
           {"limit_name": "GPT-6 Astra", "rate_limit": {"primary_window": {"used_percent": 0}, "secondary_window": {"used_percent": 12, "limit_window_seconds": 604800}}}
         ]}
        """), fallbackPlan: nil, now: now)
        #expect(r.windows.map(\.id) == ["primary", "extra-GPT-6 Astra-wk"])
        #expect(r.windows[1].label == "GPT-6 Astra week")
        #expect(r.windows[1].secondary)
    }

    @Test func emptyWhenNoWindows() {
        #expect(UsageClient.parseCodex(json("{\"plan_type\": \"pro\"}"), fallbackPlan: nil, now: now).windows.isEmpty)
    }
}
