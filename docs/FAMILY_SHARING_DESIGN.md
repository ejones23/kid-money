# Family sharing design proposal

Status: **Approved; connection prototype and local sync foundation implemented**

This document records the approved design for letting two parents use their own
Apple Accounts and devices to manage one Kid Money ledger. Implementation begins
with an isolated two-account connection test before any real ledger data is
uploaded.

## Goals

- One household ledger is shared privately with invited family members.
- Each adult uses their own Apple Account; Kid Money never handles a password.
- Both adults can add, take, query, rename, archive, and undo.
- Manual and Siri changes work immediately while offline and synchronize later.
- The transaction ledger remains the source of truth for every balance.
- Existing on-device data is preserved when the owner enables sharing.

The first release supports one household ledger, one owner, and invited
read-write participants. It does not provide public links, web access, Android,
or application-managed accounts.

## Why direct CloudKit

SwiftData's automatic CloudKit integration synchronizes a private store across
one person's devices. It does not currently expose CloudKit's user-to-user
`CKShare` collaboration APIs. Apple also cautions against placing a second
`NSPersistentCloudKitContainer` sharing stack beside SwiftData's hidden one.

Kid Money's shared model is small, so the proposed architecture is:

```text
SwiftUI views ──────┐
                   ├── LedgerService ── SwiftData local replica
App Intents ───────┘                         │
                                            ├── durable pending-change queue
                                            │
                                      CloudSyncService
                                            │
                              CKSyncEngine + CKShare
                                            │
                              private/shared CloudKit DB
```

SwiftData remains the device-local working store and is explicitly configured
with `cloudKitDatabase: .none`. A small CloudKit layer maps records to and from
that store. This avoids two frameworks trying to synchronize the same data and
keeps SwiftUI and App Intents on their existing local, fast path.

## Cloud data model

Each household gets one custom CloudKit record zone. The owner stores that zone
in their private database and shares the entire zone with a private `CKShare`.
An invited parent sees the same zone through their shared database.

The zone contains three record types:

- `Household`: stable identifier, display name, creation date, and schema
  version.
- `Child`: the existing stable identifier, name, creation date, sort order,
  archive state, and last-edit metadata.
- `LedgerTransaction`: the existing stable identifier, child identifier,
  signed `Int64` cents, creation date, note, source, and optional identifier of
  the transaction it reverses.

All records use deterministic record names derived from stable domain IDs, so a
retry cannot create a second copy. Transactions remain append-only. Renames and
archive changes are mutable child metadata; no history is deleted.

## Local-first persistence and synchronization

`LedgerService` remains the only mutation boundary. A mutation saves the local
model and a pending CloudKit change together, then returns immediately to the
UI or App Intent. This means Siri can still complete while the phone is offline.

A dedicated sync service uses `CKSyncEngine` to send queued changes and fetch
remote changes. The owner synchronizes the household zone through the private
database; an invited parent synchronizes it through the shared database. Each
database scope has its own persisted engine state. The app also stores the
CloudKit system fields needed for optimistic updates. Incoming records are
merged into SwiftData, after which balances are recalculated from the complete
local transaction set.

The app should expose a small, honest status vocabulary: synced, changes
pending, offline, iCloud unavailable, and attention required. Ordinary transient
network failures retry automatically and never discard a local transaction.

### Conflict rules

- Transactions from both parents merge because they are immutable records with
  distinct stable IDs.
- Retrying the same operation is idempotent because it has the same record ID.
- An undo remains a compensating transaction. Its cloud identity is derived
  from the original transaction so two parents cannot both reverse the same
  item and subtract it twice.
- Concurrent child renames or archive changes use a documented deterministic
  last-write-wins rule. A save conflict is fetched and resolved rather than
  blindly overwriting the server record.
- "Undo last" means the latest eligible transaction known to that device at
  invocation time. Pending remote changes may arrive later; the referenced
  transaction ID still makes the result auditable and prevents double undo.

## Authentication and invitations

There is no Kid Money login and no Sign in with Apple screen. CloudKit uses the
iCloud Apple Account already signed into each device:

1. The current ledger owner chooses **Share Family Ledger**.
2. Kid Money checks `CKContainer.accountStatus`, creates the private share, and
   opens Apple's standard sharing UI.
3. The owner invites their spouse with read-write permission.
4. The spouse installs Kid Money while signed into their own iCloud account,
   opens the private invitation, and accepts it.
