# Architecture

## Overview

Kid Money's ledger is local-first. SwiftUI and App Intents share a SwiftData
store and a small domain service. The isolated CloudKit connection probe has
completed Phase 6 transport validation. The real shared-ledger foundation now
defines local sync state, deterministic CloudKit mappings, and a durable change
queue. It can strictly decode and locally merge supplied CloudKit records. A
transport-independent queue processor now exercises send policy, retry, account
gating, and optimistic conflicts. A concrete `CKSyncEngine` delegate now maps
engine events into those persistence and merge boundaries. A durable migration
coordinator stages existing local ledgers without changing their rows. The app
does not instantiate either path or perform network synchronization. A dormant
owner setup runner composes those pieces behind an injected CloudKit boundary.

```text
SwiftUI views ──────┐
                   ├── LedgerService ── SwiftData ModelContext ── local store
App Intents ───────┘
```

## Domain model

### Child

- stable UUID, name, creation date, last-modified date, sort order, and archive flag
- relationship to ledger transactions

Archiving is preferred to destructive deletion so historical transactions remain understandable.

### LedgerTransaction

- stable UUID and optional relationship to `Child`
- signed `amountCents: Int64`
- creation date, optional note, and persisted source
- optional `reversesTransactionID` linking an undo entry to the transaction it compensates

Amounts are signed: `+10` adds ten cents and `-25` removes a quarter. The balance is always the sum of a child's transactions.

## Service boundary

`LedgerService` owns domain mutations and queries. SwiftUI uses it to add, rename, and archive children; add transactions; fetch history; and calculate balances. App Intents reuse the same operations. Archiving only changes the child's active flag and never deletes ledger history.

Before inserting a transaction, the service verifies that adding its signed cents to the current derived balance cannot overflow `Int64`. A rejected transaction is not inserted or saved.

The service is `@MainActor` because its `ModelContext` is main-actor-bound in the current small application. Revisit context ownership only if App Intent execution demonstrates a concrete concurrency need.

## Persistence

`AppModelContainer` lazily creates one process-wide `ModelContainer` for
production and can create isolated in-memory or URL-based containers for tests.
The app, App Entity queries, and App Intents all use that shared production
container. Its `ModelConfiguration` explicitly sets `cloudKitDatabase: .none`
so future CloudKit entitlements cannot cause SwiftData to start an independent
automatic synchronization stack.

Physical Phase 2 testing confirmed that background App Intent execution opens the same store safely and that values survive termination and relaunch. Do not create a separate intent-only database.

## Family sharing boundary

Private parent-to-parent sharing is being introduced in two stages. The current
`FamilySharingProbe` validates iCloud account availability, private custom-zone
creation, invitation acceptance, and two-way writes with one disposable
counter. It has no path to `AppModelContainer` or `LedgerService`, so enabling
the probe cannot upload names, balances, notes, or transactions.

Probe connection metadata is persisted only after the initial counter and
zone-wide share both save successfully. On upgrade from build 8, the probe also
recognizes the narrow incomplete-owner state where the counter and share are
both absent and clears only its disposable `UserDefaults` pointer. Ledger
models and the SwiftData container are not involved in that recovery.

That physical checkpoint passed on two Apple Accounts in build 9. SwiftData
remains the local working store and `LedgerService` remains the mutation
boundary. `SharedLedgerState` records the household, zone, database scope,
role, phase, and schema version. `PendingCloudChange` durably and idempotently
records a pending save or deletion by deterministic CloudKit record name.

When no shared household exists, ordinary ledger operations remain purely
local. A preparing household also remains local unless it has an explicit
`CloudLedgerMigrationState`. During that migration, `LedgerService` saves new
local edits and their coalesced pending changes together so an edit made during
setup cannot fall outside the initial upload. Once a household is active, the
same queueing rule continues for normal synchronization. An attention-required
household rejects further ledger mutations instead of silently accumulating
changes that cannot safely converge. No production code starts queue draining
yet, so this foundation cannot upload real ledger data.

