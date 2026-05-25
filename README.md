# androidstudiowinhelper

Windows Android Studio 安装与环境配置助手。支持 GUI（Flutter）和 CLI 两种运行方式，提供安装检测、磁盘占用扫描、环境变量诊断等功能。

## 架构

```
bin/aswh.dart                     # CLI 入口
lib/
├── main.dart                     # Flutter 入口
├── cli/commands/                 # CLI 子命令
├── core/                         # 核心逻辑
│   ├── android_studio_detector.dart   # AS 安装检测
│   ├── data_dir_scanner.dart          # 磁盘目录扫描
│   ├── script_locator.dart            # 脚本路径解析（平台适配）
│   └── models/                        # 数据模型
├── pages/
│   └── detect_page.dart          # 主界面（检测 + 扫描）
scripts/
├── detect-android-studio.ps1     # AS 检测脚本
├── detect-android-studio.cmd     # 批处理包装
└── scan-data-dirs.ps1            # 磁盘扫描脚本
```

## 启动

```bash
# GUI
flutter run -d windows

# CLI
dart run bin/aswh.dart detect-android-studio [--json] [--deep]
dart run bin/aswh.dart scan-data-dirs [--json]
```

## 功能

| 功能 | GUI | CLI | 说明 |
|---|---|---|---|
| AS 安装检测 | 进度条 + 结果卡片 | `detect-android-studio` | 进程/注册表/快捷方式/Toolbox 等多源检测 |
| 磁盘占用扫描 | 进度条 + 可展开目录树 | `scan-data-dirs` | IDE 配置、缓存、日志、SDK、Gradle 等 |
| 环境变量标记 | 绿色「使用中」标签 | `isActive` / `activeSource` 字段 | 通过 ANDROID_HOME / ANDROID_SDK_ROOT 匹配 |

## 检测来源

- 运行中进程（`studio64.exe` / `studio.exe`）
- 卸载注册表（InstallLocation / DisplayIcon / UninstallString）
- App Paths 注册表
- 开始菜单 & 桌面快捷方式
- JetBrains Toolbox
- 常见安装路径
- 深度扫描（全盘递归，`--deep` 启用）
