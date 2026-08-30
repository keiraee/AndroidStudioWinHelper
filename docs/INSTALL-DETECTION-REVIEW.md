# 安装检测模块代码审查报告

> 审查日期: 2026-08-28  
> 范围: 安装检测（模块 1）— `scripts/detect-android-studio.ps1`、`lib/core/android_studio_detector.dart`、`lib/core/models/android_studio_install.dart`、`lib/pages/install_tab.dart`  
> 方法: 静态代码审查 + 构建号格式与官方发布记录交叉验证

---

## 1. 模块概览

安装检测是 ASWH 的第一个功能页签，负责：

- 多源枚举本机 Android Studio 安装（6 种检测源）
- 识别卸载残留（注册表幽灵项、孤儿运行时配置）
- 自动选出「最佳候选」安装（运行中 > 版本最高 > 唯一候选）
- 结果缓存到 `%LOCALAPPDATA%\AndroidStudioWinHelper\install_cache.json`

**架构链路：**

```
InstallTab (GUI)
    → AndroidStudioDetector.detectAll()
        → PowerShellRunner.run(-Json -Progress [-DeepScan])
            → scripts/detect-android-studio.ps1
                → @@PROGRESS|…@@ 进度标记
                → @@RESULT|{json}@@ 结果标记
```

**总体评价：** 检测覆盖面设计扎实（六路信源 + 交叉验证 + 残留识别），但存在 **1 条会输出错误信息的逻辑 bug（渠道判定）**、**2 条会导致功能不可用或静默失败的 bug（深度扫描超时、脚本崩溃被吞）**，以及若干一致性与边界问题。

---

## 2. 问题清单（按严重程度）

### P0 — 真 Bug

#### 2.1 渠道判定逻辑错误：稳定版会被误标为 Beta / Canary

**位置：** `scripts/detect-android-studio.ps1` → `Get-Channel` 函数（约 188–224 行）

**问题代码：**

```powershell
if ($Build -and $Build -match '^AI-(\d)(\d)(\d)\.') {
    $channelDigit = [int]$Matches[3]
    if ($channelDigit -eq 1) { return "Stable" }
    if ($channelDigit -eq 2) { return "Beta" }
    return "Canary"
}
```

**根因：** 注释将 `AI-X.Y.Z` 中第三位 `Z` 解释为「渠道位（1=Stable, 2=Beta, 3+=Canary）」，但 `AI-241` / `AI-242` / `AI-243` 中的第三位是 **IntelliJ 平台分支的小版本号**（对应 2024.1 / 2024.2 / 2024.3），与发布渠道无关。

**官方反例：**

| 版本 | 渠道 | 构建号 |
|------|------|--------|
| Ladybug 2024.2.1 Patch 3 | **Stable** | `AI-242.23339.11.2421.12700392` |
| Ladybug 2024.2.1 Canary 9 | Canary | `AI-242.x`（同分支号） |

按当前逻辑，`AI-242.*` 稳定版 → **Beta**，`AI-243.*` 稳定版 → **Canary**。且方法 1 直接 `return`，后续基于路径 / `dataDirectoryName` 的字符串匹配永远不会执行。

**可靠信号（脚本已读取但未优先使用）：**

- `product-info.json` → `versionSuffix`（稳定版为空，预览版为 `"Canary 4"` / `"Beta 1"` 等）
- `product-info.json` → `dataDirectoryName`（预览版为 `AndroidStudioPreview2024.x`，稳定版为 `AndroidStudio2024.x`）

**建议修复优先级：**

1. 优先读 `versionSuffix` 和 `dataDirectoryName`
2. 路径 / 名称关键字匹配作为兜底
3. 删除或彻底重写基于 build 第三位数字的渠道推断

---

#### 2.2 脚本中途崩溃会被静默显示为「未检测到」

**位置：** `lib/core/android_studio_detector.dart` 第 45–47 行、第 72–81 行

**问题代码：**

```dart
if (!result.success && result.stdout.isEmpty) {
  throw StateError('PowerShell 执行失败：${result.stderr}');
}
// ...
if (jsonText.isEmpty) {
  return const AndroidStudioDetectionResult(installs: []);
}
```

**根因：** GUI 始终带 `-Progress`，脚本一开始就往 stdout 写进度行。若脚本在中途崩溃：

