import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/pixel_metrics.dart';
import '../../core/theme/pixel_palette.dart';
import '../../models/vocabulary_word.dart';
import '../../providers/vocabulary_provider.dart';
import '../../widgets/pixel/pixel_box.dart';
import '../../widgets/pixel/pixel_button.dart';
import '../../widgets/pixel/pixel_icon.dart';

class FallingBlock {
  FallingBlock({
    required this.word,
    required this.targetCol,
    required this.currentCol,
    required this.y,
  });

  final String word;
  final int targetCol; // 0, 1, or 2
  int currentCol;
  double y; // 0.0 to 1.0
}

/// 8-Bit Tetris / Word Stacker Puzzle Game for Vocabulary Practice.
class WordStackerGame extends StatefulWidget {
  const WordStackerGame({super.key});

  @override
  State<WordStackerGame> createState() => _WordStackerGameState();
}

class _WordStackerGameState extends State<WordStackerGame> {
  final FocusNode _focusNode = FocusNode();
  List<VocabularyWord> _deck = [];
  bool _isLoading = true;

  Timer? _gameLoop;
  List<VocabularyWord> _activeColumns = []; // 3 target words corresponding to 3 bottom columns
  List<List<String>> _stackedBlocks = [[], [], []]; // stack of blocks in each column
  FallingBlock? _fallingBlock;

  int _score = 0;
  int _linesCleared = 0;
  int _combo = 1;
  bool _isGameOver = false;

  @override
  void initState() {
    super.initState();
    _initGame();
  }

