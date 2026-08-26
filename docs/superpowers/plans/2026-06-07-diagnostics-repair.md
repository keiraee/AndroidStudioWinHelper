# 综合诊断修复系统 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为ASWH新增"诊断修复"功能，聚合现有模块状态，提供健康仪表盘 + 自动/半自动修复。

**Architecture:** 集中式诊断引擎。每个检查域实现`DiagnosticCheck`接口，由`DiagnosticOrchestrator`统一编排。启动时快速检查（本地I/O），用户手动触发深度扫描（含网络）。安全修复自动执行，风险修复需确认。

**Tech Stack:** Dart/Flutter 3.10+, Material 3, 现有PowerShellRunner/EnvPathManager/SdkSetupManager等模块

---

### Task 1: 数据模型与接口定义

**Files:**
- Create: `lib/core/diagnostics/diagnostic_result.dart`
- Create: `lib/core/diagnostics/diagnostic_check.dart`

- [ ] **Step 1: 创建DiagnosticResult数据模型**

```dart
// lib/core/diagnostics/diagnostic_result.dart

enum DiagnosticStatus { ok, warning, error }
enum IssueSeverity { info, warning, error }
enum FixRisk { safe, risky }

class DiagnosticIssue {
  final String message;
  final IssueSeverity severity;
  final FixAction? fix;

  const DiagnosticIssue({
    required this.message,
    required this.severity,
    this.fix,
  });
}

class FixAction {
  final String label;
  final FixRisk risk;
  final Future<void> Function() execute;

  const FixAction({
    required this.label,
    required this.risk,
    required this.execute,
  });
}

class DiagnosticResult {
  final String checkId;
  final String title;
  final DiagnosticStatus status;
  final List<DiagnosticIssue> issues;
  final String? relatedTabId;

  const DiagnosticResult({
    required this.checkId,
    required this.title,
    required this.status,
    this.issues = const [],
    this.relatedTabId,
  });

  factory DiagnosticResult.ok({
    required String checkId,
    required String title,
    String? relatedTabId,
  }) {
    return DiagnosticResult(
      checkId: checkId,
      title: title,
      status: DiagnosticStatus.ok,
      relatedTabId: relatedTabId,
    );
  }

  factory DiagnosticResult.withIssues({
    required String checkId,
    required String title,
    required List<DiagnosticIssue> issues,
    String? relatedTabId,
  }) {
    final hasError = issues.any((i) => i.severity == IssueSeverity.error);
    final hasWarning = issues.any((i) => i.severity == IssueSeverity.warning);
    return DiagnosticResult(
      checkId: checkId,
      title: title,
      status: hasError
          ? DiagnosticStatus.error
          : hasWarning
              ? DiagnosticStatus.warning
              : DiagnosticStatus.ok,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }
}
```

- [ ] **Step 2: 创建DiagnosticCheck抽象接口**

```dart
// lib/core/diagnostics/diagnostic_check.dart

import 'diagnostic_result.dart';

abstract class DiagnosticCheck {
  String get checkId;
  String get title;
  String? get relatedTabId => null;

  /// 快速检查：纯本地I/O，<2秒
  Future<DiagnosticResult> quickCheck();

  /// 深度扫描：可能含网络请求、文件扫描
  Future<DiagnosticResult> fullScan();
}
```

- [ ] **Step 3: 提交**

```bash
git add lib/core/diagnostics/diagnostic_result.dart lib/core/diagnostics/diagnostic_check.dart
git commit -m "feat(diagnostics): add DiagnosticResult model and DiagnosticCheck interface"
```

---

### Task 2: DiagnosticOrchestrator 编排器

**Files:**
- Create: `lib/core/diagnostics/diagnostic_orchestrator.dart`

- [ ] **Step 1: 创建Orchestrator**

```dart
// lib/core/diagnostics/diagnostic_orchestrator.dart

import 'dart:async';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'diagnostic_check.dart';
import 'diagnostic_result.dart';

class DiagnosticOrchestrator {
  final List<DiagnosticCheck> _checks;
  final LogManager _log;

  DiagnosticOrchestrator({
    required List<DiagnosticCheck> checks,
    LogManager? log,
  })  : _checks = checks,
        _log = log ?? LogManager.instance;

  List<DiagnosticCheck> get checks => List.unmodifiable(_checks);

  /// 启动快速检查：并行执行所有check的quickCheck
  Future<List<DiagnosticResult>> runQuickCheck() async {
    _log.write('Diag', 'Starting quick check (${_checks.length} checks)');
    final results = await Future.wait(
      _checks.map((c) async {
        try {
          return await c.quickCheck().timeout(
            const Duration(seconds: 5),
            onTimeout: () => DiagnosticResult(
              checkId: c.checkId,
              title: c.title,
              status: DiagnosticStatus.warning,
              issues: [
                DiagnosticIssue(
                  message: '快速检查超时',
                  severity: IssueSeverity.warning,
                ),
              ],
            ),
          );
        } catch (e) {
          _log.write('Diag', 'Quick check failed: ${c.checkId} - $e');
          return DiagnosticResult(
            checkId: c.checkId,
            title: c.title,
            status: DiagnosticStatus.warning,
            issues: [
              DiagnosticIssue(
                message: '检查失败: $e',
                severity: IssueSeverity.warning,
              ),
            ],
          );
        }
      }),
    );
    _log.write('Diag', 'Quick check done: ${results.where((r) => r.status != DiagnosticStatus.ok).length} issues');
    return results;
  }

  /// 深度扫描：串行执行，通过Stream逐个产出结果
  Stream<DiagnosticResult> runFullScan() async* {
    _log.write('Diag', 'Starting full scan (${_checks.length} checks)');
    for (final check in _checks) {
      try {
        _log.write('Diag', 'Running full scan: ${check.checkId}');
        final result = await check.fullScan().timeout(
          const Duration(seconds: 30),
          onTimeout: () => DiagnosticResult(
            checkId: check.checkId,
            title: check.title,
            status: DiagnosticStatus.warning,
            issues: [
              DiagnosticIssue(
                message: '深度扫描超时',
                severity: IssueSeverity.warning,
              ),
            ],
          ),
        );
        yield result;
      } catch (e) {
        _log.write('Diag', 'Full scan failed: ${check.checkId} - $e');
        yield DiagnosticResult(
          checkId: check.checkId,
          title: check.title,
          status: DiagnosticStatus.warning,
          issues: [
            DiagnosticIssue(
              message: '扫描失败: $e',
              severity: IssueSeverity.warning,
            ),
          ],
        );
      }
    }
    _log.write('Diag', 'Full scan complete');
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/diagnostic_orchestrator.dart
git commit -m "feat(diagnostics): add DiagnosticOrchestrator with parallel quick check and streamed full scan"
```

