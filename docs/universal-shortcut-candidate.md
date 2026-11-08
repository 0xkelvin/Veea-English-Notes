# Universal Every Open candidate — device verification pending

8 November 2026. This implementation is a test candidate, not a verified replacement for the working X flow.

## Availability

The existing X setup remains the default. Build with `--dart-define=VEEA_UNIVERSAL_GATE_PREVIEW=true` to show the candidate setup screen. Its Apple-hosted template can be overridden using `VEEA_UNIVERSAL_SHORTCUT_URL` when testing a different app bundle. Do not enable the preview by default until the physical tests below pass.

Candidate production template: <https://www.icloud.com/shortcuts/4b6b6b0d88d9402fa8f050a334bc2d76>. It references `com.nintran.veeaEnglishApp.CheckVeeaGateIntent` and `veea://`. The currently installed TestFlight version does not implement this new protocol. A personal-profile test app requires its own matching intent descriptor and URL scheme; importing this production template alone does not test the new code.

## Observed Apple setup behavior

On the user's iOS 27 phone, the imported template showed an App question and an Automation question. The import App question selected **one app**. In the imported shortcut's editor, tapping **+** beside that app allowed another app to be added to the same trigger. The editor displayed **When Calendar or Books is Opened**. This test automation was left **off**. Instructions now describe choosing the first app during import, then adding further apps through that + control. A single multi-select import picker has not been demonstrated.

The signed template contains no fixed app selection. The first import draft with inaccurate multiple-selection instructions has been superseded by the candidate link above.

## Implementation

Shortcuts retains the original Current App object. Two random integers form a per-opening correlation token. A Text action passes `veea-universal`, the token, and the app's display name to the existing Bool Check Veea Gate intent. When a challenge is needed, Open X-Callback URL opens `veea://gate?request=<token>`. Only after Veea resumes that callback does Shortcuts execute Open App with the retained App object. No guessed URL scheme or fixed X return is used.

Veea accepts a callback only for the newest request, with protection enabled and an age of at most ten minutes. Challenge targets include the request token, so completion or disposal of a stale screen cannot earn or cancel a newer request, including another opening with the same app name. Partial learning progress uses the stable name key. Distinct apps with the same display name share learning progress/status labels, while the return object remains in their respective Shortcuts execution. A rename creates a new progress label.

Earning access and sending the callback are separate. A return callback can be sent once; launch failure allows retry. The next background check consumes a single handoff and records a last-verified timestamp. Fresh openings challenge again. Cancellation clears the current request and uses Apple's cancel callback where supplied. Disabling protection or switching to native timed protection clears the universal session.

Setup validates the notebook and iOS support before opening Apple. It does not choose default catalog apps. Opening/returning from the installer never claims that an automation is enabled. Status lists apps observed by the intent, not an authoritative copy of Apple's private selection. Verification labels describe the last observed challenge/return; external changes require retesting.

## Validation completed

- Apple native Shortcuts exported and signed the candidate. Its public export was decrypted and inspected: nine actions, correct variable UUIDs, Bool guard, callback and Open App both inside the If, unchanged original App reference, App/Automation import questions, and no preselected app.
- `python3 tool/test_universal_shortcut_template.py` checks these bindings and the signed-package checksum. This is a structural check, not a device result.
- Native tests cover marker validation, disabled modes, wrong request/app, callback replacement, stale screens including repeated app names, earned-only return, replay, failure/retry, cancellation and expiry.
- Flutter tests cover setup preparation without default app selection, notebook/iOS/link guards, installer retry, no false success, observed per-app status, turn-off failure, per-app progress across request tokens, and enlarged text.
- Analyzer passed; all 16 focused setup tests passed. The full run completed 496 tests with 492 passing and four widget timing failures. All four failed cases passed in a serial rerun of their four files (56 tests passed). A final focused run also includes the new default-flow feature-switch regression. This is not recorded as a clean single full-suite run.

## Physical verification still required

The separate **Veea Gate Test** app was installed with starter words without replacing the user's production TestFlight app or notebook. Its earlier build is not the final candidate and has not completed the new callback flow. The production X4 automation was left unchanged. The disabled phone draft Veea App Gate contains Calendar and Books; the production intent has not yet been replaced with the test app's intent. A tap while adding the test intent timed out, so inspect its current action list before further editing.

iPhone Mirroring control then repeatedly timed out, including after the user reopened Mirroring and separately closed Shortcuts on the physical phone. Mac Shortcuts remained controllable. No multiple-app challenge/return cycle has passed. In particular, the actual Apple callback URL shape and resumption behavior remain unverified; the narrow callback validator must be checked against the real device value before release.

Before enabling the preview by default:

1. Finish a test-bundle shortcut variant (`com.veea.veeaRewind`, `veea-test://`) and preserve all variable/If bindings. Enable only its test apps, avoiding duplicate production X automation.
2. Build/install the latest source into the separate test app. The prior local build used a temporary CocoaPods-only staging project and a personal-profile Screen Time stub; none of that staging configuration belongs in production source.
3. Start from Veea's new setup screen, import, choose the first app, enable Automation and add it; add a second app with +. Inspect the enabled trigger and actions afterward.
4. From the physical phone's Home Screen, open app A, complete all words, verify return to A and no bounce. Repeat a fresh opening, then repeat both cycles for B.
5. Cancel mid-round and reopen. Switch apps mid-round, finish the latest challenge and verify that it cannot return to the previous app. Check cold start, failure/retry and mode switching.
6. Use Nin's production signing team for a new TestFlight build and repeat the physical test with the production template before changing the default flow.

Local transfer/build artifacts are under `/Users/kelvinm/Documents/Codex/2026-11-06/v/work/universal-gate-20261108` and `/private/tmp/veea-universal-phone`; they are not committed.
