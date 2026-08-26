# Android Studio Windows 安装器完整逆向分析报告

> Case: `as-win-write-map` | 分析日期: 2026-08-26
> 目标: `android-studio-rabbit1-canary2.exe` (NSIS-3 Unicode, ~1.43 GiB)
> 安装目录: `D:\ProgramSpace\Android\Android Studio` (Stable AI-241)
> 方法: 静态 PE/NSIS 逆向 + 动态注册表/文件系统实查

---

## 1. 安装包身份与结构

### 1.1 PE 头信息

| 属性 | 值 |
|------|-----|
| 格式 | PE32 (x86 stub) + NSIS-3 Unicode payload |
| NSIS 版本 | Nullsoft Install System v2.46.5-Unicode |
| Manifest | `requestedExecutionLevel = requireAdministrator` |
| 签名 | Google LLC |
| ProductVersion | `AI-262.9437.185.2621.16128175` |

### 1.2 NSIS 包体结构 (uninstall.exe PE 段)

| 段名 | VSize | 说明 |
|------|-------|------|
| `.text` | 0x728C | NSIS 运行时代码 |
| `.rdata` | 0x2B6E | 只读数据（导入表） |
| `.data` | 0x72B9C | 运行时数据 |
| `.ndata` | 0x289000 | **NSIS 脚本数据（压缩，核心写入逻辑在此）** |
| `.rsrc` | 0x12D90 | 资源（图标、manifest、版本信息） |
| `.reloc` | 0xFD6 | 重定位表 |

NSIS Magic 位于偏移 `0x1E408`，脚本数据在 `0x30000-0x60000` 区域。

### 1.3 NSIS 插件 (安装器运行时加载)

| 插件 | 用途 |
|------|------|
| `FindProcDLL.dll` | 检测 `studio64.exe`/`studio.exe` 是否在运行 |
| `UAC.dll` | UAC 提权 |
| `StartMenu.dll` | 开始菜单快捷方式操作 |
| `nsDialogs.dll` | 自定义安装向导 UI |
| `System.dll` | 系统 API 调用（如 `kernel32::IsWow64Process`） |

### 1.4 打包文件清单 (3321 条目)

载荷前缀: `$_31_\` (IDE 完整树 + uninstall.exe)

| 目录/文件 | 条目数 | 说明 |
|-----------|--------|------|
| `plugins/` | 2308 | IDE 插件（android, Kotlin, textmate 等） |
| `jbr/` | 485 | JetBrains Runtime (JDK) |
| `lib/` | 392 | IDE 核心库 |
| `bin/` | 84 | 可执行文件、脚本、配置 |
| `license/` | 38 | 第三方许可证 |
| `modules/` | 2 | 模块描述 |
| `product-info.json` | 1 | **运行时元数据（关键）** |
| `build.txt` | 1 | 构建号 |
| `uninstall.exe` | 1 | **卸载程序（含安装脚本逻辑副本）** |
| `$PLUGINSDIR/` | 7 | NSIS 插件 + 安装向导图片 |

---

## 2. 安装时写入 (NSIS 脚本分析)

### 2.1 注册表写入

从 `uninstall.exe` 的 UTF-16LE 脚本数据中提取到的注册表目标：

#### 2.1.1 产品注册表 (安装路径权威来源)

```
键: HKLM\SOFTWARE\Android Studio
值:
  Path             → 安装根目录 (如 D:\ProgramSpace\Android\Android Studio\)
  StartMenuGroup   → 开始菜单组名 (默认 "Android Studio")
  JdkPath          → JBR 路径 (通常为空，使用内置 jbr/)
  SdkPath          → SDK 路径 (可选，用户勾选时写入)
  InstallSdk       → 是否安装 SDK ("0" 或 "1")
  InstallHaxm      → 是否安装 HAXM ("0" 或 "1")
  UserSettingsPath → .android 路径 (默认 %USERPROFILE%\.android)
