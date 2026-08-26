import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/powershell_runner.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef EnvProgressCallback = void Function(ScanProgress progress);

class EnvPathManager {
  EnvPathManager({PowerShellRunner? runner})
      : _runner = runner ?? PowerShellRunner(logTag: 'EnvPath');

  final PowerShellRunner _runner;

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

    final result = await _runner.run(
      scriptPath: scriptFile.absolute.path,
      extraArgs: ['-Json'],
      onProgress: onProgress,
    );

    if (!result.success && result.stdout.isEmpty) {
      throw StateError('PowerShell 执行失败：${result.stderr}');
    }

    return _parseOutput(result);
  }

  Future<EnvPathWriteResult> writeVariable({
    required String variable,
    required String value,
    bool createDir = false,
    String scope = 'Machine',
    bool unset = false,
  }) async {
    return _elevatedWrite(
      scriptArgs: [
        '-Write',
        '-VarName', variable,
        '-Scope', scope,
        if (unset) '-Unset' else ...['-VarValue', value],
      ],
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
      if (item.variable == 'GRADLE_USER_HOME') continue;

      try {
        // 备份时未设置：删除 ASWH 写入的 Machine 变量
        if (item.source == 'NotSet' || item.currentValue.isEmpty) {
          results.add(await writeVariable(
            variable: item.variable,
            value: '',
            unset: true,
            scope: 'Machine',
          ));
          continue;
        }

        final scope = item.source == 'User' ? 'User' : 'Machine';

        // 原为 User：清掉可能被写成 Machine 的覆盖值，再恢复 User
        if (scope == 'User') {
          results.add(await writeVariable(
            variable: item.variable,
            value: '',
            unset: true,
            scope: 'Machine',
          ));
        }

        results.add(await writeVariable(
          variable: item.variable,
          value: item.currentValue,
          scope: scope,
        ));
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

  // ── 提权写入 ──

  // 串行锁：确保同一时间只有一个提权写入在执行
  // 避免多个 UAC 弹窗和轮询计时器交错
  static Future<void>? _writeLock;

  Future<EnvPathWriteResult> _elevatedWrite({
    required List<String> scriptArgs,
    bool createDir = false,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('环境变量写入仅支持 Windows。');
    }

    // 等待前一个写入完成（串行执行）
    while (_writeLock != null) {
      await _writeLock;
    }
    final completer = Completer<void>();
    _writeLock = completer.future;

    try {
      return await _doElevatedWrite(scriptArgs: scriptArgs, createDir: createDir);
    } finally {
      completer.complete();
      _writeLock = null;
    }
  }

  Future<EnvPathWriteResult> _doElevatedWrite({
    required List<String> scriptArgs,
    bool createDir = false,
  }) async {
    final scriptPath = await resolveConfigEnvPathsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到配置脚本：$scriptPath');
    }

    final resultFile = '${Directory.systemTemp.path}\\aswh_env_result_${DateTime.now().millisecondsSinceEpoch}.json';

    final args = [
      ...scriptArgs,
      if (createDir) '-CreateDir',
      '-ResultFile', resultFile,
      '-Json',
    ];

    final result = await _runner.runElevated(
      scriptPath: scriptFile.absolute.path,
      extraArgs: args,
    );

    // 读取结果文件
    final resultFileObj = File(resultFile);
    if (!resultFileObj.existsSync()) {
      // 如果 runElevated 没有抛异常但结果文件不存在，用 result 的 jsonResult
      if (result.jsonResult != null) {
        return EnvPathWriteResult.fromJson(result.jsonResult!);
      }
      throw StateError('写入失败：未收到结果文件。');
    }

    try {
      final json = jsonDecode(resultFileObj.readAsStringSync());
      if (json is Map<String, dynamic>) {
        return EnvPathWriteResult.fromJson(json);
      }
      throw StateError('结果文件格式无效。');
    } finally {
      try { resultFileObj.deleteSync(); } catch (_) {}
    }
  }

  // ── 结果解析 ──

  EnvPathConfigResult _parseOutput(PowerShellResult result) {
    final _log = (String msg) => LogManager.instance.write('EnvPath', msg);

    // 优先用 jsonResult
    if (result.jsonResult != null) {
      final parsed = EnvPathConfigResult.fromJson(result.jsonResult!);
      _log('解析成功: ${parsed.items.length} 个变量, ${parsed.pathEntries.length} 个 PATH 条目');
      return parsed;
    }

    // 回退：从 stdout 提取
    final stdoutText = result.stdout;
    _log('stdout (前1000字符): ${stdoutText.length > 1000 ? stdoutText.substring(0, 1000) : stdoutText}');

    const marker = '@@RESULT|';
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

    if (result.stderr.isNotEmpty && jsonText.isEmpty) {
      throw StateError('PowerShell 执行失败：${result.stderr}');
    }

    if (jsonText.isEmpty) {
      _log('JSON 为空，返回空结果');
      return const EnvPathConfigResult(items: [], pathEntries: []);
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('检测结果格式无效。');
      }
      final parsed = EnvPathConfigResult.fromJson(decoded);
      _log('解析成功: ${parsed.items.length} 个变量, ${parsed.pathEntries.length} 个 PATH 条目');
      return parsed;
    } on FormatException catch (error) {
      _log('JSON 解析失败: $error');
      throw StateError('检测结果 JSON 解析失败：$error');
    }
  }
}
