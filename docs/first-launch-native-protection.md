# First launch: native timed protection

Initial launch work: `feat/first-launch-native-accounts` (merged in PR #38).
Per-app management: `feat/per-app-unlock-times`, based on `origin/main` at `2369f61`.

## Product flow

Learning works without an account. Save vocabulary → Settings → Manage Apps to
Lock → Add Apps → allow Screen Time → choose individual apps → turn locking on.
A shielded app offers a vocabulary challenge. Completing the configured practice
round earns access **for that app only**. iOS relocks it at the scheduled end.
Return using Apple's top-left app return link, or Home / the app switcher.
Veea does not claim it can automatically launch opaque FamilyControls app tokens.

Access duration uses separate hours and minutes wheels, with explicit Save and
Cancel. Default: 15 minutes. Launch range: **5 minutes–24 hours**, whole minutes.
The zero-hour minute wheel starts at 5; at 24 hours only zero minutes is offered.
Saving changes the next pass duration; existing earned passes retain their end.
Native code validates the same range, independently of Flutter.

## Default and per-app unlock times

Manage Apps to Lock lists the selected apps with Apple's private native app
name/icon renderer. A default unlock time applies to apps without a custom rule;
each app card shows either `Default · 5 min` or its explicit override. Tapping
Unlock time opens Use default, 5/15/30-minute choices, and Custom time, which
opens the hours/minutes wheel. Cancellation leaves the saved rule unchanged.

An explicit override stays custom even if it equals the current default. Later
default edits affect inheriting apps only. Changes apply to future grants;
existing earned passes keep their original expiry. The native grant coordinator
resolves the selected app's rule from its persisted state, independently of
Flutter's display or channel arguments. Each app retains its own pass and
monitor; one app's expiry does not revoke another app's unexpired pass.

Removing an app is confirmed first, clears its rule/pass/pending challenge,
stops its monitor and removes its shield. The last removal turns locking off.
Changing selection through Apple's picker also prunes removed apps' rules and
passes, while retaining IDs/settings for apps that stay selected. Old state
JSON without per-app rules inherits the saved default and preserves passes.
App names and tokens are not exported to Flutter; the platform label receives
only Veea's app ID. The native renderer and its VoiceOver output still require
verification on a production-signed phone.

Apple documents **15 minutes minimum and one week maximum for DeviceActivity
monitoring intervals**. These constrain our interval-end relock implementation;
they are not a blanket minimum for every Screen Time unlock design. Passes below
15 minutes use an already-ongoing 15-minute monitoring window whose end is the
actual pass expiry (e.g. 10 minutes before now → 5 minutes after now). Apple
explicitly documents starting monitoring during an ongoing interval. This is a
candidate implementation: actual five-minute schedule acceptance and relocking
must be confirmed on a signed physical device before release. A rejected
schedule does not grant access. The 24-hour
maximum is a Veea product choice, below Apple's maximum.

- [intervalTooShort](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/monitoringerror/intervaltooshort)
- [intervalTooLong](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/monitoringerror/intervaltoolong)
- [startMonitoring](https://developer.apple.com/documentation/deviceactivity/deviceactivitycenter/startmonitoring(_:during:events:))

## Settings overview and lock switches

Settings shows an **App locks** section with Enable locks, a switch for each
selected app, and Manage Apps to Lock (Add, remove, and set unlock times).
The management link opens the existing selection/duration page. With no selected
apps, Settings shows No locks yet and disables the master switch; management
remains available to add apps. Vocabulary/build/permission prerequisites still
apply, and errors appear in a visible SnackBar.

An individual OFF pauses locking without removing the app or its time override.
It removes that app's active pass/pending challenge, unshields it and stops its
monitor. The native grant coordinator checks this preference both before
scheduling and under the write lock, so an app paused during a grant cannot gain
a new pass. Late callbacks recompute shields and exclude paused apps. Turning
the app back on starts it locked; completed vocabulary steps are deliberately
retained so the next challenge can continue its unfinished round.

Master OFF stops all locking and earned passes while retaining app selections,
time rules and individual choices. Disabled per-app switches continue to display
their saved choices, with a hint that they apply when Enable locks is on. Master
ON restores those choices. Older JSON without individual preferences treats all
selected apps as enabled. Removing/reselecting apps prunes obsolete paused IDs.

## Every Open is inactive on this branch

- No mode selector, Shortcut installer, import links, legacy settings, app-name
  scanner, or Every Open option in the production settings route.
- No environment flag or preview argument can re-enable the old settings UI.
- On startup, persisted legacy enabled/zero-duration config is retired while
  vocabulary, learning rules and the native Screen Time state are preserved.
- Dart ignores non-native incoming gate events and pending targets. The root
  navigation accepts native targets only.
- iOS consumes retired gate URLs without creating challenges or invoking external
  callbacks. Legacy method-channel handlers cannot enable checks, grant legacy
  passes, import/test automations or launch another app.
- The existing Check Veea Gate intent is retained only as a hidden, always-false
  compatibility action for pre-launch testers. No AppShortcutsProvider is
  registered. Older manually installed automations may still need removal in
  Apple's Shortcuts app; Veea cannot delete a user's automation.
- Android's pre-launch accessibility service is unregistered. Its platform bridge
  retires stored interception settings and reports Screen Time unavailable.
  Notebook and review functionality remain usable.

Historical Shortcut source/tests remain for the later Every Open work, but are
not routed from the launch UI. The implementation on `main` is preserved by Git;
this branch is the distinct first-launch candidate.

## Validation and limits

Tests cover wheel save/cancel, duration bounds, small-screen large text, retired
incoming events, upgrade preservation, duration persistence and existing-pass
preservation. Portable Swift tests cover native policy, scheduling failure,
24-hour cross-midnight expiry, persistence and process-safe state updates.

A production-signed iPhone/TestFlight build is still required to validate Apple's
Screen Time permission UI, actual shielding, return breadcrumb and elapsed-time
relocking on a device. Unsigned builds and platform-channel mocks cannot prove
those system behaviors. Account implementation and backend rollout are documented
separately in `account-feedback-rollout.md`.
