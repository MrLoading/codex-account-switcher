import Foundation

public struct BankedResetCredit: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let resetType: String
    public let expiresAt: Date?

    public init(id: String, status: String, resetType: String, expiresAt: Date?) {
        self.id = id
        self.status = status
        self.resetType = resetType
        self.expiresAt = expiresAt
    }
}

struct ResetExpiryEvent: Codable, Sendable {
    var mode = "dry_run"
    var resetAttempted = false
    let timestamp: Date
    let event: String
    var profileID: UUID?
    var account: String?
    var usage: WeeklyUsage?
    var error: String?
    var creditID: String?
    var expiresAt: Date?
    var checkpointMinutes: Int?
    var scheduledAt: Date?
    var delaySeconds: Double?
    var decision: String?

    var checkpointKey: String? {
        guard let profileID, let creditID, let expiresAt, let checkpointMinutes else { return nil }
        return "\(profileID)/\(creditID)/\(expiresAt.timeIntervalSince1970)/\(checkpointMinutes)"
    }
}

/// A read-only timing experiment. It has no client or reset-consumption capability.
struct ResetExpiryExperiment {
    static let checkpoints = [10, 5, 1]
    private var latestUsage: [UUID: WeeklyUsage] = [:]
    private var completed: Set<String> = []

    init(history: [ResetExpiryEvent]) {
        for event in history {
            if let id = event.profileID, let usage = event.usage, usage.resetCredits != nil {
                latestUsage[id] = usage
            }
            if let key = event.checkpointKey { completed.insert(key) }
        }
    }

    func nextCheckpoint(accountIDs: Set<UUID>) -> Date? {
        latestUsage.filter { accountIDs.contains($0.key) }.flatMap { id, usage in
            (usage.resetCredits ?? []).flatMap { credit -> [Date] in
                guard credit.status == "available", credit.resetType == "codexRateLimits",
                      let expiry = credit.expiresAt else { return [] }
                return Self.checkpoints.compactMap { minutes in
                    let event = checkpoint(profileID: id, credit: credit, minutes: minutes, at: expiry)
                    return completed.contains(event.checkpointKey!) ? nil : event.scheduledAt
                }
            }
        }.min()
    }

    mutating func observe(
        profile: AccountProfile, usage: WeeklyUsage?, error: String? = nil, at now: Date
    ) -> [ResetExpiryEvent] {
        var events = [ResetExpiryEvent(timestamp: now, event: usage == nil ? "read_failed" : "snapshot",
            profileID: profile.id, account: profile.displayName, usage: usage, error: error)]
        let previous = latestUsage[profile.id]?.resetCredits ?? []
        let current = usage?.resetCredits ?? []
        let currentIDs = Set(current.map(\.id))
        let candidates = current + previous.filter { !currentIDs.contains($0.id) }
        for credit in candidates {
            guard credit.resetType == "codexRateLimits", let expiry = credit.expiresAt else { continue }
            for (index, minutes) in Self.checkpoints.enumerated() {
                var event = checkpoint(profileID: profile.id, credit: credit, minutes: minutes, at: now)
                guard let key = event.checkpointKey, !completed.contains(key), now >= event.scheduledAt! else { continue }
                let nextStage = index + 1 < Self.checkpoints.count
                    ? expiry.addingTimeInterval(-Double(Self.checkpoints[index + 1] * 60)) : expiry
                event.account = profile.displayName
                event.usage = usage
                event.error = error
                if now >= nextStage { event.decision = "missed" }
                else if usage == nil { event.decision = "read_failed" }
                else if usage?.resetCredits == nil { event.decision = "details_unavailable" }
                else if !currentIDs.contains(credit.id) || credit.status != "available" {
                    event.decision = "credit_unavailable"
                } else {
                    // Records the timing decision only; backend eligibility is not tested.
                    event.decision = "would_attempt"
                }
                events.append(event)
                completed.insert(key)
            }
        }
        // Unknown details retain only the old schedule; checkpoint decisions still require a fresh read.
        if let usage, usage.resetCredits != nil { latestUsage[profile.id] = usage }
        return events
    }

    private func checkpoint(profileID: UUID, credit: BankedResetCredit, minutes: Int, at now: Date) -> ResetExpiryEvent {
        let scheduled = credit.expiresAt!.addingTimeInterval(-Double(minutes * 60))
        return ResetExpiryEvent(timestamp: now, event: "checkpoint", profileID: profileID,
            creditID: credit.id, expiresAt: credit.expiresAt, checkpointMinutes: minutes,
            scheduledAt: scheduled, delaySeconds: max(0, now.timeIntervalSince(scheduled)))
    }
}
