# Visual quick-action physical test

Use this checklist for TestFlight build 14 on the owner iPhone first. Build 13's
initial owner checks passed; build 14 adds the follow-up layout, visual undo, and
automatic synchronization. Record starting balances rather than relying on
balances from earlier tests.

## Preconditions

- For the owner-phone visual actions, the owner phone shows TestFlight build
  `0.1 (14)` and **Sharing enabled**. Record each active child's starting
  balance.
- Before the two-phone section, both phones show build `0.1 (14)` and
  **Sharing enabled**. Run **Sync Now** on both phones once to establish a
  matching baseline; do not use it during the automatic-sync checks.
- Do not create or archive a child during this test.

## Owner-phone visual actions

1. Confirm the home screen shows one large card per active child, an **All
   Children** card, a **Give / Take** selector, and six amount buttons per card.
2. Leave **Give** selected. Tap `+$0.05` on one child. Confirm that only that
   child increases by exactly five cents and that one manual transaction appears
   in the child's history.
3. Select **Take**. Tap `−$0.10` on a different child. Confirm that only that
   child decreases by exactly ten cents and that one manual transaction appears.
   Confirm the home-screen **Undo Last** control identifies that child and
   amount. Tap it once and verify the prior balance is restored and an **Undo**
   row appears in history.
4. Open **Quick Amounts** from the sliders button. Remove one amount, add a
   different exact amount such as `$0.75`, and reorder at least one item. Save.
   Confirm the new ordered set appears on every child and All Children, but is
   not duplicated in child detail. Terminate and relaunch Kid Money; confirm
   the preference persists.
5. Confirm **All Children** appears after every individual child. Select
   **Give**, then choose a small amount on **All Children**. The action should
   apply immediately without a confirmation dialog. Every active child must
   increase by the exact amount and receive one transaction labeled **Applied
   to all children**.
6. Select **Take** and apply a small amount to **All Children**. Confirm every
   active child decreases by exactly that amount and receives one matching
   transaction.
7. Open each child's history and verify the newest-first ordering, signed
   amounts, source, note, and balances remain correct.

## Two-phone automatic synchronization

1. Open Kid Money on both phones, then leave the spouse phone on the home
   screen. On the owner phone, make one small individual adjustment. Do **not**
   open Sharing or tap Sync Now. Confirm it reaches the spouse exactly once.
   Record whether it appeared while the spouse app remained open or only after
   backgrounding and reopening it.
2. Reverse the roles: make one small adjustment on the spouse phone without
   using Sync Now. Confirm the owner receives it exactly once. If it does not
   appear promptly, background and reopen the owner app; foreground catch-up
   must deliver it without opening Sharing.
3. Confirm the spouse phone's quick-amount buttons did not change. Quick-amount
   preferences are intentionally per device, not shared ledger data.
4. Make three quick taps on one phone. Confirm all three local transactions are
   preserved, the remote phone receives each exactly once, and the final
   balance matches. The network work may be coalesced; the ledger entries must
   not be.
5. Terminate and relaunch both apps without using Sync Now. Confirm balances
   and history remain unchanged with no duplicates.
6. Use **Sync Now** only as a recovery diagnostic if an automatic step remains
   stuck. Before tapping it, record each phone's Sync status and pending count.

## Report

Report any incorrect amount, partial all-children change, duplicated history,
stuck pending count, preference that fails to persist, or layout that is hard to
use. Screenshots are especially useful for clipping, confusing labels, or tap
targets. Siri is not part of this checkpoint.
