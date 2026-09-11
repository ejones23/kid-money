# Roadmap

The phase order is intentional: prove the riskiest Siri path before expanding the interface.

## Phase 1 — Skeleton and persistence

Status: **Complete**

- SwiftUI app and Xcode project
- SwiftData child and ledger models
- central ledger service
- child list and add-child flow
- derived balances and minimal manual action
- initial unit tests
- simulator build and test verification

## Phase 2 — Siri proof of concept

Status: **Complete**

- exact USD `Decimal`/`IntentCurrencyAmount` conversion with tests
- lightweight `ChildEntity` and case-insensitive `EntityStringQuery`
- `GiveMoneyIntent`
- `AppShortcutsProvider` using valid current phrase syntax
- focused OSLog instrumentation
- Siri capability, usage description, and explicit missing-amount prompting in TestFlight build `0.1 (2)`
- end-to-end Siri execution through a user-created shortcut on the managed iPhone
- localized App Shortcut phrase resources in TestFlight build `0.1 (3)`
- automatic App Shortcut phrase routing failed on the managed physical device in builds `0.1 (1)` through `0.1 (3)`
- automatic App Shortcut routing and prompted parameters succeeded twice on an unmanaged iPhone SE with build `0.1 (3)`
- automatic routing later succeeded on the unchanged managed-phone installation and persisted a twenty-cent transaction
- terminated and locked execution succeeded without requiring an unlock; termination/relaunch persistence is verified
- amounts below ten cents were repeatedly rejected by Siri's currency resolver before intent execution
- open and background execution succeeded; numeric “ten cents” and “twenty-five cents” resolved, while dime and quarter wording did not

Exit criterion: Rebecca begins at $0.00; a Siri utterance reasonably close to “Give Rebecca a dime in Kid Money” persists `+10` cents, Siri reports the balance, and the relaunched app shows $0.10.

Pause for the physical-device matrix in `SIRI_TEST_PLAN.md`. Do not claim success based on compilation alone.

Direct development installation was attempted on a managed work iPhone, but the organization's developer-trust policy prevented launch. The development app, Developer Mode, and pairing were removed. The owner chose TestFlight/App Store distribution as the compliant route to this checkpoint; release preparation is tracked in `APP_STORE_RELEASE.md`.

App Shortcut phrases can interpolate at most one intent parameter. The proof of concept interpolates the child; the amount remains required and may be extracted semantically or requested by Siri as a follow-up. Record the observed behavior rather than assuming one-shot routing.

## Phase 3 — Complete voice actions

Status: **In progress**

- Take Money
- Get Balance
- auditable Undo Last Transaction
- natural-language and coin-name experiments
- voice-specific error handling

Physical testing showed that `IntentCurrencyAmount` does not understand dime or quarter wording reliably, so a supplemental denomination path is justified. Keep arbitrary currency amounts available.

## Phase 4 — Useful manual interface

Status: Planned

- transaction history and quick coin buttons
- arbitrary add/subtract input
- rename and archive children
- stronger empty/error states and modest visual polish

## Phase 5 — Reliability

Status: Planned

- expanded conversion, lookup, undo, and persistence tests
- concurrency and App Intent store-access hardening
- logging, diagnostics, and device-discovered edge cases

## Explicitly deferred

CloudKit, authentication, family sharing, backend services, Android, recurring allowances, notifications, payments, subscriptions, analytics, advertising, and gamification.

Minimal TestFlight and App Store preparation is now active by explicit owner request, but later feature phases remain blocked on the physical Siri checkpoint.
