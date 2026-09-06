import CryptoKit
import Foundation
import Testing
@testable import VibeJuice

private func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func jwt(_ claims: [String: Any]) -> String {
    let header = base64url(Data("{\"alg\":\"none\"}".utf8))
    let payload = base64url(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).sig"
}

@Suite struct CodexStoreModeTests {
    @Test func parsesEveryForm() {
        #expect(CodexMain.storeMode(fromConfig: "cli_auth_credentials_store = \"keyring\"") == .keyring)
        #expect(CodexMain.storeMode(fromConfig: "cli_auth_credentials_store='auto'  # prefer keychain") == .auto)
        #expect(CodexMain.storeMode(fromConfig: "model = \"gpt\"\ncli_auth_credentials_store = \"Ephemeral\"\n") == .ephemeral)
        #expect(CodexMain.storeMode(fromConfig: "cli_auth_credentials_store = \"file\"") == .file)
    }

    @Test func defaultsToFile() {
        #expect(CodexMain.storeMode(fromConfig: "") == .file)
        #expect(CodexMain.storeMode(fromConfig: "model = \"gpt\"") == .file)
        #expect(CodexMain.storeMode(fromConfig: "cli_auth_credentials_store = \"bogus\"") == .file)
        // Commented out lines do not count.
        #expect(CodexMain.storeMode(fromConfig: "# cli_auth_credentials_store = \"keyring\"") == .file)
    }

    @Test func keychainAccountMatchesCodexDerivation() {
        // Foundation leaves /tmp alone (only deeper symlinks resolve); sha256("/tmp") starts with e9671acd244849c5.
        #expect(CodexMain.keychainAccount(forHome: URL(fileURLWithPath: "/tmp")) == "cli|e9671acd244849c5")
    }
}

@Suite struct CredentialParsingTests {
    @Test func codexReadsEmailPlanAndRenewal() throws {
        let token = jwt([
            "email": "alex@example.com",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "prolite", "chatgpt_subscription_active_until": "2026-10-03T00:00:00Z"],
        ])
        let payload = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "at", "account_id": "acc-1", "id_token": token]])
        let c = try #require(CodexCredentials(payload: payload))
        #expect(c.accessToken == "at")
        #expect(c.accountId == "acc-1")
        #expect(c.email == "alex@example.com")
        #expect(c.planType == "prolite")
        #expect(c.planLabel == "Pro 5x")
        #expect(c.renewsAt == ISO8601DateFormatter().date(from: "2026-10-03T00:00:00Z"))
    }

    @Test func codexPlanLabels() {
        #expect(CodexCredentials(planType: "pro").planLabel == "Pro 20x")
        #expect(CodexCredentials(planType: "plus").planLabel == "Plus")
        #expect(CodexCredentials(planType: "team").planLabel == "Team")
        #expect(CodexCredentials(planType: "custom_tier").planLabel == "Custom_tier")
        #expect(CodexCredentials(planType: "").planLabel == nil)
    }

    @Test func codexRejectsMissingToken() {
        #expect(CodexCredentials(payload: Data("{\"tokens\": {}}".utf8)) == nil)
        #expect(CodexCredentials(payload: Data("not json".utf8)) == nil)
    }

    @Test func claudePlanAndExpiry() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "tok", "expiresAt": 1_800_000_000_000, "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"],
        ])
        let c = try #require(ClaudeCredentials(payload: payload))
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(c.planLabel == "Max 20x")

        func label(tier: String?, sub: String?) -> String? {
            var o: [String: Any] = ["accessToken": "t"]
            if let tier { o["rateLimitTier"] = tier }
            if let sub { o["subscriptionType"] = sub }
            return ClaudeCredentials(payload: try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": o]))?.planLabel
        }
        #expect(label(tier: "claude_max_5x", sub: "max") == "Max 5x")
        #expect(label(tier: nil, sub: "pro") == "Pro")
        #expect(label(tier: nil, sub: nil) == nil)
    }

    @Test func grokReadsFirstEntryWithAKey() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "issuer::client": ["key": "", "email": "ignored@x.y"],
            "issuer::other": ["key": "k", "email": "alex@x.y", "first_name": "Alex", "expires_at": "2026-12-01T00:00:00Z"],
        ])
        let g = try #require(GrokCredentials(payload: payload))
        #expect(g.key == "k")
        #expect(g.email == "alex@x.y")
        #expect(g.name == "Alex")
        #expect(g.expiresAt == ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }
}

