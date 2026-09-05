# Project: Kid Money — Siri-First Allowance / Kid Ledger App

I want you to build this iOS app with me.

## User / project context

I am an experienced backend software engineer, but I have never personally developed and shipped an iOS app. I am comfortable reading code, debugging, using Git, working from the command line, and following technical instructions.

I use Codex extensively and am comfortable letting you make substantial changes to the project autonomously. Please act as the primary implementation engineer while explaining iOS-specific concepts when they matter.

I have previously used AI to generate iOS application code, but I have never published an app to the App Store.

This is initially a personal app for my family. Do not optimize for App Store publication yet.

## The real-world problem

I keep informal monetary balances for my children.

When a child does a small job, I may say that I owe them:

- a nickel
- a dime
- a quarter
- fifty cents
- a dollar
- some other arbitrary amount

Sometimes I subtract money as well.

Currently I keep a handwritten-style tally in an Apple Notes note. This is cumbersome because I have to:

1. unlock my phone,
2. find the note,
3. find the correct child,
4. mentally perform the arithmetic,
5. edit the balance.

I want the primary interaction to be Siri.

Examples of the experience I want:

- “Siri, give Rebecca a dime.”
- “Siri, give Daniel a nickel.”
- “Siri, give Rebecca fifty cents.”
- “Siri, take a quarter from Daniel.”
- “Siri, how much money does Rebecca have?”
- “Siri, undo that.”

Rebecca and Daniel are examples. Do NOT hard-code child names. The user must be able to create, rename, archive, and manage children in the app.

The app should respond after a successful voice transaction with something like:

“Added ten cents to Rebecca. Rebecca now has four dollars and thirty-five cents.”

The ideal end state is a single spoken utterance with no need to unlock the phone or open the app.

However, Siri's exact natural-language routing behavior is partly controlled by the operating system. Do not assume that an arbitrary phrase without the app name will work. We need to test actual behavior on a physical iPhone.

A command such as:

“Give Rebecca a dime in Kid Money”

is an acceptable first milestone if the shorter:

“Give Rebecca a dime”

cannot reliably route to our app.

## Technical direction

Use modern native Apple technologies.

Preferred stack:

- Swift
- SwiftUI
- SwiftData
- App Intents
- App Shortcuts
- no backend
- no web service
- no authentication
- no third-party dependencies
- no CloudKit/iCloud sync initially

Target a currently supported stable iOS version suitable for the current App Intents APIs. Prefer iOS 26+ unless there is a concrete reason to choose differently.

Use current APIs from the installed Xcode SDK. If an App Intents API signature differs from what you expect, inspect the SDK/compiler documentation rather than inventing a signature.

Do NOT build this using legacy SiriKit unless we discover a specific feature that requires it.

Do not introduce deprecated App Intents/Assistant APIs when a current replacement exists.

## Most important development principle

GET TO A REAL SIRI TEST EARLY.

Do not spend hours polishing UI before proving that Siri can:

1. resolve a child by name,
2. resolve a monetary amount,
3. invoke our intent,
4. persist the transaction,
5. speak the resulting balance.

The first important proof of concept is:

- App contains Rebecca.
- Rebecca has $0.00.
- I say something reasonably close to “Siri, give Rebecca a dime in Kid Money.”
- App receives the intent.
- It records +$0.10.
- Siri tells me Rebecca now has $0.10.

Once that works on my physical iPhone, continue building out the app.

---

# Domain model

Treat this as a ledger, not as a mutable balance field.

## Child

Suggested persisted SwiftData model:

- `id: UUID`
- `name: String`
- `createdAt: Date`
- `sortOrder: Int`
- `isArchived: Bool`

Do not make the monetary balance an independently mutable persisted field.

The balance should be derived from transactions.

## LedgerTransaction

Suggested persisted SwiftData model:

- `id: UUID`
- `child` relationship / child identifier
- `amountCents: Int64`
- `createdAt: Date`
- `note: String?`
- `source`: manual / Siri / other useful enum or persisted string

`amountCents` is SIGNED:

- +10 = added ten cents
- +25 = added quarter
- -25 = removed quarter
- -100 = removed one dollar

### Money representation

Within the ledger, store money in integer cents.

Do NOT use `Double` for balances.

