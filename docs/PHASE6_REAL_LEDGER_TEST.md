# Phase 6 real-ledger physical test

Status: **Prepared; do not run until the Production schema and privacy release gates pass.**

This is separate from the successful counter-only connection test. The next
build will offer an explicit owner upload of the actual child and transaction
ledger to the owner's private iCloud storage. It is not a disposable counter.
The owner should review the consent sheet before deciding to proceed.

## Before installation

1. Confirm the `Household`, `Child`, and `LedgerTransaction` record types and
   their fields are deployed to CloudKit **Production** for
   `iCloud.io.github.ejones23.KidMoney`. Verify the `cloudkit.share` type remains.
2. Confirm the published privacy policy and App Store Connect privacy answers
   describe the optional private iCloud copy and read-write invitations.
3. Install the new TestFlight build on both phones. Record its version/build
   number. Use the owner's existing iCloud account on one phone and the spouse's
   separate iCloud account on the other; the spouse's Kid Money ledger must be
   empty for this first adoption test.
4. Record the owner phone's existing child names, balances, and transaction
   count without sharing a screenshot or personal ledger details with the
   developer. Do not uninstall the app or reset a phone during this test.

## Owner opt-in and invitation

1. On the owner phone, open **Kid Money → Sharing**. Confirm it still says the
   ledger is on this phone only. Merely opening this screen must not upload.
2. Tap **Share Family Ledger**. Review the child and transaction counts and the
   exact disclosure. Tap **Not Now** once; verify no setup begins.
3. Reopen the sheet and, only if comfortable copying this ledger to private
   iCloud, tap **Upload My Ledger to iCloud**. If setup errors, record the exact
   wording and stop; do not repeatedly create a new share or reinstall.
4. When Apple's sharing sheet appears, privately invite the spouse with
   read-write access. Do not enable a public link. Record whether the owner
   screen shows **Sharing enabled** and whether **Sync Now** reports a result.

## Participant adoption

1. On the spouse's phone, open the invitation. Kid Money should say an
   invitation is ready and should not import children immediately.
2. Open **Kid Money → Sharing**. Confirm the invitation review and empty-ledger
   preflight, then tap **Join Family Ledger** once. If this phone already has
   children or transactions, stop and report the warning; do not erase data.
3. After joining, verify the same children, balances, and history. Tap **Sync
   Now** on both phones if needed; background synchronization is not enabled in
   this first test build.

## Two-way writes and persistence

1. On the owner phone, make one small manual adjustment with a distinctive
   note. Tap **Sync Now** there, then on the spouse's phone. Confirm the exact
   balance and one corresponding history row on both phones.
2. On the spouse's phone, make a different small manual adjustment. Sync on
   that phone, then on the owner phone; confirm both balances and histories.
3. If both phones use the verified Siri grammar, make one numeric-cent voice
   adjustment on each phone, such as “Give [child] fifteen cents in Kid Money.”
   Siri may ask Kid Money/Wallet disambiguation. Sync the writer, then reader,
   and verify exact cents and one transaction on each. A simulator build does
   not establish this behavior.
4. Terminate and relaunch both apps. Confirm matching balances and histories,
   then run **Sync Now** once more on each.

## Recovery checks after the basic matrix passes

- With one phone offline, make a small local edit. It should remain visible and
  show pending work. Restore connectivity; run **Sync Now** on writer then
  reader and verify the edit appears once.
- Account switching and invite revocation should be tested only after the
  basic two-way matrix is stable, with an agreed recovery plan. These can
  freeze shared edits, and the first build intentionally has no destructive
  reset or automatic account rebinding.

For any failure, send the exact on-screen error, device role, build number,
action that preceded it, and whether the existing local ledger remains visible.
Do not send iCloud credentials, device logs, or family ledger screenshots.
