# Kid Money

Kid Money is a small, local-first iPhone ledger for tracking money owed to children. The primary product goal is a fast Siri interaction such as:

> “Give Rebecca a dime in Kid Money.”

The current ledger is intentionally simple: no custom backend, application
accounts, or third-party dependencies. A child's balance is derived from an
auditable transaction ledger rather than stored as a mutable total. Private
iCloud sharing between invited parents is now in development; its approved
design preserves the local-first ledger and does not introduce a Kid Money
login or custom backend. TestFlight builds 8–9 contain only a disposable
CloudKit connection probe and do not upload ledger data. The real sync
foundation now defines
deterministic CloudKit records, a durable local pending-change queue, and tested
remote decode/merge rules. A tested queue processor now adds persisted sync
status, retry/backoff, iCloud account gating, and optimistic conflict handling,
and a `CKSyncEngine` delegate now handles scoped send/fetch events, opaque engine
state, and CloudKit system metadata. The runtime is not instantiated by the app,
so no real ledger network synchronization starts yet. A durable migration state
machine now stages an existing ledger with deterministic record identities,
repairs interrupted queues, and refuses destructive or ambiguous adoption. A
dormant setup runner now validates iCloud, idempotently provisions the private
zone, drives the explicit initial engine upload, creates the zone-wide share,
and safely cleans up failed setup without deleting the local ledger.
The participant adoption coordinator now stages a private invitation, checks
for an unrelated local ledger, accepts the share, and imports the invited zone
as an atomic initial snapshot. It remains disconnected from the app.
A separate dormant activation gate verifies owner or participant readiness,
the signed-in iCloud identity, and current share access before enabling edits.
Offline edits stay queued; account changes and revoked shares freeze new edits
without deleting local ledger history.

This is an early-stage public project. The code is available for learning,
adaptation, and contribution under the MIT License, but it should not yet be
treated as a finished personal-finance product.

The project uses internal TestFlight distribution so that its physical-device Siri checkpoint can be tested through an approved channel rather than a locally signed app on a managed phone.

## Current status

Phases 1 through 5 are complete, and Phase 6 has begun:

- SwiftUI application targeting iOS 26+
- SwiftData models for children and signed ledger transactions
- shared `LedgerService` domain logic
- add-child flow
- active-child list with derived USD balances
- newest-first transaction history with quick and arbitrary manual adjustments
- child rename and archive flows that preserve ledger history
- `GiveMoneyIntent` with a background execution mode
- `TakeMoneyIntent`, `GetBalanceIntent`, and auditable `UndoLastTransactionIntent`
- supplemental named-coin give/take intents for nickel, dime, quarter, half dollar, and dollar
- a combined child-and-common-amount Siri vocabulary for one-shot give/take requests
- case-insensitive App Entity lookup for active children
- exact USD `Decimal` to integer-cents conversion
- App Shortcut discovery phrases and focused intent logging
- unit coverage for ledger behavior, store reopening, multi-context stress,
  child lookup, formatting, localized money conversion, overflow rejection, and
  repeated undo
- a counter-only private CloudKit sharing probe for two-account validation
- deterministic CloudKit mappings and a durable, coalescing local change queue
  that remains dormant until a household is explicitly active
- strict CloudKit record decoding and atomic, idempotent remote merging with
  deterministic child conflicts and durable out-of-order transaction deferral
- restart-safe queue draining with account gating, bounded retry/backoff, and
  optimistic conflict handling behind an injected CloudKit transport boundary
- a dormant `CKSyncEngine` adapter for scoped batches, inbound merges, account
  changes, successful-send cleanup, and serialized engine-state restoration
- a non-destructive existing-ledger migration coordinator with durable phases,
  deterministic initial staging, restart repair, and guarded activation
- a dormant, injected owner setup runner covering account gating, private-zone
  provisioning, initial upload, share recovery, and confirmed remote cleanup
- a dormant participant adoption path with invitation validation, local-ledger
  preflight, scoped initial import, and interrupted-acceptance recovery
- a dormant activation gate with account/share verification, offline continuity,
  and non-destructive account-switch and revocation handling

The project builds without errors or warnings in Xcode 26.6. All 78 current
tests pass on the iOS 26.5 simulator. Xcode's App Shortcuts Preview resolves the
Phase 3 take, balance, undo, dime, and quarter phrases to their intended actions.

