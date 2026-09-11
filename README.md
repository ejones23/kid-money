# Kid Money

Kid Money is a small, local-first iPhone ledger for tracking money owed to children. The primary product goal is a fast Siri interaction such as:

> “Give Rebecca a dime in Kid Money.”

The app is intentionally simple: no backend, accounts, third-party dependencies, or cloud synchronization. A child's balance is derived from an auditable transaction ledger rather than stored as a mutable total.

This is an early-stage public project. The code is available for learning,
adaptation, and contribution under the MIT License, but it should not yet be
treated as a finished personal-finance product.

The project uses internal TestFlight distribution so that its physical-device Siri checkpoint can be tested through an approved channel rather than a locally signed app on a managed phone.

## Current status

Phase 1 is complete, and the Phase 2 Siri proof of concept is ready for physical-device verification:

- SwiftUI application targeting iOS 26+
- SwiftData models for children and signed ledger transactions
- shared `LedgerService` domain logic
- add-child flow
- active-child list with derived USD balances
- minimal manual `+$0.10` transaction action
- `GiveMoneyIntent` with a background execution mode
- case-insensitive App Entity lookup for active children
- exact USD `Decimal` to integer-cents conversion
- App Shortcut discovery phrases and focused intent logging
- unit coverage for ledger behavior, store reopening, child lookup, formatting, and money conversion

The project builds without errors or warnings in Xcode 26.6. All seven current tests pass on the iOS 26.5 iPhone 17 Pro simulator.

TestFlight build `0.1 (3)` routes both advertised phrases successfully on an unmanaged iPhone SE running iOS 26.6.2. Siri collected the missing child and amount, and two ten-cent requests produced the expected `$0.20` balance. The same build still gives an unsupported-capability response on the managed work iPhone, although a Siri-invoked user-created shortcut can run the intent there. The next diagnostic is a clean build 3 installation on the managed phone to distinguish stale upgrade state from device-management policy.

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

The next milestone is the physical-device checkpoint for the deliberately narrow Siri proof of concept:

1. Delete the test app from the managed work iPhone, understanding that this erases its local test ledger, then install TestFlight build `0.1 (3)` fresh.
2. Open it once, add Rebecca, and test “Give money in Kid Money.”
3. Record whether iOS offers the one-time shortcut authorization that appeared on the unmanaged phone.
4. If automatic routing begins working, complete the app-state and lock-state matrix. If it still fails, involve the device administrator before adding diagnostic profiles or changing managed settings.

Apple currently permits at most one intent parameter in each App Shortcut trigger phrase. Kid Money places the child parameter in its phrases and leaves the amount as a required intent parameter. Physical testing will determine how naturally Siri handles the complete utterance.

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
