import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/powershell_runner.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef DetectProgressCallback = void Function(ScanProgress progress);

class AndroidStudioDetector {
  AndroidStudioDetector({this.scriptPath, PowerShellRunner? runner})
      : _runner = runner ?? PowerShellRunner(logTag: 'Detect');

  final String? scriptPath;
  final PowerShellRunner _runner;

  Future<AndroidStudioDetectionResult> detectAll({
    bool deepScan = false,
    DetectProgressCallback? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Android Studio 检测仅支持 Windows。');
    }

    final resolvedScriptPath =
        scriptPath ?? await resolveDetectScript();
    final scriptFile = File(resolvedScriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到检测脚本：$resolvedScriptPath');
    }

    final extraArgs = [
      '-Json',
      if (deepScan) '-DeepScan',
    ];

    final result = await _runner.run(
      scriptPath: scriptFile.absolute.path,
      extraArgs: extraArgs,
      onProgress: onProgress,
    );

    if (!result.success && result.stdout.isEmpty) {
      throw StateError('PowerShell 执行失败：${result.stderr}');
    }

    return _parseOutput(result);
  }

  AndroidStudioDetectionResult _parseOutput(PowerShellResult result) {
    // 优先用 @@RESULT|@@ 标记提取的 JSON
    if (result.jsonResult != null) {
      final installs = _parseInstalls(result.jsonResult);
      final selected = _selectDefaultInstall(installs);
      return AndroidStudioDetectionResult(
        installs: installs,
        selected: selected?.$1,
        selectionReason: selected?.$2,
      );
    }

    // 回退：从 stdout 中提取 JSON
    final stdoutText = result.stdout;
    final marker = '@@RESULT|';
    final startIdx = stdoutText.indexOf(marker);
    final String jsonText;
    if (startIdx >= 0) {
      final afterMarker = startIdx + marker.length;
      final endIdx = stdoutText.indexOf('@@', afterMarker);
      if (endIdx > afterMarker) {
        jsonText = stdoutText.substring(afterMarker, endIdx).trim();
      } else {
        jsonText = stdoutText.substring(afterMarker).trim();
      }
    } else {
      jsonText = stdoutText
          .split('\n')
          .where((line) => !line.trim().startsWith('@@PROGRESS|'))
          .join('\n')
          .trim();
    }

    if (jsonText.isEmpty) {
      return const AndroidStudioDetectionResult(installs: []);
    }

    final decoded = jsonDecode(jsonText);
    final installs = _parseInstalls(decoded);
    final selected = _selectDefaultInstall(installs);

    return AndroidStudioDetectionResult(
      installs: installs,
      selected: selected?.$1,
      selectionReason: selected?.$2,
    );
  }

  List<AndroidStudioInstall> _parseInstalls(Object? decoded) {
    if (decoded is List) {
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(AndroidStudioInstall.fromJson)
          .where((item) => item.isValid)
          .toList();
    }

    if (decoded is Map<String, dynamic>) {
      final install = AndroidStudioInstall.fromJson(decoded);
      return install.isValid ? [install] : [];
    }

    return [];
  }

  (AndroidStudioInstall, AndroidStudioSelectionReason)? _selectDefaultInstall(
    List<AndroidStudioInstall> installs,
  ) {
    if (installs.isEmpty) return null;

    if (installs.length == 1) {
      return (installs.first, AndroidStudioSelectionReason.onlyCandidate);
    }

    final running = installs.where(
      (item) => item.source.contains('运行中进程'),
    );
    if (running.length == 1) {
      return (running.first, AndroidStudioSelectionReason.runningProcess);
    }

    final sorted = [...installs]
      ..sort((a, b) => _compareVersion(b.build, a.build));
    return (sorted.first, AndroidStudioSelectionReason.highestVersion);
  }

  int _compareVersion(String left, String right) {
    final leftParts = _splitVersion(left);
    final rightParts = _splitVersion(right);

    final maxLength = leftParts.length > rightParts.length
        ? leftParts.length
        : rightParts.length;

    for (var i = 0; i < maxLength; i++) {
      final leftValue = i < leftParts.length ? leftParts[i] : 0;
      final rightValue = i < rightParts.length ? rightParts[i] : 0;
      if (leftValue != rightValue) {
        return leftValue.compareTo(rightValue);
      }
    }

    return 0;
  }

  List<int> _splitVersion(String value) {
    if (value.isEmpty) return const [0];

    return value
        .split(RegExp(r'[^0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
  }
}
