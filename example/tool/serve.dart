// Minimal static file server that adds the cross-origin-isolation headers
// SharedArrayBuffer requires:
//
//   Cross-Origin-Opener-Policy: same-origin
//   Cross-Origin-Embedder-Policy: require-corp
//
// Usage (after `flutter build web --wasm`):
//
//   dart run tool/serve.dart [directory=build/web] [port=8080]
//
// Zero dependencies (dart:io only) so it runs from any checkout.
import 'dart:io';

const Map<String, String> _mimeByExtension = <String, String>{
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'mjs': 'text/javascript; charset=utf-8',
  'wasm': 'application/wasm',
  'json': 'application/json; charset=utf-8',
  'css': 'text/css; charset=utf-8',
  'png': 'image/png',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'frag': 'application/octet-stream',
};

Future<void> main(List<String> args) async {
  final root = Directory(args.isNotEmpty ? args[0] : 'build/web');
  final port = args.length > 1 ? int.parse(args[1]) : 8080;
  if (!root.existsSync()) {
    stderr.writeln(
      'serve: ${root.path} does not exist — run `flutter build web --wasm` '
      'first (and `bash tool/build_worker.sh` before that).',
    );
    exitCode = 1;
    return;
  }
  final rootPath = root.absolute.uri.toFilePath();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln(
    'Serving ${root.path} on http://localhost:$port with COOP/COEP '
    '(cross-origin isolated)',
  );
  await for (final request in server) {
    final headers = request.response.headers;
    headers.set('Cross-Origin-Opener-Policy', 'same-origin');
    headers.set('Cross-Origin-Embedder-Policy', 'require-corp');
    headers.set('Cache-Control', 'no-cache');

    var path = Uri.decodeComponent(request.uri.path);
    if (path.endsWith('/')) {
      path = '${path}index.html';
    }
    final file = File('$rootPath${path.substring(1)}');
    if (!file.absolute.uri.toFilePath().startsWith(rootPath) ||
        !file.existsSync()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('not found: $path');
      await request.response.close();
      continue;
    }
    final extension = path.split('.').last.toLowerCase();
    headers.contentType = ContentType.parse(
      _mimeByExtension[extension] ?? 'application/octet-stream',
    );
    await request.response.addStream(file.openRead());
    await request.response.close();
  }
}