TestFlight build `0.1 (3)` completed the Phase 2 physical-device checkpoint on both an unmanaged iPhone SE and the managed work iPhone after both reached iOS 26.6.2. Siri collects missing parameters, persists exact cent values, reports the resulting balance, and works with the app open, backgrounded, terminated, and while the work phone is locked. Device testing also showed that Siri accepts numeric phrases such as “ten cents” and “twenty-five cents” but rejects coin wording such as “a dime” and “a quarter,” justifying a supplemental denomination path in Phase 3.

TestFlight build `0.1 (4)` completed Phase 3 on the managed work phone. It preserved the existing ledger during migration and verified take, balance, auditable undo, named dime and quarter actions, terminated execution, repeated undo, and relaunch persistence. Coin phrases still request the child separately, and one dime attempt intermittently routed to a web result before succeeding on retry.

TestFlight build `0.1 (5)` physically verified one-shot additions for ten cents, twenty cents, and one dollar, including locked-screen execution, plus one-shot numeric subtraction. The stable wording is “Give/Take Rebecca twenty cents in Kid Money.” App-name-first forms can invoke Wallet disambiguation, and coin words remain unreliable; the owner accepted numeric amounts as the product grammar. Build `0.1 (6)` expanded the vocabulary to every five-cent increment through one dollar. Its locked-screen physical matrix passed for fifteen, twenty-five, and thirty-five cents with exact balances and relaunch persistence. Siri still requested Kid Money/Wallet disambiguation, but it extracted the child and amount without follow-up.

Phase 4's manual interface passed its physical-device review in TestFlight build `0.1 (7)`: child detail shows a newest-first transaction history, quick-add buttons, arbitrary add/subtract forms with optional notes, and rename/archive management that preserves ledger history.

Build `0.1 (8)` reached the physical CloudKit connection checkpoint and exposed
two bootstrap conditions before any invitation was sent. Production lacked
CloudKit's system-generated `cloudkit.share` type, and the failed atomic save
left a local pointer to an otherwise empty test zone. The share type was
generated by one development-environment share and deployed to Production.
Build `0.1 (9)` is active in both the internal and external family TestFlight
groups. It adds automatic recovery for that incomplete probe state and now
persists connection metadata only after both the counter and share save
successfully. This recovery does not read or modify the local ledger.

On September 24, 2026, build 9 physically passed invitation acceptance and
two-way writes across two iPhones signed into different iCloud Apple Accounts.
The owner increment was observed as counter 1 on the participant phone, and the
participant increment was observed as counter 2 on the owner phone. Counter 2
survived termination and relaunch on both phones. The isolated test also left
the owner's `Rebecca: $2.50` ledger and the participant's empty ledger unchanged,
completing the physical connection-probe matrix.

## Requirements

- macOS with Xcode 26.6 or a compatible newer Xcode
- iOS 26.5 simulator runtime for simulator testing
- an iPhone running iOS 26+ for the real Siri proof of concept
- an Apple development team configured in Xcode for physical-device installation

## Getting started

Open [KidMoney.xcodeproj](KidMoney.xcodeproj) in Xcode, select an iPhone simulator, and run the `KidMoney` scheme.

From the command line:

```zsh
xcodebuild \
  -project KidMoney.xcodeproj \
  -scheme KidMoney \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

Run tests with:

```zsh
xcodebuild \
  -project KidMoney.xcodeproj \
  -scheme KidMoney \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

The first simulator boot may spend several minutes performing data migration. Wait for it to finish before starting multiple test runs.

## Project structure

```text
KidMoney/                     Application source
KidMoneyTests/                Swift Testing domain tests
docs/ARCHITECTURE.md          Domain and persistence design
docs/APP_STORE_RELEASE.md     TestFlight and App Store checklist
docs/APP_STORE_METADATA.md    Draft public listing copy
docs/APP_ICON.md              Provisional icon notes and source prompt
docs/DEVELOPMENT.md           Setup and verification workflow
docs/FAMILY_SHARING_DESIGN.md Proposed shared-ledger persistence and identity design
docs/PHASE6_ACTIVATION_FLOW.md Safe owner opt-in and participant invitation flow
docs/PHASE6_CONNECTION_TEST.md Two-device CloudKit connection-test procedure
docs/PHASE4_TEST_PLAN.md      Manual-interface owner review
docs/ROADMAP.md               Delivery plan and next steps
docs/SIRI_TEST_PLAN.md        Physical-device proof checklist
docs/privacy.md               Draft public privacy policy
docs/support.md               Draft public support page
```

## Guiding constraints

- Store money as signed `Int64` cents; never use `Double` for ledger values.
- Derive balances from transactions.
- Keep SwiftUI and App Intents on the same domain/service path.
- Do not silently create children when voice resolution fails.
- Test Siri behavior empirically on a physical iPhone; compilation does not prove utterance routing.
- Keep the architecture proportionate to this tiny local application.

