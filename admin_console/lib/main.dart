import 'package:flutter/material.dart';

import 'src/admin_api.dart';
import 'src/console_controller.dart';
import 'src/transport.dart';
import 'src/ui/app.dart';

/// The API origin. Empty (the default) means the console is served from the
/// same origin as the Go API, which is the supported deployment (TRD 07 §3):
/// the Go service sends no CORS headers.
const _apiBase = String.fromEnvironment('VEEA_ADMIN_API_BASE_URL');

String apiBaseUrl() {
  final base = _apiBase.isNotEmpty ? _apiBase : Uri.base.origin;
  return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
}

void main() {
  final controller = ConsoleController(
    AdminApi(AdminTransport(baseUrl: apiBaseUrl())),
  );
  runApp(ConsoleApp(controller: controller));
}