`CloudLedgerRecordMapper` maps Household, Child, and LedgerTransaction values
without floating-point money. Children and transactions use their stable UUIDs
for record names. Undo transactions derive a deterministic UUID from the
original transaction UUID so two devices cannot create two distinct undo
records for the same ledger entry. A future direct CloudKit layer will drain the
queue and merge records through one private, zone-wide `CKShare`; it will not
use SwiftData's automatic CloudKit mode or an additional Core Data container.
See `FAMILY_SHARING_DESIGN.md` for the approved conflict, authentication, and
migration rules.

`CloudLedgerMergeService` validates record types, deterministic names, zone
identity, schema versions, exact integer cents, and domain fields before any
merge. A batch saves atomically or rolls back. Transactions are immutable and
idempotent; a conflicting payload for an existing ID is rejected. Child
metadata uses modification time followed by stable payload ordering as its
last-write-wins tie-breaker. Remote changes are written directly through a
dedicated merge context and never enter the outgoing queue.

`CloudLedgerQueueProcessor` drains active-household changes oldest-first through
an injected `CloudLedgerQueueTransport`. `CloudLedgerSyncState` persists status,
last attempt/success, the next retry time, error code, database scope, and a
reserved opaque `engineStateData` slot. Transient failures use bounded
exponential backoff and honor a longer server retry interval. Missing or
restricted iCloud accounts and irreconcilable data conflicts move the household
to attention-required state; queued work is retained and ordinary ledger writes
stop until recovery is explicit.

For optimistic-save conflicts, child metadata is merged with the same
deterministic last-write-wins policy as inbound records. A server winner
completes the local change; a local winner is retried using the server record's
system fields and change tag. Ledger transactions remain immutable: a different
payload for an existing transaction ID is never overwritten. The processor is
covered through an in-memory transport, including restart-safe retry state.

`CloudLedgerSyncEngineDelegate` scopes fetches and sends to exactly one household
zone, materializes send batches from the durable queue, merges fetched records,
classifies per-record failures, and stops on remote deletions or account changes
that require a product decision. Successful saves clear the corresponding local
queue entries. `CloudLedgerRecordMetadata` stores only encoded CloudKit system
fields so retries retain server change tags without duplicating ledger payloads.
The durable SwiftData queue is authoritative: initialization adds any missing
engine pending changes, while a stale engine-only save is discarded rather than
re-uploaded. If a local mutation coalesces into the queue while an older record
version is in flight, the successful-send event compares that accepted payload
with current local state and immediately requeues the newer version.

Each state-update event is JSON-encoded into `CloudLedgerSyncState.engineStateData`
and restored when constructing `CloudLedgerSyncEngineRuntime`. Automatic sync
defaults to disabled and no production call site creates the runtime. Status
UI, remote-notification capability, and the activation coordinator remain
deliberately disconnected from app startup.

`CloudLedgerMigrationCoordinator` persists the owner setup phases: awaiting
zone creation, uploading the initial ledger, awaiting share creation, ready to
activate, completed, and attention required. Beginning setup inserts a
preparing `SharedLedgerState` and queues the household plus every child and
transaction by deterministic record name without rewriting the ledger. Resume
reconstructs missing queue entries after interruption; re-sending an already
accepted deterministic record is safe through stored CloudKit system fields or
optimistic conflict handling. The coordinator will not advance beyond initial
upload while pending records remain, will not activate before a share exists,
and permits local cancellation only before a remote zone can exist. A terminal
failure preserves every ledger row and blocks further shared mutations.

Participant adoption has a separate preflight that rejects a device containing
any local children or transactions. A later product flow must offer an explicit
keep/export/replace decision instead of silently merging independent ledgers.
The sync-engine store may service a preparing household only during the
persisted initial-upload phase, and its retry or terminal errors update the
migration record.

`CloudLedgerSetupRunner` resumes that durable state machine after validating the
iCloud account. Its live transport idempotently creates the owner's private
zone, constructs the dormant sync engine for one explicit initial send, fetches
or creates the zone-wide private `CKShare`, and stops at `readyToActivate`.
Injected tests cover lost responses after zone/share creation, an incomplete
upload, unavailable iCloud, terminal errors, and retryable cleanup. Local sync
state is removed only after remote zone deletion succeeds; children and
transactions are never deleted. No app call site constructs the runner or its
live transport. Activation and ongoing sync remain disconnected.