---

### Task 3: JDK Check

**Files:**
- Create: `lib/core/diagnostics/checks/jdk_check.dart`

依赖: `EnvPathManager`, `PowerShellRunner` (用于运行`java -version`)

- [ ] **Step 1: 实现JDK检查**

```dart
// lib/core/diagnostics/checks/jdk_check.dart

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

  JdkCheck({EnvPathManager? envManager})
      : _envManager = envManager ?? EnvPathManager();

  @override
  Future<DiagnosticResult> quickCheck() async {
    final issues = <DiagnosticIssue>[];

    // 读取JAVA_HOME
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome == null || javaHome.isEmpty) {
      issues.add(DiagnosticIssue(
        message: 'JAVA_HOME 环境变量未设置',
        severity: IssueSeverity.error,
      ));
    } else if (!Directory(javaHome).existsSync()) {
      issues.add(DiagnosticIssue(
        message: 'JAVA_HOME 指向不存在的路径: $javaHome',
        severity: IssueSeverity.error,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];

    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome == null || javaHome.isEmpty) {
      issues.add(DiagnosticIssue(
        message: 'JAVA_HOME 环境变量未设置',
        severity: IssueSeverity.error,
        fix: FixAction(
          label: '在环境配置中设置',
          risk: FixRisk.risky,
          execute: () async {
            // 由UI层处理跳转到环境配置Tab
          },
        ),
      ));
      return DiagnosticResult.withIssues(
        checkId: checkId,
        title: title,
        issues: issues,
        relatedTabId: relatedTabId,
      );
    }

    if (!Directory(javaHome).existsSync()) {
      // 尝试检测已安装的JDK路径
      final detectedJdk = _detectJdkPath();
      issues.add(DiagnosticIssue(
        message: 'JAVA_HOME 指向不存在的路径: $javaHome',
        severity: IssueSeverity.error,
        fix: detectedJdk != null
            ? FixAction(
                label: '修正为 $detectedJdk',
                risk: FixRisk.risky,
                execute: () async {
                  await _envManager.writeVariable(
                    variable: 'JAVA_HOME',
                    value: detectedJdk,
                  );
                },
              )
            : FixAction(
                label: '前往环境配置设置',
                risk: FixRisk.safe,
                execute: () async {
                  // UI层通过onNavigateTab跳转到env_config Tab
                },
              ),
      ));
      return DiagnosticResult.withIssues(
        checkId: checkId,
        title: title,
        issues: issues,
        relatedTabId: relatedTabId,
      );
    }

    // 检查JDK版本
    try {
      final result = await Process.run('java', ['-version']);
      final output = (result.stderr as String).isNotEmpty
          ? result.stderr as String
          : result.stdout as String;
      final versionMatch = RegExp(r'"(\d+)\.(\d+)').firstMatch(output);
      if (versionMatch != null) {
        final major = int.tryParse(versionMatch.group(1) ?? '') ?? 0;
        if (major < 17) {
          issues.add(DiagnosticIssue(
            message: 'JDK 版本过低: 需要 17+，当前 ${versionMatch.group(0)}"',
            severity: IssueSeverity.error,
          ));
        }
      }
    } catch (_) {
      issues.add(DiagnosticIssue(
        message: '无法执行 java -version',
        severity: IssueSeverity.warning,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }

  /// 尝试从常见路径检测已安装的JDK
  String? _detectJdkPath() {
    final candidates = [
      r'C:\Program Files\Java',
      r'C:\Program Files\Eclipse Adoptium',
      r'C:\Program Files\Microsoft\jdk-17',
      r'C:\Program Files\Amazon Corretto',
    ];
    for (final dir in candidates) {
      final directory = Directory(dir);
      if (directory.existsSync()) {
        final subdirs = directory.listSync().whereType<Directory>().toList()
          ..sort((a, b) => b.path.compareTo(a.path));
        for (final sub in subdirs) {
          if (File('${sub.path}/bin/java.exe').existsSync()) {
            return sub.path;
          }
        }
      }
    }
    return null;
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/checks/jdk_check.dart
git commit -m "feat(diagnostics): add JDK check with JAVA_HOME validation and version detection"
```

---

### Task 4: SDK Check

**Files:**
- Create: `lib/core/diagnostics/checks/sdk_check.dart`

依赖: `SdkSetupManager`

- [ ] **Step 1: 实现SDK检查**

