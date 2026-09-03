# 👾 Veea English Notes

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Tests](https://img.shields.io/badge/Tests-173%20Passing-success)](https://github.com)
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
