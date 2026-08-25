import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/sdk_setup_manager.dart';

class AdbPathCheck implements DiagnosticCheck {
  @override
  String get checkId => 'adb_path';
  @override
  String get title => 'ADB / PATH';
  @override
  String? get relatedTabId => 'env_config';

  final EnvPathManager _envManager;
  AdbPathCheck({EnvPathManager? envManager}) : _envManager = envManager ?? EnvPathManager();

  @override
  Future<DiagnosticResult> quickCheck() async {
    final path = Platform.environment['PATH'] ?? '';
    final hasPlatformTools = path.split(';').any((p) => p.toLowerCase().contains('platform-tools'));
    if (hasPlatformTools) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: [
      DiagnosticIssue(message: 'platform-tools 不在系统 PATH 中', severity: IssueSeverity.warning),
    ], relatedTabId: relatedTabId);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];
    final path = Platform.environment['PATH'] ?? '';
    final hasPlatformTools = path.split(';').any((p) => p.toLowerCase().contains('platform-tools'));
    if (!hasPlatformTools) {
      final sdkDir = SdkSetupManager.detectSdkDir();
      final platformToolsPath = '$sdkDir/platform-tools';
      issues.add(DiagnosticIssue(
        message: 'platform-tools 不在系统 PATH 中',
        severity: IssueSeverity.warning,
        fix: Directory(platformToolsPath).existsSync()
            ? FixAction(label: '添加到 PATH', risk: FixRisk.safe, execute: () async { await _envManager.appendToPath(path: platformToolsPath); })
            : null,
      ));
    }
    try {
      final result = await Process.run('adb', ['version']);
      if (result.exitCode != 0) {
        issues.add(DiagnosticIssue(message: 'adb 执行失败', severity: IssueSeverity.warning));
      }
    } catch (_) {
      if (hasPlatformTools) {
        issues.add(DiagnosticIssue(message: 'adb 不在 PATH 中或无法执行', severity: IssueSeverity.warning));
      }
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }
}