```dart
// lib/core/diagnostics/checks/sdk_check.dart

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

    final androidHome = Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'];

    if (androidHome == null || androidHome.isEmpty) {
      issues.add(DiagnosticIssue(
        message: 'ANDROID_HOME / ANDROID_SDK_ROOT 未设置',
        severity: IssueSeverity.error,
      ));
    } else if (!Directory(androidHome).existsSync()) {
      issues.add(DiagnosticIssue(
        message: 'SDK 路径不存在: $androidHome',
        severity: IssueSeverity.error,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];

    // 检测SDK目录
    final sdkDir = SdkSetupManager.detectSdkDir();
    if (!Directory(sdkDir).existsSync()) {
      issues.add(DiagnosticIssue(
        message: 'SDK 目录不存在: $sdkDir',
        severity: IssueSeverity.error,
      ));
      return DiagnosticResult.withIssues(
        checkId: checkId,
        title: title,
        issues: issues,
        relatedTabId: relatedTabId,
      );
    }

    // 检查关键子目录
    final requiredDirs = ['platforms', 'build-tools', 'platform-tools'];
    for (final dir in requiredDirs) {
      final path = '$sdkDir/$dir';
      if (!Directory(path).existsSync()) {
        issues.add(DiagnosticIssue(
          message: 'SDK 缺少 $dir/ 目录',
          severity: IssueSeverity.error,
        ));
      } else {
        // 检查是否为空目录
        final contents = Directory(path).listSync();
        if (contents.isEmpty) {
          issues.add(DiagnosticIssue(
            message: 'SDK $dir/ 目录为空',
            severity: IssueSeverity.warning,
          ));
        }
      }
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/checks/sdk_check.dart
git commit -m "feat(diagnostics): add SDK check with directory structure validation"
```

---

### Task 5: ADB/PATH Check

**Files:**
- Create: `lib/core/diagnostics/checks/adb_path_check.dart`

依赖: `EnvPathManager`

- [ ] **Step 1: 实现ADB/PATH检查**

```dart
// lib/core/diagnostics/checks/adb_path_check.dart

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

  AdbPathCheck({EnvPathManager? envManager})
      : _envManager = envManager ?? EnvPathManager();

  @override
  Future<DiagnosticResult> quickCheck() async {
    final path = Platform.environment['PATH'] ?? '';
    final hasPlatformTools = path.split(';').any(
          (p) => p.toLowerCase().contains('platform-tools'),
        );

    if (hasPlatformTools) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }

    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: [
        DiagnosticIssue(
          message: 'platform-tools 不在系统 PATH 中',
          severity: IssueSeverity.warning,
        ),
      ],
      relatedTabId: relatedTabId,
    );
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];

    // 检查PATH
    final path = Platform.environment['PATH'] ?? '';
    final hasPlatformTools = path.split(';').any(
          (p) => p.toLowerCase().contains('platform-tools'),
        );

    if (!hasPlatformTools) {
      // 尝试检测platform-tools路径
      final sdkDir = SdkSetupManager.detectSdkDir();
      final platformToolsPath = '$sdkDir/platform-tools';

      issues.add(DiagnosticIssue(
        message: 'platform-tools 不在系统 PATH 中',
        severity: IssueSeverity.warning,
        fix: Directory(platformToolsPath).existsSync()
            ? FixAction(
                label: '添加到 PATH',
                risk: FixRisk.safe,
                execute: () async {
                  await _envManager.appendToPath(path: platformToolsPath);
                },
              )
            : null,
      ));
    }

    // 检查adb是否可执行
    try {
      final result = await Process.run('adb', ['version']);
      if (result.exitCode != 0) {
        issues.add(DiagnosticIssue(
          message: 'adb 执行失败',
          severity: IssueSeverity.warning,
        ));
      }
    } catch (_) {
      if (!hasPlatformTools) {
        // 已经报过PATH问题，不重复报
      } else {
        issues.add(DiagnosticIssue(
          message: 'adb 不在 PATH 中或无法执行',
          severity: IssueSeverity.warning,
        ));
      }
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/checks/adb_path_check.dart
git commit -m "feat(diagnostics): add ADB/PATH check with auto-fix for missing PATH entry"
```

---

### Task 6: Gradle Check

**Files:**
- Create: `lib/core/diagnostics/checks/gradle_check.dart`

- [ ] **Step 1: 实现Gradle检查**

```dart
// lib/core/diagnostics/checks/gradle_check.dart

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
      issues.add(DiagnosticIssue(
        message: 'Gradle 目录不存在: $gradleHome',
        severity: IssueSeverity.info,
      ));
    }

    final initGradle = File('$gradleHome/init.gradle');
    if (!initGradle.existsSync()) {
      issues.add(DiagnosticIssue(
        message: 'init.gradle 未配置（镜像源未生效）',
        severity: IssueSeverity.info,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final gradleHome = _getGradleHome();
    final issues = <DiagnosticIssue>[];

    if (!Directory(gradleHome).existsSync()) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }

    // 扫描缓存大小
    final cachesDir = Directory('$gradleHome/caches');
    if (cachesDir.existsSync()) {
      int totalSize = 0;
      try {
        await for (final entity in cachesDir.list(recursive: true)) {
          if (entity is File) {
            totalSize += await entity.length();
          }
        }
      } catch (_) {}

      final sizeGB = totalSize / (1024 * 1024 * 1024);
      if (sizeGB > 5) {
        issues.add(DiagnosticIssue(
          message:
              'Gradle 缓存占用 ${sizeGB.toStringAsFixed(1)}GB (${cachesDir.path})',
          severity: IssueSeverity.warning,
          fix: FixAction(
            label: '清理缓存（需确认）',
            risk: FixRisk.risky,
            execute: () async {
              await cachesDir.delete(recursive: true);
            },
          ),
        ));
      }
    }

    // 检查init.gradle
    final initGradle = File('$gradleHome/init.gradle');
    if (!initGradle.existsSync()) {
      issues.add(DiagnosticIssue(
        message: 'init.gradle 未配置（镜像源未生效）',
        severity: IssueSeverity.info,
        // 修复操作由NetworkCheck负责，此处不提供fix
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(
        checkId: checkId,
        title: title,
        relatedTabId: relatedTabId,
      );
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }

  String _getGradleHome() {
    final envHome = Platform.environment['GRADLE_USER_HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    return '$userProfile/.gradle';
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/checks/gradle_check.dart
git commit -m "feat(diagnostics): add Gradle check with cache size scan and init.gradle detection"
```

---

### Task 7: Runtime Check

**Files:**
- Create: `lib/core/diagnostics/checks/runtime_check.dart`

- [ ] **Step 1: 实现运行时检查**

