# Universal Every Open candidate — development phone flow verified

8 November 2026. The development-phone challenge/return flow has passed for Books and Safari. This remains an opt-in candidate until production TestFlight and the remaining edge cases are verified.

## Availability

The existing X setup remains the default. Build with `--dart-define=VEEA_UNIVERSAL_GATE_PREVIEW=true` to show the candidate setup screen. Its Apple-hosted template can be overridden using `VEEA_UNIVERSAL_SHORTCUT_URL` when testing a different app bundle. Do not enable the preview by default until the physical tests below pass.

Candidate production template: <https://www.icloud.com/shortcuts/4b6b6b0d88d9402fa8f050a334bc2d76>. It references `com.nintran.veeaEnglishApp.CheckVeeaGateIntent` and `veea://`. The currently installed TestFlight version does not implement this new protocol. A personal-profile test app requires its own matching intent descriptor and URL scheme; importing this production template alone does not test the new code.

## Observed Apple setup behavior

On the user's iOS 27.2 phone, the imported template showed an App question and an Automation question. The import App question selected **one app**. In the imported shortcut's editor, tapping **+** beside that app allowed another app to be added to the same trigger. The latest test imported Books, enabled Automation during import, then added Safari through **+**. The editor confirmed **When Books or Safari is Opened**, Automation on and Notify off. Instructions describe choosing the first app during import, then adding further apps through that + control. A single multi-select import picker has not been demonstrated.

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

## Development phone verification

Mirroring control recovered. The separate **Veea Gate Test** app was rebuilt from the current candidate and updated without replacing the production TestFlight app or notebook. Its five starter words were preserved. The production X4 automation was left unchanged.

The matching signed test template is <https://www.icloud.com/shortcuts/2e5bb4945e5941e19a4bd73acd32b753>. It uses `com.veea.veeaRewind.CheckVeeaGateIntent`, `veea-test://`, nine actions, the correct Text/Bool bindings and the original Current App return object. It was imported from the new in-app setup screen and enabled for Books and Safari.

The first physical Books test failed to show a challenge. Test-app preferences confirmed that the intent ran and Veea received Apple's callback, but the validator rejected its previously unobserved format: `shortcuts-production://x-callback-url/ic-success/<invocation UUID>`. The validator now accepts the UUID-scoped `ic-success`/`ic-cancel` endpoints while rejecting malformed IDs, extra path segments, foreign schemes, credentials, fragments and run-shortcut endpoints. The phone also supplied an `ic-cancel/<invocation UUID>` callback. Native regression checks, all 16 focused Flutter setup tests and the rebuilt iOS app passed. The fix was installed into the separate test app.

After the fix, the user confirmed a Books challenge and return with Books staying open. An initially reported repeat failure was rechecked after explicitly leaving the shortcut editor. The user confirmed the same challenge → Shortcuts → Books flow on the recheck. Saved state recorded a verified Books return at 19:17:19 local time and a subsequent fresh Books challenge request, with no native error.

The Safari physical test showed a correctly labelled Safari challenge. Completing it through Mirroring visibly returned via Shortcuts to Safari. The user then confirmed challenges and correct Safari returns on **both fresh physical openings**, including the immediate repeat. Saved state recorded a verified Safari return at 19:14:08 local time. The intermediate Shortcuts screen is visible during callback resumption. Mirroring completion left a handoff unused, whereas physical testing recorded its consumption. Do not infer a physical repeat bug solely from a Mirroring test. The existing single-use handoff logic remains unchanged.

Before enabling the preview by default:

1. Test cancellation/reopening, switching apps mid-round, cold start, failure/retry and mode switching on the physical phone. These have automated coverage but the complete physical edge-case matrix is still pending.
2. Use Nin's production signing team for a new TestFlight build and repeat the Books/Safari import, multiple selection through +, Every Open and correct-return tests with the production template. The currently installed TestFlight app does not contain this implementation.
3. Keep test-only signing/build settings separate. The local build uses a CocoaPods staging project and a personal-profile Screen Time stub; none of that staging configuration belongs in production source. Native Screen Time is not validated by this build.

Local transfer/build artifacts are under `/Users/kelvinm/Documents/Codex/2026-11-06/v/work/universal-gate-20261108` and `/Users/kelvinm/Documents/Codex/2026-11-06/v/work/gate-phone-rerun`; they are not committed.
