# 综合诊断修复系统设计

> 日期: 2026-06-07
> 状态: 待实现
> 作者: Keiraee + Claude

## 概述

为ASWH新增"诊断修复"功能，聚合现有模块状态信息，提供统一的健康仪表盘。支持启动时快速检查（<2秒，纯本地I/O）和用户手动触发的深度扫描（含网络测试、文件扫描）。安全修复自动执行，风险修复需用户确认。

## 架构

### 核心抽象

```dart
enum DiagnosticStatus { ok, warning, error }
enum IssueSeverity { info, warning, error }
enum FixRisk { safe, risky }

class DiagnosticIssue {
  final String message;
  final IssueSeverity severity;
  final FixAction? fix;
}

class FixAction {
  final String label;            // 按钮文字，如"修正JAVA_HOME"
  final FixRisk risk;
  final Future<void> Function() execute;
}

class DiagnosticResult {
  final String checkId;          // "jdk", "sdk", "gradle", "network", ...
  final String title;            // "JDK 环境", "Android SDK", ...
  final DiagnosticStatus status; // 聚合该check下所有issue的最严重级别
  final List<DiagnosticIssue> issues;
  final String? relatedTabId;    // "env_config", "sdk_setup", "storage", ...
}
```

### Orchestrator

```dart
class DiagnosticOrchestrator {
  final List<DiagnosticCheck> _checks;

  /// 启动快速检查：只做本地I/O（环境变量、注册表、文件存在性）
  Future<List<DiagnosticResult>> runQuickCheck();

  /// 深度扫描：含网络请求、目录递归扫描、组件完整性校验
  Stream<DiagnosticResult> runFullScan(); // 逐个check产出，UI实时更新

  /// 执行单个修复
  Future<void> executeFix(DiagnosticResult result, DiagnosticIssue issue);
}
```

`runQuickCheck()` 并行执行所有check的quickMode；`runFullScan()` 串行执行fullMode（避免并发PowerShell冲突），通过Stream让UI逐卡片刷新。

### DiagnosticCheck 接口

```dart
abstract class DiagnosticCheck {
  String get checkId;
  String get title;
  String? get relatedTabId;

  /// 快速检查：纯本地I/O，<2秒
  Future<DiagnosticResult> quickCheck();

  /// 深度扫描：可能含网络请求、文件扫描
  Future<DiagnosticResult> fullScan();
}
```

## 诊断检查项

### 1. JDK Check (`jdk_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | 读JAVA_HOME环境变量，读注册表Java路径 | — |
| full | 校验路径目录是否存在，运行`java -version`验证版本≥17 | 设置/修正JAVA_HOME（risky） |

### 2. SDK Check (`sdk_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | 读ANDROID_HOME / ANDROID_SDK_ROOT | — |
| full | 验证目录结构（platforms/, build-tools/, platform-tools/），调SdkSetupManager检查组件 | 补全缺失组件（risky） |

### 3. ADB/PATH Check (`adb_path_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | 遍历PATH，检查是否包含platform-tools | — |
| full | 验证adb可执行，`adb version`一致性检查 | 添加到PATH（safe） |

### 4. Gradle Check (`gradle_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | 读GRADLE_USER_HOME（有值用它，无值回退~/.gradle），检查init.gradle是否存在 | — |
| full | 扫描缓存目录大小，检查wrapper版本，检测损坏的缓存文件 | 清理缓存（risky）、更新wrapper（safe） |

### 5. Runtime Check (`runtime_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | 注册表读VC++ Redistributable版本、.NET Framework版本 | — |
| full | 验证实际DLL文件是否存在 | 提示下载安装包（无自动修复，仅info） |

### 6. Network Check (`network_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | — | — |
| full | HEAD请求Google SDK服务器、各镜像源测速、读取Gradle代理配置、读取系统代理 | 写入镜像源到init.gradle（safe）、同步代理设置（safe）、切换代理方案（risky） |

