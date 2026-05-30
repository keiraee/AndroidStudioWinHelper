import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore_for_file: avoid_print

import 'package:androidstudiowinhelper/core/models/hyperv_result.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef HypervProgressCallback = void Function(ScanProgress progress);

class HypervManager {
  static void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[HyperV $ts] $message');
  }

  // ===================== DETECT =====================

  Future<HypervResult> detect({
    HypervProgressCallback? onProgress,
  }) async {
    _log('===== 开始 Hyper-V 状态检测（提权模式） =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('Hyper-V 检测仅支持 Windows。');
    }

    final scriptPath = await resolveDetectHypervScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      _log('[错误] 检测脚本不存在: $scriptPath');
      throw StateError('未找到检测脚本：$scriptPath');
    }
    _log('检测脚本路径: ${scriptFile.absolute.path}');

    return _elevatedDetect(
      scriptFile: scriptFile,
      onProgress: onProgress,
    );
  }

  Future<HypervResult> _elevatedDetect({
    required File scriptFile,
    HypervProgressCallback? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final resultFile = '${Directory.systemTemp.path}\\aswh_hyperv_detect_result_$timestamp.json';
    final wrapperFile = '${Directory.systemTemp.path}\\aswh_hyperv_detect_$timestamp.bat';
    final escapedScriptPath = scriptFile.absolute.path;

    _log('--- 步骤 1/4: 生成提权批处理文件 ---');
    _log('临时批处理路径: $wrapperFile');
    _log('结果文件路径: $resultFile');
    _log('脚本路径: $escapedScriptPath');

    // ResultFile 路径中单引号在 PowerShell 单引号字符串里需转义，但路径不含单引号，直接使用
    final wrapperContent = '@echo off\r\n'
        'echo ASWH: 正在以管理员权限执行 Hyper-V 状态检测\r\n'
        'echo ASWH: 脚本: $escapedScriptPath\r\n'
        'echo ASWH: 结果文件: $resultFile\r\n'
        'echo ASWH: ============================\r\n'
        'chcp 65001 >nul\r\n'
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'
        "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$escapedScriptPath','-ResultFile','$resultFile','-Json' -WindowStyle Normal -Wait"
        '"\r\n'
        'echo ASWH: 检测执行完毕, exitCode: %ERRORLEVEL%\r\n';
    File(wrapperFile).writeAsStringSync(wrapperContent);
    _log('批处理文件已写入');
    _log('');
    _log('批处理内容 >>>');
    _log(wrapperContent);
    _log('<<< 批处理内容结束');

    onProgress?.call(const ScanProgress(percent: 5, message: '正在请求管理员权限...'));

    _log('--- 步骤 2/4: 执行提权命令 (cmd.exe /c $wrapperFile) ---');

    try {
      final result = await Process.run(
        'cmd.exe',
        ['/c', wrapperFile],
        stdoutEncoding: null,
        stderrEncoding: null,
      );

      final exitCode = result.exitCode;
      final stdoutText = _decodeText(result.stdout);
      final stderrText = _decodeText(result.stderr);

      _log('提权命令执行完毕, exitCode: $exitCode');
      if (stdoutText.isNotEmpty) {
        _log('cmd stdout: $stdoutText');
      }
      if (stderrText.isNotEmpty) {
        _log('cmd stderr: $stderrText');
      }

      if (exitCode != 0) {
        if (stderrText.contains('cancelled') || stderrText.contains('OperationStopped')) {
          _log('[警告] 用户取消了管理员权限请求');
          throw StateError('用户取消了管理员权限请求。');
        }
        _log('[错误] 提权执行失败');
        throw StateError('提权执行失败（exitCode: $exitCode）：$stderrText');
      }
      _log('提权执行成功');
    } on ProcessException catch (e) {
      _log('[异常] ProcessException: ${e.message}');
      if (e.message.contains('740')) {
        throw StateError('需要管理员权限，请在 UAC 弹窗中点击"是"。');
      }
      rethrow;
    } finally {
      try { File(wrapperFile).deleteSync(); } catch (_) {}
      _log('已清理临时批处理文件: $wrapperFile');
    }

    // Wait for result file
    _log('--- 步骤 3/4: 等待结果文件就绪 ---');
    final resultFileObj = File(resultFile);
    var waitMs = 0;
    const timeoutMs = 120000;

    while (!resultFileObj.existsSync() && waitMs < timeoutMs) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      waitMs += 300;
      final percent = 10 + ((waitMs / timeoutMs) * 80).toInt();
      final secs = (waitMs / 1000).toInt();
      onProgress?.call(ScanProgress(
        percent: percent.clamp(10, 90),
        message: '正在检测... (${secs}s)',
      ));
      if (waitMs % 3000 == 0) {
        _log('等待结果文件中... 已等待 ${secs}s / 120s');
      }
    }

    if (!resultFileObj.existsSync()) {
      _log('[超时] 120s 内未收到结果文件，可能是 UAC 被拒绝');
      throw StateError('操作超时：未收到结果文件（可能是 UAC 被拒绝）。');
    }
    _log('结果文件已就绪, 等待用时: ${(waitMs / 1000).toStringAsFixed(1)}s');

    onProgress?.call(const ScanProgress(percent: 95, message: '正在读取结果...'));

    _log('--- 步骤 4/4: 解析结果文件 ---');

    try {
      final rawContent = resultFileObj.readAsStringSync();
      _log('结果文件内容: ${rawContent.length > 1000 ? rawContent.substring(0, 1000) : rawContent}');
      final json = jsonDecode(rawContent);
      if (json is Map<String, dynamic>) {
        final detectResult = HypervResult.fromJson(json);
        _log('检测解析成功:');
        _log('  OS: ${detectResult.osEdition} (家庭版: ${detectResult.isHomeEdition})');
        _log('  总状态: ${detectResult.overallStatus}');
        for (final f in detectResult.features) {
          _log('  ${f.label}: ${f.state}');
        }

        onProgress?.call(const ScanProgress(percent: 100, message: '检测完成。'));
        return detectResult;
      }
      _log('[错误] 结果文件格式无效，不是 JSON 对象');
      throw StateError('结果文件格式无效。');
    } finally {
      try { resultFileObj.deleteSync(); } catch (_) {}
      _log('已清理临时结果文件');
    }
  }

  // ===================== TOGGLE =====================

  Future<HypervToggleResult> toggle({
    required bool enable,
    HypervProgressCallback? onProgress,
  }) async {
    final actionName = enable ? '启用 (Enable)' : '关闭 (Disable)';
    _log('===== 开始 Hyper-V 开关操作: $actionName =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('Hyper-V 操作仅支持 Windows。');
    }

    final scriptPath = await resolveToggleHypervScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      _log('[错误] 操作脚本不存在: $scriptPath');
      throw StateError('未找到操作脚本：$scriptPath');
    }
    _log('操作脚本路径: ${scriptFile.absolute.path}');

    return _elevatedToggle(
      scriptFile: scriptFile,
      action: enable ? 'Enable' : 'Disable',
      onProgress: onProgress,
    );
  }

  Future<HypervToggleResult> toggleFeature({
    required String featureName,
    required bool enable,
    HypervProgressCallback? onProgress,
  }) async {
    final actionName = enable ? '启用' : '关闭';
    _log('===== 开始单特性开关操作: $actionName $featureName =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('Hyper-V 操作仅支持 Windows。');
    }

    final scriptPath = await resolveToggleHypervScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      _log('[错误] 操作脚本不存在: $scriptPath');
      throw StateError('未找到操作脚本：$scriptPath');
    }
    _log('操作脚本路径: ${scriptFile.absolute.path}');

    return _elevatedToggle(
      scriptFile: scriptFile,
      action: enable ? 'Enable' : 'Disable',
      featureName: featureName,
      onProgress: onProgress,
    );
  }

  Future<HypervToggleResult> _elevatedToggle({
    required File scriptFile,
    required String action,
    String? featureName,
    HypervProgressCallback? onProgress,
  }) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final resultFile = '${Directory.systemTemp.path}\\aswh_hyperv_result_$timestamp.json';
    final wrapperFile = '${Directory.systemTemp.path}\\aswh_hyperv_$timestamp.bat';
    final escapedScriptPath = scriptFile.absolute.path;

    _log('--- 步骤 1/5: 生成提权批处理文件 ---');
    _log('临时批处理路径: $wrapperFile');
    _log('结果文件路径: $resultFile');
    _log('操作类型: $action');
    if (featureName != null) _log('目标特性: $featureName');
    _log('脚本路径: $escapedScriptPath');

    // 写一个临时 .ps1 包裹脚本，硬编码所有参数，避免 Start-Process 传参问题
    final tempPs1File = '${Directory.systemTemp.path}\\aswh_toggle_$timestamp.ps1';
    var ps1Content = "\$params = @{\r\n"
        "    Action = '$action'\r\n"
        "    ResultFile = '$resultFile'\r\n"
        "    Json = \$true\r\n";
    if (featureName != null) {
      ps1Content += "    FeatureName = '$featureName'\r\n";
    }
    ps1Content += "}\r\n"
        "& '$escapedScriptPath' @params\r\n";
    File(tempPs1File).writeAsStringSync(ps1Content);
    _log('临时 PowerShell 脚本: $tempPs1File');
    _log('临时脚本内容 >>>');
    _log(ps1Content);
    _log('<<< 临时脚本内容结束');

    // [调试模式] 终端窗口可见，方便观察执行过程
    final wrapperContent = '@echo off\r\n'
        'echo ASWH: 正在以管理员权限执行 Hyper-V 操作: $action${featureName != null ? ' ($featureName)' : ''}\r\n'
        'echo ASWH: 脚本: $escapedScriptPath\r\n'
        'echo ASWH: 结果文件: $resultFile\r\n'
        'echo ASWH: ============================\r\n'
        'chcp 65001 >nul\r\n'
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "'
        "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','$tempPs1File' -WindowStyle Normal -Wait"
        '"\r\n'
        'echo ASWH: 执行完毕, exitCode: %ERRORLEVEL%\r\n';
    File(wrapperFile).writeAsStringSync(wrapperContent);
    _log('批处理文件已写入');
    _log('');
    _log('批处理内容 >>>');
    _log(wrapperContent);
    _log('<<< 批处理内容结束');

    onProgress?.call(const ScanProgress(percent: 5, message: '正在请求管理员权限...'));

    _log('--- 步骤 2/5: 执行提权命令 (cmd.exe /c $wrapperFile) ---');

    try {
      final result = await Process.run(
        'cmd.exe',
        ['/c', wrapperFile],
        stdoutEncoding: null,
        stderrEncoding: null,
      );

      final exitCode = result.exitCode;
      final stdoutText = _decodeText(result.stdout);
      final stderrText = _decodeText(result.stderr);

      _log('提权命令执行完毕, exitCode: $exitCode');
      if (stdoutText.isNotEmpty) {
        _log('cmd stdout: $stdoutText');
      }
      if (stderrText.isNotEmpty) {
        _log('cmd stderr: $stderrText');
      }

      if (exitCode != 0) {
        if (stderrText.contains('cancelled') || stderrText.contains('OperationStopped')) {
          _log('[警告] 用户取消了管理员权限请求');
          throw StateError('用户取消了管理员权限请求。');
        }
        _log('[错误] 提权执行失败');
        throw StateError('提权执行失败（exitCode: $exitCode）：$stderrText');
      }
      _log('提权执行成功');
    } on ProcessException catch (e) {
      _log('[异常] ProcessException: ${e.message}');
      if (e.message.contains('740')) {
        throw StateError('需要管理员权限，请在 UAC 弹窗中点击"是"。');
      }
      rethrow;
    } finally {
      // Clean up wrapper file and temp ps1
      try { File(wrapperFile).deleteSync(); } catch (_) {}
      try { File(tempPs1File).deleteSync(); } catch (_) {}
      _log('已清理临时批处理文件和临时 ps1');
    }

    // Read the result file
    _log('--- 步骤 3/5: 等待结果文件就绪 ---');
    final resultFileObj = File(resultFile);
    var waitMs = 0;
    const timeoutMs = 120000;

    while (!resultFileObj.existsSync() && waitMs < timeoutMs) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      waitMs += 300;
      final percent = 10 + ((waitMs / timeoutMs) * 80).toInt();
      final secs = (waitMs / 1000).toInt();
      onProgress?.call(ScanProgress(
        percent: percent.clamp(10, 90),
        message: action == 'Enable' ? '正在启用...' : '正在关闭... (${secs}s)',
      ));
      if (waitMs % 3000 == 0) {
        _log('等待结果文件中... 已等待 ${secs}s / 120s');
      }
    }

    if (!resultFileObj.existsSync()) {
      _log('[超时] 120s 内未收到结果文件，可能是 UAC 被拒绝');
      throw StateError('操作超时：未收到结果文件（可能是 UAC 被拒绝）。');
    }
    _log('结果文件已就绪, 等待用时: ${(waitMs / 1000).toStringAsFixed(1)}s');

    onProgress?.call(const ScanProgress(percent: 95, message: '正在读取结果...'));

    _log('--- 步骤 4/5: 解析结果文件 ---');

    try {
      final rawContent = resultFileObj.readAsStringSync();
      _log('结果文件内容: ${rawContent.length > 1000 ? rawContent.substring(0, 1000) : rawContent}');
      final json = jsonDecode(rawContent);
      if (json is Map<String, dynamic>) {
        final toggleResult = HypervToggleResult.fromJson(json);
        _log('解析成功:');
        _log('  success: ${toggleResult.success}');
        _log('  message: ${toggleResult.message}');
        if (toggleResult.details.isNotEmpty) {
          _log('  details: ${toggleResult.details}');
        }
        if (toggleResult.debug.isNotEmpty) {
          _log('  [PS DEBUG]');
          for (final line in toggleResult.debug.split('\n')) {
            if (line.trim().isNotEmpty) _log('    $line');
          }
        }

        _log('--- 步骤 5/5: 操作完成 ---');
        onProgress?.call(const ScanProgress(percent: 100, message: '操作完成。'));
        return toggleResult;
      }
      _log('[错误] 结果文件格式无效，不是 JSON 对象');
      throw StateError('结果文件格式无效。');
    } finally {
      try { resultFileObj.deleteSync(); } catch (_) {}
      _log('已清理临时结果文件');
    }
  }

  // --- Helpers ---

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
}
