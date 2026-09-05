import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/theme/pixel_metrics.dart';
import '../core/theme/pixel_palette.dart';
import '../models/friend_connection.dart';
import '../models/vocabulary_word.dart';
import '../models/word_challenge.dart';
import '../providers/vocabulary_provider.dart';
import '../services/friend_challenge_service.dart';
import '../widgets/pixel/pixel_button.dart';
import '../widgets/pixel/pixel_icon.dart';

class PixelLinkScreen extends StatefulWidget {
  const PixelLinkScreen({super.key});

  @override
  State<PixelLinkScreen> createState() => _PixelLinkScreenState();
}

class _PixelLinkScreenState extends State<PixelLinkScreen> {
  final TextEditingController _codeController = TextEditingController();

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _copyFriendCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied connection code: $code'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _connectFriend() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    final service = context.read<FriendChallengeService>();
    await service.addFriend(code);
    _codeController.clear();
  }

  void _openWordDropPicker(FriendConnection friend) {
    final vocab = context.read<VocabularyProvider>();
    final words = vocab.words;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _WordDropPickerSheet(
        friend: friend,
        words: words,
      ),
    );
  }

  void _simulateIncomingDrop() {
    final service = context.read<FriendChallengeService>();
    final vocab = context.read<VocabularyProvider>();
    final sampleWord = vocab.words.isNotEmpty
        ? vocab.words.first
        : VocabularyWord(
            id: 'sample',
            word: 'resilient',
            meaning: 'kiên cường, phục hồi nhanh',
            date: '2026-08-18',
            createdAt: DateTime(2026, 8, 18),
            updatedAt: DateTime(2026, 8, 18),
          );

    service.simulateIncomingDrop(
      word: sampleWord,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = context.palette;
    final challengeService = context.watch<FriendChallengeService>();
    final friends = challengeService.friends;
    final profile = challengeService.profile;

    return Scaffold(
      backgroundColor: palette.paper,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(context, palette),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(PixelMetrics.space4),
                children: [
                  // Game Link Profile Card
                  _buildProfileCard(context, profile, palette),
                  const SizedBox(height: PixelMetrics.space4),

                  // Connect With Friend Form
                  _buildAddFriendSection(palette),
                  const SizedBox(height: PixelMetrics.space3),

                  // Simulator / Instant Test Drop Banner
                  _buildSimulatorSection(palette),
                  const SizedBox(height: PixelMetrics.space4),

                  // Linked Friends Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'CONNECTED FRIENDS (${friends.length})',
                        style: theme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: palette.inkFaint,
                        ),
                      ),
                      PixelIcon(PixelGlyph.link, color: palette.accent, scale: 2),
                    ],
                  ),
                  const SizedBox(height: PixelMetrics.space2),

                  if (friends.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(PixelMetrics.space4),
                      decoration: BoxDecoration(
                        color: palette.surface,
                        border: Border.all(color: palette.border, width: 1),
                      ),
                      child: Center(
                        child: Text(
                          'NO FRIENDS CONNECTED YET\nENTER A CODE TO DROP WORDS & DUEL!',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'Handjet',
                            fontSize: 14,
                            color: palette.inkFaint,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final friend in friends) ...[
                      _buildFriendTile(friend, palette),
                      const SizedBox(height: PixelMetrics.space2),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, PixelPalette palette) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PixelMetrics.space3,
        vertical: PixelMetrics.space2,
      ),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(
          bottom: BorderSide(
            color: palette.border,
            width: PixelMetrics.border,
          ),
        ),
      ),
      child: Row(
        children: [
          PixelIconButton(
            glyph: PixelGlyph.arrowLeft,
            semanticLabel: 'Back',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: PixelMetrics.space2),
          Text(
            'PIXEL LINK // FRIEND WORD DROP',
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: palette.ink,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    FriendProfile profile,
    PixelPalette palette,
  ) {
    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space4),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
        boxShadow: [
          BoxShadow(
            color: palette.border.withValues(alpha: 0.4),
            offset: const Offset(3, 3),
            blurRadius: 0,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  PixelIcon(PixelGlyph.gamepad, color: palette.accent, scale: 2.2),
                  const SizedBox(width: PixelMetrics.space2),
                  Text(
                    'YOUR GAME LINK CODE',
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: palette.inkFaint,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                color: palette.accent,
                child: Text(
                  '${profile.xp} XP',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: palette.paper,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  color: palette.paper,
                  child: Text(
                    profile.friendCode,
                    style: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      color: palette.accent,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: PixelMetrics.space2),
              PixelButton(
                label: 'COPY CODE',
                onPressed: () => _copyFriendCode(profile.friendCode),
              ),
            ],
          ),
          const SizedBox(height: PixelMetrics.space2),
          Row(
            children: [
              Text(
                'Won: ${profile.duelsWon} / ${profile.duelsPlayed} duels',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 14,
                  color: palette.inkMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAddFriendSection(PixelPalette palette) {
    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CONNECT WITH A FRIEND (ENTER VEEA-XXXX)',
            style: TextStyle(
              fontFamily: 'Handjet',
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: palette.inkFaint,
            ),
          ),
          const SizedBox(height: PixelMetrics.space2),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    hintText: 'e.g. VEEA-77K2',
                    hintStyle: TextStyle(
                      fontFamily: 'Handjet',
                      fontSize: 16,
                      color: palette.inkFaint,
                    ),
                    filled: true,
                    fillColor: palette.paper,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderSide: BorderSide(
                        color: palette.border,
                        width: PixelMetrics.border,
                      ),
                    ),
                  ),
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                ),
              ),
              const SizedBox(width: PixelMetrics.space2),
              PixelButton(
                label: 'CONNECT +',
                onPressed: _connectFriend,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSimulatorSection(PixelPalette palette) {
    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        border: Border.all(color: Colors.amber.shade800, width: PixelMetrics.border),
      ),
      child: Row(
        children: [
          PixelIcon(PixelGlyph.bolt, color: Colors.amber.shade900, scale: 2.2),
          const SizedBox(width: PixelMetrics.space2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TEST WORD DROP (SIMULATOR)',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: Colors.amber.shade900,
                  ),
                ),
                Text(
                  'Launch instant word quiz pop-up on screen',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 12,
                    color: palette.inkMuted,
                  ),
                ),
              ],
            ),
          ),
          PixelButton(
            label: 'TEST ⚡',
            onPressed: _simulateIncomingDrop,
          ),
        ],
      ),
    );
  }

  Widget _buildFriendTile(FriendConnection friend, PixelPalette palette) {
    return Container(
      padding: const EdgeInsets.all(PixelMetrics.space3),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border.all(color: palette.border, width: PixelMetrics.border),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            color: palette.accent.withValues(alpha: 0.2),
            alignment: Alignment.center,
            child: Text(
              friend.name.isNotEmpty ? friend.name[0].toUpperCase() : '?',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: palette.accent,
              ),
            ),
          ),
          const SizedBox(width: PixelMetrics.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  friend.name,
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: palette.ink,
                  ),
                ),
                Text(
                  'Score: ${friend.duelScoreMe} won - ${friend.duelScoreThem} lost',
                  style: TextStyle(
                    fontFamily: 'Handjet',
                    fontSize: 12,
                    color: palette.inkFaint,
                  ),
                ),
              ],
            ),
          ),
          PixelButton(
            label: 'WORD DROP ⚡',
            onPressed: () => _openWordDropPicker(friend),
          ),
        ],
      ),
    );
  }
}

