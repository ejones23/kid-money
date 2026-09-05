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

Status: **Implemented; awaiting physical-device verification**

- exact USD `Decimal`/`IntentCurrencyAmount` conversion with tests
- lightweight `ChildEntity` and case-insensitive `EntityStringQuery`
- `GiveMoneyIntent`
- `AppShortcutsProvider` using valid current phrase syntax
- focused OSLog instrumentation
- physical-device signing, installation, and one end-to-end Siri transaction — **remaining**

Exit criterion: Rebecca begins at $0.00; a Siri utterance reasonably close to “Give Rebecca a dime in Kid Money” persists `+10` cents, Siri reports the balance, and the relaunched app shows $0.10.

Pause for the physical-device matrix in `SIRI_TEST_PLAN.md`. Do not claim success based on compilation alone.

App Shortcut phrases can interpolate at most one intent parameter. The proof of concept interpolates the child; the amount remains required and may be extracted semantically or requested by Siri as a follow-up. Record the observed behavior rather than assuming one-shot routing.

## Phase 3 — Complete voice actions

Status: Planned

- Take Money
- Get Balance
- auditable Undo Last Transaction
- natural-language and coin-name experiments
- voice-specific error handling

Only add coin-denomination fallback intents if device testing shows `IntentCurrencyAmount` does not understand common coin names reliably.

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

CloudKit, authentication, family sharing, backend services, Android, recurring allowances, notifications, payments, subscriptions, analytics, advertising, gamification, and App Store release work.
