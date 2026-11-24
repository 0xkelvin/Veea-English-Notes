import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/config/app_config.dart';
import '../data/feedback_repository.dart';

/// User-controlled feedback draft ready to copy, share, or open in mail compose.
///
/// Only explicit user-entered fields and opt-in app details are included.
/// Account IDs, account emails, auth tokens, and saved vocabulary words are
/// never added automatically.
class FeedbackDraft {
  const FeedbackDraft({
    required this.kind,
    required this.message,
    this.contact,
    this.includeDiagnostics = false,
    this.diagnostics,
    this.screenshotBytes,
    this.createdAt,
  });

  final String kind;
  final String message;
  final String? contact;
  final bool includeDiagnostics;
  final Map<String, String>? diagnostics;
  final Uint8List? screenshotBytes;
  final DateTime? createdAt;

  bool get hasScreenshot =>
      screenshotBytes != null && screenshotBytes!.isNotEmpty;

  factory FeedbackDraft.fromReport(FeedbackReport report) {
    final parsedDiagnostics = _parseSafeDiagnostics(report.data['diagnostics']);
    Uint8List? screenshot;
    final encoded = report.data['screenshot_base64'];
    if (encoded is String && encoded.isNotEmpty) {
      try {
        screenshot = base64Decode(encoded);
      } catch (_) {
        screenshot = null;
      }
    }
    DateTime? createdAt;
    final rawCreatedAt = report.data['created_at'];
    if (rawCreatedAt is String && rawCreatedAt.isNotEmpty) {
      createdAt = DateTime.tryParse(rawCreatedAt);
    }
    return FeedbackDraft(
      kind: report.kind,
      message: report.message,
      contact: report.data['contact'] as String?,
      includeDiagnostics: parsedDiagnostics.isNotEmpty,
      diagnostics: parsedDiagnostics.isEmpty ? null : parsedDiagnostics,
      screenshotBytes: screenshot,
      createdAt: createdAt,
    );
  }

  static Map<String, String> _parseSafeDiagnostics(Object? raw) {
    Object? decoded = raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        return const {};
      }
    }
    if (decoded is! Map) return const {};
    const allowedKeys = {'app_version', 'platform', 'screen'};
    final result = <String, String>{};
    for (final key in allowedKeys) {
      final value = decoded[key];
      if (value is String && value.trim().isNotEmpty) {
        result[key] = value.trim();
      }
    }
    return result;
  }
}

enum FeedbackHandoffStatus {
  /// The draft was handed off to the native share sheet or mail composer.
  /// Veea does not send it automatically and cannot confirm receipt.
  handedOff,

  /// The user dismissed or cancelled the share sheet.
  cancelled,

  /// Sharing or mail compose is unavailable on this device or configuration.
  unavailable,

  /// A platform error prevented opening the share sheet or mail composer.
  failed,
}

class FeedbackHandoffResult {
  const FeedbackHandoffResult({
    required this.status,
    required this.message,
    this.attachmentIncluded = false,
  });

  final FeedbackHandoffStatus status;
  final String message;
  final bool attachmentIncluded;

  bool get isHandedOff => status == FeedbackHandoffStatus.handedOff;
}

typedef FeedbackShareHandler = Future<ShareResult> Function(ShareParams params);
typedef FeedbackUrlLauncher =
    Future<bool> Function(Uri uri, {required LaunchMode mode});

class FeedbackService {
  const FeedbackService._();

  static FeedbackShareHandler? _shareOverride;
  static FeedbackUrlLauncher? _launchOverride;

  @visibleForTesting
  static void overrideHandlers({
    FeedbackShareHandler? share,
    FeedbackUrlLauncher? launch,
  }) {
    assert(() {
      _shareOverride = share;
      _launchOverride = launch;
      return true;
    }());
  }

  static String kindTitle(String kind) => switch (kind) {
    'feature' => 'Feature request',
    'bug' => 'Problem report',
    _ => 'Other feedback',
  };

  static String subjectFor(FeedbackDraft draft) =>
      '[Veea English] ${kindTitle(draft.kind)}';