1. `stdout` 非空 → 不抛 `StateError`
2. 找不到 `@@RESULT|` 标记 → `jsonText` 为空
3. 返回 `installs: []` → UI 显示「未检测到 Android Studio 安装或卸载残留」

用户无法区分「确实没装」和「检测脚本挂了」。叠加脚本第 13 行 `$ErrorActionPreference = "SilentlyContinue"`，错误被进一步吞掉。

**建议修复：**

- 以「是否成功解析到 `@@RESULT|` 标记」作为成功判定，而非「stdout 是否为空」
- 有进度但无结果时，抛出明确错误（附 stderr / exitCode）
- 考虑将 `$ErrorActionPreference` 改为 `Stop` 或至少在顶层 `trap` 中写入错误 JSON

---

#### 2.3 `--deep` 深度扫描必然超时

**位置：**

- `lib/core/powershell_runner.dart` 默认 `timeout = 120s`
- `scripts/detect-android-studio.ps1` 第 604–625 行（全盘递归 `studio64.exe` + `studio.exe` 各一遍）

**根因：** 深度扫描对所有固定磁盘做递归文件搜索，且 `studio64.exe` 和 `studio.exe` 分两次 `Get-ChildItem -Recurse`，在真实机器上远超 120 秒 → `process.kill()` → 抛超时异常。

**附带问题：** GUI `install_tab.dart` 未暴露 deepScan 入口，`-DeepScan` 仅 CLI `aswh detect-android-studio --deep` 可达，但当前不可用。

**建议修复：**

- 深度扫描单独设置超时（如 600s 或用户可配）
- 合并为一次搜索：`-Include studio64.exe, studio.exe`
- GUI 可选增加「深度扫描」开关

---

### P1 — 逻辑缺陷

#### 2.4 残留检测存在交叉污染，可能漏报真残留

**位置：** `scripts/detect-android-studio.ps1` 第 340–383 行

**问题：** `$officialPathHint = Get-OfficialInstallPathFromProductReg` 只取第一个有效官方 Path，却被加入**每一个**卸载项的候选路径列表。若机器上有正常安装 A，同时存在安装 B 的卸载残留，B 的候选列表会混入 A 的路径 → `Test-ValidInstallDir` 通过 → `continue` → B 的残留被漏报。

**场景：** 「有正常安装 + 有历史残留」是该功能最常见的使用场景。

**建议：** 每个卸载项只从自身字段（InstallLocation、UninstallString、DisplayIcon 等）解析候选路径，不要用全局 `$officialPathHint` 做交叉填充。

---

#### 2.5 两个 Studio 同时运行时，「运行中」信号被丢弃

**位置：** `lib/core/android_studio_detector.dart` 第 156–161 行

```dart
if (running.length == 1) {
  return (running.first, AndroidStudioSelectionReason.runningProcess);
}
```

**问题：** 同时运行 Stable + Canary 时 `running.length == 2`，条件不成立，直接跳到「按版本号最高选」，丢弃「运行中」这一最强信号。Google 官方鼓励 Install Alongside Stable，双开很常见。

**建议：** 在 `running` 集合内按版本号选最高，而非要求 `length == 1`。

---

#### 2.6 孤儿配置检测的快照取得过早

**位置：** `scripts/detect-android-studio.ps1` 第 448 行（进度 45%）

```powershell
$knownInstallPaths = @($found.Keys)
```

**问题：** 此快照在快捷方式（50%）、JetBrains Toolbox（65%）、常见安装路径（75%）、深度扫描（85%）之前拍摄。后续新增的安装不会进入 `$knownInstallPaths` / `$knownDataDirNames`，只能靠 `.home` 回指兜底。若某安装缺少 `.home`，其运行时配置可能被误报为「孤儿残留」。

**建议：** 将孤儿配置检测整体移到所有检测源执行完毕之后（当前约 625 行之后、结果组装之前）。

---

### P2 — 一致性与体验问题

