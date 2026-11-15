// Local same-origin server for the admin console (TRD 07 §3.2). Development only.
//
//   flutter build web
//   dart run tool/serve.dart            # http://127.0.0.1:8090 -> Go API at 127.0.0.1:18386
//
// It serves build/web and proxies /v1/, /healthz and /readyz to the Go API, so the browser
// sees one origin, exactly like the supported deployment behind a reverse proxy. The Go API
// sends no CORS headers, so a console on another origin cannot call it. Binds loopback only.
// Environment: VEEA_ADMIN_CONSOLE_PORT (8090), VEEA_ADMIN_API_UPSTREAM (http://127.0.0.1:18386).
import 'dart:io';

Future<void> main() async {
  final port = int.parse(Platform.environment['VEEA_ADMIN_CONSOLE_PORT'] ?? '8090');
  final upstream = Uri.parse(Platform.environment['VEEA_ADMIN_API_UPSTREAM'] ?? 'http://127.0.0.1:18386');
  if (!{'127.0.0.1', 'localhost', '::1'}.contains(upstream.host)) {
    stderr.writeln('refusing a non-loopback upstream: this server is for local development only');
    exit(2);
  }
  final root = Directory('build/web');
  if (!root.existsSync()) {
    stderr.writeln('build/web is missing: run `flutter build web` first');
    exit(2);
  }
  final client = HttpClient();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('admin console on http://127.0.0.1:$port (API: $upstream)');
  await for (final req in server) {
    final res = req.response;
    res.headers
      ..set('x-frame-options', 'DENY')
      ..set('x-content-type-options', 'nosniff')
      ..set('referrer-policy', 'no-referrer');
    final path = req.uri.path;
    try {
      if (path.startsWith('/v1/') || path == '/healthz' || path == '/readyz') {
        final out = await client.openUrl(req.method, upstream.replace(path: path, query: req.uri.hasQuery ? req.uri.query : null));
        req.headers.forEach((name, values) {
          if (name != 'host') {
            for (final v in values) {
              out.headers.add(name, v);
            }
          }
        });
        await out.addStream(req);
        final back = await out.close();
        res.statusCode = back.statusCode;
        back.headers.forEach((name, values) {
          if (name != 'transfer-encoding' && name != 'connection') {
            for (final v in values) {
              res.headers.add(name, v);
            }
          }
        });
        await res.addStream(back);
      } else {
        final rel = path == '/' ? 'index.html' : path.substring(1);
        final file = File('${root.path}/$rel');
        final inside = file.absolute.path.startsWith(root.absolute.path) && !rel.contains('..');
        final target = inside && file.existsSync() ? file : File('${root.path}/index.html');
        res.headers.contentType = _type(target.path);
        if (target.path.endsWith('index.html')) res.headers.set('cache-control', 'no-store');
        await res.addStream(target.openRead());
      }
    } on Object {
      res.statusCode = HttpStatus.badGateway;
    }
    await res.close();
  }
}

ContentType _type(String p) {
  if (p.endsWith('.html')) return ContentType.html;
  if (p.endsWith('.js')) return ContentType('application', 'javascript', charset: 'utf-8');
  if (p.endsWith('.json')) return ContentType.json;
  if (p.endsWith('.png')) return ContentType('image', 'png');
  if (p.endsWith('.wasm')) return ContentType('application', 'wasm');
  if (p.endsWith('.otf') || p.endsWith('.ttf')) return ContentType('font', 'otf');
  return ContentType.binary;
}
