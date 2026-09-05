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

Amounts are signed: `+10` adds ten cents and `-25` removes a quarter. The balance is always the sum of a child's transactions.

## Service boundary

`LedgerService` owns domain mutations and queries. SwiftUI currently uses it to add children, add transactions, fetch history, and calculate balances. App Intents must reuse the same operations.

The service is `@MainActor` because its `ModelContext` is main-actor-bound in the current small application. Revisit context ownership only if App Intent execution demonstrates a concrete concurrency need.

## Persistence

`AppModelContainer` creates the shared `ModelContainer` for production and an in-memory container for tests. The app entry point constructs the production container once and installs it into the SwiftUI environment.

Phase 2 must confirm that background App Intent execution opens the same store safely. Do not create a separate intent-only database.

## Money

Ledger values use `Int64` cents. `MoneyFormatter` converts integer cents to `Decimal` for localized USD display.

`MoneyConversion` accepts USD only, uses `Decimal` arithmetic, requires exact whole cents, rejects zero and unsupported currency, and detects `Int64` overflow. `GiveMoneyIntent` converts the positive requested value before adding a signed ledger transaction.

## App Intents

`ChildEntity` is a lightweight, sendable representation of a persisted child. `ChildEntityQuery` resolves identifiers, suggests active children, and delegates case-insensitive string matching to `LedgerService`. Duplicate exact names are returned together so the system can disambiguate rather than silently choosing one.

`GiveMoneyIntent` uses iOS 26's background intent mode and opens the same local SwiftData store as the app. It validates the child and amount again immediately before persistence, records a `.siri` transaction, and returns a spoken/display dialog with the new balance.

## Undo direction

The preferred design is a compensating transaction rather than deletion. That retains an auditable history and makes the action explicit. The final choice should be implemented and documented during Phase 3, with tests for repeated undo behavior.
