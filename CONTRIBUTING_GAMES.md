# 🕹️ Building & Contributing Mini-Games to Veea English

Welcome to the **Veea English Arcade SDK**! 

Veea English is designed to make vocabulary learning fun and addictive through 8-bit retro mini-games. We welcome game developers, students, and Flutter enthusiasts to build new mini-games and contribute them to the app.

---

## ⚡ Quick Start: Building Your First Game in 5 Steps

### 1. Explore the Arcade SDK
All arcade contracts, utilities, and components live in `lib/arcade_sdk/`:
```
lib/arcade_sdk/
├── contracts/
│   ├── arcade_game_manifest.dart   # Metadata, author, category, badge
│   ├── arcade_game_context.dart    # Bridge to Vocabulary, TTS audio, Score
│   └── arcade_vocab_word.dart      # Clean word model (word, meaning, IPA)
├── components/
│   ├── arcade_crt_screen.dart      # Scanline shader and HUD overlay
│   ├── arcade_split_controls.dart  # Responsive 2-handed D-pad & action buttons
│   ├── arcade_particles.dart       # 8-bit retro pixel explosion particles
│   └── arcade_falling_badge.dart   # Falling Vietnamese meaning badge animation
└── templates/
    └── starter_template_game.dart  # Complete working reference game
```

---

### 2. Create Your Game Screen
Create a new file in `lib/screens/games/your_game_name.dart`:

```dart
import 'package:flutter/material.dart';
import '../../arcade_sdk/arcade_sdk.dart';

class MyCoolVocabGame extends StatefulWidget {
  const MyCoolVocabGame({super.key, required this.gameContext});

  final ArcadeGameContext gameContext;

  @override
  State<MyCoolVocabGame> createState() => _MyCoolVocabGameState();
}

class _MyCoolVocabGameState extends State<MyCoolVocabGame> {
  late List<ArcadeVocabWord> deck;

  @override
  void initState() {
    super.initState();
    // 1. Fetch player's vocabulary deck
    deck = widget.gameContext.getVocabularyDeck(count: 20);
  }

  void onWordHit(ArcadeVocabWord word) {
    // 2. Play English TTS audio pronunciation
    widget.gameContext.pronounce(word.word);

    // 3. Record score & spaced repetition SRS progress
    widget.gameContext.recordHit(wordId: word.id, scorePoints: 100);
  }

  @override
  Widget build(BuildContext context) {
    return ArcadeCrtScreen(
      scoreText: 'SCORE: 100',
      child: Center(
        child: Text(deck.first.word),
      ),
    );
  }
}
```

---

### 3. Register Your Game Manifest
Open `lib/arcade_sdk/registry/arcade_defaults.dart` and register your game:

```dart
ArcadeRegistry.register(
  ArcadeGameManifest(
    id: 'my_cool_game',
    title: 'MY COOL GAME',
    tagline: 'Defend base by solving vocabulary puzzles.',
    author: '@your_github_username',
    version: '1.0.0',
    glyph: PixelGlyph.gamepad,
    category: ArcadeGameCategory.community,
    badge: 'COMMUNITY',
    builder: (ctx) => MyCoolVocabGame(gameContext: ctx),
  ),
);
```

---

### 4. SDK Pre-Built Components

| Component | Description |
| :--- | :--- |
| `ArcadeCrtScreen` | Retro 8-bit monitor border, HUD score overlay, and scanline shaders. |
| `ArcadeSplitControls` | Ergonomic two-handed controller (`[◀] [▶]` on left, `[FIRE]` on right). |
| `ArcadeParticle` | Retro square explosion particles for target impacts and player defeats. |
| `ArcadeFallingBadgesOverlay` | Animated falling Vietnamese meaning badge with gravity physics. |

---

### 5. Submit Your Pull Request
1. Run `flutter analyze` and `flutter test` to ensure zero errors.
2. Commit your changes: `git commit -m "feat(arcade): add [game_name] by @your_username"`.
3. Open a Pull Request on GitHub. Once reviewed, your game will ship to all Veea English users worldwide!