App Intent input can use Apple's current monetary intent type, preferably `IntentCurrencyAmount`, which gives us a Decimal monetary value and a currency code.

Initially support USD only.

Create a well-tested conversion layer:

`IntentCurrencyAmount / Decimal -> Int64 cents`

Requirements:

- exact cent arithmetic
- no floating-point arithmetic
- reject nonsensical or unrepresentable values
- reject zero-dollar adjustments unless there is a compelling UX reason not to
- for GiveMoney, the supplied amount should conceptually be positive
- for TakeMoney, convert the positive requested amount into a negative ledger transaction

Keep currency-handling logic isolated so it could eventually support other currencies.

## Ledger service

Create one central domain/service layer responsible for operations such as:

- fetch children
- find child
- add child
- rename child
- archive child
- add transaction
- calculate balance
- get transactions
- undo last transaction

Both SwiftUI and App Intents must call this same domain logic.

Do not duplicate balance-changing logic in the views and App Intents.

Construct SwiftData persistence in a way that both normal app execution and App Intent execution can safely access the same store.

Keep the design simple. This is a tiny local app.

---

# App Intents design

This is the heart of the project.

## ChildEntity

Expose a child to App Intents using a separate lightweight `AppEntity` representation rather than forcing the SwiftData model itself to serve every App Intents role.

Suggested value:

- `id: UUID`
- `name: String`

Implement the appropriate entity query.

In particular, use `EntityStringQuery` if appropriate so that arbitrary spoken/string names can resolve against the user's children.

Behavior should be case-insensitive and friendly to natural matching.

Examples:

- “Rebecca” -> Rebecca
- “rebecca” -> Rebecca

If two children someday have indistinguishable names, let the system disambiguate rather than silently picking one.

`suggestedEntities()` should return active children.

Archived children should normally not be suggested.

## GiveMoneyIntent

Concept:

`GiveMoneyIntent`

Parameters:

- child: `ChildEntity`
- amount: preferably `IntentCurrencyAmount`

Behavior:

1. resolve child
2. validate amount
3. convert amount to cents
4. create positive transaction
5. save
6. calculate new balance
7. return a spoken/display result

Example result:

“Added ten cents to Rebecca. Rebecca now has $4.35.”

This should run without opening the app if App Intents permits it.

Use the proper current mechanism for background App Intent execution rather than forcing an app launch.

## TakeMoneyIntent

Parameters:

- child
- amount

Behavior is equivalent except the stored transaction is negative.

Example:

“Removed twenty-five cents from Daniel. Daniel now has $2.10.”

## GetBalanceIntent

Parameter:

- child

Result:

“Rebecca has $4.35.”

Do not mutate anything.

## UndoLastTransactionIntent

After the core Siri flow works, implement an undo intent.

Initially global undo of the most recent ledger transaction is sufficient.

It should:

1. identify the most recent transaction,
2. reverse/remove it using a clearly defined strategy,
3. report exactly what it undid,
4. report the resulting balance.

Prefer an auditable approach. If you decide that “undo” should create a compensating transaction rather than delete history, explain the tradeoff and choose the cleaner model for this tiny application.

---

# App Shortcuts / Siri discovery

Create an `AppShortcutsProvider` using current APIs.

Expose the important actions:

- Give Money
- Take Money
- Check Balance
- Undo Last Transaction

Provide good titles, descriptions, parameter labels, display representations, and legitimate App Shortcut phrases.

Do not hard-code individual child names into App Shortcut metadata.

Prefer semantic clarity over cleverness.

Candidate discovery phrases might conceptually resemble:

- “Give money in [App Name]”
- “Add kid money in [App Name]”
- “Take money in [App Name]”
- “Check kid balance in [App Name]”
- “Undo kid money in [App Name]”

Use whatever syntax the current AppShortcuts API actually supports.

Do not assume arbitrary dynamic values can simply be interpolated into App Shortcut phrases. Follow the current API's rules.

## Natural language test matrix

Once installed on my physical iPhone, explicitly test variants such as:

### Give

- “Give Rebecca ten cents in Kid Money.”
- “Give Rebecca a dime in Kid Money.”
- “Add ten cents to Rebecca in Kid Money.”
- “Give Rebecca ten cents.”
- “Give Rebecca a dime.”

