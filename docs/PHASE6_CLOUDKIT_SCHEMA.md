# Phase 6 CloudKit schema release gate

TestFlight runs against CloudKit Production. Development can create custom
record fields on first save, but Production needs an explicitly deployed schema.
The counter-only build deployed `FamilySharingProbe` and `cloudkit.share`.
On September 26, 2026, the three real-ledger types below were added in
Development and deployed to Production. Deploying schema copies types,
fields, and indexes, **not** any family records.

| Record type | Field | CloudKit type |
| --- | --- | --- |
| `Household` | `identifier`, `displayName` | String |
| `Household` | `schemaVersion` | Int(64) |
| `Household` | `createdAt` | Date/Time |
| `Child` | `identifier`, `name` | String |
| `Child` | `createdAt`, `lastModifiedAt` | Date/Time |
| `Child` | `sortOrder`, `isArchived` | Int(64) |
| `LedgerTransaction` | `identifier`, `childIdentifier`, `source`, `note`, `reversesTransactionIdentifier` | String |
| `LedgerTransaction` | `amountCents` | Int(64) |
| `LedgerTransaction` | `createdAt` | Date/Time |

`note` and `reversesTransactionIdentifier` are optional. Monetary values are
signed `Int64` cents, never floating-point. Record IDs are deterministic and
each household uses its own private custom zone and zone-wide share. The app
fetches changes by zone rather than querying custom fields, so no new custom
field query indexes are required for this first release. Keep the CloudKit
system fields and the existing `cloudkit.share` type intact.

## Verification before a real-ledger TestFlight upload

1. In [CloudKit Console](https://icloud.developer.apple.com/), open **CloudKit
   Database**, select `iCloud.io.github.ejones23.KidMoney`, and inspect the
   **Development** schema. Confirm all three types and fields above exist with
   the stated types. If absent, add the missing Development schema first; do
   not send real family data merely to generate it.
2. Review **Deploy Schema Changes**, then deploy the additive changes to
   **Production**. Confirm Production lists all three types and fields.
3. Confirm `cloudkit.share` remains in Production and the counter probe still
   works. Do not reset Production or delete existing types/fields.
4. Only then distribute a build exposing **Upload My Ledger to iCloud**.

The September 26 Production deployment was verified in CloudKit Console:
`Child` has 12 fields, `Household` has 10, and `LedgerTransaction` has 13,
including CloudKit's six system fields per type. The deployment diff showed
the exact custom fields and types above. The new types have no grants in the
`_world`, `_icloud`, or `_creator` public-database security roles. CloudKit
security roles govern the public database; the app uses only private and
shared databases with `CKShare` participant permissions. The existing probe,
`Users`, and `cloudkit.share` role grants were left intact.
