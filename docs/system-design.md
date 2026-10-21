# System Design

## 1. Core Operation

Codex Account Switcher manages multiple local authentication snapshots for Codex on macOS and Windows. Its primary operation is replacing the active credential in `CODEX_HOME` (`~/.codex/auth.json` on macOS, `%USERPROFILE%\.codex\auth.json` on Windows) atomically and safely.

## 2. Module Layout

```text
Sources/
├── SwitcherCore/             Cross-platform state, storage, switching, RPC, live subscription, auto-reset, L10n
├── SwitcherHost/             Typed single-pass JSON stdio bridge for Windows
├── SwitcherPlatform/         Win32 private ACLs, extended-length directory removal, atomic writes
└── CodexAccountSwitcher/     macOS SwiftUI MenuBarExtra UI, AppKit Desktop controller, Sparkle updater

windows/
├── CodexAccountSwitcher/     Windows WPF window & system-tray application
├── CodexAccountSwitcher.Core/ CoreClient stdio transport, Desktop process-tree handoff, runtime extraction
└── CodexAccountSwitcher.*Checks/ Windows transport, process-tree, and WPF UI checks
```

## 3. Local Storage

Under `~/Library/Application Support/Codex Account Switcher/` (macOS, `0700` dirs / `0600` files) or `%LOCALAPPDATA%\Codex Account Switcher\` (Windows, current-user protected DACL):

- `accounts.json` — Ordered saved `AccountProfile` entries and `activeAccountID`.
- `accounts/<profile-id>/auth.json` — Isolated credential snapshot per saved account.
- `settings.json` — Language, status-bar/tray usage window, 5-hour visibility, `autoResetEnabled`, and the macOS Desktop launch environment, post-switch script, and auto-open preference.
- `usage-cache.json` — Last normalized weekly/5-hour usage per profile for instant display on launch.
- `subscription-cache.json` — Cached `LiveSubscription` metadata per `(profileID, accountID)`.
- `auto-reset.jsonl` — Bounded, crash-resilient log of automatic reset checkpoints, attempts, and readback verifications (automatically compacted above 256 KB / 500 entries; legacy `reset-expiry-experiment.jsonl` is migrated automatically).

## 4. Switching Sequence (`SwitchService`)

1. Validate target profile existence and preflight active registry state.
2. `closeDesktop`:
   - macOS requests graceful termination of `com.openai.codex` (`/Applications/Codex.app`) and waits up to 30s.
   - Windows terminates matched Codex Desktop process trees (`DesktopProcessTree`) while preserving independent CLI sessions.
   - If Codex Desktop is not installed, `closeDesktop` and `reopenDesktop` succeed as no-ops for CLI-only users.
3. `saveCurrentCredential`: Verify the live `auth.json` matches the expected active profile and copy it back into `accounts/<active-id>/auth.json`.
4. `activateTargetCredential`: Atomically install `accounts/<target-id>/auth.json` into `CODEX_HOME/auth.json`.
5. `verifyTargetIdentity`: Confirm the newly installed credential decodes to the target profile identity; otherwise restore the previous credential.
6. `commitActiveAccountID`: Persist the new `activeAccountID` and `lastUsedAt` in `accounts.json` (restoring the previous credential if saving fails).
7. `runPostSwitchScript`: On macOS, run the optional saved shell script with reserved source/target account context after the target is committed.
8. `reopenDesktopAfterSwitch`: Reopen Codex Desktop when installed and the macOS auto-open preference is enabled; surface a dedicated non-fatal warning if the script or reopen fails after activation.

## 5. Isolated `codex app-server` Transport (`CodexClient`)

- Every child `codex app-server` runs with:
  - `-c cli_auth_credentials_store="file"`
  - `-c features.plugins=false`
  - `-c features.remote_plugin=false`
  - `-c features.apps=false`
  - `-c features.shell_snapshot=false`
- Login-shell environment resolution (`PATH`, `CODEX_CLI_PATH`) runs asynchronously off Swift's cooperative thread pool with a 5-second timeout and is cached for 5 minutes.
- Official `@openai/codex` npm wrappers (`bin/codex.js` and Windows `codex.cmd`) unwrap directly to their native vendor binary so process lifecycle management tracks the real `codex` process.
- Per-profile quota sessions (`UsageSession`) coalesce rapid UI reads and expire after 90 seconds of inactivity so child processes exit cleanly between 5-minute background polls.
- When a custom provider explicitly returns `account: null` with `requiresOpenaiAuth: false`, identity matching falls back to the readable ChatGPT identity in that same profile home's `auth.json`; malformed or missing credentials still fail.

## 6. Live Subscription Refresh & Auto-Reset

- `LiveSubscriptionClient` queries `https://chatgpt.com/backend-api/subscriptions` for each profile after quota reads complete. On HTTP 401 for an inactive profile, `AccountController` runs a single isolated token renewal (`account/read` with `refreshToken: true`) with a 6-hour per-profile backoff; active Desktop credentials are never rotated in the background.
- `AutoReset` schedules reads at 10, 5, and 1 minute before expiring `codexRateLimits` credits, persists `reset_attempt` before calling `account/rateLimitResetCredit/consume`, verifies consumption via a follow-up usage read, and isolates transient failures per credit without disabling automation for other accounts.

## 7. macOS Desktop Launch Customization

- `DesktopController` overlays the saved launch environment when opening Codex Desktop.
- A nonempty post-switch script runs through `/bin/zsh -c` after credential verification and registry commit. It receives `CODEX_HOME` plus reserved `CODEX_SWITCHER_SOURCE_*` and `CODEX_SWITCHER_TARGET_*` profile metadata; reserved values override user-provided environment entries.
- First activation supplies empty source values. Missing optional profile fields are also empty strings, and metadata is passed through `Process.environment` without shell interpolation.
- Script failure leaves the committed target active and prevents automatic reopening. An empty script is skipped. Platforms without these preferences retain the normal reopen behavior.
