import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/studio_version_service.dart';
import 'package:androidstudiowinhelper/core/version/archive_version_source.dart';
import 'package:http/http.dart' as http;

Future<void> main() async {
  LogManager.instance.init();

  final frameFile = File(
    r'H:\ProgramSpaceCode\AndroidStudioProjects\AndroidStudioWinHelper\androidstudiowinhelper\query_archive_frame.html',
  );
  if (frameFile.existsSync()) {
    final list =
        ArchiveVersionSource.parseArchiveFrame(frameFile.readAsStringSync());
    stdout.writeln('parsed from saved frame: ${list.length}');
    if (list.isNotEmpty) {
      final v = list.first;
      stdout.writeln('first: ${v.version}');
      stdout.writeln('url: ${v.downloadUrl}');
      stdout.writeln('sha: ${v.sha256}');
    }
    stdout.writeln(
      'with sha256: ${list.where((e) => e.sha256.length == 64).length}',
    );
  }

  final svc = StudioVersionService();
  try {
    final r = await svc.fetchVersions();
    stdout.writeln(
      'live fetch: ${r.versions.length} warnings=${r.warnings.length}',
    );
    stdout.writeln(
      'with url: ${r.versions.where((v) => v.downloadUrl.isNotEmpty).length}',
    );
    for (final w in r.warnings) {
      stdout.writeln('warn: $w');
    }
    if (r.versions.isNotEmpty) {
      final v = r.versions.first;
      stdout.writeln('sample: ${v.version}');
      stdout.writeln('url: ${v.downloadUrl}');
      stdout.writeln('sha: ${v.sha256}');

      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(v.downloadUrl));
        req.headers['Range'] = 'bytes=0-15';
        req.headers['Referer'] = 'https://developer.android.com/studio/archive';
        req.headers['User-Agent'] =
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
        final resp =
            await client.send(req).timeout(const Duration(seconds: 30));
        final bytes = await resp.stream.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        final mz = bytes.length >= 2 && bytes[0] == 0x4D && bytes[1] == 0x5A;
        stdout.writeln(
          'cdn status=${resp.statusCode} type=${resp.headers['content-type']} '
          'bytes=${bytes.length} mz=$mz',
        );
      } finally {
        client.close();
      }
    }
  } finally {
    svc.dispose();
  }
}
