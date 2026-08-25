import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/hyperv_result.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/powershell_runner.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef HypervProgressCallback = void Function(ScanProgress progress);

class HypervManager {
  HypervManager({PowerShellRunner? runner})
      : _runner = runner ?? PowerShellRunner(logTag: 'HyperV');

  final PowerShellRunner _runner;

  static void _log(String message) {
    LogManager.instance.write('HyperV', message);
  }

  // ===================== DETECT =====================

  Future<HypervResult> detect({
    HypervProgressCallback? onProgress,
  }) async {
    _log('===== 开始 Hyper-V 状态检测 =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('Hyper-V 检测仅支持 Windows。');
    }

    final scriptPath = await resolveDetectHypervScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到检测脚本：$scriptPath');
    }

    final result = await _runner.runElevated(
      scriptPath: scriptFile.absolute.path,
      onProgress: onProgress,
    );

    if (result.jsonResult == null) {
      throw StateError('检测结果格式无效。');
    }

    final detectResult = HypervResult.fromJson(result.jsonResult!);
    _log('检测成功: ${detectResult.osEdition}, 状态: ${detectResult.overallStatus}');

    onProgress?.call(const ScanProgress(percent: 100, message: '检测完成。'));
    return detectResult;
  }

  // ===================== TOGGLE =====================

  Future<HypervToggleResult> toggle({
    required bool enable,
    HypervProgressCallback? onProgress,
  }) async {
    final actionName = enable ? '启用' : '关闭';
    _log('===== 开始 Hyper-V 开关操作: $actionName =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('Hyper-V 操作仅支持 Windows。');
    }

    final scriptPath = await resolveToggleHypervScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到操作脚本：$scriptPath');
    }

    final result = await _runner.runElevated(
      scriptPath: scriptFile.absolute.path,
      extraArgs: ['-Action', enable ? 'Enable' : 'Disable'],
      onProgress: onProgress,
    );

    if (result.jsonResult == null) {
      throw StateError('操作结果格式无效。');
    }

    final toggleResult = HypervToggleResult.fromJson(result.jsonResult!);
    _log('操作完成: success=${toggleResult.success}, message=${toggleResult.message}');

    onProgress?.call(const ScanProgress(percent: 100, message: '操作完成。'));
    return toggleResult;
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
      throw StateError('未找到操作脚本：$scriptPath');
    }

    final result = await _runner.runElevated(
      scriptPath: scriptFile.absolute.path,
      extraArgs: ['-Action', enable ? 'Enable' : 'Disable', '-FeatureName', featureName],
      onProgress: onProgress,
    );

    if (result.jsonResult == null) {
      throw StateError('操作结果格式无效。');
    }

    final toggleResult = HypervToggleResult.fromJson(result.jsonResult!);
    _log('操作完成: success=${toggleResult.success}, message=${toggleResult.message}');

    onProgress?.call(const ScanProgress(percent: 100, message: '操作完成。'));
    return toggleResult;
  }
}
