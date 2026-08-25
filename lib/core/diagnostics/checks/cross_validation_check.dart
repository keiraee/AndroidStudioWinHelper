import 'dart:io';
import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/sdk_setup_manager.dart';

class CrossValidationCheck implements DiagnosticCheck {
  @override
  String get checkId => 'cross_validation';
  @override
  String get title => '交叉验证';
  @override
  String? get relatedTabId => null;

  final AndroidStudioDetector _detector;
  CrossValidationCheck({AndroidStudioDetector? detector}) : _detector = detector ?? AndroidStudioDetector();

  @override
  Future<DiagnosticResult> quickCheck() async {
    return DiagnosticResult.ok(checkId: checkId, title: title);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];
    final androidHome = Platform.environment['ANDROID_HOME'] ?? Platform.environment['ANDROID_SDK_ROOT'];
    final detectedSdkDir = SdkSetupManager.detectSdkDir();
    if (androidHome != null && androidHome.isNotEmpty && androidHome != detectedSdkDir) {
      issues.add(DiagnosticIssue(
        message: 'ANDROID_HOME ($androidHome) 与自动检测路径 ($detectedSdkDir) 不一致',
        severity: IssueSeverity.warning,
      ));
    }
    final javaHome = Platform.environment['JAVA_HOME'] ?? '';
    if (javaHome.isNotEmpty && Directory(javaHome).existsSync()) {
      final jbrPath = '${Platform.environment['LOCALAPPDATA']}\\Android\\Android Studio\\jbr';
      final bundledJava = Directory(jbrPath);
      if (bundledJava.existsSync() && javaHome != jbrPath) {
        // This is normal - user may have their own JDK
      }
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues);
  }
}
