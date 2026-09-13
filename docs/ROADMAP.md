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

Status: **Complete**

- Take Money
- Get Balance
- auditable Undo Last Transaction
- natural-language and coin-name experiments
- voice-specific error handling

Physical testing showed that `IntentCurrencyAmount` does not understand dime or quarter wording reliably, so a supplemental denomination path is justified. Keep arbitrary currency amounts available.

The then-current 11 tests passed, device and simulator builds succeeded without warnings, and Xcode's App Shortcuts Preview mapped the representative Phase 3 phrases to the intended actions. Build 4 physical testing verified upgrade migration, Take Money, Get Balance, Undo, the supplemental dime/quarter path, terminated execution, repeated undo, and relaunch persistence on the managed work phone. Coin utterances correctly supply the denomination but still require a child follow-up. One terminated “Give a dime” attempt routed to a web result before succeeding on retry; preserve this as a reliability finding.

### Siri reliability experiment — build 5

Status: **Distributed to internal TestFlight; physical verification pending**

The user specifically requested one-shot forms such as “Give Rebecca ten cents in Kid Money” before beginning Phase 4. The installed SDK rejects `IntentCurrencyAmount` in an App Shortcut phrase and permits only `AppEntity` or `AppEnum` phrase parameters. Build 5 therefore combines an active child and a common amount into one dynamic `LedgerAdjustmentEntity`, which fits Apple's one-parameter limit. It advertises app-name-first and app-name-last give/take forms, retains the arbitrary-amount follow-up intents, and removes the overlapping coin App Shortcuts that Xcode's flexible matcher preferred over the full request. The underlying coin actions remain available in Shortcuts.

All 12 tests pass and the simulator build has a clean Issue Navigator. The extracted App Intents metadata contains the new give/take routes. Xcode's simulator-side `linkd` helper failed to refresh dynamic shortcut parameters, so the preview could not resolve a child-specific utterance; this is not being treated as physical Siri verification. Execute the build 5 matrix in `SIRI_TEST_PLAN.md` before resuming Phase 4.

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
