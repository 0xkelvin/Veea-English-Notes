import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../services/tts_service.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

enum BattleAction { attack, spell, heal }

class BossData {
  const BossData({
    required this.name,
    required this.title,
    required this.maxHp,
    required this.spriteGlyph,
    required this.level,
  });

  final String name;
  final String title;
  final int maxHp;
  final PixelGlyph spriteGlyph;
  final int level;
}

/// 8-Bit Turn-Based Boss Battle RPG for Vocabulary Mastery.
class BossBattleGame extends StatefulWidget {
  const BossBattleGame({super.key});

  @override
  State<BossBattleGame> createState() => _BossBattleGameState();
}

class _BossBattleGameState extends State<BossBattleGame> {
  static const _bossRoster = [
    BossData(
      name: 'CYBER SLIME',
      title: 'LV.1 FOREST GUARDIAN',
      maxHp: 75,
      spriteGlyph: PixelGlyph.skull,
      level: 1,
    ),
    BossData(
      name: 'SKELETON MAGE',
      title: 'LV.2 CRYPT OVERLORD',
      maxHp: 120,
      spriteGlyph: PixelGlyph.skull,
      level: 2,
    ),
    BossData(
      name: 'VOID DRAGON',
      title: 'LV.3 APEX BEHEMOTH',
      maxHp: 160,
      spriteGlyph: PixelGlyph.skull,
      level: 3,
    ),
  ];

  int _currentBossIndex = 0;
  late int _bossHp;
  int _playerHp = 100;
  int _playerHearts = 3;
  int _score = 0;

  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  VocabularyWord? _currentQuestionWord;
  List<String> _options = [];
  String _combatLog = 'A WILD MONSTER APPEARED!';
  bool _isBossFlashing = false;
  bool _isPlayerFlashing = false;
  bool _isGameOver = false;
  bool _isVictory = false;
  BattleAction _pendingAction = BattleAction.attack;
  bool _showActionSelect = true;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  Future<void> _initGame() async {
    final provider = context.read<VocabularyProvider>();
    var words = await provider.wordsDueForReview(limit: 50);
    if (words.length < 4) {
      words = provider.words;
    }

    if (!mounted) return;
    setState(() {
      _deck = List.of(words)..shuffle();
      _bossHp = _bossRoster[_currentBossIndex].maxHp;
      _isLoading = false;
    });

    _nextTurn();
  }

  BossData get _currentBoss => _bossRoster[_currentBossIndex];

  void _nextTurn() {
    if (_deck.isEmpty) return;
    final random = math.Random();
    final target = _deck[random.nextInt(_deck.length)];

    final distractors = _deck
        .where((w) => w.id != target.id)
        .map((w) => w.meaning)
        .toSet()
        .toList()
      ..shuffle();

    final choices = <String>[target.meaning];
    for (var i = 0; i < 3 && i < distractors.length; i++) {
      choices.add(distractors[i]);
    }
    choices.shuffle();

    setState(() {
      _currentQuestionWord = target;
      _options = choices;
      _showActionSelect = true;
    });
  }

  void _selectAction(BattleAction action) {
    setState(() {
      _pendingAction = action;
      _showActionSelect = false;
      if (action == BattleAction.spell) {
        _combatLog = 'SPELL CAST: LISTEN & TRANSLATE FOR 2X CRIT!';
        if (_currentQuestionWord != null) {
          context.read<TtsService>().speak(_currentQuestionWord!.word);
        }
      } else if (action == BattleAction.heal) {
        _combatLog = 'HEAL SHIELD: ANSWER CORRECTLY TO RESTORE HP!';
      } else {
        _combatLog = 'ATTACK: CHOOSE THE MATCHING MEANING!';
      }
    });
  }

