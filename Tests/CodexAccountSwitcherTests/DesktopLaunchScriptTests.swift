import Foundation
import SwitcherCore
import Testing
@testable import CodexAccountSwitcher

struct DesktopLaunchScriptTests {
    @Test func waitsForMultilineScriptAndPassesTheActiveHomeAndEnvironment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        try await DesktopLaunchScript().run(
            """
            /bin/sleep 0.02
            print -rn -- "$SWITCHER_SCRIPT_TEST_VALUE" > "$CODEX_HOME/result"
            """,
            environment: ["SWITCHER_SCRIPT_TEST_VALUE": "value with spaces=1", "CODEX_HOME": "/wrong-home"],
            codexHome: root
        )

        #expect(try String(contentsOf: root.appending(path: "result"), encoding: .utf8) == "value with spaces=1")
    }

    @Test func blankScriptIsSkipped() async throws {
        try await DesktopLaunchScript().run(" \n\t", environment: [:], codexHome: URL(fileURLWithPath: "/missing-home"))
    }

    @Test func reportsTheExitStatus() async {
        do {
            try await DesktopLaunchScript().run("exit 42", environment: [:], codexHome: FileManager.default.temporaryDirectory)
            Issue.record("Expected a script failure")
        } catch let error as DesktopLaunchScriptError {
            #expect(error == .exited(42))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func reportsSignalTermination() async {
        do {
            try await DesktopLaunchScript().run("kill -TERM $$", environment: [:], codexHome: FileManager.default.temporaryDirectory)
            Issue.record("Expected signal termination")
        } catch let error as DesktopLaunchScriptError {
            #expect(error == .signalled(15))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func scriptsWithLargeOutputFinishWithoutAnUnreadPipe() async throws {
        try await DesktopLaunchScript().run(
            "/usr/bin/head -c 131072 /dev/zero; /usr/bin/head -c 131072 /dev/zero >&2",
            environment: [:], codexHome: FileManager.default.temporaryDirectory
        )
    }

    @Test func savedScriptRunsEvenWhenAutomaticOpeningIsDisabled() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: root)
        let target = AccountProfile(id: UUID(), displayName: "Target", email: "target@example.test",
                                    accountID: "target-account", createdAt: Date())
        try await saveProfile(target, in: store)
        try await store.commitActiveAccountID(target.id)
        try await store.saveSettings(AppSettings(
            language: .english,
            desktopLaunchEnvironment: """
            SWITCHER_SCRIPT_TEST_VALUE=after switch
            CODEX_SWITCHER_SOURCE_PROFILE_ID=stale-profile
            CODEX_SWITCHER_SOURCE_ACCOUNT_ID=stale-account
            CODEX_SWITCHER_SOURCE_EMAIL=stale@example.test
            CODEX_SWITCHER_SOURCE_NAME=stale-name
            """,
            automaticallyOpensDesktopAfterSwitch: false,
            desktopLaunchScript: """
            print -rn -- "$SWITCHER_SCRIPT_TEST_VALUE" > "$CODEX_HOME/result"
            printf '%s' "$CODEX_SWITCHER_SOURCE_PROFILE_ID" > "$CODEX_HOME/source-profile-id"
            printf '%s' "$CODEX_SWITCHER_SOURCE_ACCOUNT_ID" > "$CODEX_HOME/source-account-id"
            printf '%s' "$CODEX_SWITCHER_SOURCE_EMAIL" > "$CODEX_HOME/source-email"
            printf '%s' "$CODEX_SWITCHER_SOURCE_NAME" > "$CODEX_HOME/source-name"
            """
        ))
        let desktop = DesktopController(store: store)

        try await desktop.runPostSwitchScript()
        try await desktop.reopenDesktopAfterSwitch()

        #expect(try String(contentsOf: root.appending(path: "result"), encoding: .utf8) == "after switch")
        for name in ["source-profile-id", "source-account-id", "source-email", "source-name"] {
            #expect(try String(contentsOf: root.appending(path: name), encoding: .utf8).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func scriptReceivesSourceAndTargetAndOverridesConfiguredContext(missingOptionalFields: Bool) async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: root)
        let original = AccountProfile(
            id: UUID(), displayName: "Original 'quoted' $(printf injected)\n第一行",
            email: missingOptionalFields ? nil : "original@example.test",
            accountID: missingOptionalFields ? nil : "original-account", createdAt: Date()
        )
        let target = AccountProfile(
            id: UUID(), displayName: "Target \"quoted\" $(printf injected)\n第二行",
            email: missingOptionalFields ? nil : "target@example.test",
            accountID: missingOptionalFields ? nil : "target-account", createdAt: Date()
        )
        try await saveProfile(original, in: store)
        try await saveProfile(target, in: store)
        try await store.commitActiveAccountID(original.id)
        try await store.activateTargetCredential(id: target.id)
        try await store.commitActiveAccountID(target.id)
        try await store.saveSettings(AppSettings(
            language: .english,
            desktopLaunchEnvironment: """
            CODEX_SWITCHER_TARGET_PROFILE_ID=wrong-profile
            CODEX_SWITCHER_TARGET_ACCOUNT_ID=wrong-account
            CODEX_SWITCHER_TARGET_EMAIL=wrong@example.test
            CODEX_SWITCHER_TARGET_NAME=wrong-name
            CODEX_SWITCHER_SOURCE_PROFILE_ID=wrong-source-profile
            CODEX_SWITCHER_SOURCE_ACCOUNT_ID=wrong-source-account
            CODEX_SWITCHER_SOURCE_EMAIL=wrong-source@example.test
            CODEX_SWITCHER_SOURCE_NAME=wrong-source-name
            """,
            automaticallyOpensDesktopAfterSwitch: false,
            desktopLaunchScript: """
            printf '%s' "$CODEX_SWITCHER_TARGET_PROFILE_ID" > "$CODEX_HOME/profile-id"
            printf '%s' "$CODEX_SWITCHER_TARGET_ACCOUNT_ID" > "$CODEX_HOME/account-id"
            printf '%s' "$CODEX_SWITCHER_TARGET_EMAIL" > "$CODEX_HOME/email"
            printf '%s' "$CODEX_SWITCHER_TARGET_NAME" > "$CODEX_HOME/name"
            printf '%s' "$CODEX_SWITCHER_SOURCE_PROFILE_ID" > "$CODEX_HOME/source-profile-id"
            printf '%s' "$CODEX_SWITCHER_SOURCE_ACCOUNT_ID" > "$CODEX_HOME/source-account-id"
            printf '%s' "$CODEX_SWITCHER_SOURCE_EMAIL" > "$CODEX_HOME/source-email"
            printf '%s' "$CODEX_SWITCHER_SOURCE_NAME" > "$CODEX_HOME/source-name"
            """
        ))

        try await DesktopController(store: store).runPostSwitchScript(source: original)

        #expect(try String(contentsOf: root.appending(path: "profile-id"), encoding: .utf8) == target.id.uuidString)
        #expect(try String(contentsOf: root.appending(path: "account-id"), encoding: .utf8) == (target.accountID ?? ""))
        #expect(try String(contentsOf: root.appending(path: "email"), encoding: .utf8) == (target.email ?? ""))
        #expect(try String(contentsOf: root.appending(path: "name"), encoding: .utf8) == target.displayName)
        #expect(try String(contentsOf: root.appending(path: "source-profile-id"), encoding: .utf8) == original.id.uuidString)
        #expect(try String(contentsOf: root.appending(path: "source-account-id"), encoding: .utf8) == (original.accountID ?? ""))
        #expect(try String(contentsOf: root.appending(path: "source-email"), encoding: .utf8) == (original.email ?? ""))
        #expect(try String(contentsOf: root.appending(path: "source-name"), encoding: .utf8) == original.displayName)
    }

    @Test func blankSavedScriptDoesNotRequireAnActiveProfile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: root)
        try await store.saveSettings(AppSettings(language: .english, desktopLaunchScript: " \n\t"))

        try await DesktopController(store: store).runPostSwitchScript()
    }

    @Test func scriptDoesNotRunWithoutACommittedTarget() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root.appending(path: "store"), activeHomeURL: root)
        try await store.saveSettings(AppSettings(
            language: .english, desktopLaunchScript: "touch \"$CODEX_HOME/unexpected\""
        ))

        do {
            try await DesktopController(store: store).runPostSwitchScript()
            Issue.record("Expected a missing active profile error")
        } catch let error as AccountStoreError {
            #expect(error == .activeProfileMissing)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "unexpected").path))
    }

    private func saveProfile(_ profile: AccountProfile, in store: AccountStore) async throws {
        let home = try await store.createProfileDirectory(id: profile.id)
        try Data("{}".utf8).write(to: home.appending(path: "auth.json"))
        try await store.addProfile(profile)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "launch script \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
