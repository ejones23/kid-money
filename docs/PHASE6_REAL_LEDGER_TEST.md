# Phase 6 real-ledger physical test

Status: **Build 11 is Testing in both Internal Testing and the external Family
Test group. Build 10 passed owner opt-in, invitation, participant adoption,
and matching imported history; its ordinary Sync Now left a new edit queued.
Build 11 physically passed manual incremental sync in both directions,
owner-Siri-originated delivery, two-phone relaunch persistence, and controlled
offline/reconnect recovery. Build 14 adds guarded hybrid automatic sync and is
awaiting two-phone verification.**

This is separate from the successful counter-only connection test. Build 10
offers an explicit owner upload of the actual child and transaction ledger to
the owner's private iCloud storage. It is not a disposable counter. The owner
reviewed the consent sheet before proceeding.

## Before installation

1. Confirm the `Household`, `Child`, and `LedgerTransaction` record types and
   their fields are deployed to CloudKit **Production** for
   `iCloud.io.github.ejones23.KidMoney`. Verify the `cloudkit.share` type remains.
2. Confirm the published privacy policy and App Store Connect privacy answers
   describe the optional private iCloud copy and read-write invitations.
3. Keep build `0.1 (10)` on the owner phone. Build 10 is now available in the
   external `Family Test` group; update the spouse's phone through TestFlight
   without uninstalling the app. Use separate iCloud Apple Accounts; the
   spouse's Kid Money ledger must be empty for this first adoption test.
4. Record the owner phone's existing child names, balances, and transaction
   count without sharing a screenshot or personal ledger details with the
   developer. Do not uninstall the app or reset a phone during this test.

## Owner-only, no-upload preflight

Completed on September 26, 2026: the owner confirmed build 10 retained the
existing ledger, displayed plausible counts and the upload disclosure, and
remained local-only after tapping **Not Now**.

1. On the phone holding the ledger you intend to share, confirm TestFlight
   shows build `0.1 (10)` and the existing children, balances, and history are
   unchanged. Do not start setup from a different phone with an independent
   local ledger.
2. Open **Kid Money → Sharing**. It should say the ledger is on this phone only.
3. Tap **Share Family Ledger**. Check that the sheet shows plausible child and
   transaction counts and explains the private iCloud upload. Tap **Not Now**.
4. Reopen Sharing. It should still say the ledger is on this phone only, and
   the balances should still be unchanged. Stop here and report any unexpected
   change or error before choosing **Upload My Ledger to iCloud**.

## Owner opt-in and invitation

Owner report on September 26, 2026: the upload action completed, the Sharing
screen displayed **Sharing enabled**, and the private invitation was sent by
text. This is an owner-side physical observation, not yet confirmation that a
second device can import or edit the real ledger.

1. On the owner phone, open **Kid Money → Sharing**. Confirm it still says the
   ledger is on this phone only. Merely opening this screen must not upload.
2. Tap **Share Family Ledger**. Review the child and transaction counts and the
   exact disclosure again. The prior **Not Now** preflight is complete.
3. Only if comfortable copying this ledger to private
   iCloud, tap **Upload My Ledger to iCloud**. If setup errors, record the exact
   wording and stop; do not repeatedly create a new share or reinstall.
4. When Apple's sharing sheet appears, privately invite the spouse with
   read-write access. Do not enable a public link. Record whether the owner
   screen shows **Sharing enabled** and whether **Sync Now** reports a result.

## Participant adoption

Physical result on September 26, 2026: the spouse opened the private text
invitation on build 10, joined successfully, saw **Sharing enabled**, and could
read the owner's complete existing transaction history. Do not repeat adoption
or uninstall either app to troubleshoot later synchronization.

1. On the spouse's phone, open the invitation. Kid Money should say an
   invitation is ready and should not import children immediately.
2. Open **Kid Money → Sharing**. Confirm the invitation review and empty-ledger
   preflight, then tap **Join Family Ledger** once. If this phone already has
   children or transactions, stop and report the warning; do not erase data.
3. After joining, verify the same children, balances, and history. Tap **Sync
   Now** on both phones if needed; background synchronization is not enabled in
   this first test build.

