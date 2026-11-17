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
- **Offline-First & Optional Go Backend**: usable without an account or server; Go provides accounts and vocabulary sync. The sync/install rollout gate ships closed. Golang is the only supported backend.

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

### Local Go Backend

Needs Docker with Compose v2+ and `openssl`. From the repository root:

```sh
make backend-env                # Generate local database/HMAC/OTP/outbox keys once
# Complete the email settings described below in the private backend/.env first.
make backend-config             # Validate the selected configuration without printing secrets
make backend-up                 # Build Go, migrate, wait for health
make backend-migrate-status     # Expected: current_version=15 pending=0
make backend-health             # Go /healthz and /readyz
make backend-ps                 # Includes successful one-shot migrator
make run-cloud                  # Launch Flutter against the running Go stack
make backend-logs               # Follow logs; Ctrl-C stops following only
make backend-down               # Stop this stack, preserve PostgreSQL data and local keys
```

`make -C backend backend-up` and the other `backend-*` targets select the same Compose project
and environment. Defaults are project **veea-go** and **backend/.env**, regardless of invocation
directory. Setup never overwrites an existing env file or prints its generated keys.
All host ports bind to `127.0.0.1`: API **18386**, PostgreSQL **54328**, metrics **19090**,
Mailpit inbox **8026**, SMTP **1026**. See [backend setup and email smoke](backend/README.md#local-docker-compose).
Keep the generated keys with the volume. Sync stays disabled; this is local setup, not release approval.

The checked-in local Compose currently selects **Resend** and requires `VEEA_EMAIL_FROM`
and `VEEA_RESEND_API_KEY` in the private env file; the key generator does not supply them.
Mailpit runs, but the API does not send to it in this configuration. For synthetic,
local-only email testing use the SMTP test harness in [backend testing](backend/README.md#commands).
Do not use real delivery credentials for automated verification.

For another local project, pass the same `COMPOSE_PROJECT_NAME` and `COMPOSE_ENV_FILE` to every
command. Relative env paths are always relative to `backend/`; absolute private paths also work.
Port overrides are in [the safe example](backend/.env.example). `APP_PORT=18387` remains a Make
alias for the Go API host port unless `VEEA_GO_HTTP_PORT` is explicitly set. `run-cloud` still
launches Flutter only; start the stack first. It resolves the running Go port automatically,
or accepts an explicit `API_BASE_URL=http://localhost:18387`.

| Command | Behavior |
|---|---|
| `backend-env` | Generate `backend/.env` keys once |
| `backend-up` / `backend-run` | Build/start Go API, migration, PostgreSQL and Mailpit, detached |
| `backend-health` | Check Go `/healthz` and `/readyz` |
| `backend-down` | Stop the selected project and keep its database volume |
| `backend-config` | Validate Compose without printing secrets |
| `backend-logs` / `backend-ps` | Inspect logs and service status |
| `backend-migrate-status` / `backend-url` | Inspect migration status and the running API URL |
| `run-cloud` | Launch Flutter against the running Go API |

The explicit `backend-down-v` command deletes the selected local database volume;
use ordinary `backend-down` to preserve data. Retirement of the previous service
does not convert or delete its Docker volumes, databases or running containers.
Existing private service settings, if present locally during cleanup, are retained
under gitignored `.local/retired-backend/` and are never loaded by Go. Existing account
credentials and sync cursors from that service are incompatible with Go; there is no
automatic data migration. Preserve local notebooks and sign in through the Go email UI.

### Production Docker with Resend

Production orchestration is separate from local development and has **no Mailpit**. It runs
PostgreSQL 17, migration and permission jobs, then the non-root Go API with Resend.
Prepare private settings using [backend production setup](backend/README.md#production-docker-resend-no-mailpit), then run:

```sh
make backend-prod-config
make backend-prod-build
make backend-prod-up
make backend-prod-migrate-status
make backend-prod-health
make backend-prod-ps
make backend-prod-logs
make backend-prod-down  # Preserves database data
```

Root and backend-directory targets use the same production project/env. The database has no
host port; API/metrics bind loopback for an external HTTPS proxy/internal monitoring. Production
uses separate data, credentials and roles; existing local data is preserved. Backup/restore,
independent ledger custody, ingress and release acceptance remain deployment prerequisites.
These commands do not open sync or publish content.

### Run Tests

```bash
# Flutter analysis, unit, widget, and arcade SDK tests
flutter analyze
flutter test

# Go checks, from backend/ (requires the Go SDK version in go.mod)
cd backend
go build ./...
go test ./...
go test -race ./...
make check                      # Formatting, vet and unit tests
# Optional disposable PostgreSQL integration suite (Docker required)
make test-db-up
make test-integration
make test-db-down               # Discards only that disposable test database
```

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!
Feel free to check the [issues page](https://github.com/0xkelvin/Veea-English-Notes/issues) or read [CONTRIBUTING_GAMES.md](CONTRIBUTING_GAMES.md) to add new arcade games.

---

## 📄 License

This project is open source and available under the [MIT License](LICENSE).

## Native iOS Screen Time protection

This first-launch branch uses native Screen Time protection only. Users allow
Screen Time, choose individual apps and review vocabulary to earn access for one
app. An hours/minutes wheel offers 5 minutes–24 hours, with 15 minutes as default.
The five-minute option is a candidate pending a signed-device relock test: short
passes use an ongoing monitoring window of at least 15 minutes that ends at the
real pass expiry. Rejected scheduling never grants access.

Family Controls, a named Managed Settings store and Device Activity handle native
protection. Selection is limited to 50 individual apps; categories and websites
are excluded so each pass unlocks only its selected app. Every Open setup is
hidden and legacy triggers are retired on this branch.

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
App Group `group.com.nintran.veeaEnglishApp`:

- `com.nintran.veeaEnglishApp` — Runner
- `com.nintran.veeaEnglishApp.GateMonitor` — background relocking
- `com.nintran.veeaEnglishApp.GateShieldAction` — challenge handoff
- `com.nintran.veeaEnglishApp.GateShieldConfiguration` — blocked-app screen

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
background/terminated-app relock after 5 and 15 minutes, revoked permission, a renewed
pass surviving an old monitor callback, and turning protection off. Simulator
and unsigned builds do not establish real Screen Time enforcement.


## Temporarily paused home/lock screen widgets

Widget controls, interval selection, tap rotation, and native bridge calls are
paused via `AppConfig.areHomeScreenWidgetsEnabled = false`. Stored widget
preferences are retained. Daily reminders and app-unlock practice remain
independent. The Word of Day widget source is kept for later. Nin’s upstream
update removes its iOS target, and the Android widget receiver registration is
commented out, so updated builds do not offer the widget in the OS widget gallery.

To restore, recreate and embed the iOS widget target, restore the receiver block
in `android/app/src/main/AndroidManifest.xml`, enable the Dart flag and rebuild.
Native widget capabilities/signing must be configured for the chosen Apple
Developer team.

### Optional accounts and feedback

Configured builds use the Go email signup/sign-in, session and account-rights APIs.
The default build stays offline. Vocabulary sync and server cartridge installation
remain behind the closed rollout gate. Feedback remains saved on the device when
no compatible delivery service is available; the Go API has no feedback routes.
The optional Zalo button stays hidden until a valid group link is configured. See
[account and feedback rollout](docs/account-feedback-rollout.md) for current
contracts, local verification and remaining device/deployment checks.

## Team handoff

See [Nin’s implementation handoff](docs/nin-handoff.md) for the combined branch,
Apple signing configuration, completed changes and remaining service setup.

## First-launch candidate

Branch: `feat/first-launch-native-accounts`. Every Open is excluded from this
launch. See [native protection and duration policy](docs/first-launch-native-protection.md),
[account/backend rollout](docs/account-feedback-rollout.md) and
[executed QA and remaining device checks](docs/first-launch-qa.md).

The guided Shortcut implementation remains in Git history/source for later work;
it is not reachable from the first-launch settings or native trigger paths.
