# Free-first launch readiness: 24 November 2026

Base: `origin/main` `7aed10b`. Branch: `fix/app-store-readiness-20261124`.
No signed build, production deployment, TestFlight upload, mailbox verification,
purchase, App Store submission or legal agreement was completed by this work.

## Resulting behavior

- Free first is the owner's confirmed launch decision. Multiple locks (existing
  maximum 50), custom default durations and per-app overrides work without Pro
  ownership or account sign-in in Flutter and native iOS policy. Native unlock
  grants do not wait for StoreKit. No new purchase offer/payment is started.
- Previous purchase identity and account/environment checks are retained. Restore
  is offered only when its product and account service are configured. Free
  capability never invents purchased Pro ownership.
- The notebook remains offline across account changes. Learning rules remain.
  Every Open/Shortcut setup and widget controls stay hidden for this release.
- OTP resend updates without typing, password signup resends preserve their
  in-memory password until completion/cancel, and client-clock expiry is only a
  hint: the server decides whether a code is valid. Account deletion status uses
  readable wording and keeps local words under the existing ownership contract.
- An account-only Go API no longer triggers unsupported legacy feedback/config
  calls. Feedback can be saved locally, explicitly shared/copied, or opened in a
  mail composer when a real support mailbox is supplied. Handoff is not receipt.
  Optional diagnostics are allowlisted; screenshots require explicit selection.
- An offline-readable privacy notice is accessible from Settings. No invented
  mailbox, policy link or Zalo group appears. Optional external links are validated.
- Automatic typed-word and clipboard suggestions are local only. Online lookup
  requires explicit consent for the captured word/phrase, names Google/MyMemory,
  ignores stale results and does not automatically upload saved vocabulary.

## Verification actually executed

- Full Flutter suite: **747 passed, 8 skipped**, zero failures
  (`final-full-flutter-tests-2.log`). No golden images were regenerated.
- After final review wording and the additional signed-out/no-Pro custom-duration
  UI test: **50 focused regressions passed** (`final-ux-regressions.log`). These
  include small-phone, 200% text, landscape and dark-mode privacy/feedback cases.
- Flutter analyzer: no issues (`final-analyze-2.log`); final recheck recorded in
  `final-analyze-3.log` (no issues).
- `bash tool/test_native_screen_time.sh`: passed, including free-launch 50-app and
  custom-duration capability plus per-app independence, expiry, migration,
  aggregate switches and cross-process state tests (`final-native-tests.log`).
- iPhoneOS 27.2 SDK type check of purchase manager/shared policy/store: passed
  (`final-purchase-ios-typecheck.log`). Full manager type checking could not
  complete: the local tool environment denied SwiftUI's macro compiler sandbox
  (`final-ios-typecheck.log`). This is not a completed signed/unsigned app build.
- No Go source changed and Go SDK was unavailable here. Backend tests were not
  rerun; older paid-release results are historical evidence only.

Local test runtime: Dart 3.12.2 and this Mac's Flutter SDK. Its resolver selected
matcher 0.12.19, meta 1.18.0, test_api 0.7.11 and vector_math 2.2.0, differing from
the newer versions in the repository lockfile. Those unrelated lockfile changes
were excluded. Nin's release SDK must resolve and run its own required checks;
the local full pass does not establish the newer lockfile/runtime combination.

Logs are local in
`/Users/kelvinm/Documents/Codex/2026-11-06/v/work/app-store-readiness-20261124/`.
Early runs exposed stale fixtures and async SQLite test waits; repaired regressions
and the later full pass supersede those failed/timed-out runs. Skipped tests remain
unverified; do not describe this as device acceptance.

## Independent coordination and findings

Actual agy CLI contributed privacy, support and feedback implementation. Its test
commands timed out; it did not provide a passing test signoff. Root reviewed,
repaired and validated the contribution with the runs above.

Actual Claude CLI performed independent source review and reported no blocking
code defect. Claude did not execute tests in the final review. Its support-contact
release gate remains. Root addressed its privacy IP/session and phrase wording,
feedback delivery/scope copy, password-clear and local-clock observations. Its
reference to five old golden failures came from historical AGENTS baseline text;
that is not the result of the current successful full test run.

Known integration limitation: the retained optional Google translation endpoint
is unofficial and needs provider/terms/reliability review. Per-request consent does
not establish provider approval. No provider acceptance is claimed here.

## Still required before App Store release

1. Nin's verified public support email, operator/business name and public HTTPS
   privacy-policy URL. A routine Zalo question was sent and visibly marked sent;
   no reply or verified configuration is claimed. Host the final policy, configure
   the real links, and verify support delivery. Supply App Store Connect's real
   Support URL, policy URL and accurate privacy answers.
2. Exact signed candidate on the intended Apple team with distribution Family
   Controls permission for Runner and all three extensions. Verify five-minute
   background relock, two separate app timers, custom/per-app times with no login,
   toggle aggregate state and app labels/sheets on the phone.
3. If optional accounts ship, verify actual email delivery, sessions, deletion
   receipt/purge and notebook preservation against the operator's supported
   environment through the documented acceptance procedure. No local automated
   tests should target production services.
4. Capture final signed-build screenshots, finish metadata/review-access details
   and operator-controlled agreements/compliance answers. New billing/product
   setup is deferred for this free first release; preserve earlier-purchase rights
   if configured. See [submission copy and checklist](app-store-submission.md).
