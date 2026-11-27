import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../providers/pro_provider.dart';
import '../screens/pro_screen.dart';

import '../models/vocabulary_word.dart';
import '../providers/app_gate_provider.dart';

class PracticePoolSelection {
  const PracticePoolSelection(this.wordIds);
  final List<String>? wordIds;
}

Future<bool> choosePracticeWords(
  BuildContext context,
  AppGateProvider gate, {
  Future<void> Function()? onUpgrade,
}) async {
  await gate.prepareChallenge();
  if (!context.mounted) return false;
  final selection = await Navigator.of(context).push<PracticePoolSelection>(
    MaterialPageRoute(
      builder: (pickerContext) => AnimatedBuilder(
        animation: gate,
        builder: (_, _) => PracticeWordPicker(
          words: gate.notebookWords,
          selectedIds: gate.practiceWords.map((word) => word.id).toList(),
          title: 'Choose unlock words',
          allowFutureWords: false,
          confirmAtBottom: true,
          unlockSelection: true,
          selectionLimit: gate.canUseMultipleWords ? null : 1,
          requestMultiple: () async {
            if (onUpgrade != null) {
              await onUpgrade();
            } else {
              try {
                pickerContext.read<ProProvider>();
                await ProScreen.open(pickerContext);
              } on ProviderNotFoundException {
                if (pickerContext.mounted) {
                  ScaffoldMessenger.of(pickerContext).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Pro upgrades are unavailable right now. Your selected word stays unchanged.',
                      ),
                    ),
                  );
                }
              }
            }
            return gate.canUseMultipleWords;
          },
        ),
      ),
    ),
  );
  if (selection == null) return false;
  await gate.setPracticeWords(selection.wordIds);
  return true;
}

class PracticeWordPicker extends StatefulWidget {
  const PracticeWordPicker({
    super.key,
    required this.words,
    this.selectedIds,
    this.title = 'Practice words',
    this.confirmLabel = 'Save',
    this.allowFutureWords = true,
    this.confirmAtBottom = false,
    this.unlockSelection = false,
    this.selectionLimit,
    this.requestMultiple,
  });
  final List<VocabularyWord> words;
  final List<String>? selectedIds;
  final String title;
  final String confirmLabel;
  final bool allowFutureWords;
  final bool confirmAtBottom;
  final bool unlockSelection;
  final int? selectionLimit;
  final Future<bool> Function()? requestMultiple;
  @override
  State<PracticeWordPicker> createState() => _PracticeWordPickerState();
}

enum _SelectionAction { selectNotebook, clearSelection }

class _PracticeWordPickerState extends State<PracticeWordPicker> {
  late bool _includeNewWords;
  late final Set<String> _selected;
  late final List<VocabularyWord> _words;
  late final Map<String, String> _searchIndex;
  late final List<String> _days;
  late final Set<String> _savedDays;
  String? _day;
  final _searchInput = TextEditingController();
  String _search = '';
  late bool _multipleAllowed;
  bool _requestingUpgrade = false;
  bool get _singleChoice => widget.unlockSelection && !_multipleAllowed;

