import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/as_first_run_sdk_config.dart';
import 'package:androidstudiowinhelper/core/installer_settings_tmp.dart';
import 'package:androidstudiowinhelper/core/installer_ui_path.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';

enum InstallerInterceptPhase {
  waitingWizard,
  alignedInstallDir,
  installDirMiss,
  alignedSdkTmp,
  writingOtherXml,
  done,
  cancelled,
  error,
}

class InstallerInterceptStatus {
  const InstallerInterceptStatus({
    required this.phase,
    required this.message,
    this.detail,
  });

  final InstallerInterceptPhase phase;
  final String message;
  final String? detail;

  InstallerInterceptStatus copyWith({
    InstallerInterceptPhase? phase,
    String? message,
    String? detail,
  }) {
    return InstallerInterceptStatus(
      phase: phase ?? this.phase,
      message: message ?? this.message,
      detail: detail ?? this.detail,
    );
  }
}

/// 官方安装器路径拦截：UI 编辑框 + inst_user_settings.tmp + 装完写 other.xml。
class InstallerPathInterceptor {
  InstallerPathInterceptor._({
    required this.workingDirectory,
    required this.installHome,
    required this.androidHome,
    required this.androidUserHome,
    required this.installerProcess,
  });

  static const _logTag = 'InstallerIntercept';
  static const _pollInterval = Duration(milliseconds: 400);
  static const _installDirGrace = Duration(seconds: 60);

  static InstallerPathInterceptor? _active;

  final String workingDirectory;
  final String installHome;
  final String androidHome;
  final String androidUserHome;
  final Process installerProcess;

  final StreamController<InstallerInterceptStatus> _statusController =
      StreamController<InstallerInterceptStatus>.broadcast();

  Stream<InstallerInterceptStatus> get statusStream => _statusController.stream;

  bool _stopped = false;
  bool _installDirMissReported = false;
  bool _installDirAlignedReported = false;
  bool _sdkTmpAlignedReported = false;
  DateTime? _startedAt;
  DateTime _lastCorrectLogAt = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get hasActive => _active != null;

  static Future<InstallerPathInterceptor> start({
    required String workingDirectory,
    required Map<String, String> paths,
    required Process installerProcess,
  }) async {
    if (_active != null) {
      throw StateError('已有安装路径拦截任务在运行。');
    }

    final interceptor = InstallerPathInterceptor._(
      workingDirectory: workingDirectory,
      installHome: paths['AS_INSTALL_HOME']?.trim() ?? '',
      androidHome: paths['ANDROID_HOME']?.trim() ?? '',
      androidUserHome: paths['ANDROID_USER_HOME']?.trim() ?? '',
      installerProcess: installerProcess,
    );
    _active = interceptor;
    unawaited(interceptor._run());
    return interceptor;
  }

  void _emit(InstallerInterceptStatus status) {
    if (_stopped || _statusController.isClosed) return;
    _statusController.add(status);
  }

  void _log(String message) {
    LogManager.instance.write(_logTag, message);
  }

  void _logThrottled(String message) {
    final now = DateTime.now();
    if (now.difference(_lastCorrectLogAt) < const Duration(seconds: 2)) return;
    _lastCorrectLogAt = now;
    _log(message);
  }