  static Map<String, String> defaultDiagnostics() => {
    'app_version': AppConfig.appVersion,
    'platform': defaultTargetPlatform.name,
    'screen': 'feedback',
  };

  /// Formats a user-controlled feedback draft for copy, share, or email compose.
  ///
  /// Diagnostics are omitted unless [FeedbackDraft.includeDiagnostics] is true.
  /// If a screenshot is present on the draft but not attached to this handoff,
  /// the formatted body explicitly notes that the attachment is not included.
  static String formatDraft(
    FeedbackDraft draft, {
    bool screenshotAttached = false,
  }) {
    final buffer = StringBuffer()
      ..writeln('Veea English — ${kindTitle(draft.kind)}')
      ..writeln()
      ..writeln(draft.message.trim());

    final contact = draft.contact?.trim();
    if (contact != null && contact.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('Reply contact: $contact');
    }

    if (draft.includeDiagnostics) {
      final details =
          (draft.diagnostics != null && draft.diagnostics!.isNotEmpty)
          ? draft.diagnostics!
          : defaultDiagnostics();
      buffer
        ..writeln()
        ..writeln('App details:');
      if (details['app_version'] != null) {
        buffer.writeln('- App version: ${details['app_version']}');
      }
      if (details['platform'] != null) {
        buffer.writeln('- Platform: ${details['platform']}');
      }
      if (details['screen'] != null) {
        buffer.writeln('- Screen: ${details['screen']}');
      }
    }

    if (draft.hasScreenshot && !screenshotAttached) {
      buffer
        ..writeln()
        ..writeln(
          'Attachment note: A screenshot was selected for this feedback, '
          'but it is not attached automatically here. Attach it manually if needed.',
        );
    }

    return buffer.toString().trimRight();
  }

