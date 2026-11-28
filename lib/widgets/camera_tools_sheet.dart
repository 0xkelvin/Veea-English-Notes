import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../screens/camera_tutor_screen.dart';
import '../screens/pixel_lens_screen.dart';
import '../services/audio_commute_service.dart';
import '../services/tts_service.dart';

Future<void> showCameraTools(BuildContext context) async {
  final tutor = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Learn with your camera',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            ListTile(
              key: const Key('open_camera_tutor'),
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('Camera tutor'),
              subtitle: const Text(
                'Ask about objects and learn English · iPhone preview',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(sheetContext, true),
            ),
            ListTile(
              key: const Key('open_camera_scan'),
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('Scan text'),
              subtitle: const Text(
                'Pick English words from a photo or screenshot',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(sheetContext, false),
            ),
          ],
        ),
      ),
    ),
  );
  if (tutor == null || !context.mounted) return;
  if (tutor) {
    context.read<AudioCommuteService?>()?.pause();
    await context.read<TtsService?>()?.stop();
    if (!context.mounted) return;
  }
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          tutor ? const CameraTutorScreen() : const PixelLensScreen(),
    ),
  );
}
