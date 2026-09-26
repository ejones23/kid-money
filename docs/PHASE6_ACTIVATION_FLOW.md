# Phase 6 activation and invitation flow

Status: **Owner/participant screens are wired locally, but not enabled in TestFlight.**

The counter-only connection test proved that two Apple Accounts can share one
CloudKit zone. The real-ledger UI now follows this flow in a local build. Build
9 on TestFlight remains counter-only. Opening Sharing does not start an upload;
the owner must press **Upload My Ledger to iCloud** in a separate consent sheet.

## Owner: explicit opt-in

1. A **Share Family Ledger** action lives in a small sharing/settings screen,
   not in the add-child or Siri flows. Before any real-ledger CloudKit request,
   show a confirmation describing the upload: household name, child names,
   transaction history, notes, and derived balances. Show local child and
   transaction counts. Explain that invited adults can edit the same ledger
   and that the owner's iCloud account supplies storage.
2. On confirmation, validate iCloud availability, then durably stage the
   existing local records. The current local ledger remains visible; edits
   made during setup join the pending upload queue. Do not create a second
   ledger or mutate historical rows.
3. Resume zone creation, initial upload, and zone-wide share creation from
   the persisted migration phase. Display progress and an honest retry state.
   A lost response or relaunch resumes idempotently; it does not start a new
   household. Only the owner can create this share.
4. Activate only after the share is reachable under the same iCloud account.
   Then offer Apple's `UICloudSharingController` to invite the spouse with
   read-write access; public-link access stays disabled. The system sheet is
   for invitations, not an authentication form.
5. Before remote zone creation, cancellation can discard setup metadata while
   keeping all ledger rows. After remote work begins, cancellation must first
   confirm remote-zone cleanup; if cleanup fails, leave a retryable setup
   state rather than claiming the upload was undone.

The confirmation is the upload consent boundary. Merely opening the app,
checking iCloud, or viewing this screen must not start migration.

## Participant: invitation entry

The scene delegate receives `CKShare.Metadata` for both cold-start and
running-scene invitations. It routes the disposable counter probe separately
from a family-ledger invitation using the container, zone prefix, and
zone-wide share name. The participant coordinator then validates the complete
zone identity and read-write permission before staging. Unknown shares are
rejected rather than accepted by either path.

1. Persist the validated invitation locally and show a **Join Family Ledger**
   review screen. Do not call CloudKit acceptance from the scene callback.
2. If this device has any children or transactions, block adoption. Explain
   that joining would replace a separate local ledger; until an export or
   explicit keep/replace flow exists, offer only **Keep My Ledger**. Never
   delete or silently merge the existing rows.
3. On the parent's explicit **Join** action, accept the share under their own
   iCloud account, fetch exactly the invited shared zone, validate the one
   household, and atomically merge the first snapshot. Imported rows remain
   read-only until the access gate confirms the current account and write
   permission. Interrupted acceptance/fetch resumes from durable state.
4. After activation, show children and balances from the local replica.
   Manual and Siri edits use the existing `LedgerService`; cloud delivery is
   asynchronous and never required for Siri to finish.

## Ongoing access and recovery

- Check the pinned iCloud account and share before starting a send/fetch
  session, on account-change notifications, and on explicit retry. Do not
  construct an automatic sync engine before this check succeeds.
- Network outages, rate limiting, and temporarily unavailable iCloud leave
  local edits writable and queued. On reconnect, show **Changes Pending**
  until a fetch and queue drain complete; do not claim **Synced** solely from
  the access check.
- Missing zones or shares, revoked write permission, managed-account
  restrictions, sign-out, and account switches move the household to
  **Attention Required** and freeze new shared mutations. Preserve all local
  children, transactions, and queued changes. Do not auto-rebind an existing
  household to a different Apple Account or silently start a new share.
- Recovery from attention-required state needs a separate explicit flow for
  restoring the original account, re-invitation, or keeping/exporting local
  data. No destructive reset or automatic reactivation is part of the first
  wiring checkpoint.

## Release gates

Before a TestFlight build can expose this flow: validate owner and participant
UI state transitions; update privacy disclosures for child names, notes, and
history in private iCloud sharing; and confirm that cold-start invitations
cannot fall into the counter probe. Then run a two-device physical matrix for
initial upload, invitation acceptance, bidirectional manual and Siri edits,
offline/reconnect, restart, account changes, and revocation. Compilation and
simulator tests alone do not establish physical CloudKit or Siri behavior.

The access-checked sync session and its injected failure tests are
implemented. An activated family ledger can run it with **Sync Now**; no
automatic background sync or startup upload is enabled yet. Before TestFlight,
the Household, Child, and LedgerTransaction schema must be deployed to
Production, and the real-ledger physical matrix must be prepared.
