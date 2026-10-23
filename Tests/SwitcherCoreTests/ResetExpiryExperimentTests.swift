import Foundation
import Testing
@testable import SwitcherCore

struct ResetExpiryExperimentTests {
    let expiry = Date(timeIntervalSince1970: 2_000_000_000)
    let profile = AccountProfile(id: UUID(), displayName: "Fixture", email: nil,
        accountID: nil, createdAt: Date(timeIntervalSince1970: 1_900_000_000))

    func usage(credits: [BankedResetCredit]? = nil) -> WeeklyUsage {
        WeeklyUsage(remainingPercent: 37, resetsAt: expiry.addingTimeInterval(-7200),
            resetCreditsRemaining: 1, resetCredits: credits ?? [
                BankedResetCredit(id: "fixture-credit", status: "available", resetType: "codexRateLimits", expiresAt: expiry)
            ])
    }

    @Test func threeCheckpointsUseCreditExpiryAndSurviveRestartsWithoutDuplicates() throws {
        var experiment = ResetExpiryExperiment(history: [])
        var history = experiment.observe(profile: profile, usage: usage(), at: expiry.addingTimeInterval(-900))
        #expect(experiment.nextCheckpoint(accountIDs: [profile.id]) == expiry.addingTimeInterval(-600))
        for minutes in [10, 5, 1] {
            let now = expiry.addingTimeInterval(-Double(minutes * 60))
            let events = experiment.observe(profile: profile, usage: usage(), at: now)
            let checkpoint = try #require(events.first(where: { $0.event == "checkpoint" }))
            #expect(checkpoint.checkpointMinutes == minutes)
            #expect(checkpoint.decision == "would_attempt")
            #expect(checkpoint.scheduledAt == now)
            #expect(checkpoint.delaySeconds == 0)
            #expect(checkpoint.mode == "dry_run" && !checkpoint.resetAttempted)
            history += events
            experiment = ResetExpiryExperiment(history: history)
            #expect(experiment.observe(profile: profile, usage: usage(), at: now).count == 1)
        }
        #expect(experiment.nextCheckpoint(accountIDs: [profile.id]) == nil)
        #expect(history.filter { $0.event == "checkpoint" }.count == 3)
    }

    @Test func wakeAfterExpiryRecordsMissedCheckpointsInsteadOfPretendingToAttempt() {
        var experiment = ResetExpiryExperiment(history: [])
        _ = experiment.observe(profile: profile, usage: usage(), at: expiry.addingTimeInterval(-900))
        let events = experiment.observe(profile: profile, usage: usage(credits: []), at: expiry.addingTimeInterval(30))
        let checkpoints = events.filter { $0.event == "checkpoint" }
        #expect(checkpoints.map(\.checkpointMinutes) == [10, 5, 1])
        #expect(checkpoints.allSatisfy { $0.decision == "missed" && !$0.resetAttempted })
        #expect(experiment.nextCheckpoint(accountIDs: [profile.id]) == nil)
    }

    @Test func lateStartOnlyAttemptsCurrentStageAndRecordsDelay() {
        var experiment = ResetExpiryExperiment(history: [])
        let events = experiment.observe(profile: profile, usage: usage(), at: expiry.addingTimeInterval(-120))
        #expect(events.filter { $0.event == "checkpoint" }.map(\.decision) == ["missed", "would_attempt"])
        #expect(events.last?.delaySeconds == 180)
        #expect(experiment.nextCheckpoint(accountIDs: [profile.id]) == expiry.addingTimeInterval(-60))
    }

    @Test func failedReadAndMissingDetailsNeverBecomeSuccessfulAttempts() {
        var experiment = ResetExpiryExperiment(history: [])
        _ = experiment.observe(profile: profile, usage: usage(), at: expiry.addingTimeInterval(-900))
        let failure = experiment.observe(profile: profile, usage: nil, error: "HTTP 503", at: expiry.addingTimeInterval(-600))
        #expect(failure.last?.decision == "read_failed")
        #expect(failure.last?.error == "HTTP 503")
        let unknown = WeeklyUsage(remainingPercent: 30, resetsAt: expiry, resetCreditsRemaining: 1)
        let noDetails = experiment.observe(profile: profile, usage: unknown, at: expiry.addingTimeInterval(-300))
        #expect(noDetails.last?.decision == "details_unavailable")
        #expect(experiment.nextCheckpoint(accountIDs: [profile.id]) == expiry.addingTimeInterval(-60))
        #expect(experiment.observe(profile: profile, usage: usage(credits: []), at: expiry.addingTimeInterval(-60)).last?.decision == "credit_unavailable")
    }

    @Test func onlyAvailableKnownExpiringCreditsAreScheduledForExistingAccounts() {
        var experiment = ResetExpiryExperiment(history: [])
        let credits = [
            BankedResetCredit(id: "no-expiry", status: "available", resetType: "codexRateLimits", expiresAt: nil),
            BankedResetCredit(id: "used", status: "redeemed", resetType: "codexRateLimits", expiresAt: expiry),
            BankedResetCredit(id: "other", status: "available", resetType: "unknown", expiresAt: expiry)
        ]
        _ = experiment.observe(profile: profile, usage: usage(credits: credits), at: expiry.addingTimeInterval(-900))
        #expect(experiment.nextCheckpoint(accountIDs: [profile.id]) == nil)
        _ = experiment.observe(profile: profile, usage: usage(), at: expiry.addingTimeInterval(-900))
        #expect(experiment.nextCheckpoint(accountIDs: []) == nil)
    }

    @Test func checkpointsAreIsolatedBetweenAccountsWithTheSameCreditID() {
        var experiment = ResetExpiryExperiment(history: [])
        let other = AccountProfile(id: UUID(), displayName: "Other", email: nil, accountID: nil, createdAt: expiry)
        for account in [profile, other] {
            let events = experiment.observe(profile: account, usage: usage(), at: expiry.addingTimeInterval(-600))
            #expect(events.last?.decision == "would_attempt")
            #expect(events.last?.profileID == account.id)
        }
    }

    @Test func logPersistsAndRejectsCorruptHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "reset-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AccountStore(baseURL: root)
        var experiment = ResetExpiryExperiment(history: [])
        let events = experiment.observe(profile: profile, usage: usage(), at: expiry.addingTimeInterval(-600))
        try await store.appendResetExpiryLog(events)
        let history = try await store.loadResetExpiryLog()
        #expect(history.count == 2)
        #expect(ResetExpiryExperiment(history: history).nextCheckpoint(accountIDs: [profile.id]) == expiry.addingTimeInterval(-300))
        #if !os(Windows)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.resetExpiryLogURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
        try Data("broken\n".utf8).write(to: store.resetExpiryLogURL)
        await #expect(throws: (any Error).self) { try await store.loadResetExpiryLog() }
    }

    @Test func olderSettingsKeepExperimentOff() throws {
        #expect(!AppSettings.default.resetExpiryExperimentEnabled)
        #expect(try !JSONDecoder().decode(AppSettings.self, from: Data(#"{"language":"system"}"#.utf8)).resetExpiryExperimentEnabled)
    }
}