  Future<void> _submitAnswer(String selectedMeaning) async {
    final isCorrect = selectedMeaning == _currentQuestionWord?.meaning;

    if (isCorrect) {
      int damage;
      switch (_pendingAction) {
        case BattleAction.attack:
          damage = 25;
          _combatLog = 'DIRECT HIT! DEALT $damage DMG TO ${_currentBoss.name}!';
          break;
        case BattleAction.spell:
          damage = 50;
          _combatLog = 'CRITICAL SPELL STRIKE! DEALT $damage DMG!';
          break;
        case BattleAction.heal:
          damage = 15;
          _playerHp = math.min(100, _playerHp + 30);
          _combatLog = 'SHIELD RESTORED +30 HP & DEALT $damage DMG!';
          break;
      }

      setState(() {
        _score += damage * 10;
        _bossHp = math.max(0, _bossHp - damage);
        _isBossFlashing = true;
      });

      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (mounted) setState(() => _isBossFlashing = false);

      if (_bossHp <= 0) {
        // Boss Defeated
        if (_currentBossIndex + 1 < _bossRoster.length) {
          setState(() {
            _currentBossIndex++;
            _bossHp = _bossRoster[_currentBossIndex].maxHp;
            _combatLog = '★ ${_currentBoss.name} APPEARS!';
          });
          _nextTurn();
        } else {
          setState(() {
            _isVictory = true;
            _combatLog = '★ ALL DUNGEON BOSSES DEFEATED! ★';
          });
        }
        return;
      }
    } else {
      // Enemy Counter-Attack
      final enemyDmg = 20 + (_currentBoss.level * 5);
      setState(() {
        _playerHp = math.max(0, _playerHp - enemyDmg);
        _combatLog = 'MISS! ${_currentBoss.name} STRIKES BACK FOR $enemyDmg DMG!';
        _isPlayerFlashing = true;
      });

      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (mounted) setState(() => _isPlayerFlashing = false);

      if (_playerHp <= 0) {
        setState(() {
          _playerHearts--;
          if (_playerHearts > 0) {
            _playerHp = 100;
            _combatLog = 'HEART LOST! RESPAWNED WITH FULL HEALTH.';
          } else {
            _isGameOver = true;
            _combatLog = 'DEFEATED! GAME OVER.';
            return;
          }
        });
      }
    }

    _nextTurn();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context),
            Expanded(
              child: _isLoading
                  ? const Center(child: Text('SUMMONING MONSTERS…'))
                  : _isVictory
                  ? _buildVictoryScreen(context)
                  : _isGameOver
                  ? _buildGameOverScreen(context)
                  : _buildBattleArena(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space4,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(color: palette.border, width: PixelMetrics.border),
        ),
      ),
      child: Row(
        children: [
          PixelIconButton(
            glyph: PixelGlyph.arrowLeft,
            semanticLabel: 'Flee Dungeon',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('DUNGEON RPG', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          // Hearts display
          Row(
            children: List.generate(3, (i) {
              final isFilled = i < _playerHearts;
              return Padding(
                padding: const EdgeInsets.only(right: 3),
                child: PixelIcon(
                  PixelGlyph.heart,
                  color: isFilled ? palette.danger : palette.inkFaint,
                  scale: 2,
                ),
              );
            }),
          ),
          const SizedBox(width: PixelMetrics.space3),
          Text(
            'SCORE: $_score',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBattleArena(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);
    final boss = _currentBoss;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(PixelMetrics.space4),
      child: Column(
        children: [
          // Boss Box
          PixelBox(
            raised: true,
            color: _isBossFlashing ? palette.danger : palette.surface,
            padding: const EdgeInsets.all(PixelMetrics.space4),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(
                      boss.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(boss.title, style: theme.textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: PixelMetrics.space2),
                // Boss HP Bar
                Row(
                  children: [
                    Text('HP ', style: theme.textTheme.labelSmall),
                    Expanded(
                      child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          color: palette.paper,
                          border: Border.all(color: palette.border, width: 1),
                        ),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: (_bossHp / boss.maxHp).clamp(0.0, 1.0),
                          child: Container(color: palette.danger),
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$_bossHp/${boss.maxHp}',
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: palette.danger,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: PixelMetrics.space4),
                // 8-bit Boss Avatar
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: palette.paper,
                    border: Border.all(color: palette.border, width: PixelMetrics.border),
                  ),
                  child: Center(
                    child: PixelIcon(
                      boss.spriteGlyph,
                      color: palette.danger,
                      scale: 4,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Player Status Bar
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: PixelMetrics.space3,
              vertical: PixelMetrics.space2,
            ),
            decoration: BoxDecoration(
              color: _isPlayerFlashing ? palette.danger : palette.surface,
              border: Border.all(color: palette.border, width: PixelMetrics.border),
            ),
            child: Row(
              children: [
                Text(
                  'HERO HP',
                  style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    height: 10,
                    decoration: BoxDecoration(
                      color: palette.paper,
                      border: Border.all(color: palette.border, width: 1),
                    ),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (_playerHp / 100).clamp(0.0, 1.0),
                      child: Container(color: palette.accent),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$_playerHp/100',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: palette.accent,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: PixelMetrics.space3),

          // Retro Dialogue / Combat Log Box
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(PixelMetrics.space3),
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.border, width: PixelMetrics.border),
            ),
            child: Text(
              _combatLog,
              style: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: palette.ink,
              ),
              textAlign: TextAlign.center,
            ),
          ),

          const SizedBox(height: PixelMetrics.space4),

          // Action Menu vs Word Question Menu
          if (_showActionSelect) ...[
            Text('SELECT COMBAT ACTION:', style: theme.textTheme.labelSmall),
            const SizedBox(height: PixelMetrics.space2),
            Row(
              children: [
                Expanded(
                  child: PixelButton(
                    label: 'Attack (25D)',
                    glyph: PixelGlyph.sword,
                    filled: true,
                    onPressed: () => _selectAction(BattleAction.attack),
                  ),
                ),
                const SizedBox(width: PixelMetrics.space2),
                Expanded(
                  child: PixelButton(
                    label: 'Spell (50D)',
                    glyph: PixelGlyph.bolt,
                    filled: true,
                    onPressed: () => _selectAction(BattleAction.spell),
                  ),
                ),
              ],
            ),
            const SizedBox(height: PixelMetrics.space2),
            PixelButton(
              label: 'Heal Shield (+30 HP)',
              glyph: PixelGlyph.shield,
              expand: true,
              onPressed: () => _selectAction(BattleAction.heal),
            ),
          ] else ...[
            // Prompt Card
            if (_currentQuestionWord != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(PixelMetrics.space3),
                decoration: BoxDecoration(
                  color: palette.surface,
                  border: Border.all(color: palette.border, width: PixelMetrics.border),
                ),
                child: Column(
                  children: [
                    Text(
                      _currentQuestionWord!.word,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontFamily: 'Handjet',
                        fontWeight: FontWeight.bold,
                        fontSize: 32,
                      ),
                    ),
                    Text(
                      _currentQuestionWord!.pronunciation ?? '',
                      style: theme.textTheme.labelSmall?.copyWith(color: palette.accent),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: PixelMetrics.space3),
              // 4 Choice Buttons
              for (final opt in _options) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: PixelMetrics.space2),
                  child: PixelButton(
                    label: opt,
                    expand: true,
                    onPressed: () => _submitAnswer(opt),
                  ),
                ),
              ],
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildVictoryScreen(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space5),
        child: PixelBox(
          raised: true,
          padding: const EdgeInsets.all(PixelMetrics.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '★ DUNGEON CONQUERED! ★',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.accent,
                  fontFamily: 'Handjet',
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: PixelMetrics.space4),
              Text(
                'FINAL SCORE: $_score',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: 'Play Again',
                glyph: PixelGlyph.sword,
                filled: true,
                expand: true,
                onPressed: () {
                  setState(() {
                    _currentBossIndex = 0;
                    _playerHp = 100;
                    _playerHearts = 3;
                    _score = 0;
                    _isVictory = false;
                    _isGameOver = false;
                    _initGame();
                  });
                },
              ),
              const SizedBox(height: PixelMetrics.space2),
              PixelButton(
                label: 'Exit Arcade',
                expand: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGameOverScreen(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PixelMetrics.space5),
        child: PixelBox(
          raised: true,
          padding: const EdgeInsets.all(PixelMetrics.space5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '☠ GAME OVER ☠',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.danger,
                  fontFamily: 'Handjet',
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: PixelMetrics.space4),
              Text(
                'FINAL SCORE: $_score',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: 'Try Again',
                glyph: PixelGlyph.sword,
                filled: true,
                expand: true,
                onPressed: () {
                  setState(() {
                    _currentBossIndex = 0;
                    _playerHp = 100;
                    _playerHearts = 3;
                    _score = 0;
                    _isVictory = false;
                    _isGameOver = false;
                    _initGame();
                  });
                },
              ),
              const SizedBox(height: PixelMetrics.space2),
              PixelButton(
                label: 'Exit Arcade',
                expand: true,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
