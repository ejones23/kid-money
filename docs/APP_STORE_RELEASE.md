# App Store and TestFlight release checklist

The immediate distribution goal is a TestFlight build that can exercise the physical-device Siri checkpoint without installing a locally signed developer app on a managed work phone. TestFlight availability remains subject to the employer's device policy.

## 1. Account and app record

- [ ] Enroll as an individual in the Apple Developer Program.
- [ ] Confirm that agreements are active in App Store Connect.
- [ ] Create an iOS app record using bundle ID `io.github.ejones23.KidMoney`.
- [ ] Confirm the public App Store name; `Kid Money Ledger` is the working choice.
- [ ] Record the assigned Apple ID and SKU here without adding credentials.

## 2. Release identity and assets

- [x] Use a stable reverse-DNS bundle identifier.
- [x] Add an opaque 1024×1024 App Store icon.
- [ ] Review the provisional icon with the product owner.
- [ ] Capture representative iPhone screenshots from the release candidate.
- [ ] Finalize description, subtitle, keywords, categories, and copyright.
- [ ] Provide a user-approved public support contact method.

## 3. Privacy and compliance

- [x] Draft public privacy and support pages.
- [x] Enable GitHub Pages from the repository's `docs` directory and verify every URL.
- [ ] Audit the release build and third-party code before selecting “Data Not Collected.”
- [ ] Complete the age-rating questionnaire.
- [ ] Confirm the app is not designated Made for Kids; the operator is a parent or guardian.
- [ ] Complete export-compliance questions based on the final binary.
- [ ] Verify that all user-facing claims match the shipped behavior.

## 4. Build verification

- [x] Build the Release configuration for a generic iOS device.
- [x] Run all automated tests on the supported simulator runtime.
- [ ] Confirm a clean Xcode Issue Navigator.
- [ ] Exercise persistence across termination and relaunch.
- [ ] Audit accessibility, Dynamic Type, dark appearance, and supported screen sizes.
- [ ] Decide whether to keep iOS 26 as the initial minimum version.

## 5. TestFlight

- [ ] Increment the build number.
- [ ] Archive the app with automatic distribution signing.
- [ ] Validate the archive and upload it to App Store Connect.
- [ ] Complete beta description, feedback contact, and review information.
- [ ] Add the owner's non-managed Apple Account as an external tester if necessary.
- [ ] Submit the first external build for Beta App Review.
- [ ] Install from TestFlight on an allowed physical iPhone.
- [ ] Execute and record `docs/SIRI_TEST_PLAN.md` before expanding the intent set.

## 6. Public release

- [ ] Resolve every TestFlight finding.
- [ ] Choose storefront availability and a free price.
- [ ] Attach the verified build to the App Store version.
- [ ] Submit the app and required metadata for App Review.
- [ ] Respond to review questions without sharing private ledger or device data.
- [ ] Release manually after approval and verify the live product page.

Never commit Apple credentials, certificates, provisioning profiles, personal development-team identifiers, private contact details, or device registration data.
