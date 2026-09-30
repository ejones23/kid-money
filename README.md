# Kid Money

Kid Money is a small, local-first iPhone ledger for tracking money owed to
children. Its primary product goal is now the fastest possible visual
interaction after opening the app: choose Give or Take, then tap an amount on a
child's card. Siri and Shortcuts remain optional secondary entry points.

The current ledger is intentionally simple: no custom backend, application
accounts, or third-party dependencies. A child's balance is derived from an
auditable transaction ledger rather than stored as a mutable total. Private
iCloud sharing between invited parents is available after the ledger owner
explicitly opts in; it preserves a local copy and needs no Kid Money login or
custom backend. TestFlight build 14 passed owner and spouse two-way automatic
sync, rapid-edit, and offline/reconnect checks. One incoming change was picked
up when the receiving app returned to the foreground. The release candidate
removes the obsolete counter-test entry and home-screen Undo Last control.
A durable migration state
machine now stages an existing ledger with deterministic record identities,
repairs interrupted queues, and refuses destructive or ambiguous adoption. A
dormant setup runner now validates iCloud, idempotently provisions the private
zone, drives the explicit initial engine upload, creates the zone-wide share,
and safely cleans up failed setup without deleting the local ledger.
The participant adoption coordinator now stages a private invitation, checks
for an unrelated local ledger, accepts the share, and imports the invited zone
as an atomic initial snapshot. The local build connects this path to an
explicit Join action, not automatic acceptance. An activation gate verifies owner or participant readiness,
the signed-in iCloud identity, and current share access before enabling edits.
Offline edits stay queued; account changes and revoked shares freeze new edits
without deleting local ledger history.

This is an early-stage public project. The code is available for learning,
adaptation, and contribution under the MIT License, but it should not yet be
treated as a finished personal-finance product.

The project uses TestFlight to verify visual behavior and private sharing on
physical phones before public release, without installing a locally signed
developer app on a managed phone.

## Current status

Phases 1 through 5 are complete. The core shared-ledger and visual-first flows
have passed physical tests, and public-release preparation is in progress:

- SwiftUI application targeting iOS 26+
- SwiftData models for children and signed ledger transactions
- shared `LedgerService` domain logic
- add-child flow
- large active-child cards with derived USD balances and direct quick actions
- one configurable, ordered set of up to six quick amounts per device
- direct all-children give/take actions that create one auditable
  transaction per active child
- newest-first transaction history with arbitrary manual adjustments
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
- a `CKSyncEngine` adapter for scoped batches, inbound merges, account
  changes, successful-send cleanup, and serialized engine-state restoration
- a non-destructive existing-ledger migration coordinator with durable phases,
  deterministic initial staging, restart repair, and guarded activation
- a dormant, injected owner setup runner covering account gating, private-zone
  provisioning, initial upload, share recovery, and confirmed remote cleanup
- a dormant participant adoption path with invitation validation, local-ledger
  preflight, scoped initial import, and interrupted-acceptance recovery
- a dormant activation gate with account/share verification, offline continuity,
  and non-destructive account-switch and revocation handling
- one app-scoped automatic-sync coordinator that reuses an access-checked
  session for foreground, debounced post-mutation, and explicit Sync Now work
- CloudKit's power-aware automatic scheduler and silent-change delivery for an
  activated household, with no repeating timer or polling
- an owner upload-consent screen and separate participant invitation review;
  neither launches network work merely because the app opened

The project builds in Xcode 27. All 97 Swift Testing tests and one
out-of-process App Intents integration test pass on the iOS 27 simulator. The
integration test executes the same app-side intent path used by Siri and
Shortcuts, including dynamic child-and-amount entity resolution and an exact
fifteen-cent mutation. Natural-language routing and locked-screen behavior
remain physical-iPhone checks rather than simulator claims.

TestFlight build `0.1 (3)` completed the Phase 2 physical-device checkpoint on both an unmanaged iPhone SE and the managed work iPhone after both reached iOS 26.6.2. Siri collects missing parameters, persists exact cent values, reports the resulting balance, and works with the app open, backgrounded, terminated, and while the work phone is locked. Device testing also showed that Siri accepts numeric phrases such as “ten cents” and “twenty-five cents” but rejects coin wording such as “a dime” and “a quarter,” justifying a supplemental denomination path in Phase 3.

