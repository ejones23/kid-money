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

Phase 1 is complete. The Phase 2 `GiveMoneyIntent` proof of concept is implemented and ready for physical-device verification. The app builds in Xcode 26.6, Xcode's Issue Navigator is clean, and all seven tests pass on an iOS 26.5 simulator. Siri routing has not been verified. Direct installation was blocked by policy on the owner's managed work phone, so a minimal TestFlight/App Store preparation track is active by explicit request.

Latest verified capabilities:

- create a child
- persist a signed manual transaction
- derive each child's balance from transactions
- show active children and balances
- manually add ten cents from child detail
- resolve active children case-insensitively for App Intents
- convert positive USD amounts to exact integer cents
- run `GiveMoneyIntent` in the background and return spoken dialog

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

Prepare and distribute a minimal TestFlight build, then exercise the Phase 2 physical-device matrix in `docs/SIRI_TEST_PLAN.md` and record the results. Do not implement the remaining intents until the Siri checkpoint has been exercised and its behavior is understood. Follow `docs/APP_STORE_RELEASE.md` for distribution work.
