# Veea implementation handoff — 7 November 2026

Review branch: `feat/veea-user-flows-20261107`. Includes the accumulated app and cloud work plus upstream `8569dd0` (`feat: Update app version`). Main is left unchanged for review.

## Included

- Learning rules: searchable practice pool across dates, scoped and whole-notebook selection, selected-word preview, configurable unlock word count, rotation and optional pronunciation. The daily new-word goal is optional and off by default.
- Durable challenge progress and the Shortcut return-to-app loop fix; native Screen Time protection with three iOS extensions and timed relocking.
- Listen and Review word selection; listening options moved behind a gear into a bottom sheet. Notebook navigation, long meaning suggestions, search scope and source labels improved. Widgets are hidden and disabled.
- Duplicate detection for manual entry, quick-add paths and backup imports. Users can open the saved entry or explicitly save a different meaning; existing notebook data is not automatically deduplicated.
- Optional phone OTP account UI, separate local account notebooks, revision-based word sync, private feedback/feature requests and an offline feedback outbox. No live SMS or server connection is configured by default.

The last personal-profile phone install was build `1.0.17` (marketing `1.0.2`), with saved data preserved. This branch retains Nin’s upstream app version `2.0.1`; it has not replaced that phone install. The personal test app uses `com.veea.veeaRewind`. Installing the new bundle ID creates a separate app, so export/import the notebook deliberately when moving to it.

## Apple configuration to confirm with Nin

The following configuration comes from Nin’s upstream commit, not an independently verified Developer Portal check:

- Team: `9X6SFG9KXM`
- Runner: `com.nintran.veeaEnglishApp`
- Shared App Group: `group.com.nintran.veeaEnglishApp`

All three new extensions now use the same team and App Group as Runner, with bundle IDs:

- `com.nintran.veeaEnglishApp.GateMonitor`
- `com.nintran.veeaEnglishApp.GateShieldAction`
- `com.nintran.veeaEnglishApp.GateShieldConfiguration`

Confirm this is the intended Veea team, register the extension identifiers and enable Family Controls and the App Group for all four targets. Regenerate profiles as needed. Distribution capability approval and signed physical-device enforcement still need verification. No certificates, profiles, secrets or user notebook backups are included in this branch. The paused widget target stays removed as in upstream.

## Existing services to connect

Nin needs to supply the public API origin and the existing OTP provider name. Keep provider credentials in server settings. Twilio Verify is only a prepared optional adapter; no provider purchase or switch has been made.

Follow [account and feedback rollout](account-feedback-rollout.md) for environment settings, API contracts, migrations `20261107000008` and `20261107000009`, deployment coordination, feedback retention and real-device checks. Protocol 2 needs all vocabulary-writing API nodes upgraded before clients are enabled.

No Zalo group exists yet. Its app button stays hidden until a valid Veea group link is supplied. The desktop client and cross-device learning/protection settings are outside the current implementation.

## Validation

Before upstream integration: Flutter analyzer clean; 481 Flutter tests passed; 79 Rust unit tests passed; 14 Shortcut access checks and native policy/persistence/handoff/scheduling/locking checks passed. Two PostgreSQL integration tests are explicitly ignored pending a disposable database. See the rollout document for their command.

After integration: dependency resolution succeeded on Flutter 3.44.6 / Dart 3.12.2, analyzer is clean, all 481 Flutter tests and the native policy checks passed again. Dependency constraints from upstream are retained; the lockfile is regenerated for this SDK. Xcode project parsing succeeds with Runner, tests and all three Screen Time targets. The unsigned iOS build could not complete because access to the system Swift package cache was unavailable, so a full build with Nin’s setup is still required. Extension versions now inherit the app’s generated Flutter version/build settings. Live OTP delivery, deployed API behavior, two-device sync and the paid-team native protection flow remain unverified until the service and signing setup is available.
