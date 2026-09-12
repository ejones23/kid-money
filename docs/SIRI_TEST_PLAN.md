# Siri proof-of-concept test plan

Begin after Phase 2 compiles, tests pass, and the app is installed on a physical iPhone.

## Preconditions

- iPhone runs iOS 26 or newer.
- Kid Money launches and its actions appear in Shortcuts.
- Siri and locked-device shortcut access are enabled.
- Rebecca exists with a $0.00 balance.
- Xcode is ready to capture device logs.

## Core success test

1. Terminate or background Kid Money.
2. Say: “Siri, give Rebecca ten cents in Kid Money.”
3. Record whether Siri selects the intent and extracts the amount without clarification. A single amount follow-up is an acceptable intermediate result for this checkpoint and should be documented.
4. Confirm the response reports the adjustment and $0.10 balance.
5. Open the app and confirm Rebecca shows $0.10.
6. Terminate and relaunch; confirm $0.10 remains.
7. Repeat the utterance and confirm $0.20.

Do not proceed to Phase 3 until this path works or the failure is understood.

## Utterance matrix

Record each as one-shot success, parameter clarification, wrong routing, failed resolution, or other failure.

### Give

- “Give Rebecca ten cents in Kid Money.”
- “Give Rebecca a dime in Kid Money.”
- “Add ten cents to Rebecca in Kid Money.”
- “Give Rebecca ten cents.”
- “Give Rebecca a dime.”

### Phase 3 actions

- “Take ten cents from Rebecca in Kid Money.”
- “Take a dime from Rebecca in Kid Money.”
- “Subtract a quarter from Rebecca in Kid Money.”
- “What is Rebecca's balance in Kid Money?”
- “How much money does Rebecca have in Kid Money?”
- “Undo kid money in Kid Money.”

## Phase 3 build 4 matrix

Before updating, record the existing build 3 balance (`$1.05` on the managed work phone at the end of Phase 2). After installing build 4, confirm that the same children, balance, and history remain; this exercises the lightweight SwiftData migration that adds the optional undo link. Then record the balance after every mutating action:

1. “Take money from Rebecca in Kid Money.” Say “ten cents” if prompted. Confirm a `-$0.10` adjustment and spoken new balance.
2. “Check Rebecca balance in Kid Money.” Confirm the spoken value agrees with the app and does not create a transaction.
3. “Undo kid money in Kid Money.” Confirm it reverses the preceding take with a compensating transaction and reports the restored balance.
4. “Give a dime in Kid Money.” Select Rebecca if prompted. Confirm `+$0.10`.
5. “Give Rebecca a dime in Kid Money.” Record whether Siri supplies both parameters or asks a single clarification; confirm `+$0.10`.
6. “Take a quarter in Kid Money.” Select Rebecca if prompted. Confirm `-$0.25`.
7. Terminate the app, invoke Check Balance and one mutating action, then relaunch and confirm persistence.
8. Repeat Undo twice after two different transactions and confirm it walks backward without toggling the prior undo.

Xcode's App Shortcuts Preview resolves representative forms of all six actions, including the combined “Give Rebecca a dime in Kid Money” utterance. That is a development-tool preflight only; record real Siri behavior independently.

## Context variants

Test the core phrase with the app open, backgrounded, and terminated, and with the phone unlocked and locked. Record whether the app foregrounds and whether Siri speaks the result.

## Diagnostics

Capture the exact phrase, Siri transcript and response, clarification, foreground behavior, balance before/after, timestamped OSLog lines, device model, and iOS version.

Test coin names only after arbitrary amounts work. Add a `CoinDenomination` fallback only if physical-device evidence justifies it.

## Recorded results

### TestFlight 0.1 (1) — iPhone 15, iOS 26.6.1