  @override
  void didUpdateWidget(covariant PracticeWordPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectionLimit != widget.selectionLimit) {
      _multipleAllowed = widget.selectionLimit != 1;
      if (_singleChoice && _selected.length > 1) {
        final retained = _selected.first;
        _selected
          ..clear()
          ..add(retained);
      }
    }
  }

  Future<void> _requestMultiple([Set<String>? desired]) async {
    if (_requestingUpgrade) return;
    setState(() => _requestingUpgrade = true);
    try {
      final allowed = await widget.requestMultiple?.call() ?? false;
      if (mounted && allowed) {
        setState(() {
          _multipleAllowed = true;
          if (desired != null) {
            _selected
              ..clear()
              ..addAll(desired);
          }
        });
      }
    } finally {
      if (mounted) setState(() => _requestingUpgrade = false);
    }
  }

  void _confirm() {
    if (_selected.isEmpty) return;
    final allSelected = _selected.length == _words.length;
    Navigator.of(context).pop(
      PracticePoolSelection(
        allSelected && widget.allowFutureWords && _includeNewWords
            ? null
            : _selected.toList(),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _multipleAllowed = widget.selectionLimit != 1;
    _includeNewWords = widget.selectedIds == null;
    _words = List.of(widget.words)
      ..sort((a, b) {
        final day = b.date.compareTo(a.date);
        return day != 0
            ? day
            : a.word.toLowerCase().compareTo(b.word.toLowerCase());
      });
    final available = _words.map((word) => word.id).toSet();
    _selected = widget.selectedIds == null
        ? available
        : widget.selectedIds!.where(available.contains).toSet();
    _searchIndex = {
      for (final word in _words)
        word.id:
            '${word.word} ${word.meaning} ${word.date} ${word.tags.join(' ')}'
                .toLowerCase(),
    };
    _savedDays = _words
        .map((word) => word.date)
        .where((day) => DateTime.tryParse(day) != null)
        .toSet();
    _days = _savedDays.toList()..sort((a, b) => b.compareTo(a));
  }

  @override
  void dispose() {
    _searchInput.dispose();
    super.dispose();
  }

  void _toggleWords(Iterable<VocabularyWord> words) {
    final ids = words.map((word) => word.id).toSet();
    if (ids.isEmpty) return;
    if (_singleChoice && ids.length > 1) {
      _requestMultiple(ids);
      return;
    }
    setState(() {
      if (ids.every(_selected.contains)) {
        _selected.removeAll(ids);
      } else {
        _selected.addAll(ids);
      }
    });
  }

  String _dayLabel(String value) {
    final date = DateTime.tryParse(value);
    return date == null ? value : DateFormat.yMMMd().format(date);
  }

  Future<void> _openCalendar() async {
    if (_days.isEmpty) return;
    FocusScope.of(context).unfocus();
    final chosen = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_day ?? _days.first),
      firstDate: DateTime.parse(_days.last),
      lastDate: DateTime.parse(_days.first),
      helpText: 'Filter by saved date',
      selectableDayPredicate: (date) =>
          _savedDays.contains(DateFormat('yyyy-MM-dd').format(date)),
    );
    if (chosen != null && mounted) {
      setState(() => _day = DateFormat('yyyy-MM-dd').format(chosen));
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.trim().toLowerCase();
    final filtered = _day != null || query.isNotEmpty;
    final visible = _words
        .where(
          (word) =>
              (_day == null || word.date == _day) &&
              _searchIndex[word.id]!.contains(query),
        )
        .toList();
    final visibleSelected = visible
        .where((word) => _selected.contains(word.id))
        .length;
    final hiddenSelected = _selected.length - visibleSelected;
    final allSelected = _words.isNotEmpty && _selected.length == _words.length;
    final dayIndex = _day == null ? -1 : _days.indexOf(_day!);
    final countLabel = MediaQuery.textScalerOf(context).scale(14) > 18
        ? '${_selected.length} selected'
        : '${_selected.length} of ${_words.length} words selected';
    final wordLabel = visible.length == 1 ? 'word' : 'words';
    final scopeLabel = query.isNotEmpty
        ? 'All ${visible.length} matching $wordLabel'
        : _day != null
        ? 'All ${visible.length} $wordLabel on ${DateFormat.MMMd().format(DateTime.parse(_day!))}'
        : 'All ${_words.length} notebook words';

    final confirmation = widget.unlockSelection
        ? 'Use ${_selected.length} ${_selected.length == 1 ? 'word' : 'words'} per unlock'
        : widget.confirmLabel;
    final controls = <Widget>[
      if (widget.unlockSelection)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _singleChoice
                    ? 'Free: choose 1 word. Tap another word to replace it.'
                    : 'Every unlock includes all the words you select here.',
              ),
              if (_singleChoice)
                TextButton.icon(
                  key: const Key('unlock_picker_upgrade'),
                  onPressed: _requestingUpgrade ? null : _requestMultiple,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('Select multiple words with Pro'),
                ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          key: const Key('practice_word_search'),
          controller: _searchInput,
          onChanged: (value) => setState(() => _search = value),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search words, meanings or tags',
            suffixIcon: _search.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () => setState(() {
                      _searchInput.clear();
                      _search = '';
                    }),
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (_day != null)
              IconButton(
                tooltip: 'Previous saved day',
                onPressed: dayIndex == _days.length - 1
                    ? null
                    : () => setState(() => _day = _days[dayIndex + 1]),
                icon: const Icon(Icons.chevron_left),
              ),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  key: const Key('practice_calendar'),
                  avatar: const Icon(Icons.calendar_month, size: 18),
                  label: Text(_day == null ? 'Any date' : _dayLabel(_day!)),
                  onPressed: _days.isEmpty ? null : _openCalendar,
                  onDeleted: _day == null
                      ? null
                      : () => setState(() => _day = null),
                  deleteButtonTooltipMessage: 'Show any date',
                ),
              ),
            ),
            if (_day != null)
              IconButton(
                tooltip: 'Next saved day',
                onPressed: dayIndex <= 0
                    ? null
                    : () => setState(() => _day = _days[dayIndex - 1]),
                icon: const Icon(Icons.chevron_right),
              ),
          ],
        ),
      ),
      if (!_singleChoice)
        CheckboxListTile(
          key: const Key('select_visible_practice_words'),
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          tristate: true,
          value: visibleSelected == 0
              ? false
              : visibleSelected == visible.length
              ? true
              : null,
          onChanged: visible.isEmpty ? null : (_) => _toggleWords(visible),
          title: Text(scopeLabel),
          subtitle: Text(
            _selected.isEmpty
                ? 'Select at least one word to continue.'
                : filtered
                ? '$visibleSelected selected here · $hiddenSelected selected elsewhere'
                : 'Select or uncheck any word below.',
          ),
        ),
      if (widget.allowFutureWords &&
          allSelected &&
          MediaQuery.viewInsetsOf(context).bottom == 0)
        SwitchListTile.adaptive(
          key: const Key('include_future_practice_words'),
          dense: true,
          title: const Text('Include new words automatically'),
          subtitle: const Text('Words you save later will join practice.'),
          value: _includeNewWords,
          onChanged: (value) => setState(() => _includeNewWords = value),
        ),
      const Divider(height: 1),
    ];
    const emptyState = Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('No matching words. Change the date or clear your search.'),
      ),
    );
    Widget buildWordTile(BuildContext context, int index) {
      final word = visible[index];
      final showDay =
          _day == null && (index == 0 || visible[index - 1].date != word.date);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showDay)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                _dayLabel(word.date),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          if (_singleChoice)
            RadioListTile<String>(
              key: ValueKey('practice_word_${word.id}'),
              value: word.id,
              title: Text(word.word),
              subtitle: Text(word.meaning),
            )
          else
            CheckboxListTile(
              key: ValueKey('practice_word_${word.id}'),
              controlAffinity: ListTileControlAffinity.leading,
              value: _selected.contains(word.id),
              onChanged: (value) => setState(() {
                if (value == true) {
                  _selected.add(word.id);
                } else {
                  _selected.remove(word.id);
                }
              }),
              title: Text(word.word),
              subtitle: Text(word.meaning),
            ),
        ],
      );
    }

    final page = Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('cancel_practice_words'),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close),
        ),
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          PopupMenuButton<_SelectionAction>(
            key: const Key('practice_selection_options'),
            tooltip: 'Selection options',
            onSelected: (action) => setState(() {
              if (action == _SelectionAction.selectNotebook &&
                  _singleChoice &&
                  _words.length > 1) {
                _requestMultiple(_words.map((word) => word.id).toSet());
              } else if (action == _SelectionAction.selectNotebook) {
                _selected.addAll(_words.map((word) => word.id));
              } else {
                _selected.clear();
              }
            }),
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _SelectionAction.selectNotebook,
                enabled: !allSelected && _words.isNotEmpty,
                child: Text('Select entire notebook (${_words.length})'),
              ),
              PopupMenuItem(
                value: _SelectionAction.clearSelection,
                enabled: _selected.isNotEmpty,
                child: Text('Clear entire selection (${_selected.length})'),
              ),
            ],
          ),
          if (!widget.confirmAtBottom)
            TextButton(
              key: const Key('save_practice_words'),
              onPressed: _selected.isEmpty || _requestingUpgrade
                  ? null
                  : _confirm,
              child: Text(confirmation),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(
            MediaQuery.textScalerOf(context).scale(16) * 1.5 + 12,
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(countLabel, key: const Key('practice_selection_count')),
          ),
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final scrollControls =
                      widget.confirmAtBottom &&
                      (constraints.maxHeight < 400 ||
                          MediaQuery.textScalerOf(context).scale(14) > 20);
                  if (scrollControls) {
                    return CustomScrollView(
                      key: const Key('practice_word_list'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      slivers: [
                        SliverToBoxAdapter(child: Column(children: controls)),
                        if (visible.isEmpty)
                          const SliverToBoxAdapter(child: emptyState)
                        else
                          SliverList.builder(
                            itemCount: visible.length,
                            itemBuilder: buildWordTile,
                          ),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      ...controls,
                      Expanded(
                        child: visible.isEmpty
                            ? emptyState
                            : ListView.builder(
                                key: const Key('practice_word_list'),
                                keyboardDismissBehavior:
                                    ScrollViewKeyboardDismissBehavior.onDrag,
                                itemCount: visible.length,
                                itemBuilder: buildWordTile,
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (widget.confirmAtBottom)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('save_practice_words'),
                    onPressed: _selected.isEmpty || _requestingUpgrade
                        ? null
                        : _confirm,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(confirmation, textAlign: TextAlign.center),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    return RadioGroup<String>(
      groupValue: _singleChoice ? _selected.firstOrNull : null,
      onChanged: (id) {
        if (id != null && !_requestingUpgrade) {
          setState(
            () => _selected
              ..clear()
              ..add(id),
          );
        }
      },
      child: page,
    );
  }
}
