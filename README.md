# Kid Money

Kid Money is a small, local-first iPhone ledger for tracking money owed to children. The primary product goal is a fast Siri interaction such as:

> “Give Rebecca a dime in Kid Money.”

The app is intentionally simple: no backend, accounts, third-party dependencies, or cloud synchronization. A child's balance is derived from an auditable transaction ledger rather than stored as a mutable total.

This is an early-stage public project. The code is available for learning,
adaptation, and contribution under the MIT License, but it should not yet be
treated as a finished personal-finance product.

The project uses internal TestFlight distribution so that its physical-device Siri checkpoint can be tested through an approved channel rather than a locally signed app on a managed phone.

## Current status

Phases 1 through 3 are complete:

- SwiftUI application targeting iOS 26+
- SwiftData models for children and signed ledger transactions
- shared `LedgerService` domain logic
- add-child flow
- active-child list with derived USD balances
- minimal manual `+$0.10` transaction action
- `GiveMoneyIntent` with a background execution mode
- `TakeMoneyIntent`, `GetBalanceIntent`, and auditable `UndoLastTransactionIntent`
- supplemental named-coin give/take intents for nickel, dime, quarter, half dollar, and dollar
- a combined child-and-common-amount Siri vocabulary for one-shot give/take requests
- case-insensitive App Entity lookup for active children
- exact USD `Decimal` to integer-cents conversion
- App Shortcut discovery phrases and focused intent logging
- unit coverage for ledger behavior, store reopening, child lookup, formatting, money conversion, and repeated undo

The project builds without errors or warnings in Xcode 26.6. All 12 current tests pass on the iOS 26.5 iPhone 17 Pro simulator. Xcode's App Shortcuts Preview resolves the Phase 3 take, balance, undo, dime, and quarter phrases to their intended actions.

TestFlight build `0.1 (3)` completed the Phase 2 physical-device checkpoint on both an unmanaged iPhone SE and the managed work iPhone after both reached iOS 26.6.2. Siri collects missing parameters, persists exact cent values, reports the resulting balance, and works with the app open, backgrounded, terminated, and while the work phone is locked. Device testing also showed that Siri accepts numeric phrases such as “ten cents” and “twenty-five cents” but rejects coin wording such as “a dime” and “a quarter,” justifying a supplemental denomination path in Phase 3.

TestFlight build `0.1 (4)` completed Phase 3 on the managed work phone. It preserved the existing ledger during migration and verified take, balance, auditable undo, named dime and quarter actions, terminated execution, repeated undo, and relaunch persistence. Coin phrases still request the child separately, and one dime attempt intermittently routed to a web result before succeeding on retry.

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

Before Phase 4, TestFlight build `0.1 (5)`, now available to the internal testing group, will test a focused Siri-routing improvement. Apple permits only one intent parameter in an App Shortcut phrase, so the build presents each active child paired with a common amount as one dynamic App Entity. This is intended to support one-shot forms such as “Give Rebecca ten cents in Kid Money” and “Take twenty cents from Rebecca in Kid Money.” Supported preset amounts are one, five, ten, twenty, twenty-five, and fifty cents, plus one dollar, including common US coin synonyms. Arbitrary amounts remain available through the existing follow-up flow.

After that device experiment, the next feature milestone is Phase 4's useful manual interface:

1. Show transaction history and add quick coin buttons.
2. Support arbitrary manual additions and subtractions.
3. Add rename and archive-child flows.
4. Improve empty, error, accessibility, and visual states without expanding the architecture unnecessarily.

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
