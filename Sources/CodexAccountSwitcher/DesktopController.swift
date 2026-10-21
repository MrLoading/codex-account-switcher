import SwitcherCore
import AppKit
import Foundation

enum DesktopControllerError: LocalizedError, Sendable {
    case applicationNotFound
    case quitRequestFailed
    case didNotExit
    case reopenFailed

    var errorDescription: String? {
        switch self {
        case .applicationNotFound:
            "The Codex Desktop application could not be found."
        case .quitRequestFailed:
            "Codex Desktop rejected the quit request."
        case .didNotExit:
            "Codex Desktop did not finish quitting within 30 seconds. Finish or stop active tasks and close Desktop, then switch again. The account has not changed."
        case .reopenFailed:
            "Codex Desktop could not be reopened. Open it manually to continue."
        }
    }
}

// A quit request may be waiting for Desktop's active-task dialog or durable history writes.
// Expiry must stop the switch before credentials change; it must never escalate to SIGKILL.
struct DesktopQuitWaiter: Sendable {
    var timeout: Duration = .seconds(30)
    var pollInterval: Duration = .milliseconds(100)

    func wait(isRunning: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while await isRunning() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw DesktopControllerError.didNotExit }
            try await Task.sleep(for: min(pollInterval, deadline - clock.now))
        }
        try Task.checkCancellation()
    }
}

struct DesktopController: DesktopControlling {
    private let bundleIdentifiers = ["com.openai.codex"]
    private let applicationPaths = ["/Applications/ChatGPT.app", "/Applications/Codex.app"]
    private let store: AccountStore

    init(store: AccountStore) {
        self.store = store
    }

    func closeDesktop() async throws {
        let running = runningDesktopApplications
        guard !running.isEmpty else { return }
        for application in running where !application.isTerminated {
            let processIdentifier = application.processIdentifier
            guard application.terminate() || !isDesktopRunning(processIdentifier: processIdentifier) else {
                throw DesktopControllerError.quitRequestFailed
            }
        }

        try await DesktopQuitWaiter().wait {
            isDesktopRunning
        }
    }

    func reopenDesktop() async throws {
        guard let url = applicationURL() else {
            throw DesktopControllerError.applicationNotFound
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let settings = (try? await store.loadSettings()) ?? .default
        let launchEnvironment = DesktopLaunchEnvironment.parse(
            settings.desktopLaunchEnvironment
        )

        if !launchEnvironment.isEmpty {
            configuration.environment = launchEnvironment
        }

        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } catch {
            throw DesktopControllerError.reopenFailed
        }
    }

    func runPostSwitchScript(source: AccountProfile? = nil) async throws {
        let settings = try await store.loadSettings()
        guard !settings.desktopLaunchScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // The switch service has already verified and committed the target account.
        // The source is the snapshot captured by the switch service before credentials changed.
        let registry = try await store.loadRegistry()
        guard let activeID = registry.activeAccountID,
              let target = registry.accounts.first(where: { $0.id == activeID }) else {
            throw AccountStoreError.activeProfileMissing
        }
        var environment = DesktopLaunchEnvironment.parse(settings.desktopLaunchEnvironment)
        // Reserved context overrides configured values, including absent optional fields.
        environment["CODEX_SWITCHER_TARGET_PROFILE_ID"] = target.id.uuidString
        environment["CODEX_SWITCHER_TARGET_ACCOUNT_ID"] = target.accountID ?? ""
        environment["CODEX_SWITCHER_TARGET_EMAIL"] = target.email ?? ""
        environment["CODEX_SWITCHER_TARGET_NAME"] = target.displayName
        environment["CODEX_SWITCHER_SOURCE_PROFILE_ID"] = source?.id.uuidString ?? ""
        environment["CODEX_SWITCHER_SOURCE_ACCOUNT_ID"] = source?.accountID ?? ""
        environment["CODEX_SWITCHER_SOURCE_EMAIL"] = source?.email ?? ""
        environment["CODEX_SWITCHER_SOURCE_NAME"] = source?.displayName ?? ""

        try await DesktopLaunchScript().run(
            settings.desktopLaunchScript,
            environment: environment,
            codexHome: await store.activeCodexHome()
        )
    }

    func reopenDesktopAfterSwitch() async throws {
        let settings = try await store.loadSettings()
        guard settings.automaticallyOpensDesktopAfterSwitch else { return }
        try Task.checkCancellation()
        try await reopenDesktop()
    }

    private func applicationURL() -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        return applicationPaths
            .map(URL.init(fileURLWithPath:))
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private var isDesktopRunning: Bool {
        !runningDesktopApplications.isEmpty
    }

    private var runningDesktopApplications: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return bundleIdentifiers.contains(bundleIdentifier)
        }
    }

    private func isDesktopRunning(processIdentifier: pid_t) -> Bool {
        runningDesktopApplications.contains { $0.processIdentifier == processIdentifier }
    }
}
