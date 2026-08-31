import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/script_locator.dart';

/// 通过 PowerShell + user32 对齐 Android Studio NSIS 安装向导路径编辑框。
class InstallerUiPath {
  InstallerUiPath({
    required this.installHome,
    required this.androidHome,
    required this.androidUserHome,
  });

  final String installHome;
  final String androidHome;
  final String androidUserHome;

  static bool get isSupported => Platform.isWindows;

  Future<InstallerUiAlignResult> alignVisibleEdits() async {
    if (!isSupported) {
      return const InstallerUiAlignResult(
        installDirAligned: false,
        installDirVerified: false,
        sdkEditAligned: false,
        userHomeEditAligned: false,
        foundInstallerWindow: false,
      );
    }

    final scriptPath = await resolveAlignInstallerPathsScript();
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
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    if (result.exitCode != 0) {
      return const InstallerUiAlignResult(
        installDirAligned: false,
        installDirVerified: false,
        sdkEditAligned: false,
        userHomeEditAligned: false,
        foundInstallerWindow: false,
      );
    }

    final stdout = (result.stdout as String? ?? '').replaceFirst('\uFEFF', '').trim();
    if (stdout.isEmpty) {
      return const InstallerUiAlignResult(
        installDirAligned: false,
        installDirVerified: false,
        sdkEditAligned: false,
        userHomeEditAligned: false,
        foundInstallerWindow: false,
      );
    }

    try {
      final json = jsonDecode(stdout) as Map<String, dynamic>;
      return InstallerUiAlignResult(
        installDirAligned: json['installDirAligned'] == true,
        installDirVerified: json['installDirVerified'] == true ||
            json['installDirAligned'] == true,
        sdkEditAligned: json['sdkEditAligned'] == true,
        userHomeEditAligned: json['userHomeEditAligned'] == true,
        foundInstallerWindow: json['foundInstallerWindow'] == true,
        diagnostics: json['installDiagnostics']?.toString() ?? '',
      );
    } catch (_) {
      return const InstallerUiAlignResult(
        installDirAligned: false,
        installDirVerified: false,
        sdkEditAligned: false,
        userHomeEditAligned: false,
        foundInstallerWindow: false,
      );
    }
  }
}

class InstallerUiAlignResult {
  const InstallerUiAlignResult({
    required this.installDirAligned,
    required this.installDirVerified,
    required this.sdkEditAligned,
    required this.userHomeEditAligned,
    required this.foundInstallerWindow,
    this.diagnostics = '',
  });

  final bool installDirAligned;
  final bool installDirVerified;
  final bool sdkEditAligned;
  final bool userHomeEditAligned;
  final bool foundInstallerWindow;
  final String diagnostics;

  bool get anyAligned =>
      installDirVerified || sdkEditAligned || userHomeEditAligned;
}
