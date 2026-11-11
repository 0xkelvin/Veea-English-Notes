# First-launch QA — 10 November 2026

Candidate branch: `feat/first-launch-native-accounts`.

## Scope and review

Claude CLI supplied the initial UX/account design review, implemented the core
account lifecycle, and independently reviewed UI screenshots, flows, source,
tests and recorded results. Codex implemented the native-only protection flow,
integrated the account work, executed the checks and resolved review findings.
Claude's reviews were read-only; they were not physical-device tests.

The focused follow-up verdict was: **A1 and A2 are resolved; no remaining
blocking or medium defects in those fixes.** The two low follow-ups were also
addressed: startup receipt recovery runs after the first frame, and the legacy
operation helper also keeps sync paused while a deletion is pending.

Resolved findings include the missing return breadcrumb for unlocks initiated
inside Veea, Android protection copy, unconfirmed backup claims, and the deletion
receipt race. A negative receipt during the OTP-expiry/grace window remains
pending, survives restart, pins notebook ownership and pauses sync. A later
positive receipt completes local cleanup. Repeating deletion cannot overwrite an
unresolved request. Lost phone-change responses reconcile the server's account
identity before requesting fresh sign-in. Compact large-text keyboard testing
also led to eagerly mounted, scrollable account forms.

## Executed checks

| Check | Result |
|---|---|
| `flutter analyze --no-pub` | No issues |
| `flutter test --no-pub` | **544 passed**, including visual goldens |
| Focused phone lifecycle / account UI | **34 passed**; included in total above |
| `cargo test --lib` in `cloud` | **79 passed** |
| Opt-in PostgreSQL integration suite | **6 passed, 0 ignored**, disposable local PostgreSQL 16 |
| `bash tool/test_native_screen_time.sh` | Portable native and compatibility checks passed |
| Runner Swift type checking | Passed against the installed iOS 27.2 device SDK |
| iOS release Dart/AOT + assets assembly | Passed, arm64 App.framework built |
| Actual Flutter widget renders | Protection, duration wheel, account and phone-change states rendered and inspected in light/dark themes |
| `git diff --check` | Passed |

The new picker tests cover 5-minute/24-hour bounds, whole-minute values,
save/cancel, large text and a small screen. Swift tests cover native range
validation, invalid stored duration normalization, exact 24-hour cross-midnight
expiry, explicit UTC calendar components across DST's repeated hour, persistence,
scheduling failure and process-safe state updates. Account tests cover adoption
and switching, UUID guards, purpose/account/proof replay rejection, session
revocation, expiry/resend, provider/network errors, confirmed deletion, early and
late receipt responses, secure-storage recovery deadlines, and preserving data
on generic 401/404 errors.

## Required external validation

Full Xcode packaging hit this environment's nested `sandbox-exec` restriction.
The successful native type check and Dart/AOT assembly do **not** constitute a
signed app, archive, entitlement validation or a TestFlight upload.

Nin still needs to provide/connect the existing public API and OTP provider,
apply the new migration, and confirm the API's trusted-proxy/client-IP policy
before public OTP traffic. Real support/privacy URLs and the feedback retention
policy need team values. The no-backend build remains local and does not display
a working signup form or claim cloud backup.

A production-signed device build must verify Screen Time authorization, app
selection, per-app shielding/unlocking, the Apple return breadcrumb, 5-minute, 15-minute
and longer-pass relocking, and real SMS/account/cross-device flows. A client
recovery grace period is conservative; it is not a durable server transaction
state machine. No real-device, production SMS, deployment or upload is claimed.


## Five-minute candidate added after the range preference

The user's requested minimum is five minutes. Default stays 15 minutes, maximum
24 hours. A 5–14 minute pass keeps an at-least-15-minute monitoring window, begun
in the past, with its end exactly aligned to the stored pass expiry. This follows
Apple's documented ability to start monitoring during an ongoing interval; it is
not a claim that Apple permits a five-minute monitoring interval. Portable Swift
checks cover 5/6/10/14-minute expiry, full window length and relock state. Actual
`startMonitoring` acceptance and background relocking at five minutes remain a
required signed-device test. This candidate has not been deployed to the phone.

Claude's focused five-minute follow-up found no blocking or medium code bugs.
It explicitly distinguished the documented ongoing-interval inference from
physical-device verification. Start-callback reconciliation before/after saving
a short pass, and end-time reconciliation, are additionally exercised in the
portable Swift tests; actual Apple callbacks remain unverified.

## Per-app management follow-up — 11 November 2026

Branch `feat/per-app-unlock-times` builds on the merged launch candidate. Settings
now opens **Manage Apps to Lock**: Add Apps, a default unlock time, and a card per
selected app with Remove and Unlock time. Apps inherit the default unless given
an explicit override. Use default restores inheritance; an explicit value equal
to the default remains custom. Existing passes retain their original end times.

Latest executed checks:

- **557 Flutter tests passed**, including 13 management/model/provider checks.
- Flutter analyzer: no issues.
- Portable Swift tests passed, including old JSON migration, default inheritance,
  per-app overrides, independent expiries, retained passes and removal cleanup.
- Runner's full native source type checked against the iOS 27.2 device SDK.
- Arm64 release Dart/AOT and Flutter assets assembled successfully.
- Real Flutter light/dark management and time-sheet renders were inspected;
  the opt-in render run passed 14 checks, including its capture check.
- Claude CLI independently reviewed code, UX, previews and QA evidence. Its final
  targeted review found **no remaining blocking or medium regressions**. Resolved
  findings include visible error SnackBars, successful removal despite failed
  SQLite history cleanup, selected-app labels in both time sheets, selected-time
  semantics, grouped app controls, expired-pass refresh and explicit time styling.

The previews use fixture app labels; Apple renders actual private names/icons in
an iOS platform view. These renders do not prove native label rendering or
VoiceOver behavior on an iPhone. The final semantics test, visible-error test,
real SQLite cleanup-failure test and foreground expiry test all pass.

Current full Xcode packaging is blocked by denied access to the SwiftPM manifest
diagnostics cache in this environment. This follow-up has no signed archive,
TestFlight upload or phone installation. The successful AOT assembly and native
type check are separate checks, not a packaged iOS build.

Signed-device acceptance for Nin:

1. Add two apps. Set default to five minutes and one app's override to 15 minutes.
   Confirm real app names/icons in the list, both time sheets and Remove dialog.
2. Unlock both apps at different times. Verify each relocks at its own expiry,
   including while Veea is backgrounded/terminated. Five-minute schedule
   acceptance remains a required system test.
3. Change the default while access is active. Existing end times must stay fixed;
   the next inherited unlock must use the new default. A custom app must keep its
   own duration until Use default is chosen.
4. Cancel picker/time edits; deny/revoke and restore Screen Time; confirm errors
   are visible. Check large text, dark mode and VoiceOver's selected-time state.
5. Remove one app during an earned pass: stop locking it without changing the
   other app's timer. Remove the final app: locking must turn off.
