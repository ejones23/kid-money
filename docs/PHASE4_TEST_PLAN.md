# Phase 4 manual interface test plan

Use TestFlight build `0.1 (7)`. This is a focused owner review of the useful manual interface, not a repeat of the completed Siri matrix.

## Rebecca's ledger

1. Update Kid Money from build 6 to build 7 and open it once.
2. Confirm Rebecca's balance remains `$2.40` and her existing transactions appear newest first.
3. Open Rebecca and tap `+$0.05`. Confirm the balance becomes `$2.45` and History gains a `Manual adjustment` entry for `+$0.05`.
4. Choose **Add Money**, enter `0.15`, add the optional note `Phase 4 test`, and save. Confirm the balance becomes `$2.60` and the note appears in History.
5. Choose **Subtract Money**, enter `0.10`, and save. Confirm the balance becomes `$2.50` and History shows `-$0.10`.
6. Terminate and relaunch Kid Money. Confirm the `$2.50` balance and all three manual entries persist.

Check that the balance, buttons, dates, signed amounts, source labels, and notes are readable. Report any awkward scrolling, clipped text, unexpected keyboard behavior, or difficulty dismissing a sheet.

## Child management

Do not archive Rebecca for this test. There is intentionally no destructive deletion, and an archived child is hidden from the current active-only interface.

1. Add a temporary child named `Phase Four Test`.
2. Open that child, use the menu in the upper-right corner, and rename the child to `Temporary Child`.
3. Confirm the new name appears both on the detail screen and in the main list.
4. Open `Temporary Child`, choose **Archive**, read the confirmation, and confirm.
5. Verify the temporary child disappears from the active list and Rebecca remains unchanged.

Archiving preserves the child's ledger and excludes the child from Siri suggestions. A future archived-child management screen can expose restoration if real-world use demonstrates that it is needed.
