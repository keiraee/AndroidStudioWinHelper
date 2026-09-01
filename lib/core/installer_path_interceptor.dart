import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/as_first_run_sdk_config.dart';
import 'package:androidstudiowinhelper/core/install_env_defaults.dart';
import 'package:androidstudiowinhelper/core/install_session.dart';
import 'package:androidstudiowinhelper/core/installer_intercept_worker.dart';
import 'package:androidstudiowinhelper/core/installer_settings_tmp.dart';
import 'package:androidstudiowinhelper/core/installer_ui_path.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/nsis_direct_extractor.dart';
import 'package:androidstudiowinhelper/core/studio_launcher.dart';

enum InstallerInterceptPhase {
  listingPayload,
  extracting,
  deploying,
  writingRegistry,
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
    this.nsisDirArg,
    this.registryPrimed = false,
    this.uiInstallDirVerified = false,
    this.visibleInstallPath,
    this.extractPercent = 0,
    this.extractTotalFiles = 0,
    this.extractDoneFiles = 0,
    this.extractCurrentFile,
    this.extractTotalBytes = 0,
    this.extractDoneBytes = 0,
    this.androidUserHome,
  });

  final InstallerInterceptPhase phase;
  final String message;
  final String? detail;

  /// 目标安装目录（7z 解包部署路径）。
  final String? nsisDirArg;

  /// 解包脚本是否已写入注册表 InstallLocation / Path。
  final bool registryPrimed;

  /// 安装向导 Edit 读回是否与目标一致（NSIS 模式遗留）。
  final bool uiInstallDirVerified;

  /// 安装向导界面上当前可见的安装路径（NSIS 模式遗留）。
  final String? visibleInstallPath;

  final int extractPercent;
  final int extractTotalFiles;
  final int extractDoneFiles;
  final String? extractCurrentFile;
  final int extractTotalBytes;
  final int extractDoneBytes;
  final String? androidUserHome;

  InstallerInterceptStatus copyWith({
    InstallerInterceptPhase? phase,
    String? message,
    String? detail,
    String? nsisDirArg,
    bool? registryPrimed,
    bool? uiInstallDirVerified,
    String? visibleInstallPath,
    bool clearVisibleInstallPath = false,
    int? extractPercent,
    int? extractTotalFiles,
    int? extractDoneFiles,
    String? extractCurrentFile,
    bool clearExtractCurrentFile = false,
    int? extractTotalBytes,
    int? extractDoneBytes,
    String? androidUserHome,
  }) {
    return InstallerInterceptStatus(
      phase: phase ?? this.phase,
      message: message ?? this.message,
      detail: detail ?? this.detail,
      nsisDirArg: nsisDirArg ?? this.nsisDirArg,
      registryPrimed: registryPrimed ?? this.registryPrimed,
      uiInstallDirVerified:
          uiInstallDirVerified ?? this.uiInstallDirVerified,
      visibleInstallPath: clearVisibleInstallPath
          ? null
          : (visibleInstallPath ?? this.visibleInstallPath),
      extractPercent: extractPercent ?? this.extractPercent,
      extractTotalFiles: extractTotalFiles ?? this.extractTotalFiles,
      extractDoneFiles: extractDoneFiles ?? this.extractDoneFiles,
      extractCurrentFile: clearExtractCurrentFile
          ? null
          : (extractCurrentFile ?? this.extractCurrentFile),
      extractTotalBytes: extractTotalBytes ?? this.extractTotalBytes,
      extractDoneBytes: extractDoneBytes ?? this.extractDoneBytes,
      androidUserHome: androidUserHome ?? this.androidUserHome,
    );
  }
}