- Installation: managed work iPhone via internal TestFlight; app launched successfully.
- Initial state: Rebecca existed with a `$0.00` balance.
- Context: app in the background and phone unlocked.
- Utterance: “Give Rebecca ten cents in Kid Money.”
- Result: Siri recognized Kid Money but reported that the app had not added support for the request and offered to open the app.
- Ledger result: no transaction was created; Rebecca remained at `$0.00`.
- Follow-up utterance: “Give Rebecca money in Kid Money.”
- Follow-up result: Siri gave the same unsupported-capability response, asked no question, and left the balance at `$0.00`.
- Relaunch diagnostic: after force-quitting and relaunching Kid Money with Rebecca present, the registered phrase produced the same unsupported-capability response and `$0.00` balance.
- Shortcuts discovery: `Give Money` appeared in Apple's Shortcuts app. Tapping it prompted for a child and displayed Rebecca as an option.
- Manual execution: selecting Rebecca ran the intent without collecting an amount, produced “The amount must be greater than zero,” and left the balance at `$0.00`.
- Parameter-free Siri phrase: “Give money in Kid Money” produced the same unsupported-capability response without asking for a child.
- Interpretation: shortcut extraction and import succeeded, so the unsupported Siri responses are a Siri-routing failure. Build 2 explicitly enables the Siri capability, requests a currency amount when Shortcuts supplies its zero-valued placeholder, and refreshes shortcut parameters when a child is added.

### TestFlight 0.1 (2)

- Distribution: uploaded successfully and assigned to the `Internal Testing` group.
- Installation: updated successfully on the managed work iPhone.
- Parameter-free Siri phrase: “Give money in Kid Money” still produced “Kid Money hasn't added support for that with Siri,” created no transaction, and left the balance unchanged.
- Xcode phrase diagnostic: Product → App Shortcuts Preview matched the exact utterance “Give money in Kid Money” to `GiveMoneyIntent`.
- Interpretation: the compiled phrase matches in Apple's development tool, while the installed app's action remains visible and runnable in Shortcuts. The remaining fault is device-side Siri registration/routing or an iOS defect, not phrase syntax or the Siri code-signing entitlement.
- User-created shortcut: a shortcut named “Test Kid Money Ledger” with Rebecca and `$0.10` preset ran successfully when tapped and again when invoked by that exact name through Siri. Rebecca's balance progressed from `$0.00` to `$0.20` through two taps, then to `$0.30` through Siri.
- Interpretation: the intent, data mutation, and Siri-to-Shortcuts execution path all work on the managed phone. The failure is isolated to automatic App Shortcut phrase registration or matching.
- Build 3 diagnostic: add the specifically named `AppShortcuts.xcstrings` catalog recommended by Apple DTS so the advertised phrases are compiled as localized shortcut resources instead of using the build's `--no-app-shortcuts-localization` path.
- Build 3 preflight: Xcode's App Shortcuts Preview matched both shipped phrases—“Give money in Kid Money” and “Give Rebecca money in Kid Money”—to `GiveMoneyIntent`. A third phrase variant that did not match was removed before distribution.

### TestFlight 0.1 (3)

