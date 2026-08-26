import 'dart:convert';
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
      // 确保 .ps1 文件有 UTF-8 BOM
      if (fileName.endsWith('.ps1')) {
        final bytes = File(candidate).readAsBytesSync();
        if (bytes.length < 3 ||
            bytes[0] != 0xEF ||
            bytes[1] != 0xBB ||
            bytes[2] != 0xBF) {
          final bomFile =
              '${Directory.systemTemp.path}/aswh_bom_$fileName';
          File(bomFile)
              .writeAsBytesSync([0xEF, 0xBB, 0xBF, ...bytes]);
          return _cache[fileName] = File(bomFile).absolute.path;
        }
      }
      return _cache[fileName] = File(candidate).absolute.path;
    }
  }

  final content = await rootBundle.loadString(assetPath);
  final tempDir = Directory.systemTemp.createTempSync('aswh_scripts');
  final scriptFile = File('${tempDir.path}/$fileName');
  // Write with UTF-8 BOM so PowerShell 5.1 can parse Chinese characters correctly
  await scriptFile.writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(content)]);
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

Future<String> resolveDetectHypervScript() {
  return resolveScript(
    fileName: 'detect-hyperv.ps1',
    assetPath: 'scripts/detect-hyperv.ps1',
    envVar: 'ASWH_DETECT_HYPERV_SCRIPT',
  );
}

Future<String> resolveToggleHypervScript() {
  return resolveScript(
    fileName: 'toggle-hyperv.ps1',
    assetPath: 'scripts/toggle-hyperv.ps1',
    envVar: 'ASWH_TOGGLE_HYPERV_SCRIPT',
  );
}

Future<String> resolveCheckEmulatorScript() {
  return resolveScript(
    fileName: 'check-emulator.ps1',
    assetPath: 'scripts/check-emulator.ps1',
    envVar: 'ASWH_CHECK_EMULATOR_SCRIPT',
  );
}

Future<String> resolveSetupSdkScript() {
  return resolveScript(
    fileName: 'setup-sdk.ps1',
    assetPath: 'scripts/setup-sdk.ps1',
    envVar: 'ASWH_SETUP_SDK_SCRIPT',
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
