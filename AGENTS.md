# Agent guide

This file is the working contract for coding agents operating in this repository.

## Mission

Build a visual-first, local iPhone ledger that lets a parent add, subtract,
query, and undo money assigned to children with as little friction as possible.
Siri and Shortcuts remain supported secondary entry points, but unreliable
speech recognition and system routing must not dictate the primary interface.
Never confuse a compiling App Intent with successful Siri routing on a physical
iPhone.

Read these before substantial work:

1. `codex_build_brief_kid_money_ios_app.md` — complete product brief and constraints.
2. `README.md` — concise state and onboarding guide.
3. `docs/ARCHITECTURE.md` — current domain boundaries.
4. `docs/ROADMAP.md` — phase ordering and definition of the next checkpoint.
5. `docs/SIRI_TEST_PLAN.md` — device validation protocol.
6. `docs/FAMILY_SHARING_DESIGN.md` — proposed Phase 6 sync and identity design.

## Current state

Phases 1 through 5 and the focused Siri-routing experiment are complete. TestFlight build `0.1 (6)` physically verified the locked-screen numeric give/take grammar, exact balances, and relaunch persistence. Siri may still request Kid Money/Wallet disambiguation. Build `0.1 (7)` passed the manual-interface review. Phase 5 added exact input, duplicate-name matching, overflow protection, multi-context persistence tests, privacy-conscious logging, accessibility improvements, one production `ModelContainer`, and an opt-out from SwiftData-managed CloudKit sync.

Private CloudKit family sharing is approved for Phase 6. Build `0.1 (9)` passed the two-account counter-only physical probe on September 24, 2026: bidirectional writes and relaunch persistence worked, while both phones' local ledgers remained unchanged. The real-ledger foundation includes deterministic records, durable queues, strict atomic merge, out-of-order deferral, undo convergence, and a guarded CKSyncEngine adapter. Owner and participant setup coordinators stage, upload, share, accept, and import under injected transports. Build `0.1 (10)` wires these paths to explicit owner consent, participant Join, Sync Now, and participant-management UI; merely opening the app does not start an upload. Build 10 passed its owner-only, no-upload physical preflight on September 26, 2026, and is Testing in both internal and spouse external TestFlight groups. The owner reported Sharing enabled after upload consent and sent a private invitation. The spouse joined and saw the complete initial history. A new owner-side transaction then remained queued after Sync Now and did not arrive on the spouse's phone. Build `0.1 (11)` retains the sync runtime through fetch and send. On two phones, the previously queued owner edit cleared after Sync Now and appeared exactly once on the spouse's phone with the expected balance. The spouse then made a manual edit; Sync Now cleared her queue and delivered it once to the owner with the expected balance. Manual sync now works in both directions on physical phones. After both phones had been updated to iOS 27, build 11's locked one-shot fifteen-cent phrase requested an unlock and then returned an unsupported-capability response, while the unlocked prompted Give Money route created the correct `$0.15` Siri transaction and queued it for sync. That Siri-originated transaction subsequently reached the spouse exactly once; both phones preserved the matching `$3.00` balance and history through termination, relaunch, and another no-duplicate sync. Because both the app build and OS changed since build 6, the one-shot failure is an iOS 27 compatibility finding rather than an isolated build regression. Controlled offline/reconnect recovery then passed: an offline 35-cent owner edit remained pending across relaunch, stayed absent on the participant until reconnect, synchronized exactly once, and left both phones at `$3.35` after a no-duplicate repeat sync. Under Xcode 27, all 97 Swift Testing tests plus one out-of-process App Intents integration test pass on an iOS 27 simulator. The integration test resolves a dynamic child-and-fifteen-cent entity, executes the preset give intent, and reads back the exact 15-cent result; it does not prove Siri's natural-language or locked-screen routing. Build `0.1 (12)`, compiled with Xcode 27, then physically demonstrated that the identical one-shot phrase can fail as unsupported while unlocked and succeed from the locked screen after Kid Money/Wallet disambiguation, adding the exact 15 cents without child or amount follow-up. Later unlocked retries also succeeded with only app disambiguation and exact 15-cent mutations, including after the app was terminated. The warmed route survives termination; initial Siri phrase routing remains the nondeterministic layer.

The follow-up personal-Shortcut experiment proved that a fixed action can run,
but invoking its exact name through Siri routed to web search. A Vocal Shortcut
named “Rebecca allowance fifteen” then executed from the locked screen and
added the exact 15 cents. The owner trained 36 fixed phrases spanning three
children, six amounts, and give/take, but on-device speech recognition confused
similar names and amounts such as Daniel/David and fifty/fifteen. On September
27, 2026, the product direction therefore changed to visual-first. Voice stays
available as an optional bridge, but no more Siri-routing work or in-app voice
setup guidance is planned unless the platform behavior materially improves.

The activation gate validates owner or participant readiness, confirms iCloud
account identity and live share access, keeps offline edits queued across
restart, and freezes edits after account switching or share revocation without
deleting ledger data. Installed-SDK CloudKit errors are classified as temporary
or attention-required, including per-record partial failures. The
access-checked sync session fetches before sending, rechecks access, and
persists retry or attention-required state without deleting local rows or
queued edits. The build 14 candidate retains one automatic engine for an
activated household, forces foreground catch-up, coalesces rapid local edits,
and enables silent remote-change delivery without polling.

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
- apply one of six configurable, per-device quick amounts to an individual
  child or atomically to every active child from the home screen
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
- Preserve the physical Siri findings, but prioritize the visual interface and
  shared-ledger reliability over further voice-routing experiments.
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

Build 14 added visual Undo Last and guarded hybrid shared-ledger sync: one
app-scoped automatic CKSyncEngine, foreground catch-up, debounced post-mutation
work, silent remote-change delivery, and the existing Sync Now recovery action.
It passed 97 Swift tests, one App Intent integration test, and App Store Connect
validation; it was uploaded and is Testing in both Internal Testing and Family
Test. The owner-phone visual and pending-queue checks passed. Automatic
two-way sync, rapid edits, and offline/reconnect passed on physical phones
without Sync Now; one incoming change appeared after the receiving app was
backgrounded and foregrounded. Release cleanup removes the home-screen Undo
Last control at the owner's request and hides the disposable connection-test
UI while retaining the underlying Shortcuts undo behavior. Prepare and verify
a release candidate. Keep attention-required recovery non-destructive and do
not resume Siri-routing experiments.
