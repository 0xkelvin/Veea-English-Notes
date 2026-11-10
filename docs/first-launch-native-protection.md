# First launch: native timed protection

Branch: `feat/first-launch-native-accounts`, based on `origin/main` at `b43de0f`.

## Product flow

Learning works without an account. Save vocabulary → App protection → choose an
access duration → allow Screen Time → choose individual apps → turn protection on.
A shielded app offers a vocabulary challenge. Completing the configured practice
round earns access **for that app only**. iOS relocks it at the scheduled end.
Return using Apple's top-left app return link, or Home / the app switcher.
Veea does not claim it can automatically launch opaque FamilyControls app tokens.

Access duration uses separate hours and minutes wheels, with explicit Save and
Cancel. Default: 15 minutes. Launch range: **5 minutes–24 hours**, whole minutes.
The zero-hour minute wheel starts at 5; at 24 hours only zero minutes is offered.
Saving changes the next pass duration; existing earned passes retain their end.
Native code validates the same range, independently of Flutter.

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