TestFlight build `0.1 (4)` completed Phase 3 on the managed work phone. It preserved the existing ledger during migration and verified take, balance, auditable undo, named dime and quarter actions, terminated execution, repeated undo, and relaunch persistence. Coin phrases still request the child separately, and one dime attempt intermittently routed to a web result before succeeding on retry.

TestFlight build `0.1 (5)` physically verified one-shot additions for ten cents, twenty cents, and one dollar, including locked-screen execution, plus one-shot numeric subtraction. The stable wording is “Give/Take Rebecca twenty cents in Kid Money.” App-name-first forms can invoke Wallet disambiguation, and coin words remain unreliable; the owner accepted numeric amounts as the product grammar. Build `0.1 (6)` expanded the vocabulary to every five-cent increment through one dollar. Its locked-screen physical matrix passed for fifteen, twenty-five, and thirty-five cents with exact balances and relaunch persistence. Siri still requested Kid Money/Wallet disambiguation, but it extracted the child and amount without follow-up.

Build 12 confirmed that the app-side preset intent still works on iOS 27, but
Siri routing remained intermittent. A fixed Vocal Shortcut subsequently ran
from the locked screen, yet a larger 36-phrase matrix confused similar names
and amounts such as Daniel/David and fifty/fifteen. On September 27, 2026, the
project deliberately became visual-first. The voice implementation is retained
as a useful optional bridge, but further Siri-routing optimization and an
in-app voice-training workflow are no longer near-term goals.

Phase 4's manual interface passed its physical-device review in TestFlight build `0.1 (7)`: child detail shows a newest-first transaction history, quick-add buttons, arbitrary add/subtract forms with optional notes, and rename/archive management that preserves ledger history.

Build `0.1 (8)` reached the physical CloudKit connection checkpoint and exposed
two bootstrap conditions before any invitation was sent. Production lacked
CloudKit's system-generated `cloudkit.share` type, and the failed atomic save
left a local pointer to an otherwise empty test zone. The share type was
generated by one development-environment share and deployed to Production.
Build `0.1 (9)` remains active in the external `Family Test` group. It adds
automatic recovery for that incomplete probe state and now
persists connection metadata only after both the counter and share save
successfully. This recovery does not read or modify the local ledger.

On September 24, 2026, build 9 physically passed invitation acceptance and
two-way writes across two iPhones signed into different iCloud Apple Accounts.
The owner increment was observed as counter 1 on the participant phone, and the
participant increment was observed as counter 2 on the owner phone. Counter 2
survived termination and relaunch on both phones. The isolated test also left
the owner's existing ledger and the participant's empty ledger unchanged,
completing the physical connection-probe matrix.

## Requirements

- macOS with Xcode 27 for the complete test suite
- iOS 27 simulator runtime for App Intents integration testing (the domain
  suite also runs on iOS 26.5)
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
docs/PHASE6_CLOUDKIT_SCHEMA.md Production schema release gate
docs/PHASE6_REAL_LEDGER_TEST.md Two-device real-ledger test procedure
docs/PHASE4_TEST_PLAN.md      Manual-interface owner review
docs/QUICK_ACTION_TEST_PLAN.md Visual quick-action physical test procedure
docs/RELEASE_CANDIDATE_TEST.md Release-candidate physical smoke check
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

