# Agent guide

This file is the working contract for coding agents operating in this repository.

## Mission

Build a Siri-first, local iPhone ledger that lets a parent add, subtract, query, and undo money assigned to children. The crucial product test is a real Siri invocation on a physical iPhone; do not confuse a compiling App Intent with successful Siri routing.

Read these before substantial work:

1. `codex_build_brief_kid_money_ios_app.md` — complete product brief and constraints.
2. `README.md` — concise state and onboarding guide.
3. `docs/ARCHITECTURE.md` — current domain boundaries.
4. `docs/ROADMAP.md` — phase ordering and definition of the next checkpoint.
5. `docs/SIRI_TEST_PLAN.md` — device validation protocol.
6. `docs/FAMILY_SHARING_DESIGN.md` — proposed Phase 6 sync and identity design.

## Current state

Phases 1 through 5 and the focused Siri-routing experiment are complete. TestFlight build `0.1 (6)` physically verified the locked-screen numeric give/take grammar, exact balances, and relaunch persistence. Siri may still request Kid Money/Wallet disambiguation. Build `0.1 (7)` passed the manual-interface review. Phase 5 added exact input, duplicate-name matching, overflow protection, multi-context persistence tests, privacy-conscious logging, accessibility improvements, one production `ModelContainer`, and an opt-out from SwiftData-managed CloudKit sync.

Private CloudKit family sharing is approved for Phase 6. Build `0.1 (9)` passed the two-account counter-only physical probe on September 24, 2026: bidirectional writes and relaunch persistence worked, while the owner's `Rebecca: $2.50` ledger and participant's empty ledger remained unchanged. The real-ledger foundation now includes deterministic records, durable queues, strict atomic merge, out-of-order deferral, undo convergence, a guarded queue processor, and a dormant CKSyncEngine adapter. Dormant owner and participant setup coordinators stage, upload, share, accept, and import under injected transports. None is instantiated by the app, so real-ledger network sync remains disabled. The app builds in Xcode 26.6 with 78 passing tests on an iOS 26.5 simulator.

The dormant activation gate now validates owner or participant readiness,
confirms iCloud account identity and live share access, keeps offline edits
queued across restart, and freezes edits after account switching or share
revocation without deleting ledger data. It is not wired into the app. The
current simulator suite has 78 passing tests. Installed-SDK CloudKit errors are
now classified as temporary or attention-required, including per-record
partial failures. The consent and invitation entry points are designed in
`docs/PHASE6_ACTIVATION_FLOW.md`.

Latest verified capabilities:

- create a child
- persist a signed manual transaction
- derive each child's balance from transactions
- show active children and balances
- manually add ten cents from child detail
- resolve active children case-insensitively for App Intents
- convert positive USD amounts to exact integer cents
- run `GiveMoneyIntent` in the background and return spoken dialog
- take arbitrary USD amounts and report balances through App Intents
- undo via auditable compensating transactions
- give or take named US coin denominations through a supplemental App Enum path
- resolve child-and-numeric-amount combinations through a dynamic App Entity for one-shot give and take phrases
- show newest-first transaction history with source, date, signed amount, and optional note
- add quick or arbitrary manual adjustments
- rename or archive children while preserving their ledger history
- deterministically map households, children, transactions, and compensating
  undo entries to CloudKit records without using floating-point money
- atomically save active-household ledger mutations with durable, coalesced
  pending CloudKit changes
- strictly decode and atomically merge supplied remote records without creating
  outgoing sync echoes
- durably defer out-of-order transactions and converge duplicate undo attempts
- process queued saves with persisted account/retry status and deterministic
  optimistic-conflict handling without enabling live uploads
- bridge durable changes and inbound records through a dormant `CKSyncEngine`
  delegate while persisting engine state and server change-tag metadata
- stage and recover a non-destructive existing-ledger migration without
  activating the network runtime or silently merging independent ledgers
- orchestrate dormant owner account, zone, initial-upload, share, and cleanup
  steps through an injected transport without activating synchronization
- validate and recover participant invitation acceptance and first-zone import
  without silently merging an unrelated local ledger
- guard owner and participant activation on current account and share access;
  preserve offline edits and freeze on account switch or revocation

## Non-negotiable rules

- Use Swift, SwiftUI, SwiftData, App Intents, and App Shortcuts.
- Target iOS 26+ unless a concrete SDK constraint requires reconsideration.
- Use integer cents (`Int64`) inside the ledger. Never use `Double` for money.
- Keep the ledger transaction history as the source of truth for balances.
- Route all mutations through `LedgerService`; do not duplicate balance logic in views or intents.
- Keep USD conversion isolated and exact. Reject zero, unsupported currency, fractional cents, and overflow.
- Do not hard-code child names or silently create a child after failed voice recognition.
- Prefer current installed-SDK APIs. Inspect compiler/SDK documentation instead of copying obsolete SiriKit examples.
- Preserve the phase order. Get to a real Siri test before building the rest of the UI.
- Private CloudKit family sharing is explicitly requested and approved for Phase
  6. The counter-only physical matrix in `docs/PHASE6_CONNECTION_TEST.md` has
  passed. Do not wire real-ledger upload into the app until activation and
  ongoing sync failure recovery are covered by injected tests.
  Do not introduce third-party dependencies, a custom backend,
  application-managed accounts, schedules, or notifications without another
  explicit request.
- Never commit real family ledger data, credentials, signing material, personal development-team identifiers, or device logs containing personal information.

## Verification expectations

Before committing implementation changes:

1. Build the `KidMoney` scheme for an installed iPhone simulator.
2. Run the relevant tests, preferably all tests for domain changes.
3. Inspect Xcode warnings as well as compiler errors.
4. Run `git diff --check`.
5. State what was and was not verified—especially for Siri behavior.

If Xcode MCP is available, prefer its project-aware build, test, Issue Navigator, preview, and Apple documentation tools. The local MCP server is configured as:

```zsh
codex mcp add xcode -- xcrun mcpbridge
```

Xcode must be open with this project loaded, and **Xcode → Settings → Intelligence → Allow external agents to use Xcode tools** must be enabled.

## Working style

- Make focused, reviewable commits on `main` for this personal project unless branching is requested.
- Keep explanations useful to an experienced backend engineer who is new to iOS.
- Prefer direct, idiomatic Swift over extra protocols, repositories, dependency-injection frameworks, or view-model layers.
- Update relevant documentation when a phase completes or a physical-device discovery changes assumptions.
- Never claim that a Siri phrase, locked-device behavior, or background execution works until it is observed on the user's iPhone.

## Immediate next task

Continue the durable shared-ledger synchronization layer described in
`docs/FAMILY_SHARING_DESIGN.md` and `docs/PHASE6_ACTIVATION_FLOW.md`. Add an
access-checked, dormant sync-session entry point with injected failure tests
before UI wiring. Then implement explicit owner upload consent and safe
participant invitation routing without enabling uploads at app launch. Keep
attention-required recovery non-destructive, update privacy disclosures before
TestFlight, and preserve the physically verified Siri grammar.