@Suite struct HelperTests {
    @Test func jwtPayloadDecodesUrlSafeBase64WithoutPadding() {
        let claims = jwt(["sub": "abc", "n": 1])
        let p = JWT.payload(claims)
        #expect(p?["sub"] as? String == "abc")
        #expect(p?["n"] as? Int == 1)
        #expect(JWT.payload("nodots") == nil)
    }

    @Test func dataFromHex() {
        #expect(Data(hex: "7b7d") == Data("{}".utf8))
        #expect(Data(hex: "") == nil)
        #expect(Data(hex: "abc") == nil)
        #expect(Data(hex: "zz") == nil)
    }
}

@Suite struct GrokCredentialsTests {
    @Test func readsFirstEntryWithKey() {
        let payload = Data("""
        {"https://auth.x.ai::client": {"key": "k1", "user_id": "u1", "email": "a@example.com", "first_name": "A", "expires_at": "2026-09-08T10:09:18.512650+00:00"}}
        """.utf8)
        let c = GrokCredentials(payload: payload)
        #expect(c?.key == "k1")
        #expect(c?.userId == "u1")
        #expect(c?.email == "a@example.com")
        #expect(c?.expiresAt != nil)
    }
}

@Suite struct TokenRefreshTests {
    @Test func serviceNameMatchesClaudeCodeScheme() {
        let s = TokenRefresh.service(forConfigDir: "/Users/x/Library/Application Support/VibeJuice/refresh/abc")
        #expect(s.hasPrefix("Claude Code-credentials-"))
        let suffix = s.dropFirst("Claude Code-credentials-".count)
        #expect(suffix.count == 8)
        #expect(suffix.allSatisfy { $0.isHexDigit })
        // Same directory, different Unicode normalization, same item.
        #expect(TokenRefresh.service(forConfigDir: "/tmp/caf\u{E9}") == TokenRefresh.service(forConfigDir: "/tmp/cafe\u{301}"))
    }

    @Test func headlessArgumentsStayMinimal() {
        #expect(!TokenRefresh.arguments.contains("--bare"))
        #expect(TokenRefresh.arguments.contains("-p"))
        #expect(TokenRefresh.arguments.contains("haiku"))
    }
}

@Suite struct KeychainQuotingTests {
    @Test func quotedEscapesForSecurityInteractiveMode() {
        #expect(Keychain.quoted("plain") == "\"plain\"")
        #expect(Keychain.quoted("{\"a\":\"b\"}") == "\"{\\\"a\\\":\\\"b\\\"}\"")
        #expect(Keychain.quoted("back\\slash") == "\"back\\\\slash\"")
    }
}

@Suite struct KeychainSingleLineTests {
    @Test func prettyJSONBecomesOneLineAndOtherTextIsUntouched() {
        let flat = Keychain.singleLine("{\n  \"a\": [1, 2],\n  \"b\": \"x\\ny\"\n}")
        #expect(!flat.contains("\n"))
        #expect((try? JSONSerialization.jsonObject(with: Data(flat.utf8)) as? [String: Any])?["b"] as? String == "x\ny")
        #expect(Keychain.singleLine("{\"a\":1}") == "{\"a\":1}")
        #expect(Keychain.singleLine("not json\nat all") == "not json\nat all")
    }
}

@Suite struct KeychainLineLimitTests {
    @Test func limitLeavesRoomBelowSecuritysBuffer() {
        #expect(Keychain.interactiveLineLimit < 4028)
        #expect(Keychain.interactiveLineLimit > 2000)
    }
}
