# Reset expiry experiment

Settings includes **Auto-reset experiment (log only)**, off by default. Enabling it observes every saved account. This version never consumes a banked reset: the observer has no reset API, and the account client only reads `account/rateLimits/read` for this feature.

The app retains each reset's ID, status, type and expiration from the read response. It schedules additional usage reads at 10, 5 and 1 minute before `expiresAt`, independently of the ordinary five-minute poll. These are three simulated checkpoints for each credit. A hypothetical successful real redemption is not simulated as consuming that credit, so all three checkpoints remain observable. The usage window's `resetsAt` is not the expiry of a banked reset.

## Logs

Use **Open Log Folder** in Settings. Logs stay on this computer:

- macOS: `~/Library/Application Support/Codex Account Switcher/reset-expiry-experiment.jsonl`
- Windows: `%LOCALAPPDATA%\Codex Account Switcher\reset-expiry-experiment.jsonl`

The file uses private account-storage permissions. Each JSON line includes `mode: "dry_run"` and `resetAttempted: false`. It contains account display names and profile IDs, reset IDs and expiry times, usage snapshots, errors, planned and actual checkpoint times. Credentials and authentication tokens are not logged. Times are ISO 8601 UTC (`Z`); add eight hours for Beijing time.

| Event or decision | Meaning |
| --- | --- |
| `enabled`, `resumed`, `disabled` | Experiment enabled, restarted while enabled, or disabled |
| `snapshot` | A successful read, including the current reset details and usage |
| `read_failed` | The quota read failed; `error` preserves its cause |
| `checkpoint` / `would_attempt` | Timing and fresh available-credit data matched; only a log was written |
| `checkpoint` / `missed` | The app reached this checkpoint after its stage ended, including after expiry |
| `checkpoint` / `details_unavailable` | Count or usage is known, but reset details are unavailable |
| `checkpoint` / `credit_unavailable` | The previously observed reset is absent or no longer available |

`checkpointMinutes` is 10, 5 or 1. `scheduledAt`, `timestamp` and `delaySeconds` make delayed execution visible. Each stage ends when the next stage starts; the 1-minute stage ends at expiry. A missed stage is never reported as an on-time simulated attempt. The log also provides restart deduplication keyed by account, credit, expiry and checkpoint. Disabling stops checkpoint scheduling and observation writes; old logs remain available. A damaged log or failed write stops the experiment for that process and surfaces the error.

`would_attempt` does not assert backend eligibility or a successful reset. This experiment does not call the consumption endpoint. The official service's eligibility rules remain untested. The app must be running and the computer awake to observe a checkpoint on time. On macOS wake, the app refreshes immediately and records missed stages truthfully. No independent service or wake timer is installed.

## Validation

Shared tests advance a synthetic clock through 10/5/1 minutes, restart from saved history, check cross-account isolation, simulate failed reads, missing details, removed credits and wake after expiry. A controller test uses a near-term synthetic deadline with a one-hour ordinary polling interval to prove that the checkpoint triggers its own read; turning the setting off stops subsequent logging. A transport fixture verifies that only initialization and `account/rateLimits/read` are sent. Storage tests verify persisted history, corrupt-log errors and macOS file permissions.

No real reset is consumed during validation. Complete-cycle logs from real credits require keeping the experiment enabled until those credits approach expiry.