Build 13 completed the first visual-first checkpoint. The home screen gives each
child a large card with six direct amount buttons and uses one Give/Take
selector. The follow-up build puts All Children last, applies it without a
confirmation, keeps quick actions off child detail, and adds a contextual Undo
Last control. It also enables guarded hybrid synchronization: immediate work on
foreground and after a short mutation debounce, plus CloudKit's system-managed
automatic scheduler. Basic two-phone automatic sync passed without Sync Now;
one incoming change appeared after foreground catch-up. Rapid-edit and
automatic offline/reconnect checks remain. The amount list remains per device.

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
after account switching or invite revocation. The access-checked sync session
fetches before sending, rechecks account and share access, and retains queued
edits on failure. Build 10 has an explicit owner-consent screen,
participant invitation review, guarded Join, Sync Now, and
participant-management actions. The owner confirmed build 10 preserved the
local ledger and that cancelling upload consent left sharing disabled. The
owner then reported Sharing enabled after explicit upload and sent a private
invitation. The spouse joined and saw the complete initial history, but a new
owner-side edit remained queued after Sync Now and did not reach the spouse.
Build 11 fixes the sync runtime lifetime issue and is Testing in both internal
and spouse external groups. The previously queued edit cleared from the owner's
queue and appeared exactly once on the spouse's phone after explicit Sync Now
on each device. A subsequent spouse-side manual edit also synchronized back
to the owner exactly once with the expected balance. After both phones were
updated to iOS 27, an unlocked prompted Siri request on build 11 created an
exact fifteen-cent shared-ledger transaction and durable pending change, but
the prior locked one-shot phrase requested an unlock and then failed routing.
That Siri-originated transaction reached the spouse exactly once, and both
phones preserved the matching `$3.00` balance and history through termination,
relaunch, and another no-duplicate sync. Because both the app and OS changed
since build 6, the one-shot failure is recorded as an iOS 27 compatibility
finding rather than an isolated build regression. Controlled offline/reconnect
recovery also passed: an offline owner-side 35-cent edit survived app relaunch,
remained private until connectivity returned, synchronized exactly once, and
left both phones at `$3.35` after another no-duplicate sync. The Production CloudKit
schema and privacy disclosures passed
their release gates on September 26, 2026. The flow is documented in
[docs/PHASE6_ACTIVATION_FLOW.md](docs/PHASE6_ACTIVATION_FLOW.md).

Xcode 27's App Intents testing framework now provides a stronger automated
boundary check: the test runner launches the app, resolves the dynamic
“Rebecca fifteen cents” style entity in the app process, performs the preset
give intent out of process, and reads back exactly 15 cents. This narrows the
remaining iOS 27 one-shot issue to Siri's natural-language routing or system
registration layer. A TestFlight build compiled with Xcode 27 is the next
physical experiment. Build `0.1 (12)` was compiled and archived with Xcode 27,
uploaded successfully, and added to Internal Testing on September 26, 2026;
its owner-phone check produced a mixed but diagnostic result. The first
unlocked one-shot request returned unsupported, while the identical locked
request immediately afterward routed through Kid Money/Wallet disambiguation,
added exactly `$0.15` without child or amount follow-up, and reported the
correct balance. The route is therefore present and locked-screen capable, but
Siri's iOS 27 natural-language routing initially remained intermittent. A
subsequent unlocked retry succeeded with only Kid Money/Wallet disambiguation
and another exact `$0.15`, consistent with a one-time post-update route warm-up.
The same request also succeeded after Kid Money was terminated. A subsequent
personal-Shortcut and Vocal Shortcut experiment proved fixed actions could run
from the lock screen, but recognition collisions across the required family
phrase matrix led to the visual-first product pivot.

Build `0.1 (13)` implements the visual-first home-screen pivot: large child
cards, six configurable per-device quick amounts, a Give/Take selector, and an
atomic All Children action. It passed its owner-phone checks on September 27,
2026. Build 14 moves All Children below the individual child cards, removes its
confirmation, keeps quick actions off child detail, and enables guarded hybrid
automatic synchronization. Build 14 passed two-way automatic sync, rapid edits,
and offline/reconnect recovery on physical phones. One incoming change required
foregrounding the receiving app. Release cleanup removes the home-screen Undo
Last control and the obsolete counter-test entry; the auditable undo operation
remains available through Shortcuts.

Physical testing showed that the prior coin phrases reliably collected the denomination but still requested the child separately, even when the child was spoken in the initial utterance. Build 5 replaces those overlapping advertised coin routes with the combined entity experiment; the underlying coin intents remain available as actions in Shortcuts.

See [docs/ROADMAP.md](docs/ROADMAP.md) and [docs/SIRI_TEST_PLAN.md](docs/SIRI_TEST_PLAN.md) for the full checkpoint.

Release preparation is tracked separately in
[docs/APP_STORE_RELEASE.md](docs/APP_STORE_RELEASE.md). TestFlight remains the
physical-device verification path for visual behavior, sharing, and the
retained optional voice integrations.

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