**镜像源列表（内置）：**

| 名称 | 地址 |
|------|------|
| 阿里云 | maven.aliyun.com/repository/public |
| 腾讯云 | mirrors.cloud.tencent.com/nexus/repository/maven-public |
| 华为云 | repo.huaweicloud.com/repository/maven |
| 中科大 | mirrors.ustc.edu.cn/maven |
| 清华 | mirrors.tuna.tsinghua.edu.cn/maven |

**镜像源选择器UI：** 按钮组并排显示，每个按钮显示源名称+测速延迟，选中高亮，点击"应用到Gradle"写入init.gradle。

**init.gradle写入策略：**
- 读取GRADLE_USER_HOME确定实际路径
- 如init.gradle已存在，检查是否已有ASWH管理的镜像配置块（通过`# ASWH Mirror Start/End`标记识别）；有则替换该块，无则追加；其他内容不动
- 如不存在，生成标准模板

### 7. Cross Validation Check (`cross_validation_check.dart`)

| 模式 | 检查内容 | 修复 |
|------|---------|------|
| quick | — | — |
| full | SDK路径存在但缺platforms/；JAVA_HOME指向的JDK版本<17；多个AS版本共存冲突；ANDROID_HOME与实际安装路径不一致 | 逐项提示修复（risky） |

## 代理方案管理

### 数据模型

```dart
class ProxyScheme {
  final String name;        // "公司代理"、"家庭直连"、"校园网"
  final String? httpProxy;  // host:port
  final String? httpsProxy;
  final String? noProxy;    // 排除列表
  final Map<String, String> gradleProperties; // 自定义Gradle属性
}
```

### 存储

`%LOCALAPPDATA%\AndroidStudioWinHelper\proxy_schemes.json`

### 交互

- 代理方案列表，radio选择当前激活方案
- 支持新增/编辑/删除方案
- "应用选中方案"写入gradle.properties + 系统环境变量（risky，需确认）

## 分层修复策略

| 风险级别 | 处理方式 | 示例 |
|---------|---------|------|
| safe | 点击直接执行，按钮变loading，完成后变✓ | 添加ADB到PATH、写入镜像源到init.gradle、更新Gradle wrapper |
| risky | 弹确认对话框，说明操作内容和影响，用户确认后执行 | 清理Gradle缓存、修正JAVA_HOME、切换代理方案、删除旧版本残留 |

## UI设计

### 启动横幅

应用启动 → 后台执行快速检查 → 有error/warning时在首页顶部显示：

```
┌─────────────────────────────────────────────┐
│ ⚠ 发现 2 个问题需要关注        [查看详情]    │
└─────────────────────────────────────────────┘
```

点击"查看详情"跳转诊断Tab。全部通过时不显示横幅。用户可选择"不再提示"（持久化到`%LOCALAPPDATA%\AndroidStudioWinHelper\settings.json`的`hideDiagBanner`字段）。

### 诊断Tab布局