```dart
// lib/core/diagnostics/checks/runtime_check.dart

import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';

class RuntimeCheck implements DiagnosticCheck {
  @override
  String get checkId => 'runtime';

  @override
  String get title => '运行时依赖';

  @override
  Future<DiagnosticResult> quickCheck() async {
    final issues = <DiagnosticIssue>[];

    // 检查VC++ Redistributable（通过注册表）
    final vcVersions = _readRegistryVcVersions();
    if (vcVersions.isEmpty) {
      issues.add(DiagnosticIssue(
        message: '未检测到 Visual C++ Redistributable',
        severity: IssueSeverity.warning,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(checkId: checkId, title: title);
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
    );
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];

    // 检查VC++ Redistributable
    final vcVersions = _readRegistryVcVersions();
    if (vcVersions.isEmpty) {
      issues.add(DiagnosticIssue(
        message: '未检测到 Visual C++ Redistributable，Android模拟器可能无法运行',
        severity: IssueSeverity.warning,
        fix: FixAction(
          label: '打开下载页面',
          risk: FixRisk.safe,
          execute: () async {
            await Process.run('cmd', [
              '/c',
              'start',
              '',
              'https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist',
            ]);
          },
        ),
      ));
    }

    // 检查.NET Framework
    final dotnetVersion = _readDotNetVersion();
    if (dotnetVersion == null) {
      issues.add(DiagnosticIssue(
        message: '未检测到 .NET Framework 4.6+',
        severity: IssueSeverity.info,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(checkId: checkId, title: title);
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
    );
  }

  /// 读取注册表中的VC++版本
  List<String> _readRegistryVcVersions() {
    try {
      final result = Process.runSync('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64',
        '/v',
        'Version',
      ]);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match = RegExp(r'Versity+\s+REG_SZ\s+(.+)').firstMatch(output);
        if (match != null) return [match.group(1)!.trim()];
      }
    } catch (_) {}

    // 备用：检查DLL文件
    final dllPaths = [
      r'C:\Windows\System32\vcruntime140.dll',
      r'C:\Windows\System32\msvcp140.dll',
    ];
    final found = <String>[];
    for (final p in dllPaths) {
      if (File(p).existsSync()) found.add(p);
    }
    return found.isNotEmpty ? found : [];
  }

  /// 读取.NET Framework版本
  String? _readDotNetVersion() {
    try {
      final result = Process.runSync('reg', [
        'query',
        r'HKLM\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full',
        '/v',
        'Release',
      ]);
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
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/checks/runtime_check.dart
git commit -m "feat(diagnostics): add runtime check for VC++ Redistributable and .NET Framework"
```

---

### Task 8: Network Check + 镜像源管理

**Files:**
- Create: `lib/core/diagnostics/checks/network_check.dart`
- Create: `lib/core/diagnostics/mirror_source.dart`

- [ ] **Step 1: 创建镜像源数据模型**

```dart
// lib/core/diagnostics/mirror_source.dart

class MirrorSource {
  final String name;
  final String host;
  final String mavenUrl;
  final String? googleUrl;

  const MirrorSource({
    required this.name,
    required this.host,
    required this.mavenUrl,
    this.googleUrl,
  });

  static const List<MirrorSource> builtIn = [
    MirrorSource(
      name: '阿里云',
      host: 'maven.aliyun.com',
      mavenUrl: 'https://maven.aliyun.com/repository/public',
      googleUrl: 'https://maven.aliyun.com/repository/google',
    ),
    MirrorSource(
      name: '腾讯云',
      host: 'mirrors.cloud.tencent.com',
      mavenUrl: 'https://mirrors.cloud.tencent.com/nexus/repository/maven-public',
    ),
    MirrorSource(
      name: '华为云',
      host: 'repo.huaweicloud.com',
      mavenUrl: 'https://repo.huaweicloud.com/repository/maven',
    ),
    MirrorSource(
      name: '中科大',
      host: 'mirrors.ustc.edu.cn',
      mavenUrl: 'https://mirrors.ustc.edu.cn/maven',
    ),
    MirrorSource(
      name: '清华',
      host: 'mirrors.tuna.tsinghua.edu.cn',
      mavenUrl: 'https://mirrors.tuna.tsinghua.edu.cn/maven',
    ),
  ];
}

class MirrorTestResult {
  final MirrorSource source;
  final bool reachable;
  final int? latencyMs;

  const MirrorTestResult({
    required this.source,
    required this.reachable,
    this.latencyMs,
  });
}
```

- [ ] **Step 2: 实现Network检查**

```dart
// lib/core/diagnostics/checks/network_check.dart

import 'dart:io';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/diagnostics/mirror_source.dart';

class NetworkCheck implements DiagnosticCheck {
  @override
  String get checkId => 'network';

  @override
  String get title => '网络环境';

  /// 测试所有镜像源的连通性和延迟
  Future<List<MirrorTestResult>> testMirrors() async {
    final results = <MirrorTestResult>[];
    for (final mirror in MirrorSource.builtIn) {
      final sw = Stopwatch()..start();
      try {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        final request = await client.getUrl(Uri.parse(mirror.mavenUrl));
        final response = await request.close().timeout(
              const Duration(seconds: 5),
            );
        sw.stop();
        response.drain();
        client.close();
        results.add(MirrorTestResult(
          source: mirror,
          reachable: response.statusCode == 200,
          latencyMs: sw.elapsedMilliseconds,
        ));
      } catch (_) {
        sw.stop();
        results.add(MirrorTestResult(
          source: mirror,
          reachable: false,
          latencyMs: null,
        ));
      }
    }
    return results;
  }

  /// 测试Google SDK服务器连通性
  Future<bool> testGoogleSdk() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(
        Uri.parse('https://dl.google.com/android/repository/repository2-3.xml'),
      );
      final response = await request.close().timeout(
            const Duration(seconds: 5),
          );
      response.drain();
      client.close();
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 读取当前Gradle中已配置的镜像源
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

  /// 写入镜像源到init.gradle
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
      // 替换已有的ASWH镜像块
      final pattern = RegExp(
        r'// ASWH Mirror Start.*?// ASWH Mirror End',
        dotAll: true,
      );
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
    // 网络检查不做快速扫描
    return DiagnosticResult.ok(checkId: checkId, title: title);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];

    // 测试Google SDK服务器
    final googleOk = await testGoogleSdk();
    if (!googleOk) {
      issues.add(DiagnosticIssue(
        message: 'Google SDK 服务器不可达（可能需要代理或镜像）',
        severity: IssueSeverity.warning,
      ));
    }

    // 测试镜像源
    final mirrors = await testMirrors();
    final reachableCount = mirrors.where((m) => m.reachable).length;
    if (reachableCount == 0) {
      issues.add(DiagnosticIssue(
        message: '所有镜像源均不可达，请检查网络',
        severity: IssueSeverity.error,
      ));
    }

    // 检查当前Gradle镜像配置
    final currentMirror = readCurrentMirror();
    if (currentMirror == null && !googleOk) {
      issues.add(DiagnosticIssue(
        message: '未配置镜像源且Google服务器不可达，Gradle依赖将无法下载',
        severity: IssueSeverity.error,
      ));
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(checkId: checkId, title: title);
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
    );
  }

  String _getGradleHome() {
    final envHome = Platform.environment['GRADLE_USER_HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    return '$userProfile/.gradle';
  }
}
```

