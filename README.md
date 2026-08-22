# Veea English Notes

A notebook for the English words you run into during an ordinary day — in a
meeting, a PR review, a podcast — with what they mean, how they sound, and
where you met them.

The interface is deliberately plain: a pixel typeface, hard 2px borders, square
corners, two colours and no animation. Nothing on screen competes with the
words themselves.

## Key Features (Implemented)

- **Daily Vocabulary Journal**: Organised a day at a time with streak tracking, part of speech tags, context sentences, and source notes.
- **Automatic IPA Pronunciation & TTS**: Instant offline IPA transcription from a bundled 126k-entry dictionary plus text-to-speech audio reading.
- **Unicode Diacritic-Insensitive Search**: Fast SQLite search folding Vietnamese diacritics so typing `kien cuong` finds `kiên cường`.
- **Expanded Retro Pixel Themes**: Choose between 6 retro pixel palettes (*Paper Light, Night Dark, GameBoy Matrix Green, Cyberpunk Neon, OLED True Black, System Default*).
- **Native "Word of the Day" Widgets**: iOS WidgetKit & Android AppWidget integration displaying daily review words, streak count, and IPA transcriptions right on your Home Screen & Lock Screen.
- **Widget & Notification Toggles**: User controls in Settings to enable or disable home screen widgets and daily notifications at any time.
- **Offline-First & Cloud Sync**: Completely usable offline with local SQLite database; optional cloud sync across devices backed by a production Rust microservice.
- **Account & Data Control**: Register with email or phone, change credentials, export every word as formatted JSON, or delete your account.
- **Store Ready**: Includes Apple Privacy Manifest (`PrivacyInfo.xcprivacy`), Android permissions, and full visual test suite.

## Next Planned Features (Roadmap)

- 🎯 **Spaced Repetition System (SRS) Review Mode**: Interactive flashcard review mode powered by the SuperMemo (SM-2) algorithm to optimize long-term word retention.
- 🎙️ **Voice Recording & Speaking Practice**: Record your own voice pronouncing words and compare audio waveforms side-by-side with TTS.
- 📦 **Expanded Data Import & Export**: Export journal entries into Anki decks (`.apkg`), CSV, and Markdown files.
- 🔔 **Local Scheduled Recall Notifications**: Configurable daily push reminders to log new words and maintain active learning streaks.
- 📊 **Learning Analytics & Progress Charts**: Visual pixel-art charts tracking weekly retention and total vocabulary growth over time.

## Running it

A `Makefile` at the root wraps the commands below — `make help` lists every
target. Plain `flutter`/`cargo`/`docker` also work directly if you'd rather
skip it.

Local-only — no backend, no account, everything on the device:

```bash
make run
```

### With the backend

Two terminals. First the server and its infrastructure:

```bash
make backend-up    # postgres, redis, nats — creates cloud/.env first time
make backend-run   # migrations run automatically on startup
```

Check it came up:

```bash
make backend-health
# {"status":"healthy","checks":{"database":"up","redis":"up"}}
```

Then the app, pointed at it:

```bash
make run-cloud
```

Open the cloud button in the top bar, create an account with either an email or
a phone number, and add a word — it uploads on the next sync.

**Port already in use?** Point both sides at another port:

```bash
make backend-run APP_PORT=8081
make run-cloud APP_PORT=8081
```

**On the Android emulator**, `localhost` is the emulator itself, so
`make run-cloud` won't reach it — build the URL by hand with `10.0.2.2`, which
is how the emulator reaches the host machine:

```bash
flutter run --dart-define=VEEA_API_BASE_URL=http://10.0.2.2:18386
```

**On a physical device**, use your machine's LAN address the same way
(`ipconfig getifaddr en0` on macOS), e.g. `http://192.168.1.20:18386`, with both
on the same network.

Cleartext HTTP to a local address is allowed on both platforms for development:
iOS via a localhost-scoped ATS exception in `ios/Runner/Info.plist`, Android via
a network security config under `android/app/src/debug/`, which is not merged
into release builds. Neither opens up arbitrary HTTP.

