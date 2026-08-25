# Android Studio Win Helper (ASWH)

[![Flutter](https://img.shields.io/badge/Flutter-3.10+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows)](https://www.microsoft.com/windows)
[![Dart](https://img.shields.io/badge/Dart-3.10+-0175C2?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> Windows 端 Android Studio 一站式工具箱 — 安装检测、磁盘扫描、版本下载、环境配置、Hyper-V 管理、SDK 安装、系统诊断，一站搞定。

---

## 功能一览

| 模块 | 说明 | 亮点 |
|------|------|------|
| **安装检测** | 多源枚举所有已安装的 Android Studio | 6 种检测源，自动选出最佳候选 |
| **磁盘占用** | 递归扫描 SDK / Gradle / AVD / IDE 缓存 | 子目录展开，一键打开文件夹 |
| **版本下载** | 抓取官方版本源 + CDN 探测 | 多线程分片下载，智能重试，断点续传 |
| **环境配置** | 检测/修改 ANDROID_HOME、JAVA_HOME 等 | UAC 提权写入，一键回退 |
| **Hyper-V 管理** | 检测/启用/关闭 Hyper-V 和 WHPX | 重启提醒，状态实时刷新 |
| **SDK 一键安装** | 免装 Android Studio 直接装 SDK 包 | 镜像源切换，代理配置 |
| **环境诊断** | 7 项系统健康检查 + 自动修复 | 启动快速检查，深度扫描含网络测速 |

---

## 功能详情

### 1. 安装检测

多源枚举所有已安装的 Android Studio，自动选出最佳候选：

| 检测来源 | 说明 |
|----------|------|
| 运行中进程 | `studio64.exe` / `studio.exe` |
| 卸载注册表 | `InstallLocation` / `DisplayIcon` / `UninstallString` |
| App Paths 注册表 | Windows 应用路径别名 |
| 快捷方式 | 开始菜单 & 桌面 `.lnk` |
| JetBrains Toolbox | Toolbox 管理安装 |
| 候选路径 | 常见安装目录 |

每项安装展示路径、版本、构建号、检测来源标签。环境变量激活的安装显示 `ANDROID_HOME` 标签。所有信息支持一键复制。

### 2. 磁盘占用扫描

递归扫描 Android 开发相关目录，展示占用空间和子目录明细：

| 类别 | 扫描内容 |
|------|----------|
| SDK | `ANDROID_HOME` / `ANDROID_SDK_ROOT` |
| Gradle | `~/.gradle/caches` / wrapper |
| AVD | 模拟器镜像 |
| IDE 配置 | `AndroidStudio*` config/system 目录 |
| 缓存 | `AppData\Local\Temp\*` |

子目录支持快捷复制路径、一键打开文件夹。

### 3. 版本下载

从 `updates.xml`（Google 官方更新源）+ CDN 探测获取版本列表，按渠道分类：

| 渠道 | 说明 |
|------|------|
| Stable | 正式发布版 |
| Beta | 公测版 |
| Canary | 内测版 |
| Dev | 开发版 |

**下载引擎特性：**

- **多线程分片**：自适应 2/4/8/16 分片，基于带宽探测自动决策
- **智能重试**：超时→快速重试，5xx→退避重试，429→读 Retry-After，4xx→不重试
- **断点续传**：`.part.meta` JSON 文件记录每个分片状态，恢复时只重传失败分片
- **文件名匹配**：根据版本信息动态生成文件名（如 `android-studio-quail2-canary4-windows.exe`）
- **完整性校验**：下载完成后校验 MZ 头 + SHA256

### 4. 环境变量配置

扫描注册表中所有 Android 开发相关环境变量：

- **自动检测**：`ANDROID_HOME`、`ANDROID_SDK_ROOT`、`GRADLE_HOME`、`JAVA_HOME` 等，显示来源（Machine/User）、路径是否存在
- **PATH 管理**：检测 `platform-tools`、`build-tools`、`emulator` 等 SDK 子目录是否已加入系统 PATH，支持一键追加
- **写入系统变量**：以管理员权限（UAC）写入系统级环境变量，广播 `WM_SETTINGCHANGE` 立即生效
- **创建目录**：写入时可选自动创建目标目录
- **一键回退**：写入前自动备份当前配置，支持一键恢复

### 5. Hyper-V 管理

独立控制 Hyper-V 和 WHPX（Hypervisor Platform）：

- 检测 Windows 版本和各组件状态
- 独立启用/关闭 Hyper-V 和 WHPX
- 重启提醒（操作后需重启生效）
- 运行环境全面检测（CPU 虚拟化、GPU 驱动、磁盘类型等）

### 6. SDK 一键安装

免装 Android Studio，直接安装 Android SDK 核心组件：

- 查询已安装/可用包列表
- 快速安装核心包（ADB、模拟器、Build Tools、Platform 等）
- 镜像源切换（Flutter CDN、腾讯云、北外、Google 官方）
- 代理地址配置
- 包分类展示，勾选批量安装/卸载

### 7. 环境诊断

7 项系统健康检查，启动时快速检查（<2s），支持深度扫描：

| 检查项 | 快速检查 | 深度扫描 |
|--------|----------|----------|
| JDK 环境 | JAVA_HOME 是否设置 | 路径是否存在 + 版本检测 |
| Android SDK | ANDROID_HOME 是否设置 | 目录结构完整性 |
| ADB / PATH | platform-tools 在 PATH 中 | adb 是否可执行 |
| Gradle | 目录是否存在 | 缓存大小 + init.gradle |
| 运行时依赖 | VC++ Redistributable | .NET Framework |
| 网络环境 | — | 镜像源测速 + Google 连通性 |
| 交叉验证 | — | SDK 路径一致性 |

- 安全修复自动执行，风险修复需确认
- 诊断结果可跳转到对应功能 Tab
- AppBar 显示问题数量横幅

---

## 缓存

三层 JSON 缓存统一存放在 `%LOCALAPPDATA%\AndroidStudioWinHelper\`：

| 缓存文件 | 用途 |
|----------|------|
| `install_cache.json` | 安装检测结果 |
| `scan_cache.json` | 磁盘扫描结果 |
| `version_cache.json` | 版本下载数据 |
| `env_config_cache.json` | 环境配置回退备份 |
| `diag_cache.json` | 诊断状态缓存 |

启动即读缓存，点击「重新检测 / 重新扫描 / 重新获取」刷新。

---

## 快速开始

### GUI

```bash
flutter pub get
flutter run -d windows
```

### CLI

```bash
# 安装检测
dart run bin/aswh.dart detect-android-studio [--json] [--deep]

# 磁盘扫描
dart run bin/aswh.dart scan-data-dirs [--json]

# 环境配置（读取）
dart run bin/aswh.dart config-env-paths [--json]

# 环境配置（写入）
dart run bin/aswh.dart config-env-paths --write --name ANDROID_HOME --value "D:\SDK" --create-dir
```

### 打包安装

```bash
# 构建 Release
flutter build windows --release

# 用 Inno Setup 编译安装包
# 打开 installer.iss → Build → Compile
```

**要求**：Windows 10+，PowerShell 5.1+，Flutter SDK ≥ 3.10

---

## 项目结构

```text
bin/aswh.dart                              # CLI 入口
lib/
├── main.dart                              # Flutter 入口
├── cli/commands/                          # CLI 子命令
│   ├── detect_android_studio_command.dart
│   ├── scan_data_dirs_command.dart
│   └── config_env_paths_command.dart
├── core/
│   ├── android_studio_detector.dart       # 安装检测引擎
│   ├── data_dir_scanner.dart              # 磁盘扫描引擎
│   ├── studio_version_service.dart        # 版本抓取编排器
│   ├── download_manager.dart              # 下载管理器
│   ├── emulator_check_manager.dart        # 模拟器兼容性检测
│   ├── env_path_manager.dart              # 环境变量管理
│   ├── hyperv_manager.dart                # Hyper-V 管理
│   ├── sdk_setup_manager.dart             # SDK 包管理
│   ├── powershell_runner.dart             # PowerShell 进程管理（统一）
│   ├── file_utils.dart                    # SHA256 / PE 校验
│   ├── format_utils.dart                  # 格式化工具
│   ├── platform_utils.dart                # 系统版本检测
│   ├── log_manager.dart                   # 日志管理
│   ├── scan_cache.dart                    # JSON 缓存读写
│   ├── script_locator.dart                # 脚本路径解析
│   ├── download/                          # 分片下载引擎
│   │   ├── chunk_state.dart               # 分片状态模型
│   │   ├── chunked_downloader.dart        # 多线程分片下载器
│   │   ├── meta_store.dart                # .part.meta 读写
│   │   └── retry_engine.dart              # 智能重试引擎
│   ├── diagnostics/                       # 诊断系统
│   │   ├── diagnostic_check.dart          # 检查接口
│   │   ├── diagnostic_result.dart         # 结果模型
│   │   ├── diagnostic_orchestrator.dart   # 编排器
│   │   ├── mirror_source.dart             # 镜像源数据
│   │   ├── proxy_manager.dart             # 代理方案管理
│   │   └── checks/                        # 各检查模块
│   │       ├── jdk_check.dart
│   │       ├── sdk_check.dart
│   │       ├── adb_path_check.dart
│   │       ├── gradle_check.dart
│   │       ├── runtime_check.dart
│   │       ├── network_check.dart
│   │       └── cross_validation_check.dart
│   ├── version/                           # 版本数据源
│   │   ├── version_source.dart            # 数据源接口
│   │   ├── xml_version_source.dart        # XML 解析
│   │   ├── chocolatey_version_source.dart # Chocolatey API
│   │   ├── cdn_probe.dart                 # CDN 探测
│   │   └── url_guesser.dart               # URL 推测
│   └── models/                            # 数据模型
│       ├── android_studio_install.dart
│       ├── data_dir_entry.dart
│       ├── download_task.dart
│       ├── emulator_check_result.dart
│       ├── env_path_config.dart
│       ├── hyperv_result.dart
│       ├── scan_progress.dart
│       └── studio_version.dart
├── pages/
│   ├── detect_page.dart                   # 主界面（Tab 容器）
│   ├── shared_widgets.dart                # 共享 UI 组件
│   ├── install_tab.dart                   # 安装检测 Tab
│   ├── storage_tab.dart                   # 磁盘占用 Tab
│   ├── download_tab.dart                  # 版本下载 Tab
│   ├── download_progress_card.dart        # 下载进度卡片
│   ├── env_config_tab.dart                # 环境配置 Tab
│   ├── hyperv_tab.dart                    # Hyper-V Tab
│   ├── sdk_setup_tab.dart                 # SDK 安装 Tab
│   └── diagnostics_tab.dart               # 诊断 Tab
scripts/
├── detect-android-studio.ps1              # AS 检测脚本
├── detect-android-studio.cmd              # AS 检测（CMD 包装）
├── scan-data-dirs.ps1                     # 磁盘扫描脚本
├── config-env-paths.ps1                   # 环境变量读写脚本
├── detect-hyperv.ps1                      # Hyper-V 检测脚本
├── toggle-hyperv.ps1                      # Hyper-V 开关脚本
├── setup-sdk.ps1                          # SDK 包管理脚本
└── check-emulator.ps1                     # 模拟器兼容性检测脚本
```

---

## 架构概览

```
┌─────────────────────────────────────────────────┐
│                    GUI (Flutter)                 │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌───────┐ │
│  │Install  │ │Storage  │ │Download │ │ Diag  │ │
│  │  Tab    │ │  Tab    │ │  Tab    │ │  Tab  │ │
│  └────┬────┘ └────┬────┘ └────┬────┘ └───┬───┘ │
│       │           │           │           │     │
├───────┼───────────┼───────────┼───────────┼─────┤
│       ▼           ▼           ▼           ▼     │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌───────┐ │
│  │Detector │ │Scanner  │ │Download │ │ Orch  │ │
│  │         │ │         │ │Manager  │ │estratr│ │
│  └────┬────┘ └────┬────┘ └────┬────┘ └───┬───┘ │
│       │           │           │           │     │
│       ▼           ▼           ▼           ▼     │
│  ┌──────────────────────────────────────────┐   │
│  │         PowerShellRunner (统一)           │   │
│  │  普通执行 / 提权执行 / 行缓冲 / 进度解析   │   │
│  └──────────────────────────────────────────┘   │
│                     │                           │
│                     ▼                           │
│  ┌──────────────────────────────────────────┐   │
│  │            PowerShell 脚本               │   │
│  │  detect / scan / config / hyperv / sdk   │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
```

---

## GUI / CLI 功能对照

| 功能 | GUI | CLI |
|------|-----|-----|
| 安装检测 | 进度条 + 结果卡片 + 复制按钮 | `detect-android-studio --json` |
| 磁盘扫描 | 可展开目录树 + 子目录操作 | `scan-data-dirs --json` |
| 版本下载 | 渠道筛选 + 版本卡片 + 分片下载 | — |
| 环境配置 | 变量卡片 + 编辑 + 一键配置/回退 | `config-env-paths --json` |
| Hyper-V | 状态卡片 + 开关按钮 | — |
| SDK 安装 | 包列表 + 勾选安装 | — |
| 环境诊断 | 健康仪表盘 + 修复按钮 | — |

---

## 技术栈

- **框架**：Flutter 3.10+ (Windows Desktop)
- **语言**：Dart 3.10+
- **UI**：Material 3
- **脚本**：PowerShell 5.1+
- **打包**：Inno Setup 7.x
- **HTTP**：`http` / `dart:io` HttpClient
- **存储**：JSON 文件缓存（`%LOCALAPPDATA%`）

---

## License

MIT
