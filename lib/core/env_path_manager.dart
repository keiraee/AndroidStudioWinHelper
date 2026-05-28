import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore_for_file: avoid_print

import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef EnvProgressCallback = void Function(ScanProgress progress);

class EnvPathManager {
  Future<EnvPathConfigResult> readConfig({
    EnvProgressCallback? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('环境变量检测仅支持 Windows。');
    }

    final scriptPath = await resolveConfigEnvPathsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到检测脚本：$scriptPath');
    }

    if (onProgress == null) {
      return _readWithoutProgress(scriptFile);
    }

    return _readWithProgress(scriptFile, onProgress);
  }

  Future<EnvPathWriteResult> writeVariable({
    required String variable,
    required String value,
    bool createDir = false,
  }) async {
    return _elevatedWrite(
      scriptArgs: ['-Write', '-VarName', variable, '-VarValue', value],
      createDir: createDir,
    );
  }

  Future<EnvPathWriteResult> appendToPath({
    required String path,
    bool createDir = false,
  }) async {
    return _elevatedWrite(
      scriptArgs: ['-Write', '-AppendPath', path],
      createDir: createDir,
    );
  }

  /// 保存当前环境配置到缓存（写入前调用）
  Future<void> backupCurrentConfig() async {
    try {
      final current = await readConfig();
      ScanCache.saveEnvConfig(current);
    } catch (_) {
      // 备份失败不阻塞主流程
    }
  }

  /// 获取缓存的上一次配置
  EnvPathConfigResult? loadBackup() {
    return ScanCache.loadEnvConfig();
  }

  /// 从缓存回退到上一次配置
  Future<List<EnvPathWriteResult>> rollback() async {
    final backup = ScanCache.loadEnvConfig();
    if (backup == null) {
      throw StateError('没有可回退的配置缓存。');
    }

    final results = <EnvPathWriteResult>[];
    for (final item in backup.items) {
      // 跳过默认路径展示项和未设置的变量
      if (item.variable == 'GRADLE_USER_HOME') continue;
      if (item.source == 'NotSet' || item.currentValue.isEmpty) continue;

      try {
        final result = await writeVariable(
          variable: item.variable,
          value: item.currentValue,
        );
        results.add(result);
      } catch (error) {
        results.add(EnvPathWriteResult(
          success: false,
          variable: item.variable,
          value: item.currentValue,
          error: error.toString(),
        ));
      }
    }

    return results;
  }

  // --- Private: elevated write with result file ---

  Future<EnvPathWriteResult> _elevatedWrite({
    required List<String> scriptArgs,
    bool createDir = false,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('环境变量写入仅支持 Windows。');
    }

    final scriptPath = await resolveConfigEnvPathsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到配置脚本：$scriptPath');
    }

    final resultFile = '${Directory.systemTemp.path}\\aswh_env_result_${DateTime.now().millisecondsSinceEpoch}.json';

    final args = [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptFile.absolute.path,
      ...scriptArgs,
      if (createDir) '-CreateDir',
      '-ResultFile', resultFile,
      '-Json',
    ];

    // Use Start-Process -Verb RunAs for UAC elevation
    final psCommand = 'Start-Process powershell -Verb RunAs -ArgumentList '
        "'${args.join("', '")}' -Wait";

    try {
      final result = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-Command', psCommand],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      if (result.exitCode != 0) {
        // UAC denial or other error
        final stderr = _decodeText(result.stderr);
        if (stderr.contains('cancelled') || stderr.contains('取消')) {
          throw StateError('用户取消了管理员权限请求。');
        }
        throw StateError('提权执行失败（exitCode: ${result.exitCode}）：$stderr');
      }
    } on ProcessException catch (e) {
      if (e.message.contains('740')) {
        throw StateError('需要管理员权限，请在 UAC 弹窗中点击"是"。');
      }
      rethrow;
    }

    // Read the result file
    final resultFileObj = File(resultFile);
    var waitMs = 0;
    while (!resultFileObj.existsSync() && waitMs < 30000) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      waitMs += 200;
    }

    if (!resultFileObj.existsSync()) {
      throw StateError('写入超时：未收到结果文件（可能是 UAC 被拒绝）。');
    }

    try {
      final json = jsonDecode(resultFileObj.readAsStringSync());
      if (json is Map<String, dynamic>) {
        return EnvPathWriteResult.fromJson(json);
      }
      throw StateError('结果文件格式无效。');
    } finally {
      // Clean up temp file
      try {
        resultFileObj.deleteSync();
      } catch (_) {}
    }
  }

  // --- Private: read without progress ---

  Future<EnvPathConfigResult> _readWithoutProgress(File scriptFile) async {
    final result = await Process.run(
      'powershell.exe',
      _powershellArgs(scriptFile, withProgress: false),
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    return _parseOutput(
      stdoutText: _decodeText(result.stdout),
      stderrText: _decodeText(result.stderr),
    );
  }

  // --- Private: read with progress ---

  Future<EnvPathConfigResult> _readWithProgress(
    File scriptFile,
    EnvProgressCallback onProgress,
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

    final stderrDone = process.stderr.listen(
      (chunk) {
        stderrBuffer.write(_decodeBytes(chunk));
      },
      onError: (Object error, StackTrace _) {
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

    return _parseOutput(
      stdoutText: stdoutBuffer.toString(),
      stderrText: stderrBuffer.toString(),
    );
  }

  // --- Helpers ---

  List<String> _powershellArgs(File scriptFile, {required bool withProgress}) {
    return [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptFile.absolute.path,
      '-Json',
      if (withProgress) '-Progress',
    ];
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

  EnvPathConfigResult _parseOutput({
    required String stdoutText,
    required String stderrText,
  }) {
    // Debug: 打印原始输出
    print('[EnvPathManager] stdout (前1000字符): ${stdoutText.length > 1000 ? stdoutText.substring(0, 1000) : stdoutText}');
    if (stderrText.isNotEmpty) {
      print('[EnvPathManager] stderr: $stderrText');
    }

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
      print('[EnvPathManager] JSON 为空，返回空结果');
      return const EnvPathConfigResult(items: [], pathEntries: []);
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('检测结果格式无效。');
      }
      final result = EnvPathConfigResult.fromJson(decoded);
      // Debug: 打印每个 item 的状态
      print('[EnvPathManager] 解析成功: ${result.items.length} 个变量, ${result.pathEntries.length} 个 PATH 条目');
      for (final item in result.items) {
        print('[EnvPathManager]   ${item.variable}: source=${item.source}, exists=${item.exists}, val=${item.currentValue}');
      }
      return result;
    } on FormatException catch (error) {
      print('[EnvPathManager] JSON 解析失败: $error');
      print('[EnvPathManager] jsonText: ${jsonText.length > 500 ? jsonText.substring(0, 500) : jsonText}');
      throw StateError('检测结果 JSON 解析失败：$error');
    }
  }
}
