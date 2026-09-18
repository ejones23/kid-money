# Agent guide

This file is the working contract for coding agents operating in this repository.

## Mission

Build a Siri-first, local iPhone ledger that lets a parent add, subtract, query, and undo money assigned to children. The crucial product test is a real Siri invocation on a physical iPhone; do not confuse a compiling App Intent with successful Siri routing.

Read these before substantial work:

1. `codex_build_brief_kid_money_ios_app.md` — complete product brief and constraints.
2. `README.md` — concise state and onboarding guide.
3. `docs/ARCHITECTURE.md` — current domain boundaries.
4. `docs/ROADMAP.md` — phase ordering and definition of the next checkpoint.
5. `docs/SIRI_TEST_PLAN.md` — device validation protocol.

## Current state

Phases 1 through 3 are complete. TestFlight build `0.1 (4)` passed upgrade migration, Take Money, Get Balance, auditable Undo, supplemental dime/quarter actions, terminated execution, repeated undo, and relaunch persistence on the managed work phone. TestFlight build `0.1 (5)` physically verified its combined child-and-amount entity for one-shot numeric additions and subtraction, including locked-screen execution. The stable grammar is “Give/Take [child] [numeric amount] in Kid Money.” Coin words are no longer required. Build 6 expands the preset vocabulary to every five-cent increment through one dollar; physical verification is pending. The app builds in Xcode 26.6, Xcode's Issue Navigator is clean, and all 13 tests pass on an iOS 26.5 simulator.

Latest verified capabilities:

- create a child
- persist a signed manual transaction
- derive each child's balance from transactions
- show active children and balances
- manually add ten cents from child detail
- resolve active children case-insensitively for App Intents
- convert positive USD amounts to exact integer cents
- run `GiveMoneyIntent` in the background and return spoken dialog
- take arbitrary USD amounts and report balances through App Intents
- undo via auditable compensating transactions
- give or take named US coin denominations through a supplemental App Enum path
- resolve child-and-numeric-amount combinations through a dynamic App Entity for one-shot give and take phrases

## Non-negotiable rules

- Use Swift, SwiftUI, SwiftData, App Intents, and App Shortcuts.
- Target iOS 26+ unless a concrete SDK constraint requires reconsideration.
- Use integer cents (`Int64`) inside the ledger. Never use `Double` for money.
- Keep the ledger transaction history as the source of truth for balances.
- Route all mutations through `LedgerService`; do not duplicate balance logic in views or intents.
- Keep USD conversion isolated and exact. Reject zero, unsupported currency, fractional cents, and overflow.
- Do not hard-code child names or silently create a child after failed voice recognition.
- Prefer current installed-SDK APIs. Inspect compiler/SDK documentation instead of copying obsolete SiriKit examples.
- Preserve the phase order. Get to a real Siri test before building the rest of the UI.
- Do not introduce third-party dependencies, a backend, accounts, CloudKit, schedules, or notifications without an explicit request. Minimal App Store/TestFlight work is authorized to reach the physical Siri checkpoint.
- Never commit real family ledger data, credentials, signing material, personal development-team identifiers, or device logs containing personal information.

## Verification expectations

Before committing implementation changes:

1. Build the `KidMoney` scheme for an installed iPhone simulator.
2. Run the relevant tests, preferably all tests for domain changes.
3. Inspect Xcode warnings as well as compiler errors.
4. Run `git diff --check`.
5. State what was and was not verified—especially for Siri behavior.

If Xcode MCP is available, prefer its project-aware build, test, Issue Navigator, preview, and Apple documentation tools. The local MCP server is configured as:

```zsh
codex mcp add xcode -- xcrun mcpbridge
```

Xcode must be open with this project loaded, and **Xcode → Settings → Intelligence → Allow external agents to use Xcode tools** must be enabled.

## Working style

- Make focused, reviewable commits on `main` for this personal project unless branching is requested.
- Keep explanations useful to an experienced backend engineer who is new to iOS.
- Prefer direct, idiomatic Swift over extra protocols, repositories, dependency-injection frameworks, or view-model layers.
- Update relevant documentation when a phase completes or a physical-device discovery changes assumptions.
- Never claim that a Siri phrase, locked-device behavior, or background execution works until it is observed on the user's iPhone.

## Immediate next task

Archive and upload TestFlight build `0.1 (6)`, add it to internal testing, and execute the short locked-screen five-cent increment matrix in `docs/SIRI_TEST_PLAN.md`. If it passes, record completion and resume Phase 4.
