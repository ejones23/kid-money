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

### Later Phase 3 actions

- “Take ten cents from Rebecca in Kid Money.”
- “Take a dime from Rebecca in Kid Money.”
- “Subtract a quarter from Rebecca in Kid Money.”
- “What is Rebecca's balance in Kid Money?”
- “How much money does Rebecca have in Kid Money?”

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
- Verification status: awaiting installation and physical-device Siri retest.