- [ ] **Step 3: 提交**

```bash
git add lib/core/diagnostics/mirror_source.dart lib/core/diagnostics/checks/network_check.dart
git commit -m "feat(diagnostics): add network check with mirror source testing and init.gradle write"
```

---

### Task 9: Cross Validation Check

**Files:**
- Create: `lib/core/diagnostics/checks/cross_validation_check.dart`

依赖: `AndroidStudioDetector`, `SdkSetupManager`

- [ ] **Step 1: 实现交叉验证检查**

```dart
// lib/core/diagnostics/checks/cross_validation_check.dart

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

  final AndroidStudioDetector _detector;

  CrossValidationCheck({AndroidStudioDetector? detector})
      : _detector = detector ?? AndroidStudioDetector();

  @override
  Future<DiagnosticResult> quickCheck() async {
    // 交叉验证不做快速扫描
    return DiagnosticResult.ok(checkId: checkId, title: title);
  }

  @override
  Future<DiagnosticResult> fullScan() async {
    final issues = <DiagnosticIssue>[];

    // 检查SDK路径与实际安装的一致性
    final androidHome = Platform.environment['ANDROID_HOME'] ??
        Platform.environment['ANDROID_SDK_ROOT'];
    final detectedSdkDir = SdkSetupManager.detectSdkDir();

    if (androidHome != null &&
        androidHome.isNotEmpty &&
        androidHome != detectedSdkDir) {
      issues.add(DiagnosticIssue(
        message: 'ANDROID_HOME ($androidHome) 与实际检测到的SDK路径 ($detectedSdkDir) 不一致',
        severity: IssueSeverity.warning,
      ));
    }

    // 检查SDK目录存在但缺少关键子目录
    if (Directory(detectedSdkDir).existsSync()) {
      if (!Directory('$detectedSdkDir/platforms').existsSync() ||
          Directory('$detectedSdkDir/platforms').listSync().isEmpty) {
        issues.add(DiagnosticIssue(
          message: 'SDK 目录存在但 platforms/ 为空，需要安装SDK平台',
          severity: IssueSeverity.error,
        ));
      }
    }

    // 检查多个AS版本冲突
    try {
      final result = await _detector.detectAll();
      if (result.installs.length > 1) {
        issues.add(DiagnosticIssue(
          message: '检测到 ${result.installs.length} 个Android Studio安装，可能存在版本冲突',
          severity: IssueSeverity.info,
        ));
      }
    } catch (_) {}

    // 检查JAVA_HOME指向的JDK版本
    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null && Directory(javaHome).existsSync()) {
      try {
        final result = await Process.run('$javaHome/bin/java', ['-version']);
        final output = (result.stderr as String).isNotEmpty
            ? result.stderr as String
            : result.stdout as String;
        final versionMatch = RegExp(r'"(\d+)').firstMatch(output);
        if (versionMatch != null) {
          final major = int.tryParse(versionMatch.group(1) ?? '') ?? 0;
          if (major < 17) {
            issues.add(DiagnosticIssue(
              message: 'JAVA_HOME 指向 JDK $major，Android Studio 需要 JDK 17+',
              severity: IssueSeverity.error,
            ));
          }
        }
      } catch (_) {}
    }

    if (issues.isEmpty) {
      return DiagnosticResult.ok(checkId: checkId, title: title);
    }
    return DiagnosticResult.withIssues(
      checkId: checkId,
      title: title,
      issues: issues,
    );
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/checks/cross_validation_check.dart
git commit -m "feat(diagnostics): add cross validation check for SDK/JDK/AS consistency"
```

---

### Task 10: 代理方案管理器

**Files:**
- Create: `lib/core/diagnostics/proxy_manager.dart`

- [ ] **Step 1: 实现ProxyManager**