`CloudLedgerParticipantAdoptionCoordinator` persists a validated zone-wide,
read-write invitation before accepting it. It rejects any existing independent
local ledger. The live transport checks whether CloudKit already accepted the
share, then fetches changes from the beginning of only the invited shared zone.
The coordinator requires exactly one Household record whose UUID matches the
zone name. It merges the complete first snapshot with the local preparing
household in one save; malformed records roll back the batch. An interrupted
acceptance or fetch can be retried from durable invitation state. `LedgerService`
blocks mutations throughout participant adoption until guarded activation
marks it complete. No app call site invokes this coordinator.

`CloudLedgerActivationCoordinator` is the sole dormant path from prepared to
active. It requires completed owner upload/share setup or participant first
import, no deferred participant transactions, a reachable zone-wide share, and
the current iCloud account identity. Activation persists that identity locally
with the shared-ledger phase in one save. Subsequent access checks keep
transiently offline ledgers writable (edits remain queued), but freeze new
mutations without deleting data if the account changes or share access is
revoked. Attention-required state is deliberately not auto-recovered: the
product still needs a clear user decision for a different iCloud account or a
removed invitation. The live transport exists but is not constructed by the
app; these paths are covered only by injected tests, not physical devices.
CloudKit access errors are classified using the installed SDK's codes:
missing zones/shares and managed-account restrictions freeze shared edits,
while transient network/service failures leave the local queue writable.
Nested per-record failures in a `partialFailure` are inspected. A successful
access recheck after an outage changes status to pending, not synced, because
fetch and send have not yet completed. `PHASE6_ACTIVATION_FLOW.md` specifies
the consent and invitation entry points before app wiring.

`CloudLedgerSyncSession` is the dormant entry point for ordinary network work.
It requires an activated household with matching completed owner or participant
setup state, checks the pinned account and share before fetching, fetches the
household zone, checks again before sending any queued data, and only reports
synced after successful work. Transient CloudKit failures persist retry time
and leave local edits writable; missing zones, changed accounts, or terminal
errors freeze new edits without removing the queue. The live transport keeps
`CKSyncEngine.automaticallySync` disabled and is not constructed by the app.

CloudKit can deliver a transaction before its referenced child. Such a record
is stored as a `DeferredCloudTransaction`, survives process relaunch, and is
automatically applied after the child arrives. Undo entries converge by their
original transaction ID. This also canonicalizes undo entries created by older
builds without changing the derived balance.

## Money

Ledger values use `Int64` cents. `MoneyFormatter` converts integer cents to `Decimal` for localized USD display.

`MoneyConversion` accepts USD only, uses `Decimal` arithmetic, requires exact whole cents, rejects zero and unsupported currency, and detects `Int64` overflow. It also parses manual text using the device locale before applying the same exact conversion rules. The arbitrary-amount give and take intents convert a positive requested value before adding a signed positive or negative ledger transaction.

## App Intents

`ChildEntity` is a lightweight, sendable representation of a persisted child. `ChildEntityQuery` resolves identifiers, suggests active children, and delegates case-insensitive string matching to `LedgerService`. Duplicate exact names are returned together so the system can disambiguate rather than silently choosing one.

All ledger intents use iOS 26's background intent mode and open the same local SwiftData store as the app. `GiveMoneyIntent` and `TakeMoneyIntent` accept arbitrary USD amounts; `GetBalanceIntent` is read-only; and `UndoLastTransactionIntent` creates a compensating entry. Each validates persisted entities immediately before use and returns spoken/display dialog.

`GiveCoinIntent` and `TakeCoinIntent` supplement—not replace—the arbitrary currency intents. Their `CoinDenomination` enum gives Siri a finite vocabulary for nickel, dime, quarter, half dollar, and dollar because physical testing showed that `IntentCurrencyAmount` rejected coin nouns before invoking the app.

## Undo

Undo creates a signed compensating transaction and stores the original transaction's UUID in `reversesTransactionID`; it never deletes history. An undo entry is not itself undoable, and an already reversed original is skipped. Repeated undo therefore walks backward through the remaining unreversed original transactions across all children. Tests cover compensation, repetition, global newest-first selection, and an empty ledger.
