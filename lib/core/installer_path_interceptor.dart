import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/as_first_run_sdk_config.dart';
import 'package:androidstudiowinhelper/core/install_session.dart';
import 'package:androidstudiowinhelper/core/installer_settings_tmp.dart';
import 'package:androidstudiowinhelper/core/installer_ui_path.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/studio_launcher.dart';

enum InstallerInterceptPhase {
  waitingWizard,
  alignedInstallDir,
  installDirMiss,
  alignedSdkTmp,
  installerFinished,
  waitingStudioLaunch,
  launchingStudio,
  studioRunning,
  writingOtherXml,
  done,
  cancelled,
  interrupted,
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
}

/// 官方安装器路径拦截 + 装后启动 Studio 续装。
class InstallerPathInterceptor {
  InstallerPathInterceptor._({
    required this.versionKey,
    required this.workingDirectory,
    required this.installHome,
    required this.androidHome,
    required this.androidUserHome,
    this.installerProcess,
    this.resumePhase,
  });

  static const _logTag = 'InstallerIntercept';
  static const _pollInterval = Duration(milliseconds: 400);
  static const _installDirGrace = Duration(seconds: 60);
  static const _studioLaunchWait = Duration(seconds: 10);

  static InstallerPathInterceptor? _active;

  final String versionKey;
  final String workingDirectory;
  final String installHome;
  final String androidHome;
  final String androidUserHome;
  final Process? installerProcess;
  final InstallSessionPhase? resumePhase;

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

  Map<String, String> get _paths => {
    'AS_INSTALL_HOME': installHome,
    'ANDROID_HOME': androidHome,
    'ANDROID_USER_HOME': androidUserHome,
  };

  static Future<InstallerPathInterceptor> start({
    required String versionKey,
    required String workingDirectory,
    required Map<String, String> paths,
    required Process installerProcess,
  }) async {
    if (_active != null) {
      throw StateError('已有安装路径拦截任务在运行。');
    }

    final interceptor = InstallerPathInterceptor._(
      versionKey: versionKey,
      workingDirectory: workingDirectory,
      installHome: paths['AS_INSTALL_HOME']?.trim() ?? '',
      androidHome: paths['ANDROID_HOME']?.trim() ?? '',
      androidUserHome: paths['ANDROID_USER_HOME']?.trim() ?? '',
      installerProcess: installerProcess,
    );
    _active = interceptor;
    await InstallSession.save(
      InstallSession(
        versionKey: versionKey,
        workingDirectory: workingDirectory,
        paths: paths,
        phase: InstallSessionPhase.watchingInstaller,
      ),
    );
    unawaited(interceptor._runWithInstaller());
    return interceptor;
  }

  /// 从上次中断的会话继续（安装器可能已关闭）。
  static Future<InstallerPathInterceptor> resume({
    required InstallSession session,
  }) async {
    if (_active != null) {
      throw StateError('已有安装路径拦截任务在运行。');
    }
    final interceptor = InstallerPathInterceptor._(
      versionKey: session.versionKey,
      workingDirectory: session.workingDirectory,
      installHome: session.installHome ?? '',
      androidHome: session.androidHome ?? '',
      androidUserHome: session.paths['ANDROID_USER_HOME']?.trim() ?? '',
      resumePhase: session.phase,
    );
    _active = interceptor;
    unawaited(interceptor._runResume());
    return interceptor;
  }

  Future<void> _runResume() async {
    _log('继续安装监视，phase=${resumePhase?.name}');
    try {
      await _runPostInstall(resume: true);
    } catch (e, st) {
      _log('继续安装异常: $e\n$st');
      await _saveSession(InstallSessionPhase.interrupted);
      _emit(
        InstallerInterceptStatus(
          phase: InstallerInterceptPhase.error,
          message: '继续安装失败：$e',
        ),
      );
    } finally {
      await _dispose();
    }
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

  Future<void> _runWithInstaller() async {
    _startedAt = DateTime.now();
    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.waitingWizard,
        message: '正在监视官方安装向导…',
      ),
    );
    _log('开始监视 NSIS 安装器，cwd=$workingDirectory');

