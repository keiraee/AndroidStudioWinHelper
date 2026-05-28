# Android Studio Win Helper

[![Flutter](https://img.shields.io/badge/Flutter-3.10+-02569B?logo=flutter)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Windows-0078D6?logo=windows)](https://www.microsoft.com/windows)
[![Dart](https://img.shields.io/badge/Dart-3.10+-0175C2?logo=dart)](https://dart.dev)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

> Windows 端 Android Studio 一站式工具箱。检测安装、扫描磁盘、下载版本、配置环境变量——一站搞定。

## Features

### 安装检测

多源枚举所有已安装的 Android Studio，自动选出最佳候选。

| 检测来源 | 说明 |
| --- | --- |
| 运行中进程 | `studio64.exe` / `studio.exe` |
| 卸载注册表 | `InstallLocation` / `DisplayIcon` / `UninstallString` |
| App Paths 注册表 | Windows 应用路径别名 |
| 快捷方式 | 开始菜单 & 桌面 `.lnk` |
| JetBrains Toolbox | Toolbox 管理安装 |
| 候选路径 | 常见安装目录 |

每项安装展示 **路径**、**版本**、**构建号**、**检测来源标签**，环境变量激活的安装显示 `ANDROID_HOME` / `ANDROID_SDK_ROOT` 标签。所有信息一行复制。

### 磁盘扫描

递归扫描 Android 开发相关目录，展示占用空间和子目录明细。

| 类别 | 扫描内容 |
| --- | --- |
| SDK | `ANDROID_HOME` / `ANDROID_SDK_ROOT` |
| Gradle | `~/.gradle/caches` / wrapper |
| AVD | 模拟器镜像 |
| IDE 配置 | `AndroidStudio*` config/system 目录 |
| 缓存 | `AppData\Local\Temp\*` |

子目录支持快捷复制路径、一键打开文件夹。

### 版本下载

抓取官方版本更新源 + 历史归档，按渠道分类，支持直接下载。

| 数据源 | 说明 |
| --- | --- |
| `updates.xml` | Google 官方更新源，含 Stable / Beta / Canary / Dev 四个渠道 |
| 下载页面 | 解析 `developer.android.google.cn/studio` 获取真实下载链接 |
| Chocolatey | NuGet OData API 补充 ~40 个历史版本 |

按渠道筛选，每张版本卡片展示代号、版本号、构建号、更新日志，支持暂停/续传下载。

### 环境配置 **NEW**

扫描注册表中所有 Android 开发相关环境变量，支持检测、修改、一键回退。

- **自动检测**：从注册表读取 `ANDROID_HOME`、`ANDROID_SDK_ROOT`、`GRADLE_HOME`、`JAVA_HOME`、`GRADLE_USER_HOME`、`ANDROID_SDK_HOME` 等变量，显示来源（Machine/User）、路径是否存在
- **PATH 管理**：检测 `platform-tools`、`build-tools`、`emulator` 等 SDK 子目录是否已加入系统 PATH，支持一键追加
- **写入系统变量**：以管理员权限（UAC）写入系统级环境变量，广播 `WM_SETTINGCHANGE` 立即生效
- **创建目录**：写入时可选自动创建目标目录
- **一键回退**：写入前自动备份当前配置，支持一键恢复

## Cache

三层 JSON 缓存统一存放在 `%LOCALAPPDATA%\AndroidStudioWinHelper\`：

| 缓存文件 | 用途 |
| --- | --- |
| `install_cache.json` | 安装检测结果 |
| `scan_cache.json` | 磁盘扫描结果 |
| `version_cache.json` | 版本下载数据 |
| `env_config_cache.json` | 环境配置回退备份（存放在运行目录） |

启动即读缓存，点击「重新检测 / 重新扫描 / 重新获取」刷新。

## Quick Start

```bash
# GUI
flutter pub get
flutter run -d windows

# CLI
dart run bin/aswh.dart detect-android-studio [--json] [--deep]
dart run bin/aswh.dart scan-data-dirs [--json]
dart run bin/aswh.dart config-env-paths [--json]
dart run bin/aswh.dart config-env-paths --write --name ANDROID_HOME --value "D:\SDK" --create-dir
```

**要求**：Windows 10+，PowerShell 5.1+，Flutter SDK ≥ 3.10

## Project Structure

```text
bin/aswh.dart                          # CLI 入口
lib/
├── main.dart                          # Flutter 入口
├── cli/commands/                      # CLI 子命令
│   ├── detect_android_studio_command.dart
│   ├── scan_data_dirs_command.dart
│   └── config_env_paths_command.dart  # 环境配置 CLI
├── core/
│   ├── android_studio_detector.dart   # 安装检测引擎
│   ├── data_dir_scanner.dart          # 磁盘扫描引擎
│   ├── studio_version_service.dart    # 版本抓取服务
│   ├── download_manager.dart          # 下载管理器
│   ├── env_path_manager.dart          # 环境变量管理
│   ├── scan_cache.dart                # JSON 缓存读写
│   ├── script_locator.dart            # 脚本路径解析
│   └── models/
│       ├── android_studio_install.dart
│       ├── data_dir_entry.dart
│       ├── download_task.dart
│       ├── env_path_config.dart       # 环境变量数据模型
│       ├── scan_progress.dart
│       └── studio_version.dart
├── pages/
│   ├── detect_page.dart               # GUI 主界面（四 Tab）
│   └── download_progress_card.dart
scripts/
├── detect-android-studio.ps1          # AS 检测
├── scan-data-dirs.ps1                 # 磁盘扫描
└── config-env-paths.ps1               # 环境变量读写
```

## GUI / CLI

| 功能 | GUI | CLI |
| --- | --- | --- |
| 安装检测 | 进度条 + 结果卡片 + 复制按钮 | `detect-android-studio --json` |
| 磁盘扫描 | 可展开目录树 + 子目录操作 | `scan-data-dirs --json` |
| 版本下载 | 渠道筛选 + 版本卡片 + 下载 | — |
| 环境配置 | 变量卡片 + 编辑 + 一键配置/回退 | `config-env-paths --json` |

## License

MIT
