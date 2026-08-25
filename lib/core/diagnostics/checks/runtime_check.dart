import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';

class RuntimeCheck implements DiagnosticCheck {
  @override
  String get checkId => 'runtime';
  @override
  String get title => '运行时依赖';
  @override
  String? get relatedTabId => null;

  @override
  Future<DiagnosticResult> quickCheck() async {
    final issues = <DiagnosticIssue>[];
    final vcVersions = _readRegistryVcVersions();
    if (vcVersions.isEmpty) {
      issues.add(DiagnosticIssue(message: '未检测到 Visual C++ Redistributable', severity: IssueSeverity.warning));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];
    final vcVersions = _readRegistryVcVersions();
    if (vcVersions.isEmpty) {
      issues.add(DiagnosticIssue(
        message: '未检测到 Visual C++ Redistributable，Android模拟器可能无法运行',
        severity: IssueSeverity.warning,
        fix: FixAction(label: '打开下载页面', risk: FixRisk.safe, execute: () async {
          await Process.run('cmd', ['/c', 'start', '', 'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist']);
        }),
      ));
    }
    final dotnetVersion = _readDotNetVersion();
    if (dotnetVersion == null) {
      issues.add(DiagnosticIssue(message: '未检测到 .NET Framework 4.6+', severity: IssueSeverity.info));
    }
    if (issues.isEmpty) return DiagnosticResult.ok(checkId: checkId, title: title);
    return DiagnosticResult.withIssues(checkId: checkId, title: title, issues: issues);
  }

  List<String> _readRegistryVcVersions() {
    try {
      final result = Process.runSync('reg', ['query', r'HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64', '/v', 'Version']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match = RegExp(r'Versity+\s+REG_SZ\s+(.+)').firstMatch(output);
        if (match != null) return [match.group(1)!.trim()];
      }
    } catch (_) {}
    final dllPaths = [r'C:\Windows\System32\vcruntime140.dll', r'C:\Windows\System32\msvcp140.dll'];
    final found = <String>[];
    for (final p in dllPaths) {
      if (File(p).existsSync()) found.add(p);
    }
    return found;
  }

  String? _readDotNetVersion() {
    try {
      final result = Process.runSync('reg', ['query', r'HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full', '/v', 'Release']);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match = RegExp(r'Release\s+REG_DWORD\s+(0x[0-9a-fA-F]+)').firstMatch(output);
        if (match != null) {
          final release = int.tryParse(match.group(1)!, radix: 16) ?? 0;
          if (release >= 394254) return '4.6.1+';
        }
      }
    } catch (_) {}
    return null;
  }
}