### Take

- “Take ten cents from Rebecca in Kid Money.”
- “Take a dime from Rebecca in Kid Money.”
- “Subtract a quarter from Rebecca in Kid Money.”

### Query

- “What is Rebecca's balance in Kid Money?”
- “How much money does Rebecca have in Kid Money?”

Record which formulations:

- execute in one utterance,
- invoke the right intent but require parameter clarification,
- incorrectly route elsewhere,
- fail to resolve “dime,” “nickel,” or “quarter.”

### Coin-name fallback

Do NOT implement this prematurely.

First determine whether Siri resolves words such as:

- nickel
- dime
- quarter
- dollar

naturally into `IntentCurrencyAmount`.

If it does, great.

If it does NOT, then consider adding:

`CoinDenomination: AppEnum`

with cases:

- nickel = 5
- dime = 10
- quarter = 25
- halfDollar = 50
- dollar = 100

and possibly dedicated `GiveCoinIntent` / `TakeCoinIntent` actions.

But arbitrary monetary amounts still need to work, so coin enums should supplement—not replace—the currency amount path.

---

# SwiftUI interface

Keep the interface clean and intentionally small.

## Main screen

Show active children in a list.

Each row should prominently show:

`Rebecca                         $4.35`

`Daniel                          $2.80`

Include an obvious way to add a child.

Tapping a child opens detail/history.

## Child detail screen

Show:

- child's name
- current balance prominently
- transaction history newest-first
- date/time
- signed amount
- optional note/source if useful

Provide manual controls.

Useful quick actions:

- +$0.05
- +$0.10
- +$0.25
- +$1.00
- custom add
- custom subtract

This manual UI is secondary to Siri, but it should make the app independently useful.

## Child management

Support:

- add
- rename
- archive

Avoid destructive deletion of historical ledger data unless we explicitly decide otherwise.

## First launch

If there are no children:

Show a simple explanation:

“Add your children, then use Siri to add or subtract money.”

Provide an Add Child button.

Do not hard-code Rebecca or Daniel as production seed data.

For development/debug builds, a convenient sample-data mechanism is fine.

---

# Formatting

Centralize currency formatting using Apple's appropriate locale-aware currency formatter.

Internally:

`435 cents`

UI:

`$4.35`

Spoken response should be natural.

It is acceptable initially if Siri speaks "$4.35" naturally from returned dialog text. Do not build an elaborate number-to-English system unless necessary.

---

# Error handling

Voice interactions need useful failures.

Examples:

No children:
“Add a child in Kid Money first.”

Unknown child:
Allow App Intents/Siri parameter resolution to request clarification when possible.

Invalid amount:
“I couldn't add that amount.”

Wrong currency:
“Kid Money currently supports US dollars.”

Persistence failure:
Do not claim success if the transaction did not save.

Do not silently create a new child because Siri failed to recognize a name.

---

# Logging / debugging

Siri/App Intent debugging will matter.

Use Apple's normal logging facilities (`Logger` / OSLog) in key areas:

- intent invoked
- child resolution request
- child resolved
- amount received
- amount converted
- transaction persisted
- result returned
- meaningful errors

Do not log unnecessary private data.

During development it is fine to log child names and small ledger values locally if that materially helps debugging, but keep logging sane.

Make it easy for me to send relevant logs/errors back to you.

---

# Tests

The financial/domain logic deserves tests even though the application is small.

At minimum test:

### Money conversion

- $0.05 -> 5
- $0.10 -> 10
- $0.25 -> 25
- $1.00 -> 100
- $1.35 -> 135

No floating-point artifacts.

### Balance

Transactions:

+10
+25
-5

Balance = 30 cents.

### Independent children

Rebecca's transactions must not affect Daniel.

### Undo

Verify whichever undo semantics we select.

### Entity lookup

Case-insensitive lookup and expected ambiguity behavior where feasible.

App Intent behavior itself may require integration/manual testing on a real device.

---

# Development phases

Please work incrementally.

## Phase 1 — Skeleton + persistence

Build:

- SwiftUI app
- SwiftData models
- child list
- add child
- transaction persistence
- balance calculation
- minimal manual +$0.10 action

Confirm it builds.

Do not polish the design.

