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
        '-VarName',
        variable,
        '-Scope',
        scope,
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

  /// 选盘后提权创建 `{盘}:\Android`，确认该盘可写。
  Future<EnvPathWriteResult> prepareAndroidRoot(String rootPath) {
    return _elevatedWrite(
      scriptArgs: ['-Write', '-PrepareRoot', '-RootPath', rootPath],
    );
  }

  /// 一次提权写入多个系统环境变量并回读校验。
  Future<EnvPathBatchWriteResult> writeBatch({
    required Map<String, String> variables,
    List<String> appendPath = const [],
    bool createDir = true,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('环境变量写入仅支持 Windows。');
    }
    final payload = {
      'createDir': createDir,
      'variables': [
        for (final e in variables.entries) {'name': e.key, 'value': e.value},
      ],
      'appendPath': appendPath,
    };
    final batchFile = File(
      '${Directory.systemTemp.path}\\aswh_env_batch_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    batchFile.writeAsStringSync(
      const JsonEncoder().convert(payload),
      flush: true,
    );

    try {
      final raw = await _elevatedWriteRaw(
        scriptArgs: ['-Write', '-BatchFile', batchFile.path],
        createDir: false,
      );
      return EnvPathBatchWriteResult.fromJson(raw);
    } finally {
      try {
        batchFile.deleteSync();
      } catch (_) {}
    }
  }

  /// 读取指定变量在 Machine 作用域下的当前值（空字符串表示未设置）。
  Future<Map<String, String>> readMachineVariables(
    List<String> variables,
  ) {
    return _readScopedVariables(variables, 'Machine');
  }

  /// 读取指定变量在 User 作用域下的当前值。
  Future<Map<String, String>> readUserVariables(
    List<String> variables,
  ) {
    return _readScopedVariables(variables, 'User');
  }

  Future<Map<String, String>> _readScopedVariables(
    List<String> variables,
    String scope,
  ) async {
    if (!Platform.isWindows || variables.isEmpty) {
      return const {};
    }

    final quoted = variables.map((v) => "'$v'").join(',');
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        r'''
$names = @(''' +
            quoted +
            r''')
$scope = ''' +
            "'$scope'" +
            r'''
$result = @{}
foreach ($n in $names) {
  $v = [Environment]::GetEnvironmentVariable($n, $scope)
  if ($null -ne $v -and $v.Trim().Length -gt 0) {
    $result[$n] = $v.Trim()
  }
}
if ($result.Count -eq 0) { '{}' } else { $result | ConvertTo-Json -Compress }
''',
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    final stdout = (result.stdout as String? ?? '').replaceFirst('\uFEFF', '');
    if (stdout.trim().isEmpty) return const {};

    try {
      final decoded = jsonDecode(stdout);
      if (decoded is! Map) return const {};
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    } catch (_) {
      return const {};
    }
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
          results.add(
            await writeVariable(
              variable: item.variable,
              value: '',
              unset: true,
              scope: 'Machine',
            ),
          );
          continue;
        }

        final scope = item.source == 'User' ? 'User' : 'Machine';

        // 原为 User：清掉可能被写成 Machine 的覆盖值，再恢复 User
        if (scope == 'User') {
          results.add(
            await writeVariable(
              variable: item.variable,
              value: '',
              unset: true,
              scope: 'Machine',
            ),
          );
        }

        results.add(
          await writeVariable(
            variable: item.variable,
            value: item.currentValue,
            scope: scope,
          ),
        );
      } catch (error) {
        results.add(
          EnvPathWriteResult(
            success: false,
            variable: item.variable,
            value: item.currentValue,
            error: error.toString(),
          ),
        );
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
      return await _doElevatedWrite(
        scriptArgs: scriptArgs,
        createDir: createDir,
      );
    } finally {
      completer.complete();
      _writeLock = null;
    }
  }

  Future<Map<String, dynamic>> _elevatedWriteRaw({
    required List<String> scriptArgs,
    bool createDir = false,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('环境变量写入仅支持 Windows。');
    }
    while (_writeLock != null) {
      await _writeLock;
    }
    final completer = Completer<void>();
    _writeLock = completer.future;
    try {
      return await _doElevatedWriteJson(
        scriptArgs: scriptArgs,
        createDir: createDir,
      );
    } finally {
      completer.complete();
      _writeLock = null;
    }
  }

  Future<EnvPathWriteResult> _doElevatedWrite({
    required List<String> scriptArgs,
    bool createDir = false,
  }) async {
    final json = await _doElevatedWriteJson(
      scriptArgs: scriptArgs,
      createDir: createDir,
    );
    return EnvPathWriteResult.fromJson(json);
  }

  Future<Map<String, dynamic>> _doElevatedWriteJson({
    required List<String> scriptArgs,
    bool createDir = false,
  }) async {
    final scriptPath = await resolveConfigEnvPathsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到配置脚本：$scriptPath');
    }

    final resultFile =
        '${Directory.systemTemp.path}\\aswh_env_result_${DateTime.now().millisecondsSinceEpoch}.json';

    final args = [
      ...scriptArgs,
      if (createDir) '-CreateDir',
      '-ResultFile',
      resultFile,
      '-Json',
    ];

    final result = await _runner.runElevated(
      scriptPath: scriptFile.absolute.path,
      extraArgs: args,
      timeout: const Duration(seconds: 15),
    );

    // 读取结果文件
    final resultFileObj = File(resultFile);
    if (!resultFileObj.existsSync()) {
      // 如果 runElevated 没有抛异常但结果文件不存在，用 result 的 jsonResult
      if (result.jsonResult != null) {
        return result.jsonResult!;
      }
      throw StateError('写入失败：未收到结果文件。');
    }

    try {
      final json = jsonDecode(resultFileObj.readAsStringSync());
      if (json is Map) {
        return Map<String, dynamic>.from(json);
      }
      throw StateError('结果文件格式无效。');
    } finally {
      try {
        resultFileObj.deleteSync();
      } catch (_) {}
    }
  }

  // ── 结果解析 ──

  EnvPathConfigResult _parseOutput(PowerShellResult result) {
    final _log = (String msg) => LogManager.instance.write('EnvPath', msg);

    // 优先用 jsonResult
    if (result.jsonResult != null) {
      final parsed = EnvPathConfigResult.fromJson(result.jsonResult!);
      _log(
        '解析成功: ${parsed.items.length} 个变量, ${parsed.pathEntries.length} 个 PATH 条目',
      );
      return parsed;
    }

    // 回退：从 stdout 提取
    final stdoutText = result.stdout;
    _log(
      'stdout (前1000字符): ${stdoutText.length > 1000 ? stdoutText.substring(0, 1000) : stdoutText}',
    );

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
      _log(
        '解析成功: ${parsed.items.length} 个变量, ${parsed.pathEntries.length} 个 PATH 条目',
      );
      return parsed;
    } on FormatException catch (error) {
      _log('JSON 解析失败: $error');
      throw StateError('检测结果 JSON 解析失败：$error');
    }
  }
}
