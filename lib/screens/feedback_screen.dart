import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/config/app_config.dart';
import '../providers/feedback_provider.dart';
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
  bool _diagnostics = false, _picking = false;
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Choose a smaller screenshot, under 512 KB.'),
          ),
        );
      } else {
        setState(() => _screenshot = bytes);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not open that photo. Please try another.'),
          ),
        );
      }
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Feedback saved. Check its delivery status below.'),
      ),
    );
    await feedback.refresh();
  }

  Future<void> _community(String url) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open Zalo. Please try again later.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final feedback = context.watch<FeedbackProvider>();
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
            if (!AppConfig.isCloudEnabled)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'Feedback delivery is coming soon. Saved feedback will send when it is available. You can copy or discard it below.',
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
                    validator: (v) => (v?.trim().runes.length ?? 0) < 5
                        ? 'Please add a little more detail.'
                        : null,
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
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Reply and app details'),
                    subtitle: const Text('Optional'),
                    children: [
                      TextFormField(
                        controller: _contact,
                        maxLength: 254,
                        decoration: const InputDecoration(
                          labelText: 'Contact (optional)',
                          hintText: 'Email or Zalo number for a reply',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _diagnostics,
                        onChanged: feedback.busy
                            ? null
                            : (v) => setState(() => _diagnostics = v!),
                        title: const Text('Include app details'),
                        subtitle: const Text(
                          'App version, platform and this screen. Your words and phone number are not included.',
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
                          : AppConfig.isCloudEnabled
                          ? 'Send feedback'
                          : 'Save feedback on this device',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Text(
              'Your feedback',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (feedback.reports.isEmpty)
              const Text(
                'Your reports, delivery status and replies will appear here.',
              ),
            for (final report in feedback.reports)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: PixelBox(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        report.kind == 'feature'
                            ? 'Feature request'
                            : report.kind == 'bug'
                            ? 'Problem report'
                            : 'Feedback',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(report.message),
                      const SizedBox(height: 8),
                      Text(
                        report.statusLabel,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      if (report.error != null && report.queued)
                        Text(report.error!),
                      if (report.reply?.isNotEmpty == true)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text('Veea: ${report.reply}'),
                        ),
                      Wrap(
                        spacing: 12,
                        children: [
                          TextButton(
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: report.message),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Feedback copied'),
                                  ),
                                );
                              }
                            },
                            child: const Text('Copy'),
                          ),
                          if (report.queued && AppConfig.isCloudEnabled)
                            TextButton(
                              onPressed: feedback.refresh,
                              child: const Text('Try sending again'),
                            ),
                          if (report.queued)
                            TextButton(
                              onPressed: () => feedback.discard(report.id),
                              child: const Text('Discard'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (feedback.communityUrl != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _community(feedback.communityUrl!),
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
