# App Lock & Privacy Specification

This specification owns biometric/passcode authentication, app-wide lock synchronization, app-switcher snapshot protection, export security gates, and the on-device privacy guarantee.

- Parent Scope: [MVP.md](../../MVP.md)
- Domain Terms: [GLOSSARY.md](../../GLOSSARY.md)
- Code Mapping: `AppLock.swift`, `JournalExport.swift`, `SettingsViewController.swift` (see [architecture.md](../agents/architecture.md))

## 1. Stories & Acceptance Criteria

- **Story 58**: Offer optional Face ID, Touch ID, or device passcode protection.
- **Story 59**: Keep journal content completely obscured after failed or cancelled authentication.
- **Story 60**: Cover journal content in app-switcher snapshots immediately on resigning active.
- **Story 61**: Provide in-app static privacy documentation explaining local-first architecture.
- **Story 77**: Synchronize lock state app-wide: lock and unlock all open Liney windows simultaneously with one authentication.
- **Story 78**: Cancelling export authentication aborts only the export without locking the app.

## 2. Implementation Decisions

### Authentication Architecture & State Machine
- Powered by `LocalAuthentication` with system passcode fallback. No custom PIN/password or custom lock timeout in MVP.
- **App-Wide Lock State (`AppLockModel`)**:
  - App Lock state is global across all scenes.
  - Locks when the last foreground scene transitions to the background.
  - When returning to the foreground, the first active scene prompts for biometric/passcode authentication once.
  - A single successful authentication unlocks every connected scene and window immediately.
  - Newly connected or restored scenes inherit the app's current lock status.
  - Turning App Lock on or off in Settings applies globally across all scenes.

### Snapshot Protection & Privacy Shield
- Snapshot shielding is managed per scene via `AppLockScene` and `JournalPrivacyShield`.
- When any scene enters inactive state (`willResignActive`), it immediately displays the privacy shield over content before the system captures an app-switcher snapshot.
- Uncovers automatically when returning to active state (if already unlocked).
- Snapshot covering is an ephemeral visual shield; covering does not trigger a state lock.
- While App Lock is locked, every connected window on all displays shows `LockedJournalController` with an "Unlock" action.

### Export Gate Isolation
- Initiating Markdown export requires fresh authentication if App Lock is enabled.
- Cancelling or failing the export authentication dialog cancels only the export operation. It does not transition the app into a locked state.

### Privacy Copy
- A dedicated static privacy page inside Settings documents the local-only guarantee:
  - Journal data is strictly stored on-device.
  - No accounts, cloud sync, analytics, or advertising SDKs.
  - Photos are duplicated into the Liney app sandbox.
  - Import and export occur solely on explicit user action.