```

**实查确认 (你机器上的值):**
```
HKLM\SOFTWARE\Android Studio
  Path             = D:\ProgramSpace\Android\Android Studio\
  StartMenuGroup   = Android Studio
  SdkPath          = (空)
  UserSettingsPath = C:\Users\HCY520MH\.android
  InstallSdk       = 0
  InstallHaxm      = 0
```

> 注意: HKCU 和 WOW6432Node 下均不存在此键。安装器只写 HKLM。

#### 2.1.2 卸载注册表 (添加/删除程序)

```
键: HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Android Studio
值:
  DisplayName       → "Android Studio"
  DisplayVersion    → "2024.1" (营销版本，≠ product-info 的 build)
  Publisher         → "Google LLC"
  UninstallString   → "<安装根>\uninstall.exe"
  InstallLocation   → **通常为空** (这是 NSIS 的正常行为)
```

**实查确认:**
```
DisplayName     = Android Studio
DisplayVersion  = 2024.1
InstallLocation = (空)
UninstallString = D:\ProgramSpace\Android\Android Studio\\uninstall.exe
Publisher       = Google LLC
```

#### 2.1.3 App Paths (未写入)

```
MISSING: HKLM\...\App Paths\studio64.exe
MISSING: HKLM\...\App Paths\studio.exe
```

> **重要发现: NSIS 安装器不创建 App Paths 注册表项。** 你当前的检测脚本扫描 App Paths 是作为兜底策略，但永远不会有结果。

#### 2.1.4 HAXM 相关注册表 (嵌入在 HAXM 安装脚本中)

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\A153321B793BFB94DB4FFB19CB939073
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\5F13BCCED53473F49AD885453D6C7281
```

这些仅在用户勾选安装 Intel HAXM 时通过 MSI 写入。默认 `InstallHaxm=0` 时不涉及。

### 2.2 文件系统写入

#### 2.2.1 IDE 安装树

NSIS 将 `$_31_\*` 解压到用户选择的安装目录。**默认路径**: `C:\Program Files\Android\Android Studio`

实际安装树顶层:
```
D:\ProgramSpace\Android\Android Studio\
  bin/          (84 个文件: studio64.exe, studio.exe, idea.properties, vmoptions, 各种 bat/exe)
  jbr/          (485 个文件: JetBrains Runtime JDK)
  lib/          (392 个文件: IDE 核心 JAR/DLL)
  plugins/      (2308 个文件: android, kotlin, textmate 等插件)
  license/      (38 个文件)
  modules/      (2 个文件)
  product-info.json
  build.txt
  LICENSE.txt
  NOTICE.txt
  uninstall.exe
```

#### 2.2.2 开始菜单快捷方式

```
%ProgramData%\Microsoft\Windows\Start Menu\Programs\Android Studio\Android Studio.lnk
  → 目标: D:\ProgramSpace\Android\Android Studio\bin\studio64.exe
```

**实查确认:**
```
Path   = C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Android Studio\Android Studio.lnk
Target = D:\ProgramSpace\Android\Android Studio\bin\studio64.exe
```

#### 2.2.3 安装器临时文件 (动态捕获确认)

安装器启动后 ~9 秒在 cwd 创建:
```
inst_user_settings.tmp (UTF-16LE, 142 字节)
  第 1 行: C:\Users\HCY520MH\AppData\Local\Android\sdk    (默认 SDK 路径)
  第 2 行: C:\Users\HCY520MH\.android                      (默认用户设置路径)
```

- 创建时机: 安装向导页面显示后、用户点击 Finish 之前
- 删除时机: 取消安装或安装完成时自动删除
- 此阶段注册表 **无变化**

### 2.3 安装器不写入的位置

| 路径 | 说明 |
|------|------|
| `%APPDATA%\Google\AndroidStudio*` | 首次 IDE 运行才创建 |
| `%LOCALAPPDATA%\Google\AndroidStudio*` | 首次 IDE 运行才创建 |
| `%LOCALAPPDATA%\Android\Sdk` | 仅当用户勾选安装 SDK 时 |
| `App Paths\studio64.exe` | NSIS 脚本中无此写入 |
| `HKCU\SOFTWARE\Android Studio` | 仅写 HKLM |