### Tearing down

```bash
make backend-down      # keep the data
make backend-down-v    # wipe the database too
```

With no `VEEA_API_BASE_URL` the app is entirely local and the account screen
says so.

## Checks

```bash
make check                        # flutter analyze + flutter test
flutter test --update-goldens     # after an intentional visual change
```

Golden files live in `test/golden/` and render whole screens in both themes.
They exist mainly to catch a regression in Vietnamese diacritics, which is the
easiest thing to break here.

## Layout

```
lib/
  core/
    config/       build-time configuration (API base URL)
    theme/        palette, metrics and the pixel theme
  data/
    local/        SQLite schema, migrations, repository
    remote/       HTTP transport, auth and vocabulary endpoints
  models/         entities and text normalisation
  providers/      ChangeNotifiers the UI listens to
  screens/        home, editor, search, account
  services/       text-to-speech, sync engine
  widgets/
    pixel/        the design-system primitives
cloud/            Rust backend (see cloud/README.md)
```

## Notes on a few decisions

**The typeface is Handjet.** Of the pixel families on Google Fonts, only Handjet
and VT323 carry the full set of 134 Vietnamese precomposed characters. Press
Start 2P — the obvious "8-bit" choice — is missing 94 of them and renders
`kiên cường` as `kiên c▯▯ng`. Handjet is bundled as a 148KB subset rather than
fetched at runtime, so the app renders correctly offline and on first launch.

**IPA falls back to a system font.** No pixel font covers the IPA block, so a
transcription like `/rɪˈzɪliənt/` would otherwise be empty boxes. Only the
characters Handjet lacks fall through; everything else stays pixels.

**Icons are painted, not fonts.** Material's icon set is anti-aliased vector art
and looks smooth and modern beside a pixel typeface, so the icons here are 7×7
bitmaps drawn square by square with anti-aliasing off.

**Search has its own column.** SQLite's `LIKE` and `lower()` only fold ASCII, so
`Kiên` would never match `kiên`. A normalised, diacritic-folded haystack is
computed in Dart — whose `toLowerCase` is Unicode-aware — and stored alongside
each row.

**Deletes are soft.** A hard delete would be undone by the next device to sync,
which still holds the word and would upload it again. Tombstones are kept until
the server acknowledges them, which also makes undo a real restore.

**Pronunciation is looked up, not typed.** Every character in an IPA
transcription is off a phone keyboard, so a field asking for one stays empty on
every word forever. A 126k-entry dictionary ships with the app — 802KB gzipped,
General American, derived from CMUdict — and is queried locally, because
capturing a word usually happens mid-conversation and waiting on a network (or
failing without one) defeats the point. The free dictionary APIs were also
unreliable: `dictionaryapi.dev` returns no phonetic text at all for `resilient`.

The dictionary lives in SQLite rather than a Dart `Map`: 126k entries in memory
costs tens of megabytes, an indexed table costs almost nothing and answers in
microseconds. Import takes under a second on a phone and runs behind the first
frame. Regenerate the asset with `tool/build_pronunciation_dictionary.py`.

Unknown words say so rather than showing a blank line, and an override is there
for the rare case the dictionary is wrong — but it is a dialog, not a field, so
it never competes with the word and its meaning.

**Writes are not optimistic.** Every mutation writes to SQLite and then re-reads
the affected view, so the screen can never show a word that failed to save.

**Deleting the account wipes the device second, not first.** The local database
is cleared only once the server confirms the deletion. Wiping first would
destroy the user's words on a failed request, and those words are the whole
point of the app.

**A wrong password is not a dead session.** The server answers a failed password
confirmation with 403 `INVALID_PASSWORD` rather than 401. The transport treats
401 as "refresh the token, then sign out if that fails", so without the
distinction a single typo in the delete dialog would log the user out.

**Identifier parsing is duplicated on purpose.** `AccountIdentifier` mirrors the
server's `Identifier` and `PhoneNumber` rules so the form can label itself and
reject obvious mistakes offline. The server still re-validates everything; if
one side's rules change, the other has to change with it.
