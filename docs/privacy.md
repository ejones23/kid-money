---
layout: default
title: Kid Money Privacy Policy
---

# Kid Money privacy policy

Effective September 26, 2026

Kid Money is designed to keep its ledger data on the user's device. The developer does not operate a Kid Money server and does not receive the names, balances, or transaction history entered into the app.

Kid Money has:

- no user accounts;
- no advertising;
- no analytics or tracking SDKs;
- no third-party analytics or advertising integrations.

The app stores child names and ledger transactions locally so that it can calculate and display balances. This information is entered and controlled by the device owner. The operating system may include application data in device backups according to the user's Apple backup settings.

An optional family-sharing connection test uses the user's private iCloud
CloudKit storage. It stores one disposable counter, an update timestamp, and an
owner-or-participant role value in a private share sent only to people the owner
invites. TestFlight build 9 contains this counter-only test and does not upload
the local ledger.

A future TestFlight build will offer an optional **Share Family Ledger** action.
Only after the ledger owner explicitly confirms, Kid Money will copy the
household name, child names, transaction amounts and dates, optional notes,
and related ledger identifiers to a custom zone in the owner's private iCloud
CloudKit database. Balances remain derived from transactions. The owner may
invite another adult with read-write access through Apple's private sharing
sheet. That adult uses their own iCloud Apple Account; Kid Money does not
collect Apple Account passwords. Apple operates iCloud, and the developer does
not receive the family's records through a developer-operated server.

Each participating phone keeps a local copy so the ledger works offline.
In the first sharing test build, the parent starts synchronization with **Sync
Now**; automatic background synchronization is not yet enabled. If access is
revoked or the iCloud account changes, Kid Money
pauses new shared edits and retains the existing local copy and unsent changes
until the user decides how to recover them.

When the user invokes Kid Money through Siri, Apple may process the spoken request under Apple's Siri and privacy terms. Kid Money receives the intent values provided by the operating system and stores the resulting ledger transaction locally. The developer does not receive Siri recordings or intent values.

Deleting Kid Money from a device deletes its local application data on that
device. It does not automatically delete the owner's private CloudKit zone or
revoke an invitation; the owner can manage participants through Apple's sharing
sheet. The owner should remove the iCloud share separately when it is no longer
needed.

For privacy questions, use the contact options on the [Kid Money support page](support.md).
