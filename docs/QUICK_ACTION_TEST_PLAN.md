# Visual quick-action physical test

Use this checklist for TestFlight build 13 on the owner iPhone first. Run the
sync portion on the spouse iPhone after the owner-side behavior passes. Record
the starting balances rather than relying on balances from earlier voice tests.

## Preconditions

- Both phones show TestFlight build `0.1 (13)`.
- The shared ledger reports **Sharing enabled** on both phones.
- Run **Sync Now** on both phones and record every active child's starting
  balance.
- Do not create or archive a child during this test.

## Owner-phone visual actions

1. Confirm the home screen shows one large card per active child, an **All
   Children** card, a **Give / Take** selector, and six amount buttons per card.
2. Leave **Give** selected. Tap `+$0.05` on one child. Confirm that only that
   child increases by exactly five cents and that one manual transaction appears
   in the child's history.
3. Select **Take**. Tap `−$0.10` on a different child. Confirm that only that
   child decreases by exactly ten cents and that one manual transaction appears.
4. Open **Quick Amounts** from the sliders button. Remove one amount, add a
   different exact amount such as `$0.75`, and reorder at least one item. Save.
   Confirm the new ordered set appears on every child, All Children, and child
   detail. Terminate and relaunch Kid Money; confirm the preference persists.
5. Select **Give**, then choose a small amount on **All Children**. Confirm the
   dialog states the amount and active-child count. Cancel once and verify no
   balances change. Repeat and confirm. Every active child must increase by the
   exact amount and receive one transaction labeled **Applied to all children**.
6. Select **Take** and apply a small amount to **All Children**. Confirm every
   active child decreases by exactly that amount and receives one matching
   transaction.
7. Open each child's history and verify the newest-first ordering, signed
   amounts, source, note, and balances remain correct.

## Two-phone synchronization

1. On the owner phone, open **Sharing**. Confirm the quick-action transactions
   appear in **Changes waiting to sync**, then tap **Sync Now** and confirm the
   count reaches zero.
2. On the spouse phone, tap **Sync Now**. Confirm every individual and
   all-children transaction appears exactly once and all balances match the
   owner phone.
3. Confirm the spouse phone's quick-amount buttons did not change. Quick-amount
   preferences are intentionally per device, not shared ledger data.
4. On the spouse phone, perform one individual visual quick action, sync both
   phones, and confirm it appears exactly once on the owner phone.
5. Terminate and relaunch both apps, sync again, and confirm balances and
   history remain unchanged with no duplicates.

## Report

Report any incorrect amount, partial all-children change, duplicated history,
stuck pending count, preference that fails to persist, or layout that is hard to
use. Screenshots are especially useful for clipping, confusing labels, or tap
targets. Siri is not part of this checkpoint.
