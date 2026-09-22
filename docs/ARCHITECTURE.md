# Architecture

## Overview

Kid Money's ledger is currently local-first. SwiftUI and App Intents share a
SwiftData store and a small domain service. An isolated CloudKit connection
probe exists for Phase 6 validation, but it does not read or synchronize the
ledger.

```text
SwiftUI views ──────┐
                   ├── LedgerService ── SwiftData ModelContext ── local store
App Intents ───────┘
```

## Domain model

### Child

- stable UUID, name, creation date, sort order, and archive flag
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

After that physical checkpoint passes, SwiftData will remain the local working
store and `LedgerService` will remain the mutation boundary. A direct CloudKit
layer will synchronize deterministic records through one private, zone-wide
`CKShare`; it will not use SwiftData's automatic CloudKit mode or an additional
Core Data container. See `FAMILY_SHARING_DESIGN.md` for the approved queue,
conflict, authentication, and migration rules.

## Money

Ledger values use `Int64` cents. `MoneyFormatter` converts integer cents to `Decimal` for localized USD display.

`MoneyConversion` accepts USD only, uses `Decimal` arithmetic, requires exact whole cents, rejects zero and unsupported currency, and detects `Int64` overflow. It also parses manual text using the device locale before applying the same exact conversion rules. The arbitrary-amount give and take intents convert a positive requested value before adding a signed positive or negative ledger transaction.

## App Intents

`ChildEntity` is a lightweight, sendable representation of a persisted child. `ChildEntityQuery` resolves identifiers, suggests active children, and delegates case-insensitive string matching to `LedgerService`. Duplicate exact names are returned together so the system can disambiguate rather than silently choosing one.

All ledger intents use iOS 26's background intent mode and open the same local SwiftData store as the app. `GiveMoneyIntent` and `TakeMoneyIntent` accept arbitrary USD amounts; `GetBalanceIntent` is read-only; and `UndoLastTransactionIntent` creates a compensating entry. Each validates persisted entities immediately before use and returns spoken/display dialog.

`GiveCoinIntent` and `TakeCoinIntent` supplement—not replace—the arbitrary currency intents. Their `CoinDenomination` enum gives Siri a finite vocabulary for nickel, dime, quarter, half dollar, and dollar because physical testing showed that `IntentCurrencyAmount` rejected coin nouns before invoking the app.

## Undo

Undo creates a signed compensating transaction and stores the original transaction's UUID in `reversesTransactionID`; it never deletes history. An undo entry is not itself undoable, and an already reversed original is skipped. Repeated undo therefore walks backward through the remaining unreversed original transactions across all children. Tests cover compensation, repetition, global newest-first selection, and an empty ledger.