    final process = installerProcess;
    if (process == null) {
      await _runPostInstall(resume: false);
      return;
    }

    try {
      final exitFuture = process.exitCode;
      while (!_stopped) {
        final done = await Future.any<bool>([
          exitFuture.then((_) => true),
          Future<bool>.delayed(_pollInterval, () => false),
        ]);
        if (done || _stopped) break;
        await _pollInstallerUi();
      }

      if (_stopped) {
        await _saveSession(InstallSessionPhase.interrupted);
        _emit(
          const InstallerInterceptStatus(
            phase: InstallerInterceptPhase.interrupted,
            message: '监视已暂停，可稍后从下载页继续',
          ),
        );
        _log('用户停止监视 NSIS 阶段');
        return;
      }

      final exitCode = await exitFuture;
      _log('NSIS 安装器进程已退出，exitCode=$exitCode（Finish 时常为非 0，不代表失败）');
      await _runPostInstall(
        resume: false,
        installerExitCode: exitCode,
      );
    } catch (e, st) {
      _log('拦截异常: $e\n$st');
      await _saveSession(InstallSessionPhase.interrupted);
      _emit(
        InstallerInterceptStatus(
          phase: InstallerInterceptPhase.error,
          message: '拦截异常：$e',
        ),
      );
    } finally {
      await _dispose();
    }
  }

  Future<void> _runPostInstall({
    required bool resume,
    int? installerExitCode,
  }) async {
    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.installerFinished,
        message: '安装向导已关闭，正在验证安装结果…',
      ),
    );

    final writer = AsFirstRunSdkConfig(
      installHome: installHome,
      androidHome: androidHome,
    );
    final resolvedHome = await writer.resolveInstallHome();
    final installOk = resolvedHome != null;

    if (!installOk) {
      await _saveSession(
        InstallSessionPhase.interrupted,
        installerExitCode: installerExitCode,
        installVerified: false,
      );
      _emit(
        InstallerInterceptStatus(
          phase: InstallerInterceptPhase.interrupted,
          message: '未检测到有效安装，可重新运行安装程序或继续监视',
          detail: installerExitCode == null
              ? null
              : 'installerExitCode=$installerExitCode',
        ),
      );
      _log('安装验证失败，exitCode=${installerExitCode ?? "n/a"}');
      return;
    }

    _log('安装验证成功: $resolvedHome');
    await _writeTmpOnce(force: true);

    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.writingOtherXml,
        message: '正在写入首次启动 SDK 路径…',
      ),
    );
    final otherResult = await writer.apply();
    final otherWritten = otherResult.success;

    await _saveSession(
      InstallSessionPhase.awaitingStudioLaunch,
      installerExitCode: installerExitCode,
      installVerified: true,
      otherXmlWritten: otherWritten,
    );

    if (await StudioLauncher.isRunning()) {
      _log('检测到 Android Studio 已在运行');
      await _onStudioRunning(launchedByUs: false);
      return;
    }

    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.waitingStudioLaunch,
        message: '等待 Android Studio 启动（10 秒）…',
        detail: '安装器结束不等于配置完成，需启动 IDE 完成首次向导',
      ),
    );

    final appeared = await StudioLauncher.waitUntilRunning(
      timeout: _studioLaunchWait,
    );
    if (appeared) {
      _log('10s 内检测到 Android Studio 已启动');
      await _onStudioRunning(launchedByUs: false);
      return;
    }

    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.launchingStudio,
        message: '未自动启动，正在打开 Android Studio…',
      ),
    );
    final launched = await StudioLauncher.launch(resolvedHome);
    if (!launched) {
      await _saveSession(InstallSessionPhase.studioFirstRunPending);
      _emit(
        const InstallerInterceptStatus(
          phase: InstallerInterceptPhase.interrupted,
          message: '无法启动 Android Studio，请手动打开后继续',
        ),
      );
      _log('启动 Studio 失败: $resolvedHome');
      return;
    }

    _log('已主动启动 Android Studio: $resolvedHome');
    await StudioLauncher.waitUntilRunning(timeout: const Duration(seconds: 15));
    await _onStudioRunning(launchedByUs: true);
  }

  Future<void> _onStudioRunning({required bool launchedByUs}) async {
    await _saveSession(
      InstallSessionPhase.studioFirstRunPending,
      studioLaunchedByUs: launchedByUs,
    );
    _emit(
      InstallerInterceptStatus(
        phase: InstallerInterceptPhase.studioRunning,
        message: launchedByUs
            ? '已启动 Android Studio，请在 IDE 中完成首次配置'
            : 'Android Studio 已运行，请在 IDE 中完成首次配置',
        detail: 'NSIS 安装器与 IDE 首次向导是不同阶段',
      ),
    );

    await Future<void>.delayed(const Duration(seconds: 2));

    await _saveSession(InstallSessionPhase.completed, studioLaunchedByUs: launchedByUs);
    await InstallSession.clear();

    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.done,
        message: '安装监视完成',
        detail: '若 IDE 仍提示 SDK 路径，请在首次向导中确认或回到本工具检查环境变量',
      ),
    );
  }

  Future<void> _saveSession(
    InstallSessionPhase phase, {
    int? installerExitCode,
    bool? installVerified,
    bool? studioLaunchedByUs,
    bool? otherXmlWritten,
  }) async {
    final existing = InstallSession.loadPending();
    await InstallSession.save(
      InstallSession(
        versionKey: versionKey,
        workingDirectory: workingDirectory,
        paths: _paths,
        phase: phase,
        installerExitCode: installerExitCode ?? existing?.installerExitCode,
        installVerified: installVerified ?? existing?.installVerified ?? false,
        studioLaunchedByUs:
            studioLaunchedByUs ?? existing?.studioLaunchedByUs ?? false,
        otherXmlWritten: otherXmlWritten ?? existing?.otherXmlWritten ?? false,
      ),
    );
  }

  Future<void> _pollInstallerUi() async {
    if (!InstallerUiPath.isSupported ||
        installHome.isEmpty ||
        androidHome.isEmpty ||
        androidUserHome.isEmpty) {
      await _writeTmpOnce(force: false);
      return;
    }

    final ui = InstallerUiPath(
      installHome: installHome,
      androidHome: androidHome,
      androidUserHome: androidUserHome,
    );
    final result = await ui.alignVisibleEdits();

    if (result.foundInstallerWindow) {
      if (result.diagnostics.isNotEmpty) {
        _logThrottled('UI 诊断: ${result.diagnostics}');
      }
      if (result.installDirVerified && !_installDirAlignedReported) {
        _installDirAlignedReported = true;
        _emit(
          InstallerInterceptStatus(
            phase: InstallerInterceptPhase.alignedInstallDir,
            message: '已对齐安装目录 → $installHome',
          ),
        );
        _log('安装目录 UI 已验证: $installHome');
      } else if (result.installDirAligned && !result.installDirVerified) {
        _logThrottled('安装目录 UI 写入未生效（已用 /D= 启动）');
      } else if (result.installDirVerified) {
        _logThrottled('纠正安装目录为 $installHome');
      }

      if (result.sdkEditAligned || result.userHomeEditAligned) {
        _logThrottled(
          'SDK/用户配置编辑框 sdk=${result.sdkEditAligned} user=${result.userHomeEditAligned}',
        );
      }
    } else if (_startedAt != null &&
        !_installDirMissReported &&
        !_installDirAlignedReported &&
        DateTime.now().difference(_startedAt!) > _installDirGrace) {
      _installDirMissReported = true;
      _emit(
        const InstallerInterceptStatus(
          phase: InstallerInterceptPhase.installDirMiss,
          message: '未找到安装目录控件，已用 NSIS /D= 指定路径',
        ),
      );
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

  void stopMonitoring() {
    _stopped = true;
    unawaited(_saveSession(InstallSessionPhase.interrupted));
    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.interrupted,
        message: '监视已暂停，可从下载页点击「继续安装」',
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
