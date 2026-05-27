import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef DetectProgressCallback = void Function(ScanProgress progress);

class AndroidStudioDetector {
  AndroidStudioDetector({this.scriptPath});

  final String? scriptPath;

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

    if (onProgress == null) {
      return _detectWithoutProgress(scriptFile, deepScan);
    }

    return _detectWithProgress(scriptFile, deepScan, onProgress);
  }

  List<String> _powershellArgs(File scriptFile, bool deepScan, bool withProgress) {
    return [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptFile.absolute.path,
      '-Json',
      if (withProgress) '-Progress',
      if (deepScan) '-DeepScan',
    ];
  }

  Future<AndroidStudioDetectionResult> _detectWithoutProgress(
    File scriptFile,
    bool deepScan,
  ) async {
    final result = await Process.run(
      'powershell.exe',
      _powershellArgs(scriptFile, deepScan, false),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    return _parseOutput(
      stdoutText: _decodeText(result.stdout),
      stderrText: _decodeText(result.stderr),
    );
  }

  Future<AndroidStudioDetectionResult> _detectWithProgress(
    File scriptFile,
    bool deepScan,
    DetectProgressCallback onProgress,
  ) async {
    final process = await Process.start(
      'powershell.exe',
      _powershellArgs(scriptFile, deepScan, true),
    );

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutBytes = <int>[];

    process.stdout.listen(
      (chunk) {
        stdoutBytes.addAll(chunk);
        _drainLines(stdoutBytes, (line) {
          stdoutBuffer.writeln(line);
          final progress = _parseProgressLine(line);
          if (progress != null) {
            onProgress(progress);
          }
        });
      },
      onError: (Object error, StackTrace _) {
        stderrBuffer.writeln('stdout 读取失败：$error');
      },
    );

    process.stderr.listen(
      (chunk) {
        stderrBuffer.write(_decodeBytes(chunk));
      },
      onError: (Object error, StackTrace _) {
        stderrBuffer.writeln('stderr 读取失败：$error');
      },
    );

    final exitCode = await process.exitCode;

    if (stdoutBytes.isNotEmpty) {
      final remaining = _decodeBytes(stdoutBytes);
      if (remaining.trim().isNotEmpty) {
        stdoutBuffer.writeln(remaining);
        for (final line in remaining.split('\n')) {
          final progress = _parseProgressLine(line.trim());
          if (progress != null) {
            onProgress(progress);
          }
        }
      }
    }

    if (exitCode != 0 && stdoutBuffer.isEmpty) {
      throw StateError('PowerShell 执行失败：${stderrBuffer.toString()}');
    }

    return _parseOutput(
      stdoutText: stdoutBuffer.toString(),
      stderrText: stderrBuffer.toString(),
    );
  }

  void _drainLines(List<int> buffer, void Function(String line) onLine) {
    while (true) {
      var newlineIndex = buffer.indexOf(10);
      if (newlineIndex == -1) return;

      var lineBytes = buffer.sublist(0, newlineIndex);
      buffer.removeRange(0, newlineIndex + 1);

      if (lineBytes.isNotEmpty && lineBytes.last == 13) {
        lineBytes = lineBytes.sublist(0, lineBytes.length - 1);
      }

      final line = _decodeBytes(lineBytes).trim();
      if (line.isNotEmpty) {
        onLine(line);
      }
    }
  }

  String _decodeText(Object? data) {
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) return _decodeBytes(data);
    return data.toString();
  }

  String _decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  ScanProgress? _parseProgressLine(String line) {
    if (!line.startsWith('@@PROGRESS|') || !line.endsWith('@@')) return null;

    final body = line.substring('@@PROGRESS|'.length, line.length - 2);
    final parts = body.split('|');
    if (parts.length < 2) return null;

    final percent = int.tryParse(parts[0]) ?? 0;
    final message = parts[1];
    final path = parts.length > 2 ? parts.sublist(2).join('|') : '';

    return ScanProgress(
      percent: percent.clamp(0, 100),
      message: message,
      path: path,
    );
  }

  AndroidStudioDetectionResult _parseOutput({
    required String stdoutText,
    required String stderrText,
  }) {
    final resultMatch = RegExp(
      r'@@RESULT\|(.+?)@@',
      dotAll: true,
    ).firstMatch(stdoutText);

    final jsonText = resultMatch != null
        ? resultMatch.group(1)!.trim()
        : stdoutText
            .split('\n')
            .where((line) => !line.trim().startsWith('@@PROGRESS|'))
            .join('\n')
            .trim();

    if (stderrText.isNotEmpty && jsonText.isEmpty) {
      throw StateError('PowerShell 执行失败：$stderrText');
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