## Phase 2 — Siri proof of concept

Implement ONLY enough App Intents functionality to prove:

`GiveMoneyIntent(child, amount)`

plus:

- ChildEntity
- query/resolution
- AppShortcutsProvider
- spoken result

Then help me install it on my iPhone and test Siri.

THIS IS THE MOST IMPORTANT CHECKPOINT.

If Siri doesn't behave as expected, diagnose that before building lots of other functionality.

## Phase 3 — Complete voice actions

Add:

- TakeMoneyIntent
- GetBalanceIntent
- UndoLastTransactionIntent

Test natural-language variants.

## Phase 4 — Useful app UI

Add:

- transaction history
- manual arbitrary amounts
- quick coin buttons
- rename/archive child
- better empty states
- modest visual polish

## Phase 5 — Reliability

Add/fix:

- tests
- error cases
- logging
- edge cases
- concurrency/persistence issues
- Siri routing discoveries from real-device testing

## Explicitly defer

Do NOT build these unless I later ask:

- CloudKit
- iCloud synchronization
- accounts/login
- family sharing
- backend/API
- Android
- subscriptions
- payments
- debit cards
- allowance schedules
- notifications
- gamification
- App Store screenshots/marketing
- analytics
- ads
- elaborate architecture
- third-party packages

---

# Architecture philosophy

This is a very small application.

Do not create enterprise architecture.

I do want:

- clear separation of persistence/domain logic from UI
- reusable ledger operations
- testability
- understandable Swift
- good handling of App Intents

I do NOT want:

- unnecessary repository/service/protocol layers merely for architectural purity
- dependency injection frameworks
- networking abstractions without networking
- massive view-model hierarchies
- premature generic abstractions

Prefer straightforward idiomatic modern Swift.

---

# Important uncertainty: Siri

Do not tell me a Siri formulation is guaranteed merely because the code compiles.

There are several separate questions:

1. Is the App Intent registered?
2. Does Siri discover it?
3. Does Siri route the utterance to our app?
4. Does it extract the child correctly?
5. Does it extract “ten cents” correctly?
6. Does it understand “dime” as ten cents?
7. Does it require the app name?
8. Can it execute while the phone is locked?
9. Does it execute without bringing the app to the foreground?
10. Does Siri speak our result properly?

Treat those as empirical questions.

We will test them on my physical iPhone.

When we reach that stage, give me exact instructions for:

- signing/installing the app
- any capabilities/settings that must be enabled
- making App Shortcuts discoverable
- checking that the shortcuts appear
- invoking them through Siri
- capturing useful diagnostic information

---

# Source-of-truth rule

If you are uncertain about a current Apple API:

1. inspect the installed SDK/API documentation,
2. use compiler feedback,
3. consult current official Apple documentation if web access is available,
4. avoid blindly copying old Stack Overflow or legacy SiriKit examples.

In particular, Apple's App Intents APIs have evolved, so avoid deprecated Assistant/App Shortcut approaches when the current SDK provides replacements.

---

# Definition of v0.1 success

The app is successful when:

1. I can create Rebecca in the app.
2. Rebecca starts at $0.00.
3. From Siri, without manually opening the app, I can invoke an utterance reasonably close to:
   “Give Rebecca a dime in Kid Money.”
4. The app persists +10 cents.
5. Siri reports the new balance.
6. Opening the app shows Rebecca at $0.10.
7. Repeating the command makes it $0.20.
8. The data survives app termination/relaunch.

We should discover whether the even nicer phrase:

“Give Rebecca a dime.”

works reliably, but do not make v0.1 depend on that OS-level routing behavior.

---

# Start now

First:

1. Inspect the current repository/workspace.
2. If no Xcode project exists, help me create the smallest appropriate iOS SwiftUI project or create what you safely can from the available environment.
3. Tell me briefly what Xcode/iOS deployment target you are selecting and why.
4. Implement Phase 1.
5. Build and resolve compiler errors.
6. Then implement the minimal Phase 2 Siri proof of concept.
7. Stop at the point where physical-device Siri testing is the next useful action, and give me precise steps to perform that test.

Do not ask me to make product decisions that are already answered by this specification. Make sensible implementation decisions yourself and explain only decisions that materially affect behavior or future work.