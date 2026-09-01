import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/installer_intercept_worker.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

/// 通过 PowerShell + user32 对齐 Android Studio NSIS 安装向导路径编辑框。
class InstallerUiPath {
  InstallerUiPath({
    required this.installHome,
    required this.androidHome,
    required this.androidUserHome,
    InstallerInterceptWorker? worker,
  }) : _worker = worker;

  final String installHome;
  final String androidHome;
  final String androidUserHome;
  final InstallerInterceptWorker? _worker;

  static bool get isSupported => Platform.isWindows;

  static InstallerUiAlignResult emptyResult() {
    return const InstallerUiAlignResult(
      installDirAligned: false,
      installDirVerified: false,
      sdkEditAligned: false,
      userHomeEditAligned: false,
      foundInstallerWindow: false,
      visibleInstallPath: '',
    );
  }

  Future<InstallerUiAlignResult> alignVisibleEdits() async {
    if (!isSupported) {
      return emptyResult();
    }

    final worker = _worker;
    if (worker != null) {
      return worker.readLatestResult();
    }

    final scriptPath = await resolveAlignInstallerPathsScript();
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptPath,
          '-InstallHome',
          installHome,
          '-AndroidHome',
          androidHome,
          '-AndroidUserHome',
          androidUserHome,
        ],
      );

      if (result.exitCode != 0) {
        return emptyResult();
      }

      final stdout = _decodeStdout(result.stdout).replaceFirst('\uFEFF', '').trim();
      if (stdout.isEmpty) {
        return emptyResult();
      }

      final jsonLine = stdout.split(RegExp(r'\r?\n')).lastWhere(
        (line) => line.trim().startsWith('{'),
        orElse: () => stdout,
      );

      final json = jsonDecode(jsonLine) as Map<String, dynamic>;
      return _parseResult(json);
    } catch (_) {
      return emptyResult();
    }
  }

  static InstallerUiAlignResult _parseResult(Map<String, dynamic> json) {
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
  }

  static String _decodeStdout(Object? raw) {
    if (raw is List<int>) {
      return utf8.decode(raw, allowMalformed: true);
    }
    return (raw as String? ?? '');
  }
}

class InstallerUiAlignResult {
  const InstallerUiAlignResult({
    required this.installDirAligned,
    required this.installDirVerified,
    required this.sdkEditAligned,
    required this.userHomeEditAligned,
    required this.foundInstallerWindow,
    this.visibleInstallPath = '',
    this.diagnostics = '',
    this.registryPrimed = false,
    this.elevatedWorker = false,
  });

  final bool installDirAligned;
  final bool installDirVerified;
  final bool sdkEditAligned;
  final bool userHomeEditAligned;
  final bool foundInstallerWindow;
  final String visibleInstallPath;
  final String diagnostics;
  final bool registryPrimed;
  final bool elevatedWorker;

  bool get anyAligned =>
      installDirVerified || sdkEditAligned || userHomeEditAligned;
}
