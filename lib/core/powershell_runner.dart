import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:androidstudiowinhelper/core/elevated_ps_wrapper.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/windows_elevate.dart';

/// PowerShell 进程执行结果
class PowerShellResult {
  const PowerShellResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.progressEvents = const [],
    this.jsonResult,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
  final List<ScanProgress> progressEvents;
  final Map<String, dynamic>? jsonResult;

  bool get success => exitCode == 0;
}

/// 统一的 PowerShell 进程管理器
/// 封装进程启动、行缓冲、@@PROGRESS|@@ 解析、@@RESULT|@@ JSON 提取、
/// UTF-8 解码、UAC 提权、结果文件轮询、超时处理。
class PowerShellRunner {
  PowerShellRunner({String? logTag}) : _logTag = logTag ?? 'PS';

  final String _logTag;

  void _log(String message) {
    LogManager.instance.write(_logTag, message);
  }

  /// 普通模式执行 PowerShell 脚本
  Future<PowerShellResult> run({
    required String scriptPath,
    List<String> extraArgs = const [],
    void Function(ScanProgress)? onProgress,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    _log('===== 执行 PowerShell 脚本 =====');
    _log('脚本: $scriptPath');
    if (extraArgs.isNotEmpty) _log('参数: ${extraArgs.join(' ')}');

    final args = [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      ...extraArgs,
    ];

    final process = await Process.start('powershell.exe', args);

    final stdoutBuffer = StringBuffer();
    final stderrBuffer = StringBuffer();
    final stdoutBytes = <int>[];
    final progressEvents = <ScanProgress>[];

    final stdoutSub = process.stdout.listen(
      (chunk) {
        stdoutBytes.addAll(chunk);
        _drainLines(stdoutBytes, (line) {
          stdoutBuffer.writeln(line);
          final progress = _parseProgressLine(line);
          if (progress != null) {
            progressEvents.add(progress);
            onProgress?.call(progress);
          }
        });
      },
      onError: (Object error, StackTrace _) {
        stderrBuffer.writeln('stdout 读取失败：$error');
      },
    );

    final stderrSub = process.stderr.listen(
      (chunk) {
        stderrBuffer.write(_decodeBytes(chunk));
      },
      onError: (Object error, StackTrace _) {
        stderrBuffer.writeln('stderr 读取失败：$error');
      },
    );

    // 等待完成，带超时
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      throw StateError('PowerShell 脚本执行超时 (${timeout.inSeconds}s)');
    }

    await stdoutSub.cancel();
    await stderrSub.cancel();

    // 处理剩余字节
    if (stdoutBytes.isNotEmpty) {
      final remaining = _decodeBytes(stdoutBytes);
      if (remaining.trim().isNotEmpty) {
        stdoutBuffer.writeln(remaining);
        for (final line in remaining.split('\n')) {
          final progress = _parseProgressLine(line.trim());
          if (progress != null) {
            progressEvents.add(progress);
            onProgress?.call(progress);
          }
        }
      }
    }

    final stdoutText = stdoutBuffer.toString();
    final stderrText = stderrBuffer.toString();

    _log('执行完毕, exitCode: $exitCode');
    if (stderrText.isNotEmpty) _log('stderr: $stderrText');

    // 提取 JSON 结果
    final jsonResult = _extractJsonResult(stdoutText);

    return PowerShellResult(
      stdout: stdoutText,
      stderr: stderrText,
      exitCode: exitCode,
      progressEvents: progressEvents,
      jsonResult: jsonResult,
    );
  }

