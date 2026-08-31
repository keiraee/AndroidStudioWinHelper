# 官方安装器路径拦截 + 首次启动 SDK 兜底

> 日期: 2026-08-31  
> 状态: 已实现  
> 范围: 方案 3（混合拦截）— 安装向导可见，预填并在前进前写回；装完写 other.xml

## 1. 目标与非目标

### 目标

1. **安装目录页**：默认并纠偏为环境向导确认的 `AS_INSTALL_HOME`。
2. **SDK / 用户配置**：默认并纠偏为 `ANDROID_HOME`、`ANDROID_USER_HOME`（改 UI + 改 `inst_user_settings.tmp`）。
3. **首次启动兜底**：安装成功后预写 `other.xml` 的 `android.sdk.path`，尽量让 Setup Wizard 使用我们的 SDK 路径。
4. **可感知**：下载/安装相关 UI 显示轻量拦截状态；全程写入 `LogManager`。

### 非目标

- 不做静默 `/S` 安装（用户已选可见向导）。
- 不永久锁死控件（允许改，前进前写回）。
- 不在本功能内完整安装 SDK platforms（可建空 `platforms` 以满足路径有效性检查；组件由 SDK 页或 AS 自带管理器安装）。
- 不修改官方安装包二进制。

## 2. 已确认决策

| 项 | 决策 |
|----|------|
| 范围 | 安装器两页 + 首次启动 other.xml（方案 C） |
| 安装器形态 | 仍弹官方向导（B） |
| 纠偏策略 | 预填 + 点 Next/Install 前写回（C） |
| `.android` 行 | 一并改为 `ANDROID_USER_HOME`（A） |
| 技术路线 | 方案 3 混合：目录页 UI + tmp 文件 + other.xml |
| 生命周期 | 拦截器与安装器进程同生共死 |
| UI | 需要轻量状态条/面板 + 日志 |

## 3. 总流程

```
环境向导成功
  → 读取 Machine/确认路径: AS_INSTALL_HOME, ANDROID_HOME, ANDROID_USER_HOME
  → 启动安装器（cwd = 安装包目录）
  → 启动 InstallerPathInterceptor（后台 isolate/异步循环）
  → UI 订阅 interceptor.statusStream，展示状态
  → 安装器退出
       ├─ 成功且 product-info 可读 → 写 other.xml + 确保 SDK 目录骨架
       └─ 取消/失败 → 不写 other.xml，记日志
  → 拦截器停止，UI 显示最终结果
```

入口改造：`download_tab._runInstallerKey` / `DownloadManager.runInstaller` 在启动后挂接拦截器，不再仅 `ProcessStartMode.detached` 后立即返回。

推荐：`runInstaller` 返回 `Process`（或 pid + 可 await 的退出 Future），由上层启动 interceptor 并展示面板。

## 4. 安装目录 UI 拦截

1. 轮询枚举顶层窗口（间隔 300–500ms），匹配 Android Studio / Nullsoft 安装向导窗口。
2. 在子控件中定位路径 `Edit`（启发式：可见、内容像绝对路径、位于 Directory 页）。
3. 首次命中：`SetWindowText(AS_INSTALL_HOME)`，状态「已对齐安装目录」。
4. 持续：若 `GetWindowText` ≠ 目标则写回，日志节流（同一纠正原因 2s 内只打一次）。
5. 宽限期 60s 内未找到：状态警告「安装目录控件未找到，将依赖 SDK/首次启动兜底」，**不终止安装器**。
6. 实现落点：优先 Dart + `package:win32`；必要时薄 C++ 辅助（与现有 `windows_elevate` 风格一致）。

失败降级：仅记日志，SDK tmp 与 other.xml 仍执行。

## 5. SDK / ANDROID_USER_HOME 拦截

### 5.1 `inst_user_settings.tmp`

- 路径：安装器 **cwd**（安装包所在目录）下的 `inst_user_settings.tmp`。
- 格式：UTF-16LE，两行：
  1. `ANDROID_HOME`
  2. `ANDROID_USER_HOME`
- 行为：文件出现或内容被官方覆盖后，写回我们的两行；直到安装器退出。
- 写文件注意：原子写（写临时文件再 replace）或短重试，避免与安装器并发写冲突。

### 5.2 UI 同步（尽力）

若向导页存在 SDK / User Settings 输入框，同步 `SetWindowText`；找不到不算失败。

