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
        visibleInstallPath: '',
      );
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
        return _emptyResult();
      }

      final stdout = _decodeStdout(result.stdout).replaceFirst('\uFEFF', '').trim();
      if (stdout.isEmpty) {
        return _emptyResult();
      }

      // 只取最后一行 JSON（避免 Add-Type 等污染 stdout）
      final jsonLine = stdout.split(RegExp(r'\r?\n')).lastWhere(
        (line) => line.trim().startsWith('{'),
        orElse: () => stdout,
      );

      final json = jsonDecode(jsonLine) as Map<String, dynamic>;
      return InstallerUiAlignResult(
        installDirAligned: json['installDirAligned'] == true,
        installDirVerified: json['installDirVerified'] == true,
        sdkEditAligned: json['sdkEditAligned'] == true,
        userHomeEditAligned: json['userHomeEditAligned'] == true,
        foundInstallerWindow: json['foundInstallerWindow'] == true,
        visibleInstallPath: json['visibleInstallPath']?.toString() ?? '',
        diagnostics: json['installDiagnostics']?.toString() ?? '',
      );
    } catch (_) {
      return _emptyResult();
    }
  }

  static InstallerUiAlignResult _emptyResult() {
    return const InstallerUiAlignResult(
      installDirAligned: false,
      installDirVerified: false,
      sdkEditAligned: false,
      userHomeEditAligned: false,
      foundInstallerWindow: false,
      visibleInstallPath: '',
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
  });

  final bool installDirAligned;
  final bool installDirVerified;
  final bool sdkEditAligned;
  final bool userHomeEditAligned;
  final bool foundInstallerWindow;
  final String visibleInstallPath;
  final String diagnostics;

  bool get anyAligned =>
      installDirVerified || sdkEditAligned || userHomeEditAligned;
}