  /// 检查当前进程是否以管理员身份运行
  static Future<bool> _isAdmin() async {
    try {
      final result = await Process.run('net', ['session']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 提权模式执行 PowerShell 脚本 (UAC)
  ///
  /// 策略：
  /// 1. 如果已是管理员，直接执行（跳过 UAC）
  /// 2. 否则 ShellExecuteEx runas 启动隐藏的 powershell.exe（系统标准 UAC）
  /// 3. 等待该进程退出后读结果文件
  Future<PowerShellResult> runElevated({
    required String scriptPath,
    List<String> extraArgs = const [],
    void Function(ScanProgress)? onProgress,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    _log('===== 提权执行 PowerShell 脚本 =====');
    _log('脚本: $scriptPath');
    if (extraArgs.isNotEmpty) _log('参数: ${extraArgs.join(' ')}');

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final defaultResultFile =
        '${Directory.systemTemp.path}\\aswh_ps_result_$timestamp.json';
    final tempPs1File = '${Directory.systemTemp.path}\\aswh_ps_$timestamp.ps1';

    String? callerResultFile;
    final resultFileIdx = extraArgs.indexOf('-ResultFile');
    if (resultFileIdx >= 0 && resultFileIdx + 1 < extraArgs.length) {
      callerResultFile = extraArgs[resultFileIdx + 1];
    }
    final resultFile = callerResultFile ?? defaultResultFile;

    final ps1Content = buildElevatedWrapperScript(
      scriptPath: scriptPath,
      extraArgs: extraArgs,
      resultFile: resultFile,
    );
    File(
      tempPs1File,
    ).writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(ps1Content)]);
    _log('临时 PS1: $tempPs1File');

    onProgress?.call(const ScanProgress(percent: 5, message: '正在请求管理员权限...'));

    final admin = await _isAdmin();
    _log('当前管理员状态: $admin');

    var workerExitCode = 0;
    try {
      if (admin) {
        _log('已是管理员，直接执行脚本');
        final result = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', tempPs1File],
          stdoutEncoding: null,
          stderrEncoding: null,
        ).timeout(timeout);

        workerExitCode = result.exitCode;
        _log('直接执行完毕, exitCode: $workerExitCode');
        final stdoutText = _decodeText(result.stdout);
        final stderrText = _decodeText(result.stderr);
        if (stdoutText.isNotEmpty) _log('stdout: $stdoutText');
        if (stderrText.isNotEmpty) _log('stderr: $stderrText');
      } else {
        onProgress?.call(
          const ScanProgress(percent: 8, message: '请在系统提示中允许此应用更改设备...'),
        );
        final powershell = windowsPowerShellExe();
        final params =
            '-NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File ${quoteWindowsArg(tempPs1File)}';
        _log('提权启动: $powershell $params');
        final raw = await Isolate.run(() {
          final r = runElevatedWorker(
            executable: powershell,
            parameters: params,
            timeout: timeout,
          );
          return <String, Object>{
            'cancelled': r.cancelled,
            'exitCode': r.exitCode,
            'error': r.error,
          };
        });
        final elevate = WindowsElevateResult(
          cancelled: raw['cancelled'] as bool,
          exitCode: raw['exitCode'] as int,
          error: raw['error'] as String? ?? '',
        );
        if (elevate.cancelled) {
          throw StateError('用户取消了管理员权限请求。');
        }
        if (elevate.error.isNotEmpty) {
          throw StateError(elevate.error);
        }
        workerExitCode = elevate.exitCode;
        _log('提权进程退出码: $workerExitCode');
      }

      onProgress?.call(const ScanProgress(percent: 10, message: '正在等待脚本完成...'));

      final resultFileObj = File(resultFile);
      var waitMs = 0;
      const flushTimeoutMs = 1000;

      while (!resultFileObj.existsSync() && waitMs < flushTimeoutMs) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        waitMs += 100;
      }

      if (!resultFileObj.existsSync()) {
        _log('结果文件未生成, workerExitCode=$workerExitCode');
        throw StateError('写入失败：提权脚本未写出结果（退出码 $workerExitCode）。');
      }

      _log('结果文件就绪, 等待 ${(waitMs / 1000).toStringAsFixed(1)}s');
      onProgress?.call(const ScanProgress(percent: 95, message: '正在读取结果...'));

      try {
        final rawContent = resultFileObj.readAsStringSync();
        _log(
          '结果文件: ${rawContent.length > 1000 ? rawContent.substring(0, 1000) : rawContent}',
        );

        final decoded = jsonDecode(rawContent);
        Map<String, dynamic>? jsonResult;
        if (decoded is Map<String, dynamic>) {
          jsonResult = decoded;
        } else if (decoded is Map) {
          jsonResult = Map<String, dynamic>.from(decoded);
        }

        onProgress?.call(const ScanProgress(percent: 100, message: '执行完成。'));

        return PowerShellResult(
          stdout: rawContent,
          stderr: '',
          exitCode: 0,
          jsonResult: jsonResult,
        );
      } finally {
        try {
          resultFileObj.deleteSync();
        } catch (_) {}
      }
    } finally {
      try {
        File(tempPs1File).deleteSync();
      } catch (_) {}
    }
  }

  // ── 行缓冲 ──

  void _drainLines(List<int> buffer, void Function(String line) onLine) {
    while (true) {
      final newlineIndex = buffer.indexOf(10);
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

  // ── 编码处理 ──

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

  // ── 进度解析 ──

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

  // ── JSON 结果提取 ──

  Map<String, dynamic>? _extractJsonResult(String stdoutText) {
    const marker = '@@RESULT|';
    final startIdx = stdoutText.indexOf(marker);
    if (startIdx < 0) return null;

    final afterMarker = startIdx + marker.length;
    final endIdx = stdoutText.indexOf('@@', afterMarker);
    final String jsonText;
    if (endIdx > afterMarker) {
      jsonText = stdoutText.substring(afterMarker, endIdx).trim();
    } else {
      jsonText = stdoutText.substring(afterMarker).trim();
    }

    if (jsonText.isEmpty) return null;

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      _log('JSON 解析失败: $e');
    }
    return null;
  }
}
