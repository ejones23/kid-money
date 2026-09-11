# Architecture

## Overview

Kid Money is a single-process, local iOS application. SwiftUI and App Intents share a SwiftData store and a small domain service. There is deliberately no networking or remote identity layer.

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

`LedgerService` owns domain mutations and queries. SwiftUI currently uses it to add children, add transactions, fetch history, and calculate balances. App Intents must reuse the same operations.

The service is `@MainActor` because its `ModelContext` is main-actor-bound in the current small application. Revisit context ownership only if App Intent execution demonstrates a concrete concurrency need.

## Persistence

`AppModelContainer` creates the shared `ModelContainer` for production and an in-memory container for tests. The app entry point constructs the production container once and installs it into the SwiftUI environment.

Physical Phase 2 testing confirmed that background App Intent execution opens the same store safely and that values survive termination and relaunch. Do not create a separate intent-only database.

## Money

Ledger values use `Int64` cents. `MoneyFormatter` converts integer cents to `Decimal` for localized USD display.

`MoneyConversion` accepts USD only, uses `Decimal` arithmetic, requires exact whole cents, rejects zero and unsupported currency, and detects `Int64` overflow. The arbitrary-amount give and take intents convert a positive requested value before adding a signed positive or negative ledger transaction.

## App Intents

`ChildEntity` is a lightweight, sendable representation of a persisted child. `ChildEntityQuery` resolves identifiers, suggests active children, and delegates case-insensitive string matching to `LedgerService`. Duplicate exact names are returned together so the system can disambiguate rather than silently choosing one.

All ledger intents use iOS 26's background intent mode and open the same local SwiftData store as the app. `GiveMoneyIntent` and `TakeMoneyIntent` accept arbitrary USD amounts; `GetBalanceIntent` is read-only; and `UndoLastTransactionIntent` creates a compensating entry. Each validates persisted entities immediately before use and returns spoken/display dialog.

`GiveCoinIntent` and `TakeCoinIntent` supplement—not replace—the arbitrary currency intents. Their `CoinDenomination` enum gives Siri a finite vocabulary for nickel, dime, quarter, half dollar, and dollar because physical testing showed that `IntentCurrencyAmount` rejected coin nouns before invoking the app.

## Undo

Undo creates a signed compensating transaction and stores the original transaction's UUID in `reversesTransactionID`; it never deletes history. An undo entry is not itself undoable, and an already reversed original is skipped. Repeated undo therefore walks backward through the remaining unreversed original transactions across all children. Tests cover compensation, repetition, global newest-first selection, and an empty ledger.