---

## 3. 运行时写入 (首次 IDE 启动后)

### 3.1 核心驱动机制

`product-info.json` 中的 `dataDirectoryName` 字段决定运行时路径：

```json
{
  "dataDirectoryName": "AndroidStudio2026.2.1",
  "productVendor": "Google",
  "version": "AI-262.9437.185.2621.16128175"
}
```

JVM 启动参数 (从 `product-info.json` 的 `launch[0].additionalJvmArguments`):
```
-Didea.vendor.name=Google
-Didea.paths.selector=AndroidStudio2026.2.1
-Didea.platform.prefix=AndroidStudio
```

> `vendor.name=Google` 决定配置在 `Google\` 下而非 `JetBrains\` 下。
> `paths.selector=AndroidStudio2026.2.1` 决定子目录名。

### 3.2 配置目录 (%APPDATA%)

```
%APPDATA%\Google\<dataDirectoryName>\
  你机器 (Stable): C:\Users\HCY520MH\AppData\Roaming\Google\AndroidStudio2024.1\
  Canary 包:       %APPDATA%\Google\AndroidStudio2026.2.1\  (首次运行后创建)
```

内容:
```
codestyles/       colors/           global-model-cache/  inspection/
light-edit/       marktone/         migration/           options/
plugins/          ssl/              tasks/               tools/
workspace/        app-internal-state.db    bundled_plugins.txt
disabled_plugins.txt  disabled_update.txt  early-access-registry.txt
idea.properties   migration_installed_plugins.txt
studio64.exe.jdk  studio64.exe.vmoptions
updatedBrokenPlugins.db  user.web.token  c.kdbx  c.pwd
```

### 3.3 系统目录 (%LOCALAPPDATA%)

```
%LOCALAPPDATA%\Google\<dataDirectoryName>\
  你机器 (Stable): C:\Users\HCY520MH\AppData\Local\Google\AndroidStudio2024.1\
```

内容:
```
.home                     ← 指向安装根目录 (关键! 反查安装位置)
.android/   caches/       compile-server/  compiler/
conversion/  device-explorer/  editor/      external_build_system/
extResources/  frameworks/  global-model-cache/  gmaven.index/
gradle.versions/  icon-cache/  index/      jcef_cache/
lint/          LocalHistory/  log/          maven.google/
plugins/       projects/     recentFilesTimeStamps.dat  restart/
sdk_index/     serverflags/  splash/       stat/
stats/         terminal/     testHistory/  tmp/
vcs-log/       vcs-users/    whatsnew/     .appinfo/
.deploy_cache.db  .dex_cache.db  .pid      symbol.cache.marker
```

**`.home` 文件内容**: 安装根目录路径 (如 `D:\ProgramSpace\Android\Android Studio`)

### 3.4 共享工具目录 (非版本隔离)

| 路径 | 内容 | AS 专属? |
|------|------|----------|
| `%USERPROFILE%\.android\` | AVD, adbkey, adbkey.pub, adb_usb.ini | 与 SDK 共享 |
| `%LOCALAPPDATA%\Android\Sdk\` | SDK (platform-tools, build-tools 等) | 否 |
| `%USERPROFILE%\.gradle\` | Gradle 缓存 | 否 |
| `%USERPROFILE%\.m2\` | Maven 仓库 | 否 |
| `%USERPROFILE%\AndroidStudioProjects\` | 默认项目目录 | 是 |
| `%USERPROFILE%\java_error_in_studio64_*.log` | JVM 崩溃日志 | 是 |
| `%USERPROFILE%\java_error_in_studio64_*.hprof` | JVM 堆转储 | 是 |

### 3.5 JetBrains 目录 (非 AS 主配置)

```
%APPDATA%\JetBrains\    ← 其他 JetBrains IDE 使用 (IntelliJ, CLion, PyCharm 等)
%LOCALAPPDATA%\JetBrains\
```

> Android Studio (Google 构建版) 的主配置在 `Google\` 下，不在 `JetBrains\` 下。
> 但 `JetBrains\Shared\vAny` 可能存在共享数据。不要将整个 JetBrains 目录视为 AS 残留。

---

## 4. 完整安装时序 (5 阶段)

```
[0] 双击 android-studio-rabbit1-canary2.exe
    cwd = 安装器所在目录
    │
    ▼