```
┌──────────────────────────────────────────────────────────┐
│  系统健康度                                    [开始深度扫描] │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  │
│                                                          │
│  ┌─ 错误 (2) ──────────────────────────────────────────┐ │
│  │  ● JAVA_HOME 指向不存在的路径                        │ │
│  │    → C:\Program Files\Java\jdk-17  (目录不存在)      │ │
│  │    [修正为已检测到的JDK路径]    [环境配置Tab →]        │ │
│  │                                                     │ │
│  │  ● Android SDK 路径无效                              │ │
│  │    → ANDROID_HOME 未设置                             │ │
│  │    [自动配置]    [SDK安装Tab →]                       │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ 警告 (1) ──────────────────────────────────────────┐ │
│  │  ▲ Gradle 缓存占用 8.2GB                            │ │
│  │    → ~/.gradle/caches/                             │ │
│  │    [清理缓存(需确认)]    [存储扫描Tab →]              │ │
│  └─────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌─ 通过 (5) ──────────────────────────────────────────┐ │
│  │  ✓ ADB 已在PATH中                                   │ │
│  │  ✓ Hyper-V 正常                                     │ │
│  │  ✓ VC++ 2019 Redistributable 已安装                 │ │
│  │  ✓ SDK platforms 组件完整                            │ │
│  │  ✓ 网络连通性正常                                    │ │
│  └─────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

- "通过"区域默认折叠
- 有fix的issue显示修复按钮
- `[Tab名称 →]` 链接通过DetectPage.switchToTab()跳转，映射关系：env_config→3, sdk_setup→5, storage→1, download→2, hyperv→4

### 网络诊断区块（在诊断Tab内展开）

```
┌─ 网络环境 ─────────────────────────────────────────────┐
│                                                        │
│  Google SDK服务器    ✗ 不可达 (超时 5s)                 │
│  阿里云镜像          ✓ 45ms                            │
│  腾讯云镜像          ✓ 62ms                            │
│  华为云镜像          ✓ 78ms                            │
│                                                        │
│  镜像源: [阿里云✓] [腾讯云✓] [华为云✓] [中科大✓] [清华✓]  │
│  当前Gradle配置: 阿里云 (maven.aliyun.com)              │
│                                                        │
│  代理方案:                                              │
│  ┌──────────────────────────────────────────┐          │
│  │ ○ 公司代理 (proxy.corp.com:8080)         │          │
│  │ ● 直连 (无代理)              [当前]      │          │
│  │ ○ 自定义方案...                          │          │
│  └──────────────────────────────────────────┘          │
│                                                        │
│  [应用选中方案]  [管理方案...]  [应用镜像到Gradle]       │
└────────────────────────────────────────────────────────┘
```

## 缓存策略

| 数据 | 存储位置 | 生命周期 |
|------|---------|---------|
| 快速检查结果 | 内存 | 每次启动重新扫描 |
| 深度扫描结果 | `%LOCALAPPDATA%\AndroidStudioWinHelper\diag_cache.json` | 持久化，用户手动刷新 |
| 代理方案 | `%LOCALAPPDATA%\AndroidStudioWinHelper\proxy_schemes.json` | 持久化 |

## 路径策略

所有路径从环境变量或现有Manager动态获取，不硬编码：

- Gradle路径 → 读`GRADLE_USER_HOME`，无值回退`~/.gradle`
- SDK路径 → 读`ANDROID_HOME`，无值由`SdkSetupManager`自动检测
- JDK路径 → 读`JAVA_HOME` + 注册表

环境配置Tab迁移路径后，诊断系统下次扫描自动跟随新路径。

## 文件结构

```
lib/core/diagnostics/
  ├── diagnostic_check.dart
  ├── diagnostic_result.dart
  ├── diagnostic_orchestrator.dart
  ├── proxy_manager.dart
  └── checks/
      ├── jdk_check.dart
      ├── sdk_check.dart
      ├── adb_path_check.dart
      ├── gradle_check.dart
      ├── runtime_check.dart
      ├── network_check.dart
      └── cross_validation_check.dart

lib/pages/
  └── diagnostics_tab.dart
```

## 现有模块改动

| 模块 | 改动 |
|------|------|
| `detect_page.dart` | 新增第7个Tab入口 + 启动时调用DiagnosticOrchestrator.runQuickCheck() |
| 其他现有模块 | 无改动，诊断check直接调用其公开方法 |

## 实现顺序

1. 数据模型 + DiagnosticCheck接口 + DiagnosticOrchestrator骨架
2. quickMode各check实现（JDK、SDK、ADB/PATH、Gradle、Runtime）
3. 诊断Tab UI + 启动横幅 + Tab跳转联动
4. fullMode各check实现（网络测速、镜像源、交叉验证）
5. 代理方案管理（ProxyManager + UI）
6. init.gradle镜像源写入
7. 缓存持久化 + 边界情况处理