```dart
// lib/core/diagnostics/proxy_manager.dart

import 'dart:convert';
import 'dart:io';

class ProxyScheme {
  final String name;
  final String? httpProxy;
  final String? httpsProxy;
  final String? noProxy;
  final Map<String, String> gradleProperties;

  const ProxyScheme({
    required this.name,
    this.httpProxy,
    this.httpsProxy,
    this.noProxy,
    this.gradleProperties = const {},
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'httpProxy': httpProxy,
        'httpsProxy': httpsProxy,
        'noProxy': noProxy,
        'gradleProperties': gradleProperties,
      };

  factory ProxyScheme.fromJson(Map<String, dynamic> json) => ProxyScheme(
        name: json['name'] as String,
        httpProxy: json['httpProxy'] as String?,
        httpsProxy: json['httpsProxy'] as String?,
        noProxy: json['noProxy'] as String?,
        gradleProperties: Map<String, String>.from(
          json['gradleProperties'] as Map? ?? {},
        ),
      );

  static const direct = ProxyScheme(name: '直连（无代理）');
}

class ProxyManager {
  final String _configPath;

  ProxyManager({String? configDir})
      : _configPath = '${configDir ?? _defaultConfigDir()}\\proxy_schemes.json';

  List<ProxyScheme> _schemes = [];
  String _activeSchemeName = '直连（无代理）';

  List<ProxyScheme> get schemes => List.unmodifiable(_schemes);
  String get activeSchemeName => _activeSchemeName;
  ProxyScheme get activeScheme =>
      _schemes.firstWhere((s) => s.name == _activeSchemeName,
          orElse: () => ProxyScheme.direct);

  Future<void> load() async {
    try {
      final file = File(_configPath);
      if (!file.existsSync()) {
        _schemes = [ProxyScheme.direct];
        return;
      }
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _schemes = (json['schemes'] as List)
          .map((e) => ProxyScheme.fromJson(e as Map<String, dynamic>))
          .toList();
      _activeSchemeName = json['active'] as String? ?? '直连（无代理）';

      // 确保直连方案始终存在
      if (!_schemes.any((s) => s.name == '直连（无代理）')) {
        _schemes.insert(0, ProxyScheme.direct);
      }
    } catch (_) {
      _schemes = [ProxyScheme.direct];
    }
  }

  Future<void> save() async {
    final dir = Directory(_configPath).parent;
    if (!dir.existsSync()) await dir.create(recursive: true);
    final json = {
      'schemes': _schemes.map((s) => s.toJson()).toList(),
      'active': _activeSchemeName,
    };
    File(_configPath).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(json),
    );
  }

  void addScheme(ProxyScheme scheme) {
    _schemes.removeWhere((s) => s.name == scheme.name);
    _schemes.add(scheme);
  }

  void removeScheme(String name) {
    if (name == '直连（无代理）') return;
    _schemes.removeWhere((s) => s.name == name);
    if (_activeSchemeName == name) _activeSchemeName = '直连（无代理）';
  }

  void setActive(String name) {
    if (_schemes.any((s) => s.name == name)) {
      _activeSchemeName = name;
    }
  }

  /// 将当前激活方案写入Gradle配置
  Future<void> applyToGradle() async {
    final scheme = activeScheme;
    final gradleHome = _getGradleHome();
    final propsFile = File('$gradleHome/gradle.properties');

    var lines = <String>[];
    if (propsFile.existsSync()) {
      lines = propsFile.readAsLinesSync();
    }

    // 移除旧的ASWH代理配置
    lines.removeWhere((l) =>
        l.startsWith('systemProp.http.') ||
        l.startsWith('systemProp.https.'));

    // 移除ASWH标记块
    final startIdx = lines.indexOf('# ASWH Proxy Start');
    final endIdx = lines.indexOf('# ASWH Proxy End');
    if (startIdx != -1 && endIdx != -1) {
      lines.removeRange(startIdx, endIdx + 1);
    }

    // 写入新配置
    if (scheme.httpProxy != null || scheme.httpsProxy != null) {
      lines.add('# ASWH Proxy Start');
      if (scheme.httpProxy != null) {
        lines.add('systemProp.http.proxyHost=${scheme.httpProxy!.split(':').first}');
        if (scheme.httpProxy!.contains(':')) {
          lines.add('systemProp.http.proxyPort=${scheme.httpProxy!.split(':').last}');
        }
      }
      if (scheme.httpsProxy != null) {
        lines.add('systemProp.https.proxyHost=${scheme.httpsProxy!.split(':').first}');
        if (scheme.httpsProxy!.contains(':')) {
          lines.add('systemProp.https.proxyPort=${scheme.httpsProxy!.split(':').last}');
        }
      }
      if (scheme.noProxy != null) {
        lines.add('systemProp.http.nonProxyHosts=${scheme.noProxy}');
      }
      for (final entry in scheme.gradleProperties.entries) {
        lines.add('${entry.key}=${entry.value}');
      }
      lines.add('# ASWH Proxy End');
    }

    await Directory(gradleHome).create(recursive: true);
    await propsFile.writeAsString(lines.join('\n'));
  }

  String _getGradleHome() {
    final envHome = Platform.environment['GRADLE_USER_HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    return '$userProfile/.gradle';
  }

  static String _defaultConfigDir() {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    return '$localAppData\\AndroidStudioWinHelper';
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/diagnostics/proxy_manager.dart
git commit -m "feat(diagnostics): add ProxyManager with scheme CRUD and Gradle integration"
```

---

### Task 11: Diagnostics Tab UI

**Files:**
- Create: `lib/pages/diagnostics_tab.dart`

依赖: Task 1-10全部完成

- [ ] **Step 1: 实现诊断Tab主界面**