[1] NSIS UI 引导
    │ 释放 $PLUGINSDIR (UAC.dll, FindProcDLL.dll, StartMenu.dll, nsDialogs.dll)
    │ FindProcDLL: 检查 studio64.exe/studio.exe 是否在运行 → 拒绝安装
    │ UAC.dll: 请求管理员权限 (requireAdministrator)
    ▼
[2] 早期写入 (Finish 之前)
    │ 创建: <cwd>\inst_user_settings.tmp (UTF-16LE)
    │   行1: %LOCALAPPDATA%\Android\sdk
    │   行2: %USERPROFILE%\.android
    │ 注册表: 无变化
    │ 生命周期: 取消或完成后删除
    ▼
[3] 向导选择
    │ 安装位置 (默认 C:\Program Files\Android\Android Studio)
    │ 可选: Android SDK / Android User Settings / Intel HAXM
    │ 用户路径选择可能更新 tmp 文件内容
    ▼
[4] 点击 Finish 提交 ← 核心写入阶段
    │ ① 解压 $_31_\* → 选择的安装根目录
    │ ② WriteRegStr HKLM\SOFTWARE\Android Studio
    │      Path, StartMenuGroup, JdkPath, SdkPath,
    │      InstallSdk, InstallHaxm, UserSettingsPath
    │ ③ WriteRegStr HKLM\...\Uninstall\Android Studio
    │      DisplayName, DisplayVersion, Publisher,
    │      UninstallString (InstallLocation 通常为空)
    │ ④ CreateShortCut <StartMenuGroup>\Android Studio.lnk
    │      → bin\studio64.exe
    │ ⑤ (可选) 释放 SDK / .android / HAXM MSI
    │ ⑥ Delete inst_user_settings.tmp
    ▼
[5] 首次 IDE 运行 (非安装时)
    │ JVM 参数: -Didea.paths.selector=<dataDirectoryName>
    │ 创建: %APPDATA%\Google\<selector>\      (配置)
    │ 创建: %LOCALAPPDATA%\Google\<selector>\ (系统缓存)
    │ 创建: %LOCALAPPDATA%\Google\<selector>\.home (回指安装根)
    │ 创建: %USERPROFILE%\.android\ (如不存在)