- Distribution: archived successfully with validated localized App Shortcut resources and generated Siri/NLU training assets, then uploaded and assigned to the `Internal Testing` group.
- Managed iPhone verification: both “Give money in Kid Money” and “Give Rebecca money in Kid Money” produced “Kid Money hasn't added support for that with Siri.” Siri asked no follow-up question and created no transaction.
- Unmanaged iPhone verification: on an iPhone SE running iOS 26.6.2, a fresh build 3 installation first asked permission to turn on shortcuts for Kid Money. “Give money in Kid Money” then requested the child and amount; Rebecca and ten cents created `+$0.10`. “Give Rebecca money in Kid Money” offered a Kid Money/Wallet disambiguation, then requested the amount; ten cents created another `+$0.10`, for a `$0.20` balance.
- Later managed-iPhone retry: after updating from iOS 26.6.1 to 26.6.2, and without deleting the app—the prior `$0.30` balance remained—“Give money in Kid Money” routed successfully. Siri offered Kid Money/Wallet disambiguation, requested the amount, accepted twenty cents, and responded “0.20 has been given to Rebecca. Rebecca now has 0.50.” No one-time shortcut authorization prompt appeared.
- Persistence: force-quitting and relaunching preserved the `$0.50` balance.
- Terminated and unlocked: “Give Rebecca money in Kid Money” routed after Kid Money/Wallet disambiguation. The amount prompt rejected “one cent,” repeated attempts at “one penny,” and “five cents” by asking again. “Ten cents” succeeded and raised the balance to `$0.60`.
- Terminated and locked: Siri did not require an unlock. The same sub-ten-cent responses failed, while “ten cents” succeeded and raised the balance to `$0.70`.
- App open and unlocked: at the amount prompt, “a dime” and “one dime” were rejected; “ten cents” succeeded and raised the balance to `$0.80`.
- App backgrounded and unlocked: “a quarter” was rejected; “twenty-five cents” succeeded and raised the balance to `$1.05`.
- Interpretation: automatic App Shortcut routing, background execution, locked-device execution, parameter prompting, spoken confirmation, and persistence work on both phones. The iOS 26.6.2 update preceded the managed phone's recovery, but the evidence does not distinguish an OS fix from a registration refresh caused by the update. Siri's `IntentCurrencyAmount` resolver does not accept the observed sub-ten-cent responses, and the app never receives them.
- Phase 2 result: complete. The context matrix, persistence, automatic routing, parameter clarification, spoken result, and locked-device behavior all passed on physical hardware. Numeric cent phrases at or above ten cents worked in the observed tests, while penny, dime, and quarter wording did not resolve; this justifies a supplemental denomination path in Phase 3 without replacing arbitrary currency amounts.

### TestFlight 0.1 (4) — managed work iPhone, iOS 26.6.2

- Upgrade migration: updating in place preserved Rebecca and her `$1.05` build 3 balance after the optional undo-link field was added to the SwiftData model.
- Take Money: “Take money from Rebecca in Kid Money” routed successfully, removed `$0.10`, and reported the correct `$0.95` balance.
- Check Balance: Siri returned the correct `$0.95` balance without changing it.
- Undo: “Undo kid money in Kid Money” correctly compensated for the preceding ten-cent removal and reported the restored `$1.05` balance.
- Give Coin with denomination only: “Give a dime in Kid Money” asked which child should receive money; selecting Rebecca added `$0.10` and produced `$1.15`.
- Give Coin with child spoken: “Give Rebecca a dime in Kid Money” still asked which child should receive money; selecting Rebecca added `$0.10` and produced `$1.25`. Siri therefore routed the named denomination correctly but did not retain the child from a phrase whose advertised parameter is the denomination.
- Take Coin: “Take a quarter in Kid Money” asked which child; selecting Rebecca removed `$0.25` and produced `$1.00`.
- Terminated balance query: with Kid Money terminated, Siri reported “Rebecca has $1.00” without opening the app.
- Terminated coin mutation: the first “Give a dime in Kid Money” attempt routed to a web result about dimes for children. Repeating with clearer enunciation routed to Kid Money, requested the child, added `$0.10`, and correctly reported Rebecca's new `$1.10` balance.
- Repeated undo: two successive invocations reversed the terminated dime addition and then the preceding quarter removal, producing `$1.00` and `$1.25` as expected.
- Relaunch persistence: terminating and relaunching preserved `$1.25`.
- Exact response transcripts were not captured; repeating these successful cases solely for wording is unnecessary. Functional routing, mutation, read-only querying, spoken balance, and undo correctness are verified.
- Phase 3 result: complete. Every build 4 matrix capability passed on physical hardware. Named-coin routing had one intermittent web-search miss before succeeding on retry, and combined coin phrases still requested the child separately; retain both findings as reliability inputs rather than treating preview matching as a guarantee.