```dart
// lib/pages/diagnostics_tab.dart

import 'package:flutter/material.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_orchestrator.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/jdk_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/sdk_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/adb_path_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/gradle_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/runtime_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/network_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/cross_validation_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/mirror_source.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class DiagnosticsTab extends StatefulWidget {
  final void Function(int tabIndex)? onNavigateTab;

  const DiagnosticsTab({super.key, this.onNavigateTab});

  @override
  State<DiagnosticsTab> createState() => _DiagnosticsTabState();
}

class _DiagnosticsTabState extends State<DiagnosticsTab> {
  late final DiagnosticOrchestrator _orchestrator;
  late final NetworkCheck _networkCheck;
  List<DiagnosticResult> _quickResults = [];
  List<DiagnosticResult> _fullResults = [];
  bool _quickLoading = true;
  bool _fullLoading = false;
  bool _fullScanDone = false;

  @override
  void initState() {
    super.initState();
    _networkCheck = NetworkCheck();
    _orchestrator = DiagnosticOrchestrator(checks: [
      JdkCheck(),
      SdkCheck(),
      AdbPathCheck(),
      GradleCheck(),
      RuntimeCheck(),
      _networkCheck,
      CrossValidationCheck(),
    ]);
    _runQuickCheck();
  }

  Future<void> _runQuickCheck() async {
    setState(() => _quickLoading = true);
    final results = await _orchestrator.runQuickCheck();
    setState(() {
      _quickResults = results;
      _quickLoading = false;
    });
  }

  Future<void> _runFullScan() async {
    setState(() {
      _fullLoading = true;
      _fullResults = [];
      _fullScanDone = false;
    });
    await for (final result in _orchestrator.runFullScan()) {
      setState(() {
        _fullResults.add(result);
      });
    }
    setState(() {
      _fullLoading = false;
      _fullScanDone = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final allResults = _fullScanDone ? _fullResults : _quickResults;
    final errors = allResults
        .where((r) => r.status == DiagnosticStatus.error)
        .toList();
    final warnings = allResults
        .where((r) => r.status == DiagnosticStatus.warning)
        .toList();
    final ok = allResults
        .where((r) => r.status == DiagnosticStatus.ok)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          // 标题栏
          Row(
            children: [
              const Icon(Icons.health_and_safety, size: 28),
              const SizedBox(width: 12),
              Text('系统健康度', style: Theme.of(context).textTheme.headlineSmall),
              const Spacer(),
              if (_quickLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (!_quickLoading && !_fullLoading)
                ActionButton(
                  label: '开始深度扫描',
                  icon: Icons.search,
                  loading: false,
                  onPressed: _runFullScan,
                ),
              if (_fullLoading)
                const ActionButton(
                  label: '扫描中...',
                  icon: Icons.hourglass_top,
                  loading: true,
                  onPressed: null,
                ),
            ],
          ),
          const SizedBox(height: 16),

          // 错误区域
          if (errors.isNotEmpty) ...[
            _buildSectionHeader('错误', errors.length, Colors.red),
            ...errors.map((r) => _buildResultCard(r)),
            const SizedBox(height: 12),
          ],

          // 警告区域
          if (warnings.isNotEmpty) ...[
            _buildSectionHeader('警告', warnings.length, Colors.orange),
            ...warnings.map((r) => _buildResultCard(r)),
            const SizedBox(height: 12),
          ],

          // 通过区域（默认折叠）
          if (ok.isNotEmpty)
            _buildOkSection(ok),

          // 网络诊断区块（深度扫描后显示）
          if (_fullScanDone) ...[
            const SizedBox(height: 16),
            _buildNetworkSection(),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String label, int count, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text('$label ($count)',
              style: TextStyle(fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }

  Widget _buildResultCard(DiagnosticResult result) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.title,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...result.issues.map((issue) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        issue.severity == IssueSeverity.error
                            ? Icons.error
                            : issue.severity == IssueSeverity.warning
                                ? Icons.warning
                                : Icons.info,
                        size: 18,
                        color: issue.severity == IssueSeverity.error
                            ? Colors.red
                            : issue.severity == IssueSeverity.warning
                                ? Colors.orange
                                : Colors.blue,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(issue.message),
                            if (issue.fix != null) ...[
                              const SizedBox(height: 4),
                              _buildFixButton(issue),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                )),
            if (result.relatedTabId != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      widget.onNavigateTab?.call(_tabIdToIndex(result.relatedTabId!)),
                  child: const Text('查看详情 →'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFixButton(DiagnosticIssue issue) {
    final fix = issue.fix!;
    if (fix.risk == FixRisk.safe) {
      return OutlinedButton.icon(
        icon: const Icon(Icons.build, size: 16),
        label: Text(fix.label),
        onPressed: () async {
          await fix.execute();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('修复完成')),
            );
            _runQuickCheck();
          }
        },
      );
    }
    return OutlinedButton.icon(
      icon: const Icon(Icons.build, size: 16),
      label: Text(fix.label),
      style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
      onPressed: () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('确认修复'),
            content: Text('确定要执行: ${fix.label}？\n此操作可能需要管理员权限。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('确定')),
            ],
          ),
        );
        if (confirmed == true) {
          await fix.execute();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('修复完成')),
            );
            _runQuickCheck();
          }
        }
      },
    );
  }

  Widget _buildOkSection(List<DiagnosticResult> ok) {
    return ExpansionTile(
      title: Text('通过 (${ok.length})',
          style: const TextStyle(color: Colors.green)),
      initiallyExpanded: false,
      children: ok
          .map((r) => ListTile(
                leading: const Icon(Icons.check_circle, color: Colors.green),
                title: Text(r.title),
                dense: true,
              ))
          .toList(),
    );
  }

  Widget _buildNetworkSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('网络环境',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            // 镜像源测速结果
            FutureBuilder<List<MirrorTestResult>>(
              future: _networkCheck.testMirrors(),
              builder: (ctx, snap) {
                if (!snap.hasData) return const CircularProgressIndicator();
                return Wrap(
                  spacing: 8,
                  children: snap.data!.map((r) {
                    return Chip(
                      avatar: Icon(
                        r.reachable ? Icons.check : Icons.close,
                        size: 16,
                        color: r.reachable ? Colors.green : Colors.red,
                      ),
                      label: Text(
                        '${r.source.name}${r.reachable ? ' ${r.latencyMs}ms' : ''}',
                      ),
                    );
                  }).toList(),
                );
              },
            ),
            const SizedBox(height: 12),
            // 当前镜像配置
            Text('当前Gradle配置: ${_networkCheck.readCurrentMirror() ?? '未配置'}'),
            const SizedBox(height: 8),
            // 应用镜像按钮
            ActionButton(
              label: '应用镜像到Gradle',
              icon: Icons.save,
              loading: false,
              onPressed: () async {
                // 弹出选择对话框
                final mirrors = MirrorSource.builtIn;
                final selected = await showDialog<MirrorSource>(
                  context: context,
                  builder: (ctx) => SimpleDialog(
                    title: const Text('选择镜像源'),
                    children: mirrors
                        .map((m) => SimpleDialogOption(
                              onPressed: () => Navigator.pop(ctx, m),
                              child: Text(m.name),
                            ))
                        .toList(),
                  ),
                );
                if (selected != null) {
                  await _networkCheck.applyMirror(selected);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已应用 ${selected.name} 镜像')),
                    );
                    setState(() {});
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  int _tabIdToIndex(String tabId) {
    switch (tabId) {
      case 'storage':
        return 1;
      case 'download':
        return 2;
      case 'env_config':
        return 3;
      case 'hyperv':
        return 4;
      case 'sdk_setup':
        return 5;
      case 'diagnostics':
        return 6;
      default:
        return 0;
    }
  }
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/pages/diagnostics_tab.dart
git commit -m "feat(diagnostics): add DiagnosticsTab UI with quick/full scan and mirror selector"
```

