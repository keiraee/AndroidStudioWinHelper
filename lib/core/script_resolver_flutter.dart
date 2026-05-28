import 'dart:io';

import 'package:flutter/services.dart';

final _cache = <String, String>{};

Future<String> resolveScript({
  required String fileName,
  required String assetPath,
  String? envVar,
}) async {
  final cached = _cache[fileName];
  if (cached != null && File(cached).existsSync()) {
    return cached;
  }

  if (envVar != null) {
    final envPath = Platform.environment[envVar];
    if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
      return _cache[fileName] = File(envPath).absolute.path;
    }
  }

  for (final candidate in _projectCandidates(fileName)) {
    if (File(candidate).existsSync()) {
      return _cache[fileName] = File(candidate).absolute.path;
    }
  }

  final content = await rootBundle.loadString(assetPath);
  final tempDir = Directory.systemTemp.createTempSync('aswh_scripts');
  final scriptFile = File('${tempDir.path}/$fileName');
  await scriptFile.writeAsString(content);
  return _cache[fileName] = scriptFile.absolute.path;
}

Future<String> resolveDetectScript() {
  return resolveScript(
    fileName: 'detect-android-studio.ps1',
    assetPath: 'scripts/detect-android-studio.ps1',
    envVar: 'ASWH_DETECT_SCRIPT',
  );
}

Future<String> resolveScanDataDirsScript() {
  return resolveScript(
    fileName: 'scan-data-dirs.ps1',
    assetPath: 'scripts/scan-data-dirs.ps1',
    envVar: 'ASWH_SCAN_DATA_DIRS_SCRIPT',
  );
}

Future<String> resolveConfigEnvPathsScript() {
  return resolveScript(
    fileName: 'config-env-paths.ps1',
    assetPath: 'scripts/config-env-paths.ps1',
    envVar: 'ASWH_CONFIG_ENV_SCRIPT',
  );
}

Iterable<String> _projectCandidates(String fileName) sync* {
  final cwd = Directory.current.path;
  yield _join(cwd, 'scripts/$fileName');
  yield _join(cwd, '../scripts/$fileName');

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  yield _join(exeDir, 'scripts/$fileName');
  yield _join(exeDir, '../../scripts/$fileName');
  yield _join(exeDir, '../../../scripts/$fileName');
}

String _join(String base, String relative) {
  final normalizedBase = base.replaceAll('/', Platform.pathSeparator);
  final normalizedRelative = relative.replaceAll('/', Platform.pathSeparator);
  return '$normalizedBase${Platform.pathSeparator}$normalizedRelative';
}
