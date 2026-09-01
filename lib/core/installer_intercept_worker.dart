import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/installer_ui_path.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';
import 'package:androidstudiowinhelper/core/windows_elevate.dart';

/// 提权后台 worker：注册表预写 + 安装向导 UI 纠偏（解决 UIPI 导致非管理员无法改 Edit）。
class InstallerInterceptWorker {
  InstallerInterceptWorker._({
    required this.configFile,
    required this.resultFile,
    required this.stopFile,
  });

  static const _logTag = 'InstallerIntercept';
  static InstallerInterceptWorker? _active;

  final String configFile;
  final String resultFile;
  final String stopFile;

  bool _stopped = false;

  static Future<InstallerInterceptWorker?> start({
    required String installHome,
    required String androidHome,
    required String androidUserHome,
  }) async {
    if (!Platform.isWindows) return null;
    if (_active != null) return _active;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final configFile = '${Directory.systemTemp.path}\\aswh_intercept_cfg_$ts.json';
    final resultFile =
        '${Directory.systemTemp.path}\\aswh_intercept_result_$ts.json';
    final stopFile = '${Directory.systemTemp.path}\\aswh_intercept_stop_$ts.flag';

    final worker = InstallerInterceptWorker._(
      configFile: configFile,
      resultFile: resultFile,
      stopFile: stopFile,
    );

    await worker._writeConfig(
      installHome: installHome,
      androidHome: androidHome,
      androidUserHome: androidUserHome,
    );

    final launched = await worker._launchWorker();
    if (!launched) {
      await worker.dispose();
      return null;
    }

    _active = worker;
    return worker;
  }

  Future<void> _writeConfig({
    required String installHome,
    required String androidHome,
    required String androidUserHome,
  }) async {
    final payload = {
      'installHome': installHome,
      'androidHome': androidHome,
      'androidUserHome': androidUserHome,
    };
    await File(configFile).writeAsString(
      jsonEncode(payload),
      flush: true,
    );
  }

  Future<bool> _launchWorker() async {
    final scriptPath = await resolveAlignInstallerPathsScript();
    final ps = windowsPowerShellExe();
    final args = [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      scriptPath,
      '-WorkerConfigFile',
      configFile,
      '-WorkerResultFile',
      resultFile,
      '-WorkerStopFile',
      stopFile,
    ];
    final params = args.map(quoteWindowsArg).join(' ');

    if (await _isAdmin()) {
      LogManager.instance.write(_logTag, '已是管理员，直接启动 UI 纠偏 worker');
      final process = await Process.start(ps, args);
      LogManager.instance.write(_logTag, 'UI worker pid=${process.pid}');
      return true;
    }

    LogManager.instance.write(_logTag, '请求管理员权限以同步安装向导路径…');
    final launch = launchElevated(executable: ps, parameters: params);
    if (launch.cancelled) {
      LogManager.instance.write(_logTag, '用户取消了 UI 纠偏 UAC');
      return false;
    }
    if (!launch.launched) {
      LogManager.instance.write(
        _logTag,
        'UI worker 启动失败: ${launch.error}',
      );
      return false;
    }
    LogManager.instance.write(_logTag, '已启动提权 UI 纠偏 worker');
    return true;
  }

  static Future<bool> _isAdmin() async {
    try {
      final result = await Process.run('net', ['session']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<InstallerUiAlignResult> readLatestResult() async {
    final file = File(resultFile);
    if (!await file.exists()) {
      return InstallerUiPath.emptyResult();
    }
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return InstallerUiPath.emptyResult();
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return InstallerUiPath.emptyResult();
      return InstallerUiAlignResult(
        installDirAligned: json['installDirAligned'] == true,
        installDirVerified: json['installDirVerified'] == true,
        sdkEditAligned: json['sdkEditAligned'] == true,
        userHomeEditAligned: json['userHomeEditAligned'] == true,
        foundInstallerWindow: json['foundInstallerWindow'] == true,
        visibleInstallPath: json['visibleInstallPath']?.toString() ?? '',
        diagnostics: json['installDiagnostics']?.toString() ?? '',
        registryPrimed: json['registryPrimed'] == true,
        elevatedWorker: json['elevatedWorker'] == true,
      );
    } catch (_) {
      return InstallerUiPath.emptyResult();
    }
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      await File(stopFile).writeAsString('stop', flush: true);
    } catch (_) {}
    if (_active == this) {
      _active = null;
    }
  }

  Future<void> dispose() async {
    await stop();
    for (final path in [configFile, resultFile, stopFile]) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }
}