---

### Task 12: DetectPage集成（第7个Tab + 启动快速检查 + 横幅）

**Files:**
- Modify: `lib/pages/detect_page.dart`

- [ ] **Step 1: 添加diagnostics到_PageTab枚举**

在 `enum _PageTab` 中添加 `diagnostics` 值。

- [ ] **Step 2: 添加侧边栏Tab入口**

在sidebar Column中，第6个 `_TabTile` 之后添加：
```dart
_TabTile(
  icon: Icons.health_and_safety,
  title: '诊断修复',
  subtitle: '系统健康检查与自动修复',
  selected: _activeTab == _PageTab.diagnostics,
  onTap: () => setState(() => _activeTab = _PageTab.diagnostics),
),
```

- [ ] **Step 3: 添加switch case**

在 `switch (_activeTab)` 表达式中添加：
```dart
_PageTab.diagnostics => DiagnosticsTab(
    onNavigateTab: (index) {
      final tabs = _PageTab.values;
      if (index >= 0 && index < tabs.length) {
        setState(() => _activeTab = tabs[index]);
      }
    },
  ),
```

- [ ] **Step 4: 添加启动快速检查和横幅逻辑**

在 `_DetectPageState.initState()` 中：
```dart
DiagnosticOrchestrator? _orchestrator;
List<DiagnosticResult> _quickResults = [];
bool _bannerDismissed = false;

@override
void initState() {
  super.initState();
  _runStartupCheck();
}

Future<void> _runStartupCheck() async {
  _orchestrator = DiagnosticOrchestrator(checks: [
    JdkCheck(), SdkCheck(), AdbPathCheck(), GradleCheck(), RuntimeCheck(),
  ]);
  final results = await _orchestrator!.runQuickCheck();
  final issues = results.where((r) => r.status != DiagnosticStatus.ok).toList();
  if (issues.isNotEmpty && mounted) {
    setState(() => _quickResults = results);
  }
}
```

在build方法的Column顶部，sidebar之前添加横幅：
```dart
if (_quickResults.any((r) => r.status != DiagnosticStatus.ok) && !_bannerDismissed)
  MaterialBanner(
    content: Text('发现 ${_quickResults.where((r) => r.status != DiagnosticStatus.ok).length} 个问题需要关注'),
    leading: const Icon(Icons.warning, color: Colors.orange),
    actions: [
      TextButton(
        onPressed: () => setState(() => _activeTab = _PageTab.diagnostics),
        child: const Text('查看详情'),
      ),
      TextButton(
        onPressed: () => setState(() => _bannerDismissed = true),
        child: const Text('不再提示'),
      ),
    ],
  ),
```

- [ ] **Step 5: 添加import**

```dart
import 'package:androidstudiowinhelper/pages/diagnostics_tab.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_orchestrator.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/jdk_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/sdk_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/adb_path_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/gradle_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/runtime_check.dart';
```

- [ ] **Step 6: 提交**

```bash
git add lib/pages/detect_page.dart
git commit -m "feat(diagnostics): integrate diagnostics tab with startup quick check and banner"
```

---

### Task 13: ScanCache扩展（诊断结果缓存）

**Files:**
- Modify: `lib/core/scan_cache.dart`

- [ ] **Step 1: 添加诊断结果缓存方法**

在 `ScanCache` 类中添加：
```dart
static Future<List<DiagnosticResult>?> loadDiagnostics() async {
  try {
    final file = File('${_cacheDir()}\\diag_cache.json');
    if (!file.existsSync()) return null;
    final json = jsonDecode(file.readAsStringSync()) as List;
    // 简单缓存，只存状态和消息，不存修复函数
    return null; // 诊断结果含Function无法序列化，仅缓存状态
  } catch (_) {
    return null;
  }
}

static Future<void> saveDiagnosticsStatus(Map<String, DiagnosticStatus> statuses) async {
  try {
    await Directory(_cacheDir()).create(recursive: true);
    final file = File('${_cacheDir()}\\diag_cache.json');
    final json = statuses.map((k, v) => MapEntry(k, v.name));
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(json),
    );
  } catch (_) {}
}

static String _cacheDir() {
  final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
  return '$localAppData\\AndroidStudioWinHelper';
}
```

- [ ] **Step 2: 提交**

```bash
git add lib/core/scan_cache.dart
git commit -m "feat(diagnostics): add diagnostic status cache to ScanCache"
```

---

### Task 14: 编译验证

- [ ] **Step 1: 运行Flutter分析**

```bash
flutter analyze
```

Expected: No errors (warnings acceptable).

- [ ] **Step 2: 运行Flutter构建**

```bash
flutter build windows --debug
```

Expected: Build succeeds.

- [ ] **Step 3: 运行应用验证**

```bash
flutter run -d windows
```

验证：
1. 启动后顶部横幅显示（如有问题）
2. 侧边栏出现"诊断修复"Tab
3. 点击Tab显示快速检查结果
4. 点击"开始深度扫描"执行全量扫描
5. 网络区块显示镜像源测速
6. 修复按钮可点击

- [ ] **Step 4: 提交最终修复（如有）**

```bash
git add -A
git commit -m "fix(diagnostics): address compilation issues found during verification"
```