## Two-way writes and persistence

Current build 10 finding: an owner-side manual `+$0.25` appeared locally and
left one change waiting to sync. **Sync Now** on the owner did not clear that
change, and **Sync Now** on the participant did not deliver it; the participant
still showed the pre-edit balance. This is a failure of ordinary sync, not an
expected manual-refresh delay. Build 11 contains a candidate engine-lifetime
fix. Update both phones through TestFlight without uninstalling or re-inviting.
Before making any more edits, tap **Sync Now** on the owner phone and check
that the pending count reaches zero. Then tap **Sync Now** on the spouse's
phone and check that this same 25-cent transaction appears exactly once. If
either check fails, record the **Sync** status and pending count on both phones
and any alert text, then pause again. **Result:** both phones updated to build
11; the owner's pending count dropped to zero, and the participant received
the edit once with the expected balance.

1. The existing owner-side manual adjustment passed on build 11: explicit
   **Sync Now** cleared the pending queue, and the participant saw exactly one
   new history row and the expected balance after their **Sync Now**.
2. **Passed:** the spouse made a small manual adjustment, synced it, and the
   owner received it once with the expected balance after Sync Now.
3. **Partially passed, with an iOS 27 routing compatibility finding:** after
   both phones had been updated to iOS 27, build 11 rejected the locked and
   then unlocked one-shot phrase “Give Rebecca fifteen cents in Kid Money,”
   but the unlocked prompted route “Give money in Kid Money” collected Rebecca
   and fifteen cents, created exactly one Siri transaction, reached `$3.00`,
   and queued one cloud change. Because both the app build and OS changed since
   the build 6 success, the observation does not isolate an app regression from
   an OS routing change. **Passed:** that transaction reached the spouse
   exactly once with a matching `$3.00` balance. Siri is disabled on the
   spouse's iPhone 14, so no participant-side Siri test is required; the
   already-passed manual reverse
   mutation covers participant-to-owner synchronization. A simulator build
   does not establish Siri behavior.
4. **Passed:** terminating and relaunching both apps preserved the matching
   `$3.00` balance and history. Another **Sync Now** on each phone created no
   duplicate transaction.

## Recovery checks after the basic matrix passes

- **Passed on September 26, 2026:** with the owner phone offline, a 35-cent
  local edit remained visible and pending, survived termination and relaunch,
  and did not appear on the participant phone prematurely. After connectivity
  returned, **Sync Now** on the writer drained the pending change and **Sync
  Now** on the reader delivered it exactly once. A repeated sync created no
  duplicate; both phones converged from `$3.00` to `$3.35`.
- Account switching and invite revocation should be tested only after the
  basic two-way matrix is stable, with an agreed recovery plan. These can
  freeze shared edits, and the first build intentionally has no destructive
  reset or automatic account rebinding.

For any failure, send the exact on-screen error, device role, build number,
action that preceded it, and whether the existing local ledger remains visible.
Do not send iCloud credentials, device logs, or family ledger screenshots.

## Build 14 automatic-sync matrix

Run this after both phones show build 14. Keep **Sync Now** as a diagnostic
fallback rather than part of the normal path.

1. Launch Kid Money on both phones so each activated household creates its one
   automatic engine. Record matching starting balances.
2. Adjust one child on the owner phone. Do not open Sharing. Confirm the pending
   queue clears automatically and the participant receives the transaction
   exactly once. If delivery is not prompt, background and reopen the
   participant app; the foreground fetch must catch up automatically.
3. Make a different adjustment on the participant and confirm the reverse path
   under the same rules.
4. Make three rapid adjustments on one phone. Confirm all three transactions
   arrive exactly once even though the network wakeup is debounced.
5. Put the owner phone offline, make one adjustment, and confirm it remains
   local and queued. Restore connectivity and bring Kid Money to the foreground;
   confirm automatic exact-once delivery without Sync Now.
6. Terminate and relaunch both apps. Confirm matching balances and histories,
   no duplicate rows, and no unexpected attention-required state.
7. If any step remains stuck, record Sync status and pending count on both
   phones before using **Sync Now**. A successful manual recovery is useful but
   does not count as automatic-sync success for the failed step.