  /// Computes a guaranteed-valid non-zero global rect for iPad share popovers.
  static Rect resolveShareOrigin(BuildContext context) {
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox &&
        renderObject.hasSize &&
        renderObject.size.width > 0 &&
        renderObject.size.height > 0) {
      final origin = renderObject.localToGlobal(Offset.zero);
      final rect = origin & renderObject.size;
      if (_isValidRect(rect)) return rect;
    }
    final size = MediaQuery.maybeSizeOf(context);
    if (size != null && size.width > 0 && size.height > 0) {
      return Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2),
        width: 1,
        height: 1,
      );
    }
    return const Rect.fromLTWH(0, 0, 1, 1);
  }

  /// Normalizes any provided share origin to a valid positive-area [Rect].
  static Rect sanitizeShareOrigin(Rect? origin) {
    if (origin != null && _isValidRect(origin)) return origin;
    return const Rect.fromLTWH(0, 0, 1, 1);
  }

  static bool _isValidRect(Rect rect) =>
      rect.left.isFinite &&
      rect.top.isFinite &&
      rect.width.isFinite &&
      rect.height.isFinite &&
      rect.width > 0 &&
      rect.height > 0;

  static ({String filename, String mimeType})? _detectImageMeta(
    Uint8List bytes,
  ) {
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      return (filename: 'veea_feedback_screenshot.jpg', mimeType: 'image/jpeg');
    }
    if (bytes.length >= 8 &&
        listEquals(bytes.sublist(0, 8), const [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ])) {
      return (filename: 'veea_feedback_screenshot.png', mimeType: 'image/png');
    }
    return null;
  }

  /// Hands off [draft] to the system share sheet using `share_plus`.
  ///
  /// Includes the screenshot as a file attachment when present and valid.
  /// Never sends automatically or marks a saved report as received/sent.
  static Future<FeedbackHandoffResult> shareDraft(
    FeedbackDraft draft, {
    Rect? sharePositionOrigin,
  }) async {
    final origin = sanitizeShareOrigin(sharePositionOrigin);
    final subject = subjectFor(draft);
    final imageMeta = draft.hasScreenshot
        ? _detectImageMeta(draft.screenshotBytes!)
        : null;
    final attachImage = imageMeta != null;
    final body = formatDraft(draft, screenshotAttached: attachImage);
    final shareFn = _shareOverride ?? SharePlus.instance.share;

    try {
      final params = attachImage
          ? ShareParams(
              text: body,
              subject: subject,
              files: [
                XFile.fromData(
                  draft.screenshotBytes!,
                  name: imageMeta.filename,
                  mimeType: imageMeta.mimeType,
                ),
              ],
              fileNameOverrides: [imageMeta.filename],
              sharePositionOrigin: origin,
            )
          : ShareParams(
              text: body,
              subject: subject,
              sharePositionOrigin: origin,
            );
      final result = await shareFn(params);
      return switch (result.status) {
        ShareResultStatus.success => FeedbackHandoffResult(
          status: FeedbackHandoffStatus.handedOff,
          attachmentIncluded: attachImage,
          message: attachImage
              ? 'Draft and screenshot handed off to the app you chose. Veea does not send feedback automatically.'
              : draft.hasScreenshot
              ? 'Feedback text handed off without the screenshot attachment. Veea does not send feedback automatically.'
              : 'Draft handed off to the app you chose. Veea does not send feedback automatically.',
        ),
        ShareResultStatus.dismissed => const FeedbackHandoffResult(
          status: FeedbackHandoffStatus.cancelled,
          message: 'Sharing was cancelled. Nothing was sent.',
        ),
        ShareResultStatus.unavailable => const FeedbackHandoffResult(
          status: FeedbackHandoffStatus.unavailable,
          message:
              'Sharing is not available on this device. You can copy your feedback text instead.',
        ),
      };
    } catch (e) {
      debugPrint('Could not open share sheet for feedback: $e');
      return const FeedbackHandoffResult(
        status: FeedbackHandoffStatus.failed,
        message:
            'Could not open the share sheet. You can copy your feedback text instead.',
      );
    }
  }

  /// Builds a percent-encoded `mailto:` URI for a validated support email.
  static Uri buildMailtoUri({
    required String email,
    required FeedbackDraft draft,
  }) {
    final subject = subjectFor(draft);
    // mailto: URIs cannot carry binary file attachments.
    final body = formatDraft(draft, screenshotAttached: false);
    return Uri(
      scheme: 'mailto',
      path: email,
      query:
          'subject=${Uri.encodeComponent(subject)}'
          '&body=${Uri.encodeComponent(body)}',
    );
  }

  /// Opens the system email composer for the configured support mailbox.
  ///
  /// Fails closed if no validated support email is configured for this build.
  /// Never sends automatically or marks a saved report as received/sent.
  static Future<FeedbackHandoffResult> openEmailDraft(
    FeedbackDraft draft,
  ) async {
    final email = AppConfig.supportEmail;
    if (email == null) {
      return const FeedbackHandoffResult(
        status: FeedbackHandoffStatus.unavailable,
        message:
            'No support email is configured in this build. Use Share feedback or Copy instead.',
      );
    }

    final uri = buildMailtoUri(email: email, draft: draft);
    final launcher = _launchOverride ?? launchUrl;
    try {
      final launched = await launcher(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        return FeedbackHandoffResult(
          status: FeedbackHandoffStatus.handedOff,
          attachmentIncluded: false,
          message: draft.hasScreenshot
              ? 'Email draft opened for $email. Your screenshot is not attached—attach it in your mail app or use Share feedback.'
              : 'Email draft opened for $email. Send it from your mail app when ready.',
        );
      }
      return const FeedbackHandoffResult(
        status: FeedbackHandoffStatus.unavailable,
        message:
            'No email app is available on this device. You can share or copy your feedback draft instead.',
      );
    } catch (e) {
      debugPrint('Could not launch email client: $e');
      return const FeedbackHandoffResult(
        status: FeedbackHandoffStatus.failed,
        message:
            'Could not open an email app. You can share or copy your feedback draft instead.',
      );
    }
  }

  /// Opens an externally validated HTTPS URL in the system browser.
  static Future<bool> openTrustedUrl(Uri uri) async {
    final validated = AppConfig.parseTrustedHttpsUrl(uri.toString());
    if (validated == null) return false;
    final launcher = _launchOverride ?? launchUrl;
    try {
      return await launcher(validated, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('Could not open external URL: $e');
      return false;
    }
  }
}
