import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';

class GradleCheck implements DiagnosticCheck {
  @override
  String get checkId => 'gradle';
  @override
  String get title => 'Gradle';
  @override
  String? get relatedTabId => 'storage';

  @override
  Future<DiagnosticResult> quickCheck() async {
    final gradleHome = _getGradleHome();
    final issues = <DiagnosticIssue>[];
    if (!Directory(gradleHome).existsSync()) {
      issues.add(DiagnosticIssue(message: 'Gradle 目录不存在: $gradleHome', severity: IssueSeverity.info));
    }
    final initGradle = File('$gradleHome/init.gradle');
    if (!initGradle.existsSync()) {
      issues.add(DiagnosticIssue(message: 'init.gradle 未配置（镜像源未生效）', severity: IssueSeverity.info));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final gradleHome = _getGradleHome();
    final issues = <DiagnosticIssue>[];
    if (!Directory(gradleHome).existsSync()) {
      return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    }
    final cachesDir = Directory('$gradleHome/caches');
    if (cachesDir.existsSync()) {
      int totalSize = 0;
      try {
        await for (final entity in cachesDir.list(recursive: true)) {
          if (entity is File) totalSize += await entity.length();
        }
      } catch (_) {}
      final sizeGB = totalSize / (1024 * 1024 * 1024);
      if (sizeGB > 5) {
        issues.add(DiagnosticIssue(
          message: 'Gradle 缓存占用 ${sizeGB.toStringAsFixed(1)}GB (${cachesDir.path})',
          severity: IssueSeverity.warning,
          fix: FixAction(label: '清理缓存（需确认）', risk: FixRisk.risky, execute: () async { await cachesDir.delete(recursive: true); }),
        ));
      }
    }
    final initGradle = File('$gradleHome/init.gradle');
    if (!initGradle.existsSync()) {
      issues.add(DiagnosticIssue(message: 'init.gradle 未配置（镜像源未生效）', severity: IssueSeverity.info));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }

  String _getGradleHome() {
    final envHome = Platform.environment['GRADLE_USER_HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    return '$userProfile/.gradle';
  }
}
