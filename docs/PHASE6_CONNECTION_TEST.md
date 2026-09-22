# Phase 6 family-sharing connection test

Status: **Build 9 active in internal and family TestFlight groups; physical two-account verification pending**

TestFlight build `0.1 (8)` contains an isolated CloudKit probe. It shares only
an integer counter, a timestamp, and whether the last writer was the owner or
participant. It does **not** upload child names, balances, notes, or ledger
transactions. The existing local ledger continues to work exactly as before.

The matching counter-only schema has been deployed to CloudKit production, and
the system-generated `cloudkit.share` type has been deployed to Production.
Build 9 adds safe recovery for an incomplete build 8 setup attempt and is
available in both the `Internal Testing` and external `Family Test` groups.

The first production attempt established the custom zone but failed before the
counter and share saved because Production did not yet contain
`cloudkit.share`. Build 8 had already persisted the zone identifier locally, so
it subsequently reported `Record not found`. Build 9 detects the exact owner
state where both the probe record and share are absent, clears only that
disposable local pointer, and presents **Create Connection Test** again. It does
not clear children, transactions, balances, or any other ledger state.

This checkpoint answers one question before the real sync layer is built: can
the managed work phone and a second parent's Apple Account accept a private
CloudKit share and both write to it?

## Prerequisites

- Install TestFlight build 9 on the owner phone and the same or newer approved
  build on the participant phone.
- Each phone must be signed into iCloud with a different Apple Account.
- Keep iCloud Drive enabled if the device permits it.
- Run the steps sequentially so that this connection test does not intentionally
  create a write conflict.

The App Store/TestFlight Apple Account and the device's iCloud Apple Account do
not have to be the same account.

## Owner phone

1. Open Kid Money and tap the two-person button at the upper left.
2. Confirm **Account** says `iCloud is available`.
3. If an upgrade-recovery alert appears, dismiss it and confirm the screen now
   offers **Create Connection Test**.
4. Tap **Create Connection Test**.
5. In Apple's sharing sheet, invite the other parent's Apple Account with
   private, read-write access. Messages or Mail are both acceptable.
6. After sending the invitation, note the displayed shared-counter value.

Do not enter or change any ledger data as part of this test.

## Participant phone

1. Install and open Kid Money once.
2. Open the invitation while signed into the invited iCloud Apple Account.
3. Accept the share and return to Kid Money.
4. Tap the two-person button. Confirm the screen says **Connected as
   Participant** and shows the same counter as the owner phone.

Record any device-management message verbatim. A restriction here is a product
finding, not a reason to change the phone's security settings.

## Two-way write matrix

1. On the owner phone, tap **Increment Shared Counter** once.
2. On the participant phone, tap **Refresh from iCloud** and confirm the value
   increased by one.
3. On the participant phone, tap **Increment Shared Counter** once.
4. On the owner phone, tap **Refresh from iCloud** and confirm the value
   increased by one again.
5. Terminate and relaunch Kid Money on both phones. Confirm both still show the
   same counter after refreshing.

## Pass criteria

- Both phones report that iCloud is available.
- The participant accepts the private invitation.
- Each phone observes a write made by the other phone.
- The shared connection survives termination and relaunch.
- The existing local child and balance data remains unchanged on each phone.

Do not begin real-ledger migration merely because the app builds or the owner
can create a share. Both directions must be observed on the two physical phones.

## After the test

Leave the test share in place until the result is recorded. It contains no real
ledger data. The production Phase 6 implementation will replace the probe with
the durable household model, offline queue, merge rules, and explicit migration
flow described in [FAMILY_SHARING_DESIGN.md](FAMILY_SHARING_DESIGN.md).