  Future<void> _run() async {
    _startedAt = DateTime.now();
    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.waitingWizard,
        message: '正在等待安装向导…',
      ),
    );
    _log('开始监视安装器，cwd=$workingDirectory');

    try {
      final exitFuture = installerProcess.exitCode;
      while (!_stopped) {
        final done = await Future.any<bool>([
          exitFuture.then((_) => true),
          Future<bool>.delayed(_pollInterval, () => false),
        ]);
        if (done || _stopped) break;
        await _pollOnce();
      }

      if (_stopped) {
        _emit(
          const InstallerInterceptStatus(
            phase: InstallerInterceptPhase.cancelled,
            message: '已停止监视（安装器仍在运行）',
          ),
        );
        _log('用户停止监视');
        return;
      }

      final exitCode = await exitFuture;
      _log('安装器已退出，exitCode=$exitCode');

      if (exitCode != 0) {
        _emit(
          InstallerInterceptStatus(
            phase: InstallerInterceptPhase.cancelled,
            message: '安装已取消或未成功完成，未写首次启动配置',
            detail: 'exitCode=$exitCode',
          ),
        );
        return;
      }

      await _writeTmpOnce(force: true);

      _emit(
        const InstallerInterceptStatus(
          phase: InstallerInterceptPhase.writingOtherXml,
          message: '正在写入首次启动 SDK 路径…',
        ),
      );

      final writer = AsFirstRunSdkConfig(
        installHome: installHome,
        androidHome: androidHome,
      );
      final result = await writer.apply();

      if (result.success) {
        _emit(
          InstallerInterceptStatus(
            phase: InstallerInterceptPhase.done,
            message: '路径拦截完成',
            detail: result.message,
          ),
        );
      } else {
        _emit(
          InstallerInterceptStatus(
            phase: InstallerInterceptPhase.cancelled,
            message: result.message,
          ),
        );
      }
    } catch (e, st) {
      _log('拦截异常: $e\n$st');
      _emit(
        InstallerInterceptStatus(
          phase: InstallerInterceptPhase.error,
          message: '拦截异常：$e（安装器仍可继续）',
        ),
      );
    } finally {
      await _dispose();
    }
  }

  Future<void> _pollOnce() async {
    if (InstallerUiPath.isSupported &&
        installHome.isNotEmpty &&
        androidHome.isNotEmpty &&
        androidUserHome.isNotEmpty) {
      final ui = InstallerUiPath(
        installHome: installHome,
        androidHome: androidHome,
        androidUserHome: androidUserHome,
      );
      final result = await ui.alignVisibleEdits();

      if (result.foundInstallerWindow) {
        if (result.installDirAligned && !_installDirAlignedReported) {
          _installDirAlignedReported = true;
          _emit(
            InstallerInterceptStatus(
              phase: InstallerInterceptPhase.alignedInstallDir,
              message: '已对齐安装目录 → $installHome',
            ),
          );
          _log('已对齐安装目录: $installHome');
        } else if (result.installDirAligned) {
          _logThrottled('纠正安装目录为 $installHome');
        }

        if (result.sdkEditAligned || result.userHomeEditAligned) {
          _logThrottled(
            '已对齐 SDK/用户配置编辑框 (sdk=${result.sdkEditAligned}, user=${result.userHomeEditAligned})',
          );
        }
      } else if (_startedAt != null &&
          !_installDirMissReported &&
          DateTime.now().difference(_startedAt!) > _installDirGrace) {
        _installDirMissReported = true;
        _emit(
          const InstallerInterceptStatus(
            phase: InstallerInterceptPhase.installDirMiss,
            message: '安装目录控件未找到，将依赖后续兜底',
          ),
        );
        _log('60s 内未找到安装向导窗口，降级为 tmp/other.xml');
      }
    }

    await _writeTmpOnce(force: false);
  }

  Future<void> _writeTmpOnce({required bool force}) async {
    if (androidHome.isEmpty || androidUserHome.isEmpty) return;

    final existing = await InstallerSettingsTmp.readFrom(workingDirectory);
    final needsWrite =
        force ||
        existing == null ||
        !existing.matchesTarget(androidHome, androidUserHome);

    if (!needsWrite) return;

    try {
      await InstallerSettingsTmp.writeAtomic(
        workingDirectory: workingDirectory,
        sdkPath: androidHome,
        userSettingsPath: androidUserHome,
      );
      if (!_sdkTmpAlignedReported) {
        _sdkTmpAlignedReported = true;
        _emit(
          const InstallerInterceptStatus(
            phase: InstallerInterceptPhase.alignedSdkTmp,
            message: '已对齐 SDK/用户配置临时文件',
          ),
        );
      }
      _log('已写入 ${InstallerSettingsTmp.fileName}');
    } catch (e) {
      _log('写入 ${InstallerSettingsTmp.fileName} 失败: $e');
    }
  }

  /// 停止监视但不结束安装器。
  void stopMonitoring() {
    _stopped = true;
    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.cancelled,
        message: '已停止监视（安装器仍在运行）',
      ),
    );
    _log('用户停止监视');
  }

  Future<void> _dispose() async {
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
    if (_active == this) {
      _active = null;
    }
  }
}