/// 官方安装器路径拦截 + 装后启动 Studio 续装。
class InstallerPathInterceptor {
  InstallerPathInterceptor._({
    required this.versionKey,
    required this.workingDirectory,
    required this.installHome,
    required this.androidHome,
    required this.androidUserHome,
    required this.installerExePath,
    this.registryPrimed = false,
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
  final String installerExePath;
  bool registryPrimed;

  final StreamController<InstallerInterceptStatus> _statusController =
      StreamController<InstallerInterceptStatus>.broadcast();

  Stream<InstallerInterceptStatus> get statusStream => _statusController.stream;

  bool _stopped = false;
  bool _installDirMissReported = false;
  bool _installDirAlignedReported = false;
  bool _sdkTmpAlignedReported = false;
  bool _uiInstallDirVerified = false;
  String _visibleInstallPath = '';
  InstallerInterceptWorker? _uiWorker;
  DateTime? _startedAt;
  DateTime _lastCorrectLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  InstallerInterceptStatus? _lastStatus;
  NsisExtractProgress? _lastExtractProgress;

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
    required String installerExePath,
  }) async {
    if (_active != null) {
      throw StateError('已有安装路径拦截任务在运行。');
    }

    final installHome = paths['AS_INSTALL_HOME']?.trim() ?? '';
    final exe = installerExePath.trim();
    if (exe.isEmpty || !File(exe).existsSync()) {
      throw StateError('安装包不存在: $exe');
    }

    final androidUserHome = paths['ANDROID_USER_HOME']?.trim().isNotEmpty == true
        ? paths['ANDROID_USER_HOME']!.trim()
        : (InstallEnvDefaults.sdkUserHomeFromInstallHome(installHome) ?? '');

    final interceptor = InstallerPathInterceptor._(
      versionKey: versionKey,
      workingDirectory: workingDirectory,
      installHome: installHome,
      androidHome: paths['ANDROID_HOME']?.trim() ?? '',
      androidUserHome: androidUserHome,
      installerExePath: File(exe).absolute.path,
      registryPrimed: false,
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
    unawaited(interceptor._runDirectExtract());
    return interceptor;
  }

  /// 不再支持从下载页恢复监视。
  static Future<InstallerPathInterceptor> resume({
    required InstallSession session,
  }) {
    throw UnsupportedError('已移除继续监视功能，请重新运行安装。');
  }

  void _emit(InstallerInterceptStatus status) {
    if (_stopped || _statusController.isClosed) return;
    final enriched = InstallerInterceptStatus(
      phase: status.phase,
      message: status.message,
      detail: status.detail,
      nsisDirArg: installHome.isEmpty ? status.nsisDirArg : installHome,
      registryPrimed: registryPrimed || status.registryPrimed,
      uiInstallDirVerified: _uiInstallDirVerified,
      visibleInstallPath: _visibleInstallPath.isEmpty
          ? status.visibleInstallPath
          : _visibleInstallPath,
      extractPercent: status.extractPercent,
      extractTotalFiles: status.extractTotalFiles,
      extractDoneFiles: status.extractDoneFiles,
      extractCurrentFile: status.extractCurrentFile,
      extractTotalBytes: status.extractTotalBytes,
      extractDoneBytes: status.extractDoneBytes,
      androidUserHome: androidUserHome.isEmpty
          ? status.androidUserHome
          : androidUserHome,
    );
    _lastStatus = enriched;
    _statusController.add(enriched);
  }

  InstallerInterceptStatus _withLayers({
    required InstallerInterceptPhase phase,
    required String message,
    String? detail,
    NsisExtractProgress? extract,
  }) {
    return InstallerInterceptStatus(
      phase: phase,
      message: message,
      detail: detail,
      nsisDirArg: installHome.isEmpty ? null : installHome,
      registryPrimed: registryPrimed,
      uiInstallDirVerified: _uiInstallDirVerified,
      visibleInstallPath:
          _visibleInstallPath.isEmpty ? null : _visibleInstallPath,
      extractPercent: extract?.percent ?? _lastExtractProgress?.percent ?? 0,
      extractTotalFiles:
          extract?.totalFiles ?? _lastExtractProgress?.totalFiles ?? 0,
      extractDoneFiles:
          extract?.extractedFiles ?? _lastExtractProgress?.extractedFiles ?? 0,
      extractCurrentFile:
          extract?.currentFile ?? _lastExtractProgress?.currentFile,
      extractTotalBytes:
          extract?.totalBytes ?? _lastExtractProgress?.totalBytes ?? 0,
      extractDoneBytes:
          extract?.extractedBytes ?? _lastExtractProgress?.extractedBytes ?? 0,
      androidUserHome: androidUserHome.isEmpty ? null : androidUserHome,
    );
  }

  void _emitLayers({
    required InstallerInterceptPhase phase,
    required String message,
    String? detail,
    NsisExtractProgress? extract,
  }) {
    _emit(_withLayers(
      phase: phase,
      message: message,
      detail: detail,
      extract: extract,
    ));
  }

  InstallerInterceptPhase _mapExtractPhase(String phase) {
    return switch (phase) {
      'listing' => InstallerInterceptPhase.listingPayload,
      'extracting' => InstallerInterceptPhase.extracting,
      'deploying' => InstallerInterceptPhase.deploying,
      'registry' || 'shortcut' => InstallerInterceptPhase.writingRegistry,
      'error' => InstallerInterceptPhase.error,
      'done' => InstallerInterceptPhase.installerFinished,
      _ => InstallerInterceptPhase.extracting,
    };
  }

  void _onExtractProgress(NsisExtractProgress progress) {
    _lastExtractProgress = progress;
    _emit(
      _withLayers(
        phase: _mapExtractPhase(progress.phase),
        message: progress.message,
        detail: _formatExtractDetail(progress),
        extract: progress,
      ),
    );
  }

  String? _formatExtractDetail(NsisExtractProgress progress) {
    final parts = <String>[];
    if (progress.totalFiles > 0) {
      parts.add(
        '文件 ${progress.extractedFiles}/${progress.totalFiles}',
      );
    }
    if (progress.currentFile != null && progress.currentFile!.isNotEmpty) {
      parts.add(progress.currentFile!);
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  void _refreshLayerStatus({InstallerInterceptPhase? phase, String? message}) {
    final current = _lastStatus;
    if (current == null) return;
    _emit(
      current.copyWith(
        phase: phase ?? current.phase,
        message: message ?? current.message,
        uiInstallDirVerified: _uiInstallDirVerified,
        visibleInstallPath: _visibleInstallPath.isEmpty
            ? null
            : _visibleInstallPath,
      ),
    );
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

  Future<void> _runDirectExtract() async {
    _startedAt = DateTime.now();
    _emitLayers(
      phase: InstallerInterceptPhase.listingPayload,
      message: installHome.isEmpty
          ? '正在解包 Android Studio 安装包…'
          : '正在解包并部署到 $installHome…',
      detail: r'7-Zip 直接解压 $_31_ 载荷，绕过 NSIS /D=',
    );
    _log(
      '开始 7z 解包安装: exe=$installerExePath -> $installHome',
    );

    final extractor = NsisDirectExtractor();
    StreamSubscription<NsisExtractProgress>? progressSub;
    progressSub = extractor.progressStream.listen(_onExtractProgress);

    try {
      await _writeTmpOnce(force: true);

      final result = await extractor.extractAndDeploy(
        installerPath: installerExePath,
        installHome: installHome,
        androidHome: androidHome,
        androidUserHome: androidUserHome,
      );

      if (_stopped) {
        _emit(
          const InstallerInterceptStatus(
            phase: InstallerInterceptPhase.cancelled,
            message: '安装已取消',
          ),
        );
        return;
      }

      if (!result.success) {
        _emit(
          InstallerInterceptStatus(
            phase: InstallerInterceptPhase.error,
            message: '解包部署失败',
            detail: result.error.isEmpty ? '未知错误' : result.error,
          ),
        );
        _log('解包失败: ${result.error}');
        await InstallSession.clear();
        return;
      }

      registryPrimed = true;
      _log('解包成功: ${result.totalFiles} 个文件 -> ${result.installHome}');
      await _runPostInstall(resume: false);
    } catch (e, st) {
      _log('解包异常: $e\n$st');
      _emit(
        InstallerInterceptStatus(
          phase: InstallerInterceptPhase.error,
          message: '解包异常：$e',
        ),
      );
      await InstallSession.clear();
    } finally {
      await progressSub.cancel();
      await _dispose();
    }
  }

  Future<void> _runPostInstall({
    required bool resume,
    int? installerExitCode,
  }) async {
    final writer = AsFirstRunSdkConfig(
      installHome: installHome,
      androidHome: androidHome,
    );
    _emit(
      const InstallerInterceptStatus(
        phase: InstallerInterceptPhase.installerFinished,
        message: '解包部署完成，正在验证安装结果（最多 20 秒）…',
      ),
    );
    final resolvedHome = await writer.resolveInstallHomeWithRetry();
    final installOk = resolvedHome != null;

    if (!installOk) {
      await InstallSession.clear();
      _emit(
        InstallerInterceptStatus(
          phase: InstallerInterceptPhase.error,
          message: '未检测到有效安装，请重新运行安装',
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
    final launched = await StudioLauncher.launch(
      resolvedHome,
      androidHome: androidHome,
      androidUserHome: androidUserHome,
    );
    if (!launched) {
      _emit(
        const InstallerInterceptStatus(
          phase: InstallerInterceptPhase.error,
          message: '无法启动 Android Studio，请手动打开',
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
        detail: '解包部署与 IDE 首次向导是不同阶段',
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
      worker: _uiWorker,
    );
    final result = await ui.alignVisibleEdits();

    if (result.registryPrimed) {
      registryPrimed = true;
    }

    if (result.foundInstallerWindow) {
      if (result.diagnostics.isNotEmpty) {
        _logThrottled('UI 诊断: ${result.diagnostics}');
      }

      if (result.visibleInstallPath.isNotEmpty) {
        _visibleInstallPath = result.visibleInstallPath;
      }

      if (result.installDirVerified) {
        _uiInstallDirVerified = true;
        if (!_installDirAlignedReported) {
          _installDirAlignedReported = true;
          _emitLayers(
            phase: InstallerInterceptPhase.alignedInstallDir,
            message: '安装向导界面路径已验证 → $installHome',
            detail: 'NSIS /D= 与界面读回一致',
          );
          _log('安装目录 UI 已验证: $installHome');
        } else {
          _refreshLayerStatus();
        }
      } else if (result.foundInstallerWindow &&
          result.visibleInstallPath.isNotEmpty) {
        _uiInstallDirVerified = false;
        _logThrottled(
          '界面仍显示 ${result.visibleInstallPath}，继续纠偏；实际安装以 /D=$installHome 为准',
        );
        _refreshLayerStatus(
          message: 'NSIS /D= 已指定 $installHome，界面仍显示 ${result.visibleInstallPath}',
        );
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
      _emitLayers(
        phase: InstallerInterceptPhase.installDirMiss,
        message: installHome.isEmpty
            ? '未找到安装目录控件'
            : '未找到安装目录控件，实际安装目录已指定',
        detail: installHome.isEmpty ? null : installHome,
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
  }

  Future<void> _dispose() async {
    await _uiWorker?.dispose();
    _uiWorker = null;
    if (!_statusController.isClosed) {
      await _statusController.close();
    }
    if (_active == this) {
      _active = null;
    }
  }
}
