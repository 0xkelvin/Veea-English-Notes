import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../core/config/app_config.dart';
import '../data/feedback_repository.dart';
import '../providers/feedback_provider.dart';
import '../services/feedback_service.dart';
import '../widgets/pixel/pixel_box.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});
  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  final _message = TextEditingController(), _contact = TextEditingController();
  final _form = GlobalKey<FormState>();
  String _kind = 'bug';
  bool _diagnostics = false, _picking = false, _handingOff = false;
  Uint8List? _screenshot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<FeedbackProvider>().refresh();
    });
  }

  @override
  void dispose() {
    _message.dispose();
    _contact.dispose();
    super.dispose();
  }

  void _showSnackBar(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  FeedbackDraft _currentFormDraft() => FeedbackDraft(
    kind: _kind,
    message: _message.text.trim(),
    contact: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
    includeDiagnostics: _diagnostics,
    diagnostics: _diagnostics ? FeedbackService.defaultDiagnostics() : null,
    screenshotBytes: _screenshot,
  );

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 60,
        requestFullMetadata: false,
      );
      if (image == null) return;
      final bytes = await image.readAsBytes();
      if (!mounted) return;
      if (bytes.length > 524288) {
        _showSnackBar('Choose a smaller screenshot, under 512 KB.');
      } else {
        setState(() => _screenshot = bytes);
      }
    } catch (_) {
      _showSnackBar('Could not open that photo. Please try another.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final feedback = context.read<FeedbackProvider>();
    final ok = await feedback.submit(
      kind: _kind,
      message: _message.text,
      contact: _contact.text,
      diagnostics: _diagnostics,
      screenshot: _screenshot,
    );
    if (!ok || !mounted) return;
    _message.clear();
    _contact.clear();
    setState(() => _screenshot = null);
    final hasSupportEmail = AppConfig.supportEmail != null;
    _showSnackBar(
      AppConfig.isFeedbackDeliveryEnabled
          ? 'Feedback saved. Check its delivery status below.'
          : hasSupportEmail
          ? 'Feedback draft saved on this device. Use Share feedback, Email support, or Copy below when ready.'
          : 'Feedback draft saved on this device. Use Share feedback or Copy below when ready.',
    );
    await feedback.refresh();
  }

  Future<void> _shareFormDraft(BuildContext anchorContext) async {
    if (_handingOff || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await _shareDraft(
      _currentFormDraft(),
      FeedbackService.resolveShareOrigin(anchorContext),
    );
  }

  Future<void> _emailFormDraft() async {
    if (_handingOff || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await _emailDraft(_currentFormDraft());
  }

  Future<void> _shareDraft(FeedbackDraft draft, Rect shareOrigin) async {
    if (_handingOff) return;
    setState(() => _handingOff = true);
    try {
      final result = await FeedbackService.shareDraft(
        draft,
        sharePositionOrigin: shareOrigin,
      );
      _showSnackBar(result.message);
    } finally {
      if (mounted) setState(() => _handingOff = false);
    }
  }

  Future<void> _emailDraft(FeedbackDraft draft) async {
    if (_handingOff) return;
    setState(() => _handingOff = true);
    try {
      final result = await FeedbackService.openEmailDraft(draft);
      _showSnackBar(result.message);
    } finally {
      if (mounted) setState(() => _handingOff = false);
    }
  }

  Future<void> _copyDraft(FeedbackDraft draft) async {
    final formatted = FeedbackService.formatDraft(
      draft,
      screenshotAttached: false,
    );
    await Clipboard.setData(ClipboardData(text: formatted));
    _showSnackBar(
      draft.hasScreenshot
          ? 'Feedback text copied. Screenshot is not included in clipboard text.'
          : 'Feedback copied',
    );
  }

  Future<void> _community(String url) async {
    final safeUrl = trustedZaloCommunity(url);
    final opened = safeUrl != null
        ? await FeedbackService.openTrustedUrl(Uri.parse(safeUrl))
        : false;
    if (!opened) {
      _showSnackBar('Could not open Zalo. Please try again later.');
    }
  }

  String _reportStatusLabel(FeedbackReport report, bool deliveryEnabled) {
    if (report.queued && !deliveryEnabled) {
      return 'Saved on this device · Not sent';
    }
    return report.statusLabel;
  }

  String? _draftMetaSummary(FeedbackDraft draft) {
    final parts = <String>[
      if (draft.includeDiagnostics) 'Includes app details',
      if (draft.hasScreenshot) 'Includes screenshot',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final feedback = context.watch<FeedbackProvider>();
    final deliveryEnabled = AppConfig.isFeedbackDeliveryEnabled;
    final supportEmail = AppConfig.supportEmail;
    final communityUrl = trustedZaloCommunity(feedback.communityUrl);

    return Scaffold(
      appBar: AppBar(title: const Text('Help and feedback')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            Text(
              'Help shape Veea',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Report a problem or suggest something you’d love to see. No account needed.',
            ),
            if (!deliveryEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: PixelBox(
                  child: Text(
                    supportEmail != null
                        ? 'Use Share feedback or Email support to send your message. Saving a draft keeps it on this phone.'
                        : 'Save or copy a draft, or choose where to share it. Sharing does not send it directly to Veea. Find Veea’s support contact in the App Store listing.',
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    key: const Key('feedback_kind'),
                    initialValue: _kind,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Feedback type',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'bug',
                        child: Text('Report a problem'),
                      ),
                      DropdownMenuItem(
                        value: 'feature',
                        child: Text('Request a feature'),
                      ),
                      DropdownMenuItem(
                        value: 'other',
                        child: Text('Other feedback'),
                      ),
                    ],
                    onChanged: feedback.busy
                        ? null
                        : (v) => setState(() => _kind = v!),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('feedback_message'),
                    controller: _message,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 4000,
                    decoration: InputDecoration(
                      labelText: _kind == 'feature'
                          ? 'What would make Veea better?'
                          : 'What happened?',
                      border: const OutlineInputBorder(),
                      alignLabelWithHint: true,
                      hintText: _kind == 'feature'
                          ? 'Tell us what you want to do and why.'
                          : 'What were you doing, and what did you expect?',
                    ),
                    validator: (v) {
                      final length = v?.trim().runes.length ?? 0;
                      if (length < 5) return 'Please add a little more detail.';
                      if (length > 4000) {
                        return 'Please shorten your message. Some emoji use more than one character.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 8),
                  if (_screenshot != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        _screenshot!,
                        height: 180,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Text(
                          'Cannot preview this photo. Please choose a JPG or PNG.',
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: feedback.busy
                          ? null
                          : () => setState(() => _screenshot = null),
                      icon: const Icon(Icons.close),
                      label: const Text('Remove screenshot'),
                    ),
                  ] else
                    OutlinedButton.icon(
                      onPressed: feedback.busy || _picking ? null : _pick,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(
                        _picking ? 'Opening photos…' : 'Add a screenshot',
                      ),
                    ),
                  const Text(
                    'Check screenshots for personal details before sharing.',
                  ),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    key: const Key('feedback_optional_details'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Reply and app details'),
                    subtitle: const Text('Optional'),
                    children: [
                      TextFormField(
                        key: const Key('feedback_contact'),
                        controller: _contact,
                        maxLength: 254,
                        decoration: const InputDecoration(
                          labelText: 'Contact (optional)',
                          hintText: 'Email or other contact for a reply',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      CheckboxListTile(
                        key: const Key('feedback_include_diagnostics'),
                        contentPadding: EdgeInsets.zero,
                        value: _diagnostics,
                        onChanged: feedback.busy
                            ? null
                            : (v) => setState(() => _diagnostics = v!),
                        title: const Text('Include app details'),
                        subtitle: const Text(
                          'App version, platform and this screen. Your words and account details are not included.',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (feedback.error != null)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(feedback.error!),
                      ),
                    ),
                  FilledButton(
                    key: const Key('submit_feedback'),
                    onPressed: feedback.busy ? null : _submit,
                    child: Text(
                      feedback.busy
                          ? 'Saving…'
                          : deliveryEnabled
                          ? 'Send feedback'
                          : 'Save draft on this device',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Builder(
                    builder: (buttonContext) => OutlinedButton.icon(
                      key: const Key('share_feedback_draft'),
                      onPressed: feedback.busy || _handingOff
                          ? null
                          : () => _shareFormDraft(buttonContext),
                      icon: const Icon(Icons.share_outlined),
                      label: const Text('Share feedback'),
                    ),
                  ),
                  if (supportEmail != null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('email_support_draft'),
                      onPressed: feedback.busy || _handingOff
                          ? null
                          : _emailFormDraft,
                      icon: const Icon(Icons.mail_outline),
                      label: const Text('Email support'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Your feedback',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Drafts are saved separately for each account and for guests. Signing in or out changes which drafts appear here.',
            ),
            const SizedBox(height: 8),
            if (feedback.reports.isEmpty)
              Text(
                deliveryEnabled
                    ? 'Your reports, delivery status and replies will appear here.'
                    : 'Saved feedback drafts on this device will appear here so you can share, copy, or discard them.',
              ),
            for (final report in feedback.reports)
              Builder(
                builder: (context) {
                  final draft = FeedbackDraft.fromReport(report);
                  final meta = _draftMetaSummary(draft);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: PixelBox(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            FeedbackService.kindTitle(report.kind),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          Text(report.message),
                          if (meta != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              meta,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            _reportStatusLabel(report, deliveryEnabled),
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          if (report.error != null &&
                              report.queued &&
                              deliveryEnabled)
                            Text(report.error!),
                          if (report.reply?.isNotEmpty == true)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text('Veea: ${report.reply}'),
                            ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              Builder(
                                builder: (shareContext) => TextButton(
                                  key: ValueKey('share_report_${report.id}'),
                                  onPressed: _handingOff
                                      ? null
                                      : () => _shareDraft(
                                          draft,
                                          FeedbackService.resolveShareOrigin(
                                            shareContext,
                                          ),
                                        ),
                                  child: const Text('Share feedback'),
                                ),
                              ),
                              if (supportEmail != null)
                                TextButton(
                                  key: ValueKey('email_report_${report.id}'),
                                  onPressed: _handingOff
                                      ? null
                                      : () => _emailDraft(draft),
                                  child: const Text('Email support'),
                                ),
                              TextButton(
                                key: ValueKey('copy_report_${report.id}'),
                                onPressed: () => _copyDraft(draft),
                                child: const Text('Copy'),
                              ),
                              if (report.queued && deliveryEnabled)
                                TextButton(
                                  onPressed: feedback.refresh,
                                  child: const Text('Try sending again'),
                                ),
                              if (report.queued)
                                TextButton(
                                  key: ValueKey('discard_report_${report.id}'),
                                  onPressed: () => feedback.discard(report.id),
                                  child: const Text('Discard'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            if (communityUrl != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('feedback_zalo_community'),
                onPressed: () => _community(communityUrl),
                icon: const Icon(Icons.groups_outlined),
                label: const Text('Join the Veea Zalo community'),
              ),
              const Text(
                'Chat with other learners. Keep private account details out of the group.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
