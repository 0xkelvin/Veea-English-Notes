import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/offline_tutor.dart';
import '../models/word_identity.dart';
import '../providers/offline_tutor_controller.dart';
import '../providers/vocabulary_provider.dart';
import '../services/offline_tutor_service.dart';
import 'word_editor_screen.dart';

class CameraTutorScreen extends StatefulWidget {
  const CameraTutorScreen({
    super.key,
    this.controller,
    this.previewBuilder,
    this.choosePhoto,
    this.saveWord,
  });
  final OfflineTutorController? controller;
  final WidgetBuilder? previewBuilder;
  final Future<String?> Function()? choosePhoto;
  final Future<void> Function(BuildContext, TutorVocabulary)? saveWord;

  @override
  State<CameraTutorScreen> createState() => _CameraTutorScreenState();
}

class _CameraTutorScreenState extends State<CameraTutorScreen>
    with WidgetsBindingObserver {
  static bool _licensesRegistered = false;
  late final OfflineTutorController _tutor;
  final _question = TextEditingController();
  final _scroll = ScrollController();
  final _lessonKeys = List.generate(6, (_) => GlobalKey());
  final _saved = <String>{};
  var _speechRevision = 0;
  var _submissionRevision = 0;
  var _turnCount = 0;

  @override
  void initState() {
    super.initState();
    if (!_licensesRegistered) {
      _licensesRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          ['Google AI Edge Gallery (design reference)', 'LiteRT-LM'],
          await rootBundle.loadString(
            'assets/legal/google-ai-edge-Apache-2.0.txt',
          ),
        );
      });
    }
    WidgetsBinding.instance.addObserver(this);
    _tutor = widget.controller ?? OfflineTutorController();
    _tutor.addListener(_updated);
    unawaited(_tutor.initialize());
  }

  void _updated() {
    if (!mounted) return;
    if (_speechRevision != _tutor.speechRevision) {
      _speechRevision = _tutor.speechRevision;
      _question.value = TextEditingValue(
        text: _tutor.dictation,
        selection: TextSelection.collapsed(offset: _tutor.dictation.length),
      );
    }
    if (_submissionRevision != _tutor.submissionRevision) {
      _submissionRevision = _tutor.submissionRevision;
      FocusScope.of(context).unfocus();
      if (_question.text.trim() == _tutor.pendingQuestion) _question.clear();
    }
    if (_turnCount != _tutor.turns.length) {
      _turnCount = _tutor.turns.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final index = _tutor.turns.length - 1;
        final lessonContext = index >= 0
            ? _lessonKeys[index].currentContext
            : null;
        if (mounted && lessonContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              lessonContext,
              alignment: 0,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            ),
          );
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_tutor.pause());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_tutor.resume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tutor.removeListener(_updated);
    if (widget.controller == null) _tutor.dispose();
    _question.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _choosePhoto() => _tutor.choosePhoto(
    widget.choosePhoto ??
        () async {
          final photo = await ImagePicker().pickImage(
            source: ImageSource.gallery,
            maxWidth: 1024,
            maxHeight: 1024,
            imageQuality: 85,
            requestFullMetadata: false,
          );
          return photo?.path;
        },
  );

  Future<void> _newPhoto() async {
    await _tutor.startNewScene();
    if (mounted && _scroll.hasClients) {
      await _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _save(TutorVocabulary word) async {
    if (widget.saveWord case final save?) {
      await save(context, word);
      return;
    }
    // Reuse the existing editor and its duplicate checks. Capture and audio
    // stop while the editor is in front; the idle lesson can resume afterwards.
    await _tutor.pause();
    if (!mounted) return;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => WordEditorScreen.draft(
            draft: WordDraft(
              word: word.word,
              meaning: word.meaningVi,
              pronunciation: word.pronunciation,
              source: 'Camera tutor',
              examples: word.exampleEn.isEmpty ? const [] : [word.exampleEn],
              tags: const ['camera-tutor'],
            ),
          ),
        ),
      );
      if (!mounted) return;
      final notebook = await context.read<VocabularyProvider>().matchingWords(
        word.word,
      );
      if (!mounted) return;
      if (notebook.any(
        (saved) =>
            WordIdentity.key(saved.word) == WordIdentity.key(word.word) &&
            saved.meaning.trim() == word.meaningVi.trim(),
      )) {
        setState(() => _saved.add(WordIdentity.key(word.word)));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('“${word.word}” is in your notebook.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Open your notebook to check whether the word was saved. Your lesson is still here.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) await _tutor.resume();
    }
  }

  Future<void> _modelPage() async {
    var opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm',
        ),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {}
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the model page. Try again when online.',
          ),
        ),
      );
    }
  }

  Future<void> _settings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: AnimatedBuilder(
            animation: _tutor,
            builder: (_, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Tutor settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Read replies aloud'),
                  subtitle: const Text(
                    'Vietnamese explanation, then English pronunciation',
                  ),
                  value: _tutor.readAloud,
                  onChanged: (_) => _tutor.toggleReadAloud(),
                ),
                if (_tutor.status.speechLocales.length > 1)
                  DropdownButtonFormField<String>(
                    initialValue: _tutor.speechLocale,
                    decoration: const InputDecoration(
                      labelText: 'Language you speak',
                    ),
                    items: [
                      for (final locale in _tutor.status.speechLocales)
                        DropdownMenuItem(
                          value: locale,
                          child: Text(
                            locale == 'vi-VN' ? 'Tiếng Việt' : 'English',
                          ),
                        ),
                    ],
                    onChanged: _tutor.listening || _tutor.microphoneStarting
                        ? null
                        : (value) {
                            if (value != null) _tutor.setSpeechLocale(value);
                          },
                  ),
                if (_tutor.status.speechLocales.length == 1)
                  Text(
                    _tutor.speechLocale == 'vi-VN'
                        ? 'Offline voice input: Tiếng Việt'
                        : 'Offline voice input: English. You can also type in Vietnamese.',
                  ),
                const SizedBox(height: 20),
                Text(
                  'Offline model',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  _tutor.status.modelReady
                      ? 'Gemma model installed · ${(_tutor.status.modelBytes / 1000000000).toStringAsFixed(1)} GB'
                      : 'No model installed',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('Import model from Files'),
                  onPressed:
                      _tutor.busy ||
                          _tutor.listening ||
                          _tutor.microphoneStarting ||
                          !_tutor.status.canRun ||
                          !_tutor.status.runtimeAvailable
                      ? null
                      : () async {
                          Navigator.pop(sheetContext);
                          await _tutor.importModel();
                        },
                ),
                if (_tutor.status.modelReady)
                  TextButton(
                    onPressed:
                        _tutor.busy ||
                            _tutor.listening ||
                            _tutor.microphoneStarting
                        ? null
                        : () async {
                            final confirmed = await showDialog<bool>(
                              context: sheetContext,
                              builder: (dialogContext) => AlertDialog(
                                title: const Text('Remove the AI model?'),
                                content: const Text(
                                  'Your saved words stay in your notebook. Download or import the model again to use the camera tutor.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, false),
                                    child: const Text('Keep model'),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(dialogContext, true),
                                    child: const Text('Remove model'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              if (sheetContext.mounted) {
                                Navigator.pop(sheetContext);
                              }
                              await _tutor.removeModel();
                            }
                          },
                    child: const Text('Remove downloaded model'),
                  ),
                const Divider(height: 32),
                const Text(
                  'Photos, questions and voice stay on this phone. Only words you choose to save go into your notebook. AI explanations can be mistaken; review the meaning before saving.',
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _modelPage,
                  child: const Text('Model details and license'),
                ),
                TextButton(
                  onPressed: () => showLicensePage(
                    context: sheetContext,
                    applicationName: 'Veea Camera tutor',
                  ),
                  child: const Text('Open-source licenses'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _tutor,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Camera tutor'),
        actions: [
          IconButton(
            tooltip: _tutor.readAloud ? 'Mute replies' : 'Read replies aloud',
            onPressed: _tutor.toggleReadAloud,
            icon: Icon(
              _tutor.readAloud
                  ? Icons.volume_up_outlined
                  : Icons.volume_off_outlined,
            ),
          ),
          IconButton(
            tooltip: 'Tutor settings',
            onPressed: _settings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child:
                _tutor.operation == TutorOperation.checking &&
                    !_tutor.status.supported
                ? const Center(child: CircularProgressIndicator())
                : !_tutor.status.ready
                ? _setup(context)
                : Column(
                    children: [
                      Expanded(
                        child: ListView(
                          controller: _scroll,
                          padding: const EdgeInsets.all(16),
                          children: [
                            _KeptCamera(child: _camera(context)),
                            if (_tutor.turns.isEmpty &&
                                _tutor.pendingQuestion == null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 20,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _tutor.hasScene
                                          ? 'What would you like to learn?'
                                          : 'Learn from what’s around you',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleLarge,
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      _tutor.hasScene
                                          ? 'Quick replies with up to 2 word cards. Ask follow-up questions about this photo.'
                                          : 'Point at an object, menu or sign. Take a photo, then ask about it.',
                                    ),
                                    if (_tutor.hasScene) ...[
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          ActionChip(
                                            label: const Text('What is this?'),
                                            onPressed: _tutor.canAsk
                                                ? () => _tutor.ask(
                                                    'What is this? Explain in Vietnamese and teach me the English word.',
                                                  )
                                                : null,
                                          ),
                                          ActionChip(
                                            label: const Text(
                                              'Teach me useful words',
                                            ),
                                            onPressed: _tutor.canAsk
                                                ? () => _tutor.ask(
                                                    'Teach me useful English words from this photo, with Vietnamese meanings.',
                                                  )
                                                : null,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            Column(
                              children: [
                                for (final (index, turn)
                                    in _tutor.turns.indexed)
                                  _lesson(context, turn, _lessonKeys[index]),
                              ],
                            ),
                            if (_tutor.pendingQuestion != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _tutor.pendingQuestion!,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 12),
                              const LinearProgressIndicator(),
                              const SizedBox(height: 8),
                              const Text(
                                'Thinking on your phone… The first reply may take longer.',
                              ),
                              Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: TextButton(
                                  onPressed: _tutor.cancel,
                                  child: const Text('Stop'),
                                ),
                              ),
                            ],
                            if (_tutor.turns.length >= 6)
                              Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: OutlinedButton.icon(
                                  onPressed: _newPhoto,
                                  icon: const Icon(Icons.camera_alt_outlined),
                                  label: const Text('Start with a new photo'),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_tutor.error != null)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: MediaQuery.sizeOf(context).height * .25,
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _error(context),
                          ),
                        ),
                      _composer(context),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );

  Widget _setup(BuildContext context) {
    final status = _tutor.status;
    final canInstall =
        status.supported && status.runtimeAvailable && status.canRun;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const SizedBox(height: 12),
        Icon(
          Icons.camera_alt_outlined,
          size: 44,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Learn English from a photo',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 12),
        const Text(
          'Ask in English or Vietnamese, then save useful words. Your photos and questions stay on this phone.',
        ),
        const SizedBox(height: 24),
        if (!status.supported)
          const Text(
            'Camera tutor is an iPhone preview on this branch. Your notebook, Listen and Review still work normally.',
          ),
        if (status.supported && !status.runtimeAvailable)
          const Text(
            'This build does not include the offline AI runtime. Use a tutor-enabled iPhone build.',
          ),
        if (status.supported && status.runtimeAvailable && !status.canRun)
          const Text(
            'This phone cannot run the camera tutor model. An iPhone with at least 8 GB of memory is recommended.',
          ),
        if (canInstall) ...[
          Text('One-time setup', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            'Gemma 4 E2B · About 2.6 GB. Use Wi-Fi and keep this page open. Allow about 6 GB free during installation.',
          ),
          const SizedBox(height: 12),
          const Text(
            'After setup, photo questions work offline. You can type or use your iPhone’s available offline voice input.',
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            key: const Key('download_tutor_model'),
            onPressed: _tutor.busy ? null : _tutor.downloadModel,
            icon: const Icon(Icons.download_outlined),
            label: Text(
              _tutor.operation == TutorOperation.downloading
                  ? _tutor.downloadPhase == 'verifying'
                        ? 'Verifying model…'
                        : _tutor.downloadPhase == 'installing'
                        ? 'Installing model…'
                        : _tutor.downloadProgress == null
                        ? 'Starting download…'
                        : 'Downloading · ${(_tutor.downloadProgress! * 100).round()}%'
                  : _tutor.busy
                  ? 'Installing model…'
                  : 'Download AI model · 2.6 GB',
            ),
          ),
          if (_tutor.operation == TutorOperation.downloading)
            TextButton(
              key: const Key('cancel_tutor_download'),
              onPressed: _tutor.cancellingDownload
                  ? null
                  : _tutor.cancelDownload,
              child: Text(
                _tutor.cancellingDownload ? 'Cancelling…' : 'Cancel download',
              ),
            ),
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('import_tutor_model'),
            onPressed: _tutor.busy ? null : _tutor.importModel,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('Already have the file? Import from Files'),
          ),
          TextButton(
            onPressed: _tutor.busy ? null : _modelPage,
            child: const Text('About Gemma 4 E2B · Apache 2.0'),
          ),
        ],
        if (_tutor.busy)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(
              value:
                  _tutor.operation == TutorOperation.downloading &&
                      _tutor.downloadPhase == 'downloading'
                  ? _tutor.downloadProgress
                  : null,
            ),
          ),
        if (_tutor.error != null) _error(context),
      ],
    );
  }

  Widget _camera(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SizedBox(
          height: (MediaQuery.sizeOf(context).height * .3).clamp(160, 280),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (widget.previewBuilder case final preview?)
                preview(context)
              else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
                const UiKitView(viewType: NativeOfflineTutorService.previewType)
              else
                const ColoredBox(color: Color(0xff19232d)),
              if (_tutor.imagePath case final path?)
                Image.file(
                  File(path),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const Center(child: Text('Photo selected')),
                ),
              Positioned(
                left: 12,
                bottom: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xdd19232d),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Text(
                      _tutor.hasScene
                          ? 'This photo · Offline'
                          : 'Live camera · Offline',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            key: const Key('capture_tutor_photo'),
            onPressed:
                _tutor.busy && _tutor.operation != TutorOperation.thinking
                ? null
                : _tutor.hasScene
                ? _newPhoto
                : _tutor.capture,
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(_tutor.hasScene ? 'New photo' : 'Take photo'),
          ),
          OutlinedButton.icon(
            key: const Key('choose_tutor_photo'),
            onPressed: _tutor.busy ? null : _choosePhoto,
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Choose photo'),
          ),
        ],
      ),
    ],
  );

  Widget _lesson(BuildContext context, TutorTurn turn, Key key) {
    final theme = Theme.of(context);
    final canSpeak =
        !_tutor.busy && !_tutor.listening && !_tutor.microphoneStarting;
    return Padding(
      key: key,
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(turn.question, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            color: theme.colorScheme.surfaceContainerLow,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(turn.reply.explanationVi),
                  const SizedBox(height: 12),
                  SelectableText(
                    turn.reply.answerEn,
                    style: theme.textTheme.titleMedium,
                  ),
                  TextButton.icon(
                    onPressed: canSpeak ? () => _tutor.speak(turn.reply) : null,
                    icon: const Icon(Icons.volume_up_outlined),
                    label: const Text('Hear reply'),
                  ),
                ],
              ),
            ),
          ),
          for (final word in turn.reply.vocabulary) ...[
            const SizedBox(height: 12),
            Card(
              elevation: 0,
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            word.word,
                            style: theme.textTheme.headlineSmall,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Pronounce ${word.word}',
                          onPressed: canSpeak
                              ? () => _tutor.pronounce(word.word)
                              : null,
                          icon: const Icon(Icons.volume_up_outlined),
                        ),
                      ],
                    ),
                    if (word.pronunciation != null) Text(word.pronunciation!),
                    const SizedBox(height: 6),
                    Text(word.meaningVi),
                    if (word.exampleEn.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        word.exampleEn,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: ValueKey('save_tutor_word_${word.word}'),
                      onPressed: _tutor.busy ? null : () => _save(word),
                      icon: Icon(
                        _saved.contains(WordIdentity.key(word.word))
                            ? Icons.check
                            : Icons.add,
                      ),
                      label: Text(
                        _saved.contains(WordIdentity.key(word.word))
                            ? 'In your notebook · View draft'
                            : 'Review & save word',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _error(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Semantics(
      liveRegion: true,
      child: Text(
        _tutor.error!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    ),
  );

  Widget _composer(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_tutor.status.speechLocales.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Offline voice is unavailable. Type your question below.',
              ),
            ),
          if (_tutor.listening || _tutor.microphoneStarting)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'Listening… Your question will be sent when you finish speaking.',
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const Key('tutor_question'),
                  controller: _question,
                  enabled: _tutor.canAsk || _tutor.listening,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 1200,
                  decoration: InputDecoration(
                    hintText: _tutor.hasScene
                        ? 'Ask about this photo…'
                        : 'Take a photo to begin',
                    counterText: '',
                    border: const OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (text) => _tutor.ask(text),
                ),
              ),
              const SizedBox(width: 4),
              if (_tutor.status.speechLocales.isNotEmpty)
                IconButton(
                  key: const Key('tutor_microphone'),
                  tooltip: _tutor.listening
                      ? 'Finish speaking'
                      : _tutor.speechLocale == 'vi-VN'
                      ? 'Ask by voice in Vietnamese'
                      : 'Ask by voice in English',
                  onPressed: _tutor.canAsk || _tutor.listening
                      ? _tutor.toggleListening
                      : null,
                  icon: Icon(
                    _tutor.listening
                        ? Icons.stop_circle_outlined
                        : Icons.mic_none,
                  ),
                ),
              IconButton.filled(
                key: const Key('ask_tutor'),
                tooltip: 'Ask tutor',
                onPressed: _tutor.canAsk
                    ? () => _tutor.ask(_question.text)
                    : null,
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Keep the native preview attachment through list scrolling. Captured scenes
/// pause its session explicitly, and new-scene/background/close own its lifetime.
class _KeptCamera extends StatefulWidget {
  const _KeptCamera({required this.child});
  final Widget child;
  @override
  State<_KeptCamera> createState() => _KeptCameraState();
}

class _KeptCameraState extends State<_KeptCamera>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
