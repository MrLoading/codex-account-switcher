import Foundation
import SwitcherCore
import Testing
@testable import CodexAccountSwitcher

@MainActor
struct PostSwitchIntegrationTests {
    @Test(arguments: ["switch", "external-login", "first-activation", "script-failure", "register-current-account"])
    func localIdentitySyncPreservesLaunchSettingsAndScriptContext(scenario: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "post-switch integration \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appending(path: "active")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: active)
        let original = AccountProfile(id: UUID(), displayName: "Original", email: "same@example.test",
                                      accountID: "original-workspace", createdAt: Date())
        let target = AccountProfile(id: UUID(), displayName: "Target", email: "same@example.test",
                                    accountID: "target-workspace", createdAt: Date())
        if scenario != "first-activation" {
            try credential(original).write(to: active.appending(path: "auth.json"))
            try await store.importCurrentProfile(original)
        }
        let targetHome = try await store.createProfileDirectory(id: target.id)
        try credential(target).write(to: targetHome.appending(path: "auth.json"))
        try await store.addProfile(target)
        let destination = scenario == "external-login" ? original : target
        let source: AccountProfile? = scenario == "first-activation" ? nil
            : (scenario == "external-login" ? target : original)
        let destinationHome = await store.profileHome(id: destination.id)
        let config = Data("model_provider = \"custom\"\n".utf8)
        try config.write(to: active.appending(path: "config.toml"))
        let settings = AppSettings(
            language: .english,
            desktopLaunchEnvironment: """
            SWITCHER_TEST_PROXY=http://localhost:7890
            SWITCHER_EXPECTED_TARGET_AUTH=\(destinationHome.appending(path: "auth.json").path)
            CODEX_SWITCHER_SOURCE_PROFILE_ID=wrong-source
            CODEX_SWITCHER_TARGET_PROFILE_ID=wrong-target
            """,
            automaticallyOpensDesktopAfterSwitch: false,
            desktopLaunchScript: """
            /usr/bin/cmp "$CODEX_HOME/auth.json" "$SWITCHER_EXPECTED_TARGET_AUTH" || exit 8
            printf '%s' "$CODEX_SWITCHER_SOURCE_PROFILE_ID" > "$CODEX_HOME/source-profile"
            printf '%s' "$CODEX_SWITCHER_SOURCE_ACCOUNT_ID" > "$CODEX_HOME/source-account"
            printf '%s' "$CODEX_SWITCHER_TARGET_PROFILE_ID" > "$CODEX_HOME/target-profile"
            printf '%s' "$CODEX_SWITCHER_TARGET_ACCOUNT_ID" > "$CODEX_HOME/target-account"
            printf '%s' "$SWITCHER_TEST_PROXY" > "$CODEX_HOME/proxy"
            """ + (scenario == "script-failure" ? "\nexit 9" : "")
        )
        try await store.saveSettings(settings)
        let desktop = IntegrationDesktop(controller: DesktopController(store: store))
        let model = AccountController(store: store, codex: IntegrationClient(),
            switchService: SwitchService(desktop: desktop, store: store, codex: CredentialIdentity()))
        await model.start()
        #expect(model.visibleError == nil)
        if scenario == "register-current-account" {
            await model.registerCurrentAccount()
            await model.waitForWeeklyUsageRefresh()
            #expect(model.activeAccountID == original.id)
            #expect(model.visibleError == nil)
            #expect(await desktop.calls.isEmpty)
        }
        if scenario == "external-login" {
            // The UI still has Original selected. Sync must discover Target before switching back.
            try credential(target).write(to: active.appending(path: "auth.json"))
        }

        await model.switchAccount(to: destination.id)
        await model.waitForWeeklyUsageRefresh()

        #expect(model.activeAccountID == destination.id)
        #expect(model.activeIdentityConfirmed)
        #expect(!model.isMutating)
        #expect(try await store.loadRegistry().activeAccountID == destination.id)
        #expect(try Data(contentsOf: active.appending(path: "auth.json")) == credential(destination))
        #expect(try Data(contentsOf: active.appending(path: "config.toml")) == config)
        #expect(try await store.loadSettings() == settings)
        let expected = [
            "source-profile": source?.id.uuidString ?? "",
            "source-account": source?.accountID ?? "",
            "target-profile": destination.id.uuidString,
            "target-account": destination.accountID ?? "",
            "proxy": "http://localhost:7890",
        ]
        for (name, value) in expected {
            #expect(try String(contentsOf: active.appending(path: name), encoding: .utf8) == value)
        }
        if scenario == "script-failure" {
            #expect(model.visibleError?.stage == .runPostSwitchScript)
            #expect(model.visibleError?.titleKey == "switched_reopen_title")
            #expect(await desktop.calls == ["close", "script"])
        } else {
            #expect(model.visibleError == nil)
            #expect(await desktop.calls == ["close", "script", "launch-policy"])
        }
    }

    private func credential(_ profile: AccountProfile) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": profile.email ?? ""])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["tokens": [
            "account_id": profile.accountID ?? "", "id_token": "header.\(payload).signature",
        ]], options: .sortedKeys)
    }
}

private actor IntegrationDesktop: DesktopControlling {
    let controller: DesktopController
    var calls: [String] = []
    init(controller: DesktopController) { self.controller = controller }
    // Isolate Desktop lifecycle while exercising the production script and launch preference.
    func closeDesktop() async throws { calls.append("close") }
    func runPostSwitchScript(source: AccountProfile?) async throws {
        calls.append("script")
        try await controller.runPostSwitchScript(source: source)
    }
    func reopenDesktopAfterSwitch() async throws {
        try await controller.reopenDesktopAfterSwitch()
        calls.append("launch-policy")
    }
    func reopenDesktop() async throws { Issue.record("Auto-open is disabled") }
}

private struct IntegrationClient: AccountClient {
    func readIdentity(profileHome: URL) async throws -> AccountIdentity {
        Issue.record("Startup and switching must use local identity without app-server")
        throw CodexClientError.identityUnavailable
    }
    func login(profileHome: URL) async throws -> AccountIdentity {
        Issue.record("A saved-account switch must not start a login")
        throw CodexClientError.identityUnavailable
    }
    func readWeeklyUsage(profileHome: URL) async throws -> WeeklyUsage {
        WeeklyUsage(remainingPercent: 72, resetsAt: Date(timeIntervalSince1970: 2_000_000_000))
    }
}
