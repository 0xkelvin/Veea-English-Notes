# Veea English Notes

A notebook for the English words you run into during an ordinary day — in a
meeting, a PR review, a podcast — with what they mean, how they sound, and
where you met them.

The interface is deliberately plain: a pixel typeface, hard 2px borders, square
corners, two colours and no animation. Nothing on screen competes with the
words themselves.

## How it works

- **A day at a time.** The home screen is one day's words. Arrows move between
  days; the label opens a picker.
- **Search reaches everything.** Any word, meaning, example sentence, source or
  tag, from any day. Accents are optional — `kien cuong` finds `kiên cường`.
- **Local first.** Everything is written to SQLite on the device and works with
  no account and no network. Signing in only adds sync between devices.

## Running it

```bash
flutter pub get
flutter run
```

To build against the cloud service in `cloud/`:

```bash
flutter run --dart-define=VEEA_API_BASE_URL=http://localhost:8080
```

With no `VEEA_API_BASE_URL` the app is entirely local and the account screen
says so.

## Checks

```bash
flutter analyze
flutter test                      # unit, widget and golden tests
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

**Writes are not optimistic.** Every mutation writes to SQLite and then re-reads
the affected view, so the screen can never show a word that failed to save.
