# 👾 Veea English Notes

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Tests](https://img.shields.io/badge/Tests-256%20Passing-success)](https://github.com)
[![PRs Welcome](https://img.shields.io/badge/PRs-Welcome-brightgreen.svg)](CONTRIBUTING_GAMES.md)

**A minimalist 8-bit retro vocabulary journal and arcade gaming center for English learners.**

</div>

---

## 🌟 What is Veea English Notes?

Veea English Notes is a fast, offline-first personal notebook for capturing words you encounter during your day — in a meeting, a PR review, a podcast, or a book — complete with IPA pronunciation, Vietnamese definitions, example sentences, active streak tracking, and retro 8-bit mini-games.

---

## 🕹️ 8-Bit Retro Arcade Center

Practice your captured vocabulary through classic arcade games with 8-bit CRT scanlines, pixel explosion effects, TTS audio pronunciation, and falling Vietnamese meaning badges:

1. ⚡ **Word Rush 60s**: Rapid-fire definition matching against the clock with combo multipliers.
2. 🐍 **Vocab Snake**: Slither around the retro grid and devour matching vocabulary pellets.
3. 👾 **Vocab Invaders**: Galaga/Space-Invaders shooter — blast descending alien UFOs carrying the matching terms.
4. 💀 **Pixel Typer**: Typing-of-the-Dead recall drill — Vietnamese meanings descend and you *type* the English word from memory before it breaches the line.

---

## 🛠️ Build Your Own Games: The Veea Arcade SDK

Veea English is open source and extensible! Anyone can build and contribute a custom mini-game in pure Dart & Flutter using our **Arcade SDK**:

* 📄 **Developer Guide**: [CONTRIBUTING_GAMES.md](CONTRIBUTING_GAMES.md)
* 🚀 **Starter Template**: [`lib/arcade_sdk/templates/starter_template_game.dart`](lib/arcade_sdk/templates/starter_template_game.dart)
* 📦 **SDK Components**: `ArcadeCrtScreen`, `ArcadeSplitControls`, `ArcadeParticle`, `ArcadeFallingBadgesOverlay`, `ArcadeRegistry`.

---

## 📱 Key Features

- **Daily Vocabulary Journal**: Organised a day at a time with streak tracking, part of speech tags, context sentences, and source notes.
- **Interactive Homepage Widget**: Word of the Day widget right on your homepage — tap to hear natural TTS pronunciation and rotate words.
- **Native iOS & Android Widgets**: WidgetKit & AppWidget integration with in-place rotation right on your phone's Home Screen & Lock Screen.
- **Spaced Repetition System (SRS)**: SuperMemo (SM-2) review algorithm to ensure long-term retention.
- **Automatic IPA Pronunciation & Offline Dictionary**: Bundled 126,000-word offline dictionary with text-to-speech audio reading.
- **Unicode Diacritic-Insensitive Search**: Fast SQLite search folding Vietnamese diacritics (e.g. typing `kien cuong` finds `kiên cường`).
- **6 Retro Pixel Themes**: *Paper Light, Night Dark, GameBoy Matrix Green, Cyberpunk Neon, OLED True Black, System Default*.
- **Offline-First & Optional Cloud Sync**: 100% usable without an internet connection; optional cloud sync across devices backed by Rust microservice.

---

## 🚀 Getting Started

### Prerequisites
* [Flutter SDK](https://flutter.dev/docs/get-started/install) (v3.22+)
* Xcode (for iOS Simulator / device testing)
* Android Studio (for Android Emulator / device testing)

### Run the App Locally (Offline Mode)

```bash
# Clone the repository
git clone https://github.com/0xkelvin/Veea-English-Notes.git
cd Veea-English-Notes

# Install Flutter dependencies
flutter pub get

# Run on simulator or connected device
flutter run
```

### Run Tests

```bash
# Run unit, widget, and arcade SDK test suite (173 tests)
flutter test
```

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!
Feel free to check the [issues page](https://github.com/0xkelvin/Veea-English-Notes/issues) or read [CONTRIBUTING_GAMES.md](CONTRIBUTING_GAMES.md) to add new arcade games.

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

## Native iOS Screen Time protection

Native protection lets a user authorize Screen Time, choose individual apps,
and earn a 15- or 30-minute pass by completing vocabulary challenges. It uses
Family Controls, a named Managed Settings store, and Device Activity monitoring.
Selection is limited to 50 apps. Categories and websites are intentionally excluded so each earned pass unlocks
only its selected app. Five-minute and Every Open passes remain in Shortcut mode.
Existing Veea Shortcut checks pause while native protection is enabled.

The **Learning rules** shortcut near the top of Settings opens the practice
word selection, unlock count, and pronunciation preferences. **Edit practice
words** opens one searchable checklist, with an optional **Any date** calendar
filter. Search, the date filter, and the scoped select-all checkbox remain visible
while the lazy word list scrolls. The calendar enables only dates with saved
words and provides previous/next saved-day arrows; clearing the date shows the
whole notebook again. Choices persist across dates and searches, and filtered
views show selected counts here and elsewhere.

The master checkbox changes only the visible words. **Selection options** keeps
**Select entire notebook** and **Clear entire selection** separate from filtered
selection. The total selected count stays visible, **Save** commits the draft,
and **Cancel** discards it. When every notebook word is checked, **Include new
words automatically** controls whether future saved words join practice.
Existing automatic-all and explicit-all preferences are preserved, including
when words are temporarily unchecked and rechecked before saving. Learning
rules also previews up to three selected words with their saved dates. **View all
selected words** opens the complete saved pool grouped by date, with search over
words, meanings, tags, and dates. It excludes unselected/deleted words and has
an **Edit** action that returns to the full notebook picker; viewing/searching
never changes selection, learning history, or word rotation.
The count accepts any positive number up to the current pool size. Removing
selected words reduces the count when needed and never silently switches a
custom pool to the whole notebook.

Completed words rotate through the selected pool before repeating, including
across app switches and restarts. Learning priority breaks ties among words that
have not been practiced. Failed unlock grants and preview challenges do not
advance rotation. Schema version 9 stores completion order separately and seeds
it from existing review dates without changing vocabulary or learning history.
The count accepts any positive number up to the current pool size. Removing
selected words reduces the count when needed and never silently switches a
custom pool to the whole notebook.

Automatic pronunciation defaults to off; manual **Hear it** remains available.
The optional daily notebook goal never blocks app access. Schema version 8
converts the previous daily-capture requirement into that nonblocking goal and
preserves existing vocabulary, history, and app protection settings.

Completed steps are saved per app in SQLite and survive closing or restarting
Veea. Saving a step and its learning credit is one transaction. The final correct
answer is saved separately until access can be granted, preserving its original
hint grade across retries. Changing the pool retains eligible completed work.
The practice challenge never grants/revokes access, launches apps, or updates
learning history, and can be tried before enabling protection.

Restoring Screen Time authorization retains selected apps. Active native pass
expiry comes from iOS, including after restart; the on-screen countdown only
updates the UI. Switching to another protected app updates the current challenge
instead of dropping the event or stacking duplicate gates. A monitoring failure
retains earlier completed words, and a history-write failure after a successful
grant reports that access is unlocked rather than making the user earn it twice.

On iOS 26.5 and newer, the shield's **Learn in Veea** button opens the app and
routes to that app's challenge. On older supported iOS versions (16+), open Veea
manually or use **Protected apps → Learn to unlock**. After earning native access,
return to the protected app using the app switcher. Monitoring callbacks are
system-managed and occur when the device is used; expiry is also reconciled when
Veea resumes. No main-app timer is used for relocking.
If iOS rejects a new monitoring schedule (including its concurrent-monitor limit),
the app stays protected and the challenge reports the error without recording a
successful unlock. Completed monitors are cleaned up when Veea resumes.

### Signing and distribution

A paid Apple Developer Program team is required to sign the native build.
The main app and all three Screen Time extensions need Family Controls and the
App Group `group.com.veea.veeaRewind.screentime`:

- `com.veea.veeaRewind` — Runner
- `com.veea.veeaRewind.GateMonitor` — background relocking
- `com.veea.veeaRewind.GateShieldAction` — challenge handoff
- `com.veea.veeaRewind.GateShieldConfiguration` — blocked-app screen

Enable these capabilities for the four App IDs, select the paid team on the four
targets, and regenerate their development profiles. TestFlight/App Store builds
also require Apple's Family Controls distribution approval for each target.
A personal development profile cannot activate these capabilities. The unsigned
build can be checked with `flutter build ios --release --no-codesign`; it cannot
be installed as a working native-protection build without appropriate signing.

### Verification

Run `bash tool/test_native_screen_time.sh` for policy, persistence, handoff,
scheduling-failure, stale-callback, and cross-process locking checks. Run
`flutter test` for Flutter setup and challenge regression tests.

Before distribution, test the signed build on a real device: permission denial,
app selection/cancellation, app A remaining locked when app B earns access,
background/terminated-app relock after 15 minutes, revoked permission, a renewed
pass surviving an old monitor callback, and turning protection off. Simulator
and unsigned builds do not establish real Screen Time enforcement.


## Temporarily paused home/lock screen widgets

Widget controls, interval selection, tap rotation, and native bridge calls are
paused via `AppConfig.areHomeScreenWidgetsEnabled = false`. Stored widget
preferences are retained. Daily reminders and app-unlock practice remain
independent. The Word of Day widget source and target are kept for later, but
the widget extension embedding/dependency entries in the Runner target and the
Android widget receiver registration are commented out, so updated builds do
not offer the widget in the OS widget gallery.

To restore, uncomment both marked entries in `ios/Runner.xcodeproj/project.pbxproj`
and the receiver block in `android/app/src/main/AndroidManifest.xml`, then enable
the Dart flag and rebuild. Native widget capabilities/signing must be configured
for the chosen Apple Developer team.

### Accounts and feedback (prepared; service connection pending)

Phone OTP account screens, separate local account notebooks, safer word sync,
and an offline feedback outbox are implemented. The default build stays local
until Nin's existing API and OTP service are connected. The optional Zalo button
is hidden until a Veea group link is configured. See
[account and feedback rollout](docs/account-feedback-rollout.md) for the user flow,
server setup, desktop data contract and remaining integration checks.