| # | 问题 | 位置 | 说明 |
|---|------|------|------|
| 2.7 | 注释与代码矛盾 | PS1 204、667 行 | 注释写 `channel=2 → Canary`，代码返回 `"Beta"`；注释写「优先 dataDirectoryName」，实际排最后 |
| 2.8 | 退出码语义混乱 | PS1 712、758 行 | 「什么都没找到」`exit 1`，与「检测失败」无法区分 |
| 2.9 | README 承诺未实现 | README 第 41 行 | 「环境变量激活的安装显示 ANDROID_HOME 标签」— `install_tab.dart` 无此逻辑 |
| 2.10 | `installed` 是死字段 | PS1 685 行、模型默认值 | 硬编码 `installed = $true`，永远不会 false |
| 2.11 | 8.3 短路径可能导致重复卡片 | PS1 116–117 行 | `Resolve-Path` 不展开 `PROGRA~1` 短名，同一安装可能显示两张卡片 |
| 2.12 | `jsonDecode` 无 try/catch | `android_studio_detector.dart` 83 行 | 非 JSON stdout 会抛未处理 `FormatException` |
| 2.13 | 缓存反序列化无 `isValid` 过滤 | `AndroidStudioDetectionResult.fromJson` | 与实时检测路径校验强度不一致 |
| 2.14 | 残留卡片标签写死 | `install_tab.dart` 302 行 | 所有残留显示「注册表残留」，但 `kind` 含 `orphanConfig` |
| 2.15 | 选中原因未展示 | `install_tab.dart` | `selectionReason` 有星标但无文字说明（如「运行中进程」） |
| 2.16 | DeepScan 无 GUI 入口 | `install_tab.dart` | 功能仅 CLI 可达且当前超时不可用 |

---

## 3. 检测源覆盖（无问题，供参考）

| 检测源 | 进度 | 脚本位置 | 状态 |
|--------|------|----------|------|
| 运行中进程 | 5% | 266–268 | ✅ |
| 官方产品注册表 (SOFTWARE\Android Studio) | 12% | 276–330 | ✅ |
| 卸载注册表 | 18% | 332–404 | ⚠️ 交叉污染见 2.4 |
| App Paths 注册表 | 35% | 406–428 | ✅ |
| IDE 配置回指 (.home) | 42% | 431–443 | ✅ |
| 孤儿配置检测 | 45% | 446–548 | ⚠️ 快照过早见 2.6 |
| 开始菜单与桌面快捷方式 | 50% | 550–570 | ✅ |
| JetBrains Toolbox | 65% | 572–589 | ✅ |
| 常见安装路径 | 75% | 591–602 | ✅ |
| 深度扫描 (DeepScan) | 85% | 604–625 | ❌ 超时见 2.3 |

---

## 4. 建议修复顺序

```
Phase 1（用户可见错误信息）
  ├── 2.1 渠道判定重写
  └── 2.2 脚本失败不再静默为空结果

Phase 2（功能可用性）
  ├── 2.3 深度扫描超时 + 合并搜索
  └── 2.4 残留检测去交叉污染

Phase 3（边界与体验）
  ├── 2.5 多运行实例选中逻辑
  ├── 2.6 孤儿检测后移
  └── 2.7–2.16 一致性清理
```

---

## 5. 涉及文件索引

| 文件 | 行数 | 职责 |
|------|------|------|
| `scripts/detect-android-studio.ps1` | 760 | 核心检测逻辑（PowerShell） |
| `lib/core/android_studio_detector.dart` | 197 | Dart 编排 + 结果解析 + 默认选中 |
| `lib/core/models/android_studio_install.dart` | 201 | 数据模型 |
| `lib/pages/install_tab.dart` | 394 | GUI 展示 |
| `lib/core/powershell_runner.dart` | 414 | 进程管理 + 超时 |
| `lib/core/scan_cache.dart` | — | 安装检测缓存读写 |
| `lib/cli/commands/detect_android_studio_command.dart` | — | CLI `--deep` 入口 |

---

## 6. 验证建议

修复后可用以下方式验证：

```powershell
# 1. 直接跑脚本，检查渠道字段
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/detect-android-studio.ps1 -Json

# 2. CLI 检测
dart run bin/aswh.dart detect-android-studio --json

# 3. 深度扫描（修复超时后）
dart run bin/aswh.dart detect-android-studio --json --deep

# 4. 模拟脚本中途失败：在 PS1 某处故意 throw，确认 Dart 侧报明确错误而非空结果
```

**渠道判定验收标准：**

- `AI-242.*` 且 `dataDirectoryName = AndroidStudio2024.2.1` → Stable
- `AI-242.*` 且 `dataDirectoryName = AndroidStudioPreview2024.2.1` → 按 versionSuffix / 路径判断 Beta 或 Canary
- 不再仅凭 build 第三位数字判定渠道
