import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/env_path_manager.dart';

class JdkCheck implements DiagnosticCheck {
  @override
  String get checkId => 'jdk';
  @override
  String get title => 'JDK 环境';
  @override
  String? get relatedTabId => 'env_config';

  final EnvPathManager _envManager;
  JdkCheck({EnvPathManager? envManager}) : _envManager = envManager ?? EnvPathManager();

  @override
  Future<DiagnosticResult> quickCheck() async {
    final issues = <DiagnosticIssue>[];
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome == null || javaHome.isEmpty) {
      issues.add(DiagnosticIssue(message: 'JAVA_HOME 环境变量未设置', severity: IssueSeverity.error));
    } else if (!Directory(javaHome).existsSync()) {
      issues.add(DiagnosticIssue(message: 'JAVA_HOME 指向不存在的路径: $javaHome', severity: IssueSeverity.error));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome == null || javaHome.isEmpty) {
      issues.add(DiagnosticIssue(
        message: 'JAVA_HOME 环境变量未设置',
        severity: IssueSeverity.error,
        fix: FixAction(label: '在环境配置中设置', risk: FixRisk.risky, execute: () async {}),
      ));
      return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
    }
    if (!Directory(javaHome).existsSync()) {
      final detectedJdk = _detectJdkPath();
      issues.add(DiagnosticIssue(
        message: 'JAVA_HOME 指向不存在的路径: $javaHome',
        severity: IssueSeverity.error,
        fix: detectedJdk != null
            ? FixAction(label: '修正为 $detectedJdk', risk: FixRisk.risky,
                execute: () async { await _envManager.writeVariable(variable: 'JAVA_HOME', value: detectedJdk); })
            : FixAction(label: '前往环境配置设置', risk: FixRisk.safe, execute: () async {}),
      ));
      return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
    }
    try {
      final result = await Process.run('java', ['-version']);
      final output = (result.stderr as String).isNotEmpty ? result.stderr as String : result.stdout as String;
      final versionMatch = RegExp(r'"(\d+)\.(\d+)').firstMatch(output);
      if (versionMatch != null) {
        final major = int.tryParse(versionMatch.group(1) ?? '') ?? 0;
        if (major < 17) {
          issues.add(DiagnosticIssue(message: 'JDK 版本过低: 需要 17+，当前 ${versionMatch.group(0)}', severity: IssueSeverity.error));
        }
      }
    } catch (_) {
      issues.add(DiagnosticIssue(message: '无法执行 java -version', severity: IssueSeverity.warning));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title, relatedTabId: relatedTabId);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues, relatedTabId: relatedTabId);
  }

  String? _detectJdkPath() {
    final candidates = [r'C:\Program Files\Java', r'C:\Program Files\Eclipse Adoptium', r'C:\Program Files\Microsoft\jdk-17', r'C:\Program Files\Amazon Corretto'];
    for (final dir in candidates) {
      final directory = Directory(dir);
      if (directory.existsSync()) {
        final subdirs = directory.listSync().whereType<Directory>().toList()..sort((a, b) => b.path.compareTo(a.path));
        for (final sub in subdirs) {
          if (File('${sub.path}/bin/java.exe').existsSync()) return sub.path;
        }
      }
    }
    return null;
  }
}