## Next milestone

Build 6 completed the focused Siri-routing improvement. Apple permits only one intent parameter in an App Shortcut phrase, so the app presents each active child paired with a preset amount as one dynamic App Entity. Every five-cent increment from five cents through one dollar is available through the verified child-first grammar; arbitrary amounts remain available through the existing follow-up flow. Physical testing confirmed correct locked-screen execution after Siri's Kid Money/Wallet app choice.

Phase 4's useful manual interface passed the focused physical-hardware review in [docs/PHASE4_TEST_PLAN.md](docs/PHASE4_TEST_PLAN.md). Phase 5 reliability work is complete: locale-aware exact input parsing, duplicate child-name disambiguation, balance-overflow rejection, the minimum-integer undo edge case, multi-context store stress, privacy-conscious diagnostics, and focused accessibility improvements are covered. The app and App Intents now use one process-wide production container, with SwiftData-managed CloudKit synchronization explicitly disabled in preparation for the direct CloudKit layer.

Phase 6 adds a private shared household ledger so two parents can manage the
same children from separate Apple Accounts. The approved local-first SwiftData
plus direct CloudKit/`CKShare` design, authentication model, migration rules,
and two-device test plan are documented in
[docs/FAMILY_SHARING_DESIGN.md](docs/FAMILY_SHARING_DESIGN.md). Build 9 passed
the isolated invitation and two-way-write checkpoint in
[docs/PHASE6_CONNECTION_TEST.md](docs/PHASE6_CONNECTION_TEST.md). The code now
has deterministic Household, Child, and LedgerTransaction record mappings, a
durable local pending-change queue, an atomic remote merge service, and a tested
queue processor with persisted sync state, account gating, exponential backoff,
and deterministic conflict handling. A dormant `CKSyncEngine` runtime now
bridges the durable queue to scoped send batches, merges inbound events, saves
record change-tag metadata, and persists/restores the engine's opaque state.
The migration coordinator now keeps the existing SwiftData ledger intact,
persists each setup phase, stages a deterministic initial queue, repairs an
interrupted queue after restart, retains edits made during setup, prevents share
creation before the initial queue drains, and refuses to silently merge an
invitation into a second local ledger. The injected setup runner now implements
idempotent account, zone, upload, share, interruption, and cleanup orchestration.
The participant adoption path now validates a zone-wide, read-write invitation,
rejects a phone with an unrelated local ledger, imports the invited zone, and
recovers a lost acceptance response after relaunch. The injected activation
gate now checks the iCloud account and live share before enabling a prepared
ledger. It preserves queued offline edits across restart and freezes new edits
after account switching or invite revocation. The next checkpoint is a safe,
explicit app entry point and an access-checked sync session. Real family data remains
local because setup, activation, and sync are not called from the app.
The proposed consent, invitation-routing, and attention-required screens are
documented in [docs/PHASE6_ACTIVATION_FLOW.md](docs/PHASE6_ACTIVATION_FLOW.md).

Physical testing showed that the prior coin phrases reliably collected the denomination but still requested the child separately, even when the child was spoken in the initial utterance. Build 5 replaces those overlapping advertised coin routes with the combined entity experiment; the underlying coin intents remain available as actions in Shortcuts.

See [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/SIRI_TEST_PLAN.md](docs/SIRI_TEST_PLAN.md) for the full checkpoint.

Release preparation is tracked separately in [docs/APP_STORE_RELEASE.md](docs/APP_STORE_RELEASE.md). It exists to unblock the physical Siri test through TestFlight; it does not replace the Siri-first product phase order.

## Source of truth

The original product and engineering brief is preserved in [codex_build_brief_kid_money_ios_app.md](codex_build_brief_kid_money_ios_app.md). If this README and the brief disagree on product requirements, update both deliberately rather than allowing them to drift.

## Contributing and privacy

Issues and focused pull requests are welcome while the project evolves. Please
read [AGENTS.md](AGENTS.md) for the engineering constraints and current workflow.

Do not commit real family ledger data, signing certificates, provisioning
profiles, Apple development-team identifiers, secrets, or device logs containing
personal information. Runtime ledger data belongs in the app's local container
and is not part of this repository.

## License

Kid Money is available under the [MIT License](LICENSE).

## Naming

The app display name is **Kid Money** and the repository name is **kid-money**. The shorter repository name is descriptive without repeating implementation details such as “ledger” or “app.”
