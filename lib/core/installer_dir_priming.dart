import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 启动 NSIS 安装器前预写注册表，辅助安装目录默认值（优先级低于 `/D=`）。
class InstallDirPrimingResult {
  const InstallDirPrimingResult({
    required this.installHome,
    this.uninstallInstallLocation = false,
    this.productRegistryPath = false,
    this.error = '',
  });

  final String installHome;
  final bool uninstallInstallLocation;
  final bool productRegistryPath;
  final String error;

  bool get anyWritten =>
      uninstallInstallLocation || productRegistryPath;

  bool get attempted => installHome.isNotEmpty;
}

class InstallerDirPriming {
  static const _logTag = 'InstallerIntercept';

  /// 在安装器启动前写入 Uninstall.InstallLocation 与 Android Studio.Path。
  static Future<InstallDirPrimingResult> prime(String installHome) async {
    final home = installHome
        .trim()
        .replaceAll('/', r'\')
        .replaceAll(RegExp(r'[\\/]+$'), '');
    if (!Platform.isWindows || home.isEmpty) {
      return InstallDirPrimingResult(installHome: home);
    }

    try {
      final script = r'''
$home = '__INSTALL_HOME__'
$out = @{
  uninstallInstallLocation = $false
  productRegistryPath = $false
  error = ''
}
try {
  $uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Android Studio'
  if (-not (Test-Path -LiteralPath $uninstallKey)) {
    New-Item -Path $uninstallKey -Force | Out-Null
  }
  Set-ItemProperty -LiteralPath $uninstallKey -Name 'InstallLocation' -Value $home -Type ExpandString -Force
  $out.uninstallInstallLocation = $true
} catch {
  $out.error = $_.Exception.Message
}
try {
  $productKey = 'HKLM:\SOFTWARE\Android Studio'
  if (-not (Test-Path -LiteralPath $productKey)) {
    New-Item -Path $productKey -Force | Out-Null
  }
  Set-ItemProperty -LiteralPath $productKey -Name 'Path' -Value $home -Type ExpandString -Force
  $out.productRegistryPath = $true
} catch {
  if ($out.error) { $out.error += ' | ' }
  $out.error += $_.Exception.Message
}
$out | ConvertTo-Json -Compress
'''.replaceFirst('__INSTALL_HOME__', _escapePsSingleQuoted(home));

      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          script,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      final stdout = (result.stdout as String? ?? '').replaceFirst('\uFEFF', '');
      if (stdout.trim().isEmpty) {
        return InstallDirPrimingResult(
          installHome: home,
          error: (result.stderr as String? ?? '').trim(),
        );
      }

      final json = jsonDecode(stdout.trim());
      if (json is! Map) {
        return InstallDirPrimingResult(installHome: home, error: '注册表预写结果无效');
      }

      final parsed = InstallDirPrimingResult(
        installHome: home,
        uninstallInstallLocation: json['uninstallInstallLocation'] == true,
        productRegistryPath: json['productRegistryPath'] == true,
        error: json['error']?.toString() ?? '',
      );
      LogManager.instance.write(
        _logTag,
        '注册表预写 installHome=$home '
        'uninstall=${parsed.uninstallInstallLocation} '
        'product=${parsed.productRegistryPath}'
        '${parsed.error.isEmpty ? '' : ' error=${parsed.error}'}',
      );
      return parsed;
    } catch (e) {
      LogManager.instance.write(_logTag, '注册表预写异常: $e');
      return InstallDirPrimingResult(installHome: home, error: e.toString());
    }
  }

  static String _escapePsSingleQuoted(String value) {
    return value.replaceAll("'", "''");
  }
}
