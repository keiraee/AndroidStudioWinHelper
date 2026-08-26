import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/sdk_setup_manager.dart';

class SdkCheck implements DiagnosticCheck {
  @override
  String get checkId => 'sdk';
  @override
  String get title => 'Android SDK';
  @override
  String? get relatedTabId => 'sdk_setup';

  @override
  Future<DiagnosticResult> quickCheck() async {
    final issues = <DiagnosticIssue>[];
    final androidHome = Platform.environment['ANDROID_HOME'] ?? Platform.environment['ANDROID_SDK_ROOT'];
    if (androidHome == null || androidHome.isEmpty) {
      issues.add(DiagnosticIssue(message: 'ANDROID_HOME / ANDROID_SDK_ROOT 未设置', severity: IssueSeverity.error));
    } else if (!Directory(androidHome).existsSync()) {
      issues.add(DiagnosticIssue(message: 'SDK 路径不存在: $androidHome', severity: IssueSeverity.error));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];
    final sdkDir = SdkSetupManager.detectSdkDir();
    if (!Directory(sdkDir).existsSync()) {
      issues.add(DiagnosticIssue(message: 'SDK 目录不存在: $sdkDir', severity: IssueSeverity.error));
      return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
    }
    final requiredDirs = ['platforms', 'build-tools', 'platform-tools'];
    for (final dir in requiredDirs) {
      final path = '$sdkDir/$dir';
      if (!Directory(path).existsSync()) {
        issues.add(DiagnosticIssue(message: 'SDK 缺少 $dir/ 目录', severity: IssueSeverity.error));
      } else {
        final contents = Directory(path).listSync();
        if (contents.isEmpty) {
          issues.add(DiagnosticIssue(message: 'SDK $dir/ 目录为空', severity: IssueSeverity.warning));
        }
      }
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }
}