  @override
  void dispose() {
    _gameLoop?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _initGame() async {
    final provider = context.read<VocabularyProvider>();
    var words = await provider.wordsDueForReview(limit: 50);
    if (words.length < 3) words = provider.words;

    if (!mounted) return;
    setState(() {
      _deck = List.of(words)..shuffle();
      _isLoading = false;
      _score = 0;
      _linesCleared = 0;
      _combo = 1;
      _isGameOver = false;
      _stackedBlocks = [[], [], []];
    });

    _refreshColumnsAndSpawn();
    _startGameLoop();
  }

  void _startGameLoop() {
    _gameLoop?.cancel();
    _gameLoop = Timer.periodic(const Duration(milliseconds: 60), (_) {
      _tick();
    });
  }

  void _refreshColumnsAndSpawn() {
    if (_deck.length < 3) return;
    _deck.shuffle();
    final columns = _deck.take(3).toList();
    setState(() {
      _activeColumns = columns;
    });
    _spawnBlock();
  }

  void _spawnBlock() {
    if (_activeColumns.isEmpty) return;
    final random = Random();
    final colIdx = random.nextInt(3);
    final targetWord = _activeColumns[colIdx];

    setState(() {
      _fallingBlock = FallingBlock(
        word: targetWord.word,
        targetCol: colIdx,
        currentCol: 1, // spawn in middle column
        y: 0.05,
      );
    });
  }

  void _moveBlock(int dCol) {
    if (_fallingBlock == null || _isGameOver) return;
    setState(() {
      _fallingBlock!.currentCol = (_fallingBlock!.currentCol + dCol).clamp(0, 2);
    });
  }

  void _hardDrop() {
    if (_fallingBlock == null || _isGameOver) return;
    _resolveDrop();
  }

  void _tick() {
    if (_isGameOver || _fallingBlock == null) return;

    _fallingBlock!.y += 0.018;

    // Check if reached stack height
    final col = _fallingBlock!.currentCol;
    final stackHeight = _stackedBlocks[col].length;
    final landingY = 0.82 - (stackHeight * 0.12);

    if (_fallingBlock!.y >= landingY) {
      _resolveDrop();
    }

    setState(() {});
  }

  void _resolveDrop() {
    if (_fallingBlock == null) return;
    final block = _fallingBlock!;
    final col = block.currentCol;

    if (col == block.targetCol) {
      // Correct Match!
      _score += 200 * _combo;
      _linesCleared++;
      _combo = (_combo + 1).clamp(1, 5);

      // If stack had wrong blocks in this column, clear top one as bonus
      if (_stackedBlocks[col].isNotEmpty) {
        _stackedBlocks[col].removeLast();
      }
    } else {
      // Wrong Match - Add to column stack
      _combo = 1;
      _stackedBlocks[col].add(block.word);

      // Overflow check (max 4 blocks per column)
      if (_stackedBlocks[col].length >= 4) {
        _isGameOver = true;
        _gameLoop?.cancel();
        setState(() {});
        return;
      }
    }

    // Refresh columns if 5 lines cleared
    if (_linesCleared > 0 && _linesCleared % 4 == 0) {
      _refreshColumnsAndSpawn();
    } else {
      _spawnBlock();
    }

    setState(() {});
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyA:
        _moveBlock(-1);
        break;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyD:
        _moveBlock(1);
        break;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.space:
        _hardDrop();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: palette.paper,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context),
              Expanded(
                child: _isLoading
                    ? const Center(child: Text('LOADING WELL…'))
                    : _isGameOver
                    ? _buildGameOver(context)
                    : _buildStackWell(context),
              ),
            ],
          ),
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
            semanticLabel: 'Exit Stacker',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text('WORD STACKER', style: Theme.of(context).textTheme.titleMedium),
          const Spacer(),
          if (_combo > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: palette.danger,
                border: Border.all(color: palette.border, width: 1),
              ),
              child: Text(
                '${_combo}X COMBO',
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'Handjet',
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
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

  Widget _buildStackWell(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    return Column(
      children: [
        // Drop Instruction
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PixelMetrics.space3,
            vertical: 4,
          ),
          child: Text(
            'DROP FALLING WORD INTO MATCHING DEFINITION COLUMN',
            style: theme.textTheme.labelSmall?.copyWith(fontSize: 10),
          ),
        ),

        // Tetris Well
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PixelMetrics.space3),
            child: Container(
              decoration: BoxDecoration(
                color: palette.surface,
                border: Border.all(color: palette.border, width: PixelMetrics.border),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final colWidth = constraints.maxWidth / 3;
                  final h = constraints.maxHeight;

                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragEnd: (details) {
                      final v = details.primaryVelocity;
                      if (v != null) {
                        if (v < -60) _moveBlock(-1);
                        if (v > 60) _moveBlock(1);
                      }
                    },
                    onVerticalDragEnd: (details) {
                      if ((details.primaryVelocity ?? 0) > 80) _hardDrop();
                    },
                    child: Stack(
                      children: [
                        // Column Separator Lines
                        for (var i = 1; i < 3; i++)
                          Positioned(
                            left: i * colWidth,
                            top: 0,
                            bottom: 0.18 * h,
                            child: Container(
                              width: 1,
                              color: palette.border.withValues(alpha: 0.3),
                            ),
                          ),

                        // Stacked Blocks in Each Column
                        for (var c = 0; c < 3; c++)
                          for (var s = 0; s < _stackedBlocks[c].length; s++)
                            Positioned(
                              left: (c * colWidth) + 4,
                              bottom: (0.18 * h) + (s * 36) + 4,
                              width: colWidth - 8,
                              height: 32,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: palette.inkFaint.withValues(alpha: 0.3),
                                  border: Border.all(color: palette.border, width: 1),
                                ),
                                child: Center(
                                  child: Text(
                                    _stackedBlocks[c][s].toUpperCase(),
                                    style: TextStyle(
                                      fontFamily: 'Handjet',
                                      fontSize: 10,
                                      color: palette.inkFaint,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),

                        // Falling Block
                        if (_fallingBlock != null)
                          Positioned(
                            left: (_fallingBlock!.currentCol * colWidth) + 4,
                            top: _fallingBlock!.y * h,
                            width: colWidth - 8,
                            height: 36,
                            child: Container(
                              decoration: BoxDecoration(
                                color: palette.accent,
                                border: Border.all(color: palette.border, width: 1.5),
                                boxShadow: [
                                  BoxShadow(
                                    color: palette.border.withValues(alpha: 0.4),
                                    offset: const Offset(1, 1),
                                    blurRadius: 0,
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  _fallingBlock!.word.toUpperCase(),
                                  style: TextStyle(
                                    fontFamily: 'Handjet',
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: palette.onAccent,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),

                        // Bottom 3 Definition Trays
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          height: 0.18 * h,
                          child: Container(
                            decoration: BoxDecoration(
                              color: palette.paper,
                              border: Border(
                                top: BorderSide(
                                  color: palette.border,
                                  width: PixelMetrics.border,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                for (var i = 0; i < _activeColumns.length; i++)
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () {
                                        if (_fallingBlock != null) {
                                          setState(() => _fallingBlock!.currentCol = i);
                                          _hardDrop();
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          border: Border(
                                            right: i < 2
                                                ? BorderSide(
                                                    color: palette.border,
                                                    width: 1,
                                                  )
                                                : BorderSide.none,
                                          ),
                                        ),
                                        child: Center(
                                          child: Text(
                                            _activeColumns[i].meaning,
                                            style: const TextStyle(
                                              fontFamily: 'Handjet',
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold,
                                            ),
                                            textAlign: TextAlign.center,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),

        const SizedBox(height: PixelMetrics.space3),

        // Ergonomic Two-Handed Controls
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PixelMetrics.space3,
            0,
            PixelMetrics.space3,
            PixelMetrics.space3,
          ),
          child: Row(
            children: [
              // Left Thumb: Column Movement
              _StackerTouchButton(
                glyph: PixelGlyph.arrowLeft,
                label: '◀',
                semanticLabel: 'Move Block Left',
                onAction: () => _moveBlock(-1),
              ),
              const SizedBox(width: PixelMetrics.space2),
              _StackerTouchButton(
                glyph: PixelGlyph.arrowRight,
                label: '▶',
                semanticLabel: 'Move Block Right',
                onAction: () => _moveBlock(1),
              ),

              const Spacer(),

              // Right Thumb: Big Drop Button
              _StackerDropButton(
                glyph: PixelGlyph.tetris,
                label: 'DROP ⬇',
                onDrop: _hardDrop,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGameOver(BuildContext context) {
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
                '☠ WELL OVERFLOW ☠',
                style: theme.textTheme.headlineSmall?.copyWith(
                  color: palette.danger,
                  fontFamily: 'Handjet',
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: PixelMetrics.space4),
              Row(
                children: [
                  Text('FINAL SCORE', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text(
                    '$_score',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: PixelMetrics.space2),
              Row(
                children: [
                  Text('BLOCKS CLEARED', style: theme.textTheme.labelSmall),
                  const Spacer(),
                  Text('$_linesCleared', style: theme.textTheme.titleMedium),
                ],
              ),
              const SizedBox(height: PixelMetrics.space5),
              PixelButton(
                label: 'Play Again',
                glyph: PixelGlyph.gamepad,
                filled: true,
                expand: true,
                onPressed: _initGame,
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

class _StackerTouchButton extends StatelessWidget {
  const _StackerTouchButton({
    required this.glyph,
    required this.label,
    required this.semanticLabel,
    required this.onAction,
  });

  final PixelGlyph glyph;
  final String label;
  final String semanticLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Semantics(
      label: semanticLabel,
      button: true,
      child: GestureDetector(
        onTapDown: (_) => onAction(),
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 58,
          height: 48,
          decoration: BoxDecoration(
            color: palette.surface,
            border: Border.all(color: palette.border, width: PixelMetrics.border),
            boxShadow: [
              BoxShadow(
                color: palette.border.withValues(alpha: 0.4),
                offset: const Offset(1, 1),
                blurRadius: 0,
              ),
            ],
          ),
          child: Center(
            child: PixelIcon(
              glyph,
              color: palette.ink,
              scale: 2.2,
            ),
          ),
        ),
      ),
    );
  }
}

class _StackerDropButton extends StatelessWidget {
  const _StackerDropButton({
    required this.glyph,
    required this.label,
    required this.onDrop,
  });

  final PixelGlyph glyph;
  final String label;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return GestureDetector(
      onTap: onDrop,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: palette.accent,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.4),
              offset: const Offset(2, 2),
              blurRadius: 0,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PixelIcon(
              glyph,
              color: palette.onAccent,
              scale: 2.0,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: palette.onAccent,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
