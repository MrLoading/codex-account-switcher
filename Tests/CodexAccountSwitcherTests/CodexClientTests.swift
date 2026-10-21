@testable import SwitcherCore
import Foundation
import Testing
@testable import CodexAccountSwitcher

struct CodexClientTests {
    @Test func customProviderUsesTheCredentialFromTheRequestedHome() async throws {
        let fixture = try ScriptFixture(accountResult: #"{"account":null,"requiresOpenaiAuth":false,"workspaceRouting":null}"#)
        defer { fixture.remove() }
        let claims = Data(#"{"email":"saved@example.test","https://api.openai.com/auth":{"chatgpt_account_id":"workspace"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        try Data("{\"tokens\":{\"id_token\":\"header.\(claims).signature\"}}".utf8)
            .write(to: fixture.root.appending(path: "auth.json"))
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))

        #expect(try await client.readIdentity(profileHome: fixture.root)
            == AccountIdentity(accountID: "workspace", email: "saved@example.test"))
        let emptyHome = fixture.root.appending(path: "empty-home")
        try FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        await #expect(throws: CodexClientError.identityUnavailable) {
            _ = try await client.readIdentity(profileHome: emptyHome)
        }
    }

    @Test(arguments: [
        #"{"account":null,"requiresOpenaiAuth":true}"#,
        #"{"account":null}"#,
        #"{"requiresOpenaiAuth":false}"#,
        #"{"account":"malformed","requiresOpenaiAuth":false}"#,
        #"{"account":null,"requiresOpenaiAuth":"false"}"#,
    ])
    func doesNotUseLocalCredentialsForOtherMissingAccountResponses(accountResult: String) async throws {
        let fixture = try ScriptFixture(accountResult: accountResult)
        defer { fixture.remove() }
        try Data(#"{"tokens":{"account_id":"workspace"}}"#.utf8)
            .write(to: fixture.root.appending(path: "auth.json"))
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))

        await #expect(throws: CodexClientError.identityUnavailable) {
            _ = try await client.readIdentity(profileHome: fixture.root)
        }
    }

    @Test(arguments: [
        "{}",
        #"{"OPENAI_API_KEY":"fixture-key"}"#,
        #"{"tokens":{"account_id":""}}"#,
        #"{"tokens":{"account_id":"workspace","id_token":"malformed"}}"#,
        "malformed fixture credential",
    ])
    func customProviderStillRequiresAReadableChatGPTIdentity(credential: String) async throws {
        let fixture = try ScriptFixture(accountResult: #"{"account":null,"requiresOpenaiAuth":false}"#)
        defer { fixture.remove() }
        try Data(credential.utf8).write(to: fixture.root.appending(path: "auth.json"))
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))

        await #expect(throws: CodexClientError.identityUnavailable) {
            _ = try await client.readIdentity(profileHome: fixture.root)
        }
    }

    @Test(arguments: ["matching", "wrong-source", "wrong-target"])
    func customProviderHandoffKeepsCredentialMatchingAndRestoration(scenario: String) async throws {
        let fixture = try ScriptFixture(accountResult: #"{"account":null,"requiresOpenaiAuth":false}"#)
        defer { fixture.remove() }
        let activeHome = fixture.root.appending(path: "active")
        try FileManager.default.createDirectory(at: activeHome, withIntermediateDirectories: true)
        let config = Data("model_provider = \"custom\"\n".utf8)
        try config.write(to: activeHome.appending(path: "config.toml"))
        let store = AccountStore(baseURL: fixture.root.appending(path: "store"), activeHomeURL: activeHome)
        let original = AccountProfile(id: UUID(), displayName: "Original", email: nil,
                                      accountID: "original", createdAt: Date())
        let target = AccountProfile(id: UUID(), displayName: "Target", email: nil,
                                    accountID: "target", createdAt: Date())
        let originalBytes = Data(#"{"tokens":{"account_id":"original"}}"#.utf8)
        try originalBytes.write(to: activeHome.appending(path: "auth.json"))
        try await store.importCurrentProfile(original)
        let targetHome = try await store.createProfileDirectory(id: target.id)
        let targetBytes = Data(#"{"tokens":{"account_id":"target"}}"#.utf8)
        let wrongBytes = Data(#"{"tokens":{"account_id":"unexpected"}}"#.utf8)
        try (scenario == "wrong-target" ? wrongBytes : targetBytes).write(to: targetHome.appending(path: "auth.json"))
        try await store.addProfile(target)
        if scenario == "wrong-source" {
            try wrongBytes.write(to: activeHome.appending(path: "auth.json"))
        }
        let desktop = IdentityCheckDesktop()
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        let service = SwitchService(desktop: desktop, store: store, codex: client)

        if scenario == "matching" {
            try await service.switchAccount(to: target.id)
            #expect(try await store.loadRegistry().activeAccountID == target.id)
            #expect(try Data(contentsOf: activeHome.appending(path: "auth.json")) == targetBytes)
            #expect(await desktop.recordedCalls() == ["close", "script", "reopen"])
        } else {
            do {
                try await service.switchAccount(to: target.id)
                Issue.record("A mismatched credential must stop the switch")
            } catch let error as OperationError {
                #expect(error.stage == (scenario == "wrong-source" ? .saveCurrentCredential : .verifyTargetIdentity))
            }
            #expect(try await store.loadRegistry().activeAccountID == original.id)
            #expect(try Data(contentsOf: activeHome.appending(path: "auth.json"))
                == (scenario == "wrong-source" ? wrongBytes : originalBytes))
            #expect(await desktop.recordedCalls() == ["close"])
        }
        let originalHome = await store.profileHome(id: original.id)
        #expect(try Data(contentsOf: originalHome.appending(path: "auth.json")) == originalBytes)
        #expect(try Data(contentsOf: activeHome.appending(path: "config.toml")) == config)
    }

    @Test func fillsMissingWorkspaceIDFromTheSameProfileCredential() async throws {
        let fixture = try ScriptFixture(body: #"""
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *account*read*) printf '%s\n' '{"id":1,"result":{"account":{"email":"same@example.test"}}}' ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        try Data(#"{"tokens":{"account_id":"workspace"}}"#.utf8)
            .write(to: fixture.root.appending(path: "auth.json"))
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        let identity = try await client.readIdentity(profileHome: fixture.root)
        #expect(identity.accountID == "workspace")
        #expect(identity.email == "same@example.test")
    }

    @Test func usageReadCanBeCancelledBeforeItsRequestTimeout() async throws {
        let fixture = try ScriptFixture(body: #"""
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *rateLimits*) touch "$CODEX_HOME/reading" ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(20))
        let read = Task { try await client.readWeeklyUsage(profileHome: fixture.root) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: fixture.root.appending(path: "reading").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.appending(path: "reading").path))
        let started = ContinuousClock.now
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func keepsCodexQuotaSeparateFromOtherMeteredBuckets() async throws {
        let fixture = try ScriptFixture(body: #"""
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *rateLimits*) printf '%s\n' '{"id":1,"result":{"rateLimitResetCredits":{"availableCount":2},"rateLimits":{"secondary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":100}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":300,"resetsAt":100},"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":100}},"other-product":{"primary":{"usedPercent":99,"windowDurationMins":300,"resetsAt":100},"secondary":{"usedPercent":95,"windowDurationMins":11520,"resetsAt":100}}}}}' ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        let usage = try await client.readWeeklyUsage(profileHome: fixture.root)
        #expect(usage.remainingPercent == 80)
        #expect(usage.fiveHourRemainingPercent == 90)
        #expect(usage.resetCreditsRemaining == 2)
    }

    @Test func preservesFinalResponseWithoutNewline() async throws {
        let fixture = try ScriptFixture(body: #"""
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *account*read*) printf '%s' '{"id":1,"result":{"account":{"accountId":"last-response"}}}'; exit 0 ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        #expect(try await client.readIdentity(profileHome: fixture.root).accountID == "last-response")
    }

    @Test func missingResetCountRemainsUnknown() async throws {
        let fixture = try ScriptFixture(body: #"""
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *rateLimits*) printf '%s\n' '{"id":1,"result":{"rateLimits":{"secondary":{"usedPercent":20,"windowDurationMins":10080,"resetsAt":100}}}}' ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        let usage = try await client.readWeeklyUsage(profileHome: fixture.root)
        #expect(usage.remainingPercent == 80)
        #expect(usage.resetCreditsRemaining == nil)
    }

    @Test func waitsForStderrThatArrivesAfterStdoutEOF() async throws {
        let fixture = try ScriptFixture(body: #"""
        read -r line
        exec 1>&-
        sleep 0.05
        printf '%s\n' 'Delayed stderr: unsupported protocol' >&2
        exit 42
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        do {
            _ = try await client.readIdentity(profileHome: fixture.root)
            Issue.record("Expected runtime failure")
        } catch {
            #expect(error.localizedDescription.contains("Delayed stderr: unsupported protocol"))
        }
    }

    @Test func stderrCompletionStillHonorsRequestTimeout() async throws {
        let fixture = try ScriptFixture(body: #"""
        read -r line
        exec 1>&-
        sleep 2
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .milliseconds(50))
        await #expect(throws: CodexClientError.timeout) { try await client.readIdentity(profileHome: fixture.root) }
    }

    @Test func includesSubprocessFailureReason() async throws {
        let fixture = try ScriptFixture(body: #"""
        read -r line
        printf '%s\n' 'Test runtime: unsupported protocol' >&2
        exit 42
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        do {
            _ = try await client.readIdentity(profileHome: fixture.root)
            Issue.record("Expected runtime failure")
        } catch {
            #expect(error.localizedDescription.contains("unsupported protocol"))
        }
    }

    @Test func ignoresErrorsForOtherRequestIDs() async throws {
        let fixture = try ScriptFixture(body: #"""
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *account*read*)
              printf '%s\n' '{"id":99,"error":{"code":-1,"message":"other request"}}'
              printf '%s\n' '{"id":1,"result":{"account":{"accountId":"expected"}}}' ;;
          esac
        done
        """#)
        defer { fixture.remove() }
        let client = CodexClient(locator: .init(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        #expect(try await client.readIdentity(profileHome: fixture.root).accountID == "expected")
    }

    @Test func numericWindowRejectsOverflowAndFractionInsteadOfCrashingOrTruncating() throws {
        for number in ["1e100", "300.5"] {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(number.utf8))
            #expect(value.intValue == nil)
        }
    }

    @Test func usesDesktopRuntimeOverrideBeforeBundledCLI() throws {
        let fixture = try ScriptFixture(body: "exit 0")
        defer { fixture.remove() }
        let located = try CodexExecutableLocator().locate(environment: [
            "CODEX_CLI_PATH": fixture.executable.path,
        ])
        #expect(located == fixture.executable)
    }

    @Test func resolvesSystemCommandFromPATHWithoutSwitcherSpecificOverride() throws {
        let fixture = try ScriptFixture(body: "exit 0")
        defer { fixture.remove() }
        #expect(try CodexExecutableLocator().locate(environment: [
            "CODEX_CLI_PATH": fixture.executable.lastPathComponent,
            "PATH": fixture.executable.deletingLastPathComponent().path,
            "CODEX_SWITCHER_CODEX_PATH": "/bin/sh",
        ]) == fixture.executable)
        #expect(throws: CodexClientError.self) {
            try CodexExecutableLocator(desktopApplicationURLs: []).locate(environment: ["PATH": "/nonexistent"])
        }
    }

    @Test func invalidDesktopOverrideDoesNotSilentlyUseAnotherRuntime() throws {
        #expect(throws: CodexClientError.self) {
            try CodexExecutableLocator().locate(environment: [
                "CODEX_CLI_PATH": "/nonexistent/codex-switcher-test",
            ])
        }
    }

    @Test func performsHandshakeBeforeReadingFiveHourAndWeeklyUsage() async throws {
        let fixture = try ScriptFixture(body: """
        state=0
        while IFS= read -r line; do
          case "$line" in
            *initialized*)
              test "$state" -eq 1 || exit 11
              state=2
              ;;
            *initialize*)
              state=1
              printf '%s\n' '{"id":0,"result":{}}'
              ;;
            *rateLimits*)
              test "$state" -eq 2 || exit 12
              printf '%s\n' '{"id":1,"result":{"rateLimitResetCredits":{"availableCount":0},"rateLimits":{"primary":{"usedPercent":80,"windowDurationMins":300,"resetsAt":100},"secondary":{"usedPercent":58,"windowDurationMins":10080,"resetsAt":1750000000}}}}'
              ;;
          esac
        done
        """)
        defer { fixture.remove() }
        let client = CodexClient(
            locator: CodexExecutableLocator(explicitURL: fixture.executable),
            requestTimeout: .seconds(2)
        )

        let usage = try await client.readWeeklyUsage(profileHome: fixture.root)
        #expect(usage.remainingPercent == 42)
        #expect(usage.resetsAt == Date(timeIntervalSince1970: 1_750_000_000))
        #expect(usage.fiveHourRemainingPercent == 20)
        #expect(usage.fiveHourResetsAt == Date(timeIntervalSince1970: 100))
        #expect(usage.resetCreditsRemaining == 0)
    }

    @Test func readsResetCreditDetailsUsingOnlyReadRequests() async throws {
        let fixture = try ScriptFixture(body: """
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "$CODEX_HOME/requests.jsonl"
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\\n' '{"id":0,"result":{}}' ;;
            *rateLimits*) printf '%s\\n' '{"id":1,"result":{"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"first","status":"available","resetType":"codexRateLimits","expiresAt":1793300849},{"id":"second","status":"available","resetType":"codexRateLimits","expiresAt":null}]},"rateLimits":{"primary":{"usedPercent":63,"windowDurationMins":10080,"resetsAt":1793293778}}}}' ;;
            *) exit 99 ;;
          esac
        done
        """)
        defer { fixture.remove() }
        let client = CodexClient(locator: CodexExecutableLocator(explicitURL: fixture.executable), requestTimeout: .seconds(2))
        let usage = try await client.readWeeklyUsage(profileHome: fixture.root)
        #expect(usage.resetCreditsRemaining == 2)
        #expect(usage.resetCredits?.first?.expiresAt == Date(timeIntervalSince1970: 1_793_300_849))
        #expect(usage.resetCredits?.last?.expiresAt == nil)
        let lines = try String(contentsOf: fixture.root.appending(path: "requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let methods = try lines.map { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["method"] as? String
        }
        #expect(methods == ["initialize", "initialized", "account/rateLimits/read"])
    }

    @Test func decodesAccountIdentity() async throws {
        let fixture = try ScriptFixture(body: """
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *account*read*) printf '%s\n' '{"id":1,"result":{"account":{"type":"chatgpt","email":"user@example.com","accountId":"acct-123"},"requiresOpenaiAuth":true}}' ;;
          esac
        done
        """)
        defer { fixture.remove() }
        let client = CodexClient(
            locator: CodexExecutableLocator(explicitURL: fixture.executable),
            requestTimeout: .seconds(2)
        )

        let identity = try await client.readIdentity(profileHome: fixture.root)
        #expect(identity == AccountIdentity(accountID: "acct-123", email: "user@example.com"))
    }

    @Test func surfacesMalformedJSON() async {
        let fixture = try! ScriptFixture(body: """
        while IFS= read -r line; do
          printf '%s\n' 'malformed'
        done
        """)
        defer { fixture.remove() }
        let client = CodexClient(
            locator: CodexExecutableLocator(explicitURL: fixture.executable),
            requestTimeout: .seconds(2)
        )

        do {
            _ = try await client.readIdentity(profileHome: fixture.root)
            Issue.record("Malformed JSON should fail")
        } catch let error as CodexClientError {
            #expect(error == .malformedResponse)
        } catch {
            Issue.record("Expected CodexClientError, got \(error)")
        }
    }

    @Test func timesOutWithoutRetrying() async throws {
        let fixture = try ScriptFixture(body: """
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *account*read*) sleep 5 ;;
          esac
        done
        """)
        defer { fixture.remove() }
        let client = CodexClient(
            locator: CodexExecutableLocator(explicitURL: fixture.executable),
            requestTimeout: .milliseconds(50)
        )

        do {
            _ = try await client.readIdentity(profileHome: fixture.root)
            Issue.record("The request should time out")
        } catch let error as CodexClientError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Expected CodexClientError, got \(error)")
        }
    }
}

private struct ScriptFixture {
    let root: URL
    let executable: URL

    init(accountResult: String) throws {
        try self.init(body: """
        while IFS= read -r line; do
          case "$line" in
            *initialized*) ;;
            *initialize*) printf '%s\\n' '{"id":0,"result":{}}' ;;
            *account*read*) printf '%s\\n' '{"id":1,"result":\(accountResult)}' ;;
          esac
        done
        """)
    }

    init(body: String) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "codex-client-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        executable = root.appending(path: "fake-codex")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor IdentityCheckDesktop: DesktopControlling {
    private var calls: [String] = []
    func closeDesktop() async throws { calls.append("close") }
    func runPostSwitchScript(source: AccountProfile?) async throws { calls.append("script") }
    func reopenDesktop() async throws { calls.append("reopen") }
    func recordedCalls() -> [String] { calls }
}