class _WordDropPickerSheet extends StatefulWidget {
  const _WordDropPickerSheet({
    required this.friend,
    required this.words,
  });

  final FriendConnection friend;
  final List<VocabularyWord> words;

  @override
  State<_WordDropPickerSheet> createState() => _WordDropPickerSheetState();
}

class _WordDropPickerSheetState extends State<_WordDropPickerSheet> {
  ChallengeMode _mode = ChallengeMode.vnToEn;
  VocabularyWord? _selectedWord;
  bool _isSent = false;

  @override
  void initState() {
    super.initState();
    if (widget.words.isNotEmpty) {
      _selectedWord = widget.words.first;
    }
  }

  void _sendDrop() {
    if (_selectedWord == null) return;
    final service = context.read<FriendChallengeService>();
    service.createChallenge(
      friend: widget.friend,
      word: _selectedWord!,
      mode: _mode,
      otherWordsPool: widget.words,
    );

    setState(() {
      _isSent = true;
    });

    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: const EdgeInsets.all(PixelMetrics.space3),
        padding: const EdgeInsets.all(PixelMetrics.space4),
        decoration: BoxDecoration(
          color: palette.surface,
          border: Border.all(color: palette.border, width: PixelMetrics.border * 1.5),
          boxShadow: [
            BoxShadow(
              color: palette.border.withValues(alpha: 0.6),
              offset: const Offset(4, 4),
              blurRadius: 0,
            ),
          ],
        ),
        child: SafeArea(
          child: _isSent
              ? _buildSentConfirmation(palette)
              : _buildPickerBody(palette),
        ),
      ),
    );
  }

  Widget _buildSentConfirmation(PixelPalette palette) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PixelIcon(PixelGlyph.bolt, color: Colors.amber, scale: 3),
        const SizedBox(height: PixelMetrics.space2),
        Text(
          'WORD DROP CHALLENGE SENT!',
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: palette.accent,
          ),
        ),
        Text(
          'Sent to ${widget.friend.name}',
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 14,
            color: palette.inkMuted,
          ),
        ),
      ],
    );
  }

  Widget _buildPickerBody(PixelPalette palette) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            PixelIcon(PixelGlyph.bolt, color: Colors.amber, scale: 2),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: Text(
                'DROP WORD TO ${widget.friend.name.toUpperCase()}',
                style: TextStyle(
                  fontFamily: 'Handjet',
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: palette.ink,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: PixelMetrics.space3),

        // Direction Mode Selector
        Text(
          'CHALLENGE MODE:',
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 12,
            color: palette.inkFaint,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: PixelMetrics.space1),
        Row(
          children: [
            Expanded(
              child: _buildModeTab(
                mode: ChallengeMode.vnToEn,
                label: '🇻🇳 ➔ 🇬🇧 (GUESS ENGLISH)',
                palette: palette,
              ),
            ),
            const SizedBox(width: PixelMetrics.space2),
            Expanded(
              child: _buildModeTab(
                mode: ChallengeMode.enToVn,
                label: '🇬🇧 ➔ 🇻🇳 (GUESS MEANING)',
                palette: palette,
              ),
            ),
          ],
        ),

        const SizedBox(height: PixelMetrics.space3),

        // Select Word from Notebook
        Text(
          'SELECT WORD FROM YOUR JOURNAL:',
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 12,
            color: palette.inkFaint,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: PixelMetrics.space1),

        if (widget.words.isEmpty)
          Container(
            padding: const EdgeInsets.all(PixelMetrics.space3),
            color: palette.paper,
            child: Text(
              'No words in your journal yet! Add words before challenging friends.',
              style: TextStyle(
                fontFamily: 'Handjet',
                fontSize: 14,
                color: palette.danger,
              ),
            ),
          )
        else
          Container(
            constraints: const BoxConstraints(maxHeight: 180),
            decoration: BoxDecoration(
              color: palette.paper,
              border: Border.all(color: palette.border, width: PixelMetrics.border),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: widget.words.length,
              itemBuilder: (context, i) {
                final w = widget.words[i];
                final isSelected = _selectedWord?.id == w.id;
                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    selected: isSelected,
                    selectedTileColor: palette.accent.withValues(alpha: 0.15),
                    title: Text(
                      w.word,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: isSelected ? palette.accent : palette.ink,
                      ),
                    ),
                    subtitle: Text(
                      w.meaning,
                      style: TextStyle(
                        fontFamily: 'Handjet',
                        fontSize: 12,
                        color: palette.inkMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      setState(() {
                        _selectedWord = w;
                      });
                    },
                  ),
                );
              },
            ),
          ),

        const SizedBox(height: PixelMetrics.space4),

        PixelButton(
          label: '⚡ SEND CHALLENGE NOW!',
          onPressed: _selectedWord != null ? _sendDrop : null,
        ),
      ],
    );
  }

  Widget _buildModeTab({
    required ChallengeMode mode,
    required String label,
    required PixelPalette palette,
  }) {
    final isSelected = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isSelected ? palette.accent : palette.paper,
          border: Border.all(color: palette.border, width: PixelMetrics.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Handjet',
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: isSelected ? palette.paper : palette.ink,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