```

---

## 5. 关键检测路径总结 (按优先级)

### 5.1 有效安装检测

| 优先级 | 来源 | 路径/键 | 验证方法 |
|--------|------|---------|----------|
| 1 | 产品注册表 | `HKLM\SOFTWARE\Android Studio\Path` | 验证 `bin\studio64.exe` 或 `product-info.json` 存在 |
| 2 | 卸载注册表 | `HKLM\...\Uninstall\Android Studio\UninstallString` | 取父目录 → 验证 |
| 3 | 开始菜单 | `%ProgramData%\...\Android Studio.lnk` | 解析 TargetPath → 验证 |
| 4 | 运行进程 | `studio64.exe` / `studio.exe` 进程 | 取 Path → 验证 |
| 5 | .home 回指 | `%LOCALAPPDATA%\Google\AndroidStudio*\*.home` | 读取内容 → 验证 |
| 6 | 常见路径 | `C:\Program Files\Android\Android Studio` | 直接验证 |
| 7 | JetBrains Toolbox | `%LOCALAPPDATA%\JetBrains\Toolbox\apps\` | 递归搜索 studio64.exe |

### 5.2 残留判定规则

残留 = 注册表项存在 **且** 所有候选路径均无法验证为有效安装

- `InstallLocation` 为空 **不是** 残留信号（NSIS 正常行为）
- `App Paths` 不存在 **不是** 异常（NSIS 不创建）
- `HKCU\SOFTWARE\Android Studio` 不存在 **不是** 异常（只写 HKLM）

### 5.3 版本信息优先级

1. `product-info.json` → `version`, `buildNumber`, `dataDirectoryName` (最准确)
2. `build.txt` → 单行构建号
3. 注册表 `DisplayVersion` (营销版本，可能不同)

### 5.4 运行时数据残留检测

首次运行后的"孤儿配置" = `Google\AndroidStudio*` 目录存在，但对应的安装已不存在

检测方法:
1. 枚举 `%APPDATA%\Google\AndroidStudio*` + `%LOCALAPPDATA%\Google\AndroidStudio*`
2. 通过 `.home` 文件关联到已知安装
3. 无对应安装的 = 孤儿配置（真正的卸载残留）

---

## 6. ASWH 当前检测脚本覆盖度评估

### 6.1 已覆盖

- ✅ `HKLM\SOFTWARE\Android Studio` (产品注册表) + HKCU + WOW6432Node
- ✅ Uninstall 注册表 (HKLM + HKCU + WOW6432Node)
- ✅ App Paths (作为兜底)
- ✅ .home 回指检测 (`%LOCALAPPDATA%\Google\AndroidStudio*\.home`)
- ✅ 开始菜单 + 桌面快捷方式
- ✅ JetBrains Toolbox
- ✅ 运行中进程
- ✅ 常见路径扫描
- ✅ 深度扫描模式
- ✅ 残留检测 (residue)
- ✅ product-info.json 读取版本信息
- ✅ build.txt 兜底

### 6.2 可改进

1. **App Paths 不会命中** — NSIS 安装器不写此键，扫描可保留但不应依赖
2. **StartMenuGroup 动态解析** — 当前脚本已从 `HKLM\SOFTWARE\Android Studio\StartMenuGroup` 读取组名，这是正确的
3. **SDK 路径检测** — 可以从 `SdkPath` 注册表值 + `ANDROID_HOME`/`ANDROID_SDK_ROOT` 环境变量交叉验证
4. **孤儿配置检测** — 可以增加 `%APPDATA%\Google\AndroidStudio*` 枚举，关联 `.home` 后识别真正的残留

---

## 7. 分析方法论

| 阶段 | 方法 | 产出 |
|------|------|------|
| PE 分析 | `file` 命令 + PE 结构解析 | NSIS-3 Unicode 标识、段布局 |
| 包体分析 | 7-Zip 列出 NSIS payload | 3321 条目清单、`$_31_\` 前缀 |
| 脚本提取 | UTF-16LE 字符串扫描 `uninstall.exe` | 注册表键值名、路径、快捷方式名 |
| 元数据分析 | 解析 `product-info.json` | dataDirectoryName、launcherPath、JVM 参数 |
| 动态捕获 | 启动安装器 → 轮询 → 终止 | `inst_user_settings.tmp` 临时文件 |
| 注册表实查 | PowerShell 读取 HKLM/HKCU | 确认实际写入值 |
| 文件系统实查 | 目录遍历 + `.home` 读取 | 运行时配置目录结构 |

**核心发现**: 对于 NSIS 安装器，最高 ROI 的分析链是：
1. 识别安装器类型（NSIS/Inno/WiX）
2. 从 payload 提取 `uninstall.exe` + `product-info.json`
3. 对 `uninstall.exe` 做字符串提取获取写入目标
4. 读取实机注册表 + 快速方式 + `.home` 获取真实值

IDA 深度逆向 NSIS stub 属于"可选精修"，在前 4 步已获取完整写入地图后几乎不会增加新信息。