5. CloudKit authorizes that Apple Account to the shared zone. Kid Money stores
   no Apple Account password, authentication token, or contact information.

The owner can review participants or revoke access through the system sharing
UI. Public-link access stays disabled. If a participant loses access, signs out
of iCloud, or has CloudKit disabled by device management, Kid Money must stop
shared mutations and prevent stale cached data from masquerading as a current
ledger.

The managed work phone needs a specific early test: its organization may allow
TestFlight while restricting iCloud Drive, CloudKit, or share invitations.
Family sharing should not be considered viable on that phone until invite
acceptance and two-way synchronization succeed there.

## Existing-data migration

Enabling sharing is an explicit, reversible setup operation:

1. Keep the existing SwiftData ledger untouched as the source snapshot.
2. Check iCloud account availability and create the household zone.
3. Upload the household, children, and transaction history with deterministic
   IDs.
4. Create the private share only after the initial upload succeeds.
5. Mark the local household cloud-backed and begin normal synchronization.

An interrupted upload is safe to retry. The app must not delete local data on a
failed migration. Accepting an invitation on a device that already contains a
different local ledger must not silently merge the two; the user must choose
which ledger to keep, with export or backup offered before replacement.

## Privacy and operating cost

The shared ledger uses the owner's private CloudKit database and the invited
participant's shared database, never CloudKit's public database. Apple enforces
the `CKShare` participant permissions. The developer does not operate a server
or receive the family's records through an application backend.

This design adds no separate hosted-service subscription for the developer;
CloudKit is part of the existing Apple developer and iCloud ecosystem. Shared
records count against the originating owner's iCloud storage quota. The privacy
policy and App Store privacy answers must be updated before a build containing
cloud synchronization is distributed.

## Delivery plan

1. Finish the narrow Phase 5 reliability work that protects the ledger service,
   but avoid further local-only persistence assumptions.
2. Add sync invariants and migration tests before enabling CloudKit.
3. Build a disposable two-account prototype for zone creation, invitation,
   acceptance, and two-way counter sync. **Complete in builds 8–9. The full
   two-account physical matrix, including relaunch persistence and unchanged
   local ledgers, passed on September 24, 2026.**
4. Add the durable queue, merge rules, sync status, and existing-ledger upload.
   **In progress: deterministic mappings, durable local queues, strict remote
   decoding, atomic merge, out-of-order deferral, undo convergence, persisted
   queue state, account gating, retry/backoff, and optimistic-conflict policy are
   complete and tested. A concrete CKSyncEngine delegate now provides scoped
   send/fetch handling, system-field persistence, and engine-state restoration,
   but is not instantiated by the app. Status UI, migration, remote-notification
   capability, and live activation remain disabled.**
5. Verify manual and Siri mutations on both adults' devices, including app
   termination and offline/reconnect behavior.
6. Test concurrent additions, same-transaction undo, rename/archive conflicts,
   iCloud sign-out, invite revocation, device replacement, and failed migration.
7. Update privacy disclosures, promote the CloudKit production schema, and ship
   through TestFlight before any App Store release.

## Approved implementation assumptions

The proposal assumes:

- the current device's ledger owner creates the household;
- the spouse receives full read-write access;
- one shared household is enough for the first version; and
- iCloud is an acceptable requirement for shared mode, while local-only mode
  remains available for people who do not enable it.

The owner confirmed these assumptions on September 19, 2026.

## Connection-test boundary

The first Phase 6 build uses a separate custom zone containing one disposable
`FamilySharingProbe` record and its zone-wide share. The record holds only a
counter, timestamp, and last-writer role. It does not read from or upload the
SwiftData ledger. See [PHASE6_CONNECTION_TEST.md](PHASE6_CONNECTION_TEST.md)
for the two-device validation procedure.

## Apple references

- [Syncing model data across a person's devices](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
- [CKShare](https://developer.apple.com/documentation/cloudkit/ckshare)
- [CKSyncEngine](https://developer.apple.com/documentation/cloudkit/cksyncengine-4b4w9)
- [Deciding whether CloudKit is right for your app](https://developer.apple.com/documentation/cloudkit/deciding-whether-cloudkit-is-right-for-your-app)
- [Apple DTS: CKShare-style user-to-user sharing support in SwiftData](https://developer.apple.com/forums/thread/825496)
