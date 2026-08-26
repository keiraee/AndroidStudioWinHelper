import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/diagnostics/mirror_source.dart';

class NetworkCheck implements DiagnosticCheck {
  @override
  String get checkId => 'network';
  @override
  String get title => '网络环境';
  @override
  String? get relatedTabId => null;

  Future<List<MirrorTestResult>> testMirrors() async {
    final results = <MirrorTestResult>[];
    for (final mirror in MirrorSource.builtIn) {
      final sw = Stopwatch()..start();
      try {
        final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
        final request = await client.getUrl(Uri.parse(mirror.mavenUrl));
        final response = await request.close().timeout(const Duration(seconds: 5));
        sw.stop();
        response.drain();
        client.close();
        results.add(MirrorTestResult(source: mirror, reachable: response.statusCode == 200, latencyMs: sw.elapsedMilliseconds));
      } catch (_) {
        sw.stop();
        results.add(MirrorTestResult(source: mirror, reachable: false, latencyMs: null));
      }
    }
    return results;
  }

  Future<bool> testGoogleSdk() async {
    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(Uri.parse('https://dl.google.com/android/repository/repository2-3.xml'));
      final response = await request.close().timeout(const Duration(seconds: 5));
      response.drain();
      client.close();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  String? readCurrentMirror() {
    final gradleHome = _getGradleHome();
    final initGradle = File('$gradleHome/init.gradle');
    if (!initGradle.existsSync()) return null;
    final content = initGradle.readAsStringSync();
    for (final mirror in MirrorSource.builtIn) {
      if (content.contains(mirror.mavenUrl)) return mirror.name;
    }
    return null;
  }

  Future<void> applyMirror(MirrorSource mirror) async {
    final gradleHome = _getGradleHome();
    await Directory(gradleHome).create(recursive: true);
    final initGradle = File('$gradleHome/init.gradle');
    final mirrorBlock = '''// ASWH Mirror Start
allprojects {
    repositories {
        maven { url '${mirror.mavenUrl}' }
        ${mirror.googleUrl != null ? "maven { url '${mirror.googleUrl}' }" : ''}
        mavenCentral()
        google()
    }
}
// ASWH Mirror End''';
    if (initGradle.existsSync()) {
      var content = initGradle.readAsStringSync();
      final pattern = RegExp(r'// ASWH Mirror Start.*?// ASWH Mirror End', dotAll: true);
      if (pattern.hasMatch(content)) {
        content = content.replaceAll(pattern, mirrorBlock);
      } else {
        content = '$content\n\n$mirrorBlock';
      }
      await initGradle.writeAsString(content);
    } else {
      await initGradle.writeAsString(mirrorBlock);
    }
  }

  @override
  Future<DiagnosticResult> quickCheck() async {
    return DiagnosticResult.ok(checkId: checkId, title: title);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];
    final googleOk = await testGoogleSdk();
    if (!googleOk) {
      issues.add(DiagnosticIssue(message: 'Google SDK 服务器不可达（可能需要代理或镜像）', severity: IssueSeverity.warning));
    }
    final mirrors = await testMirrors();
    final reachableCount = mirrors.where((m) => m.reachable).length;
    if (reachableCount == 0) {
      issues.add(DiagnosticIssue(message: '所有镜像源均不可达，请检查网络', severity: IssueSeverity.error));
    }
    final currentMirror = readCurrentMirror();
    if (currentMirror == null && !googleOk) {
      issues.add(DiagnosticIssue(message: '未配置镜像源且Google服务器不可达，Gradle依赖将无法下载', severity: IssueSeverity.error));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues);
  }

  String _getGradleHome() {
    final envHome = Platform.environment['GRADLE_USER_HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    return '$userProfile/.gradle';
  }
}
