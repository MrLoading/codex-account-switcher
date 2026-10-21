import Foundation

enum DesktopLaunchScriptError: LocalizedError, Equatable {
    case exited(Int32)
    case signalled(Int32)

    var errorDescription: String? {
        switch self {
        case let .exited(status):
            "The shell script exited with status \(status)."
        case let .signalled(signal):
            "The shell script was terminated by signal \(signal)."
        }
    }
}

struct DesktopLaunchScript: Sendable {
    func run(_ script: String, environment: [String: String], codexHome: URL) async throws {
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment.merging(environment) { _, custom in custom }
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        // A script cannot prompt for input or fill an unread output pipe in the menu-bar app.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Wait for termination without blocking the UI or a cooperative executor thread.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { finished in
                if finished.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: DesktopLaunchScriptError.signalled(finished.terminationStatus))
                } else if finished.terminationStatus != 0 {
                    continuation.resume(throwing: DesktopLaunchScriptError.exited(finished.terminationStatus))
                } else {
                    continuation.resume()
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try Task.checkCancellation()
    }
}
