import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef ScanProgressCallback = void Function(ScanProgress progress);

class DataDirScanner {
  Future<DataDirScanResult> scanAll({
    ScanProgressCallback? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('数据目录扫描仅支持 Windows。');
    }

    final scriptPath = await resolveScanDataDirsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到扫描脚本：$scriptPath');
    }

    if (onProgress == null) {
      return _scanWithoutProgress(scriptFile);
    }

    return _scanWithProgress(scriptFile, onProgress);
  }

  List<String> _powershellArgs(File scriptFile, {required bool withProgress}) {
    return [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptFile.absolute.path,
      '-Json',
      if (withProgress) '-Progress',
    ];
  }

  Future<DataDirScanResult> _scanWithoutProgress(File scriptFile) async {
    final result = await Process.run(
      'powershell.exe',
      _powershellArgs(scriptFile, withProgress: false),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    return _parseProcessOutput(
      stdoutText: _decodeProcessText(result.stdout),
      stderrText: _decodeProcessText(result.stderr),
    );
  }

  Future<DataDirScanResult> _scanWithProgress(
    File scriptFile,
    ScanProgressCallback onProgress,
  ) async {
    final process = await Process.start(
      'powershell.exe',
      _powershellArgs(scriptFile, withProgress: true),
    );

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutBytes = <int>[];

    final stdoutDone = process.stdout.listen(
      (chunk) {
        stdoutBytes.addAll(chunk);
        _drainStdoutLines(stdoutBytes, (line) {
          stdoutBuffer.writeln(line);
          final progress = _parseProgressLine(line);
          if (progress != null) {
            onProgress(progress);
          }
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        stderrBuffer.writeln('stdout 读取失败：$error');
      },
    );

    final stderrDone = process.stderr.listen(
      (chunk) {
        stderrBuffer.write(_decodeBytes(chunk));
      },
      onError: (Object error, StackTrace stackTrace) {
        stderrBuffer.writeln('stderr 读取失败：$error');
      },
    );

    final exitCode = await process.exitCode;
    await stdoutDone.cancel();
    await stderrDone.cancel();

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

    return _parseProcessOutput(
      stdoutText: stdoutBuffer.toString(),
      stderrText: stderrBuffer.toString(),
    );
  }

  void _drainStdoutLines(List<int> buffer, void Function(String line) onLine) {
    while (true) {
      var newlineIndex = buffer.indexOf(10);
      if (newlineIndex == -1) {
        return;
      }

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

  String _decodeProcessText(Object? data) {
    if (data == null) {
      return '';
    }
    if (data is String) {
      return data;
    }
    if (data is List<int>) {
      return _decodeBytes(data);
    }
    return data.toString();
  }

  String _decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) {
      return '';
    }

    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  ScanProgress? _parseProgressLine(String line) {
    if (!line.startsWith('@@PROGRESS|') || !line.endsWith('@@')) {
      return null;
    }

    final body = line.substring('@@PROGRESS|'.length, line.length - 2);
    final parts = body.split('|');
    if (parts.length < 2) {
      return null;
    }

    final percent = int.tryParse(parts[0]) ?? 0;
    final message = parts[1];
    final path = parts.length > 2 ? parts.sublist(2).join('|') : '';

    return ScanProgress(
      percent: percent.clamp(0, 100),
      message: message,
      path: path,
    );
  }

  DataDirScanResult _parseProcessOutput({
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
      return const DataDirScanResult(
        entries: [],
        totalSizeBytes: 0,
        totalSizeHuman: '0 B',
        foundCount: 0,
      );
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('扫描结果格式无效。');
      }
      return DataDirScanResult.fromJson(decoded);
    } on FormatException catch (error) {
      throw StateError('扫描结果 JSON 解析失败：$error');
    }
  }
}