## 6. 首次启动 other.xml 兜底

安装器退出后：

1. 判定安装成功：`AS_INSTALL_HOME\product-info.json` 存在，或 `HKLM\SOFTWARE\Android Studio\Path` 指向有效树。
2. 读 `dataDirectoryName`（如 `AndroidStudio2024.1`）。
3. 创建：`%APPDATA%\Google\<dataDirectoryName>\options\`
4. 写入 `other.xml`（内容为 JSON）：
   ```json
   {
     "android.sdk.path": "<ANDROID_HOME>"
   }
   ```
   若文件已存在：合并/覆盖 `android.sdk.path`，尽量保留其他键。
5. 确保 `ANDROID_HOME` 存在；创建空子目录 `platforms`（满足「含 platforms/」有效性检查，避免仍弹默认 `%LOCALAPPDATA%\Android\Sdk`）。**不**伪造 platform 内容。
6. 可选：同步确认 `ANDROID_SDK_ROOT` 与 `ANDROID_HOME` 一致（若环境向导未写则可补写；本迭代以 other.xml + 已有 ANDROID_HOME 为主）。

取消安装或无 product-info：跳过，状态「未写入首次启动配置」。

## 7. UI 与日志

### UI

在下载 Tab 安装动作附近或 modal/bottom 轻量面板：

| 状态 | 文案示例 |
|------|----------|
| waitingWizard | 正在等待安装向导… |
| alignedInstallDir | 已对齐安装目录 → {path} |
| installDirMiss | 安装目录控件未找到，将依赖后续兜底 |
| alignedSdkTmp | 已对齐 SDK/用户配置临时文件 |
| writingOtherXml | 正在写入首次启动 SDK 路径… |
| done | 路径拦截完成 |
| cancelled | 安装已取消，未写首次启动配置 |
| error | 拦截异常：{msg}（安装器仍可继续） |

可取消「监视」但不杀安装器（可选按钮）；默认随进程退出自动停。

### 日志

`LogManager` 类别建议：`InstallerIntercept`  
关键事件：启动、找到窗口、预填、纠正、tmp 读写、other.xml 路径、成功/降级原因。

## 8. 模块划分（建议）

| 模块 | 职责 |
|------|------|
| `lib/core/installer_path_interceptor.dart` | 编排：轮询、状态流、退出后 other.xml |
| `lib/core/installer_ui_path.dart`（或 win32 封装） | 找窗、读写 Edit |
| `lib/core/installer_settings_tmp.dart` | 读写 `inst_user_settings.tmp` |
| `lib/core/as_first_run_sdk_config.dart` | product-info → other.xml + platforms 骨架 |
| `lib/pages/...` | 状态面板；`runInstaller` 接线 |

路径来源：优先传入向导刚确认的 `Map`；否则读 Machine 环境变量。

## 9. 测试计划

1. **单元**：tmp 编解码（UTF-16LE 两行）；other.xml 写入/合并；platforms 骨架创建（用临时目录）。
2. **单元**：拦截状态机（waiting → aligned → done / cancelled）不依赖真实安装器。
3. **实机**（新电脑）：向导选盘 → 运行安装器 → 目录页应为 `AS_INSTALL_HOME`；改路径再 Next 前应被改回；SDK 页/tmp 为自定义路径；装完检查 other.xml；首次开 AS 默认 SDK 路径正确。
4. **降级**：故意找不到 Edit 时，tmp + other.xml 仍成功。

## 10. 风险与缓解

| 风险 | 缓解 |
|------|------|
| AS 版本 UI 变化 | 启发式 + 60s 超时降级；不阻断安装 |
| tmp 与安装器抢写 | 重试 + 退出前最后一次写 |
| 空 `platforms` 仍弹组件向导 | 可接受；路径已不是默认 LocalAppData；完整组件走 SDK 页 |
| 多监控实例 | 同一时间只允许一个 interceptor |
| 安装包 cwd 非下载目录 | 以 `Process` 启动时显式 `workingDirectory: dirname(exe)` |

## 11. 实现顺序

1. tmp 读写 + other.xml + platforms 骨架（可测）
2. Interceptor 状态机 + DownloadManager 返回 Process
3. Win32 安装目录 Edit 拦截
4. UI 状态面板 + 日志
5. 实机验证与容错调参
