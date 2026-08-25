import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/diagnostics/checks/adb_path_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/cross_validation_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/gradle_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/jdk_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/network_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/runtime_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/checks/sdk_check.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_orchestrator.dart';
import 'package:androidstudiowinhelper/core/diagnostics/diagnostic_result.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/pages/diagnostics_tab.dart';
import 'package:androidstudiowinhelper/pages/download_tab.dart';
import 'package:androidstudiowinhelper/pages/env_config_tab.dart';
import 'package:androidstudiowinhelper/pages/hyperv_tab.dart';
import 'package:androidstudiowinhelper/pages/install_tab.dart';
import 'package:androidstudiowinhelper/pages/sdk_setup_tab.dart';
import 'package:androidstudiowinhelper/pages/storage_tab.dart';

enum _PageTab { install, storage, download, envConfig, hyperV, sdkSetup, diagnostics }

class DetectPage extends StatefulWidget {
  const DetectPage({super.key});

  @override
  State<DetectPage> createState() => _DetectPageState();
}

class _DetectPageState extends State<DetectPage> {
  _PageTab _activeTab = _PageTab.install;

  // 启动快速诊断
  Map<String, DiagnosticStatus> _diagStatuses = {};
  bool _diagQuickDone = false;

  @override
  void initState() {
    super.initState();
    _runStartupDiagnostics();
  }

  Future<void> _runStartupDiagnostics() async {
    // 先加载缓存
    final cached = ScanCache.loadDiagnosticsStatus();
    if (cached != null && cached.isNotEmpty) {
      setState(() => _diagStatuses = cached);
    }

    // 后台执行快速检查
    try {
      final orchestrator = DiagnosticOrchestrator(checks: [
        JdkCheck(),
        SdkCheck(),
        GradleCheck(),
        AdbPathCheck(),
        RuntimeCheck(),
        NetworkCheck(),
        CrossValidationCheck(),
      ]);
      final results = await orchestrator.runQuickCheck();
      final map = <String, DiagnosticStatus>{};
      for (final r in results) {
        map[r.checkId] = r.status;
      }
      ScanCache.saveDiagnosticsStatus(map);
      if (!mounted) return;
      setState(() {
        _diagStatuses = map;
        _diagQuickDone = true;
      });
    } catch (_) {
      // 快速诊断失败不阻塞主流程
    }
  }

  /// 从 tabId 字符串映射到 _PageTab 枚举
  void _navigateToTab(String tabId) {
    final tab = _tabIdToIndex(tabId);
    if (tab != null) setState(() => _activeTab = tab);
  }

  static _PageTab? _tabIdToIndex(String tabId) {
    switch (tabId) {
      case 'install':
        return _PageTab.install;
      case 'storage':
        return _PageTab.storage;
      case 'download':
        return _PageTab.download;
      case 'env_config':
        return _PageTab.envConfig;
      case 'hyper_v':
        return _PageTab.hyperV;
      case 'sdk_setup':
        return _PageTab.sdkSetup;
      case 'diagnostics':
        return _PageTab.diagnostics;
      default:
        return null;
    }
  }

  int get _diagErrorCount =>
      _diagStatuses.values.where((s) => s == DiagnosticStatus.error).length;
  int get _diagWarningCount =>
      _diagStatuses.values.where((s) => s == DiagnosticStatus.warning).length;
  bool get _hasDiagIssues => _diagErrorCount > 0 || _diagWarningCount > 0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('androidstudiowinhelper'),
        centerTitle: false,
        actions: [
          // 诊断问题横幅
          if (_hasDiagIssues && _activeTab != _PageTab.diagnostics)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () =>
                      setState(() => _activeTab = _PageTab.diagnostics),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _diagErrorCount > 0
                          ? Theme.of(context)
                              .colorScheme
                              .errorContainer
                              .withValues(alpha: 0.7)
                          : Theme.of(context)
                              .colorScheme
                              .tertiaryContainer
                              .withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _diagErrorCount > 0
                              ? Icons.error_outline
                              : Icons.warning_amber_rounded,
                          size: 16,
                          color: _diagErrorCount > 0
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.tertiary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '发现 ${_diagErrorCount + _diagWarningCount} 个问题',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: _diagErrorCount > 0
                                    ? Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer
                                    : Theme.of(context)
                                        .colorScheme
                                        .onTertiaryContainer,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: _diagErrorCount > 0
                              ? Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer
                              : Theme.of(context)
                                  .colorScheme
                                  .onTertiaryContainer,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 280,
            child: ColoredBox(
              color: colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '环境助手',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '检测 Android Studio 安装，并分析配置、缓存、日志与 SDK 的磁盘占用。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                    ),
                    const SizedBox(height: 24),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            _TabTile(
                              icon: Icons.desktop_windows_outlined,
                              title: '安装检测',
                              subtitle: '查找 Android Studio 安装位置与版本',
                              selected: _activeTab == _PageTab.install,
                              onTap: () => setState(() => _activeTab = _PageTab.install),
                            ),
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.pie_chart_outline,
                              title: '磁盘占用体检',
                              subtitle: '统计配置、缓存、日志、SDK 目录大小',
                              selected: _activeTab == _PageTab.storage,
                              onTap: () => setState(() => _activeTab = _PageTab.storage),
                            ),
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.download_outlined,
                              title: '版本下载',
                              subtitle: '获取 Android Studio 最新版本安装包',
                              selected: _activeTab == _PageTab.download,
                              onTap: () => setState(() => _activeTab = _PageTab.download),
                            ),
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.tune_outlined,
                              title: '环境配置',
                              subtitle: '检测并配置 ANDROID_HOME、GRADLE_HOME 等环境变量',
                              selected: _activeTab == _PageTab.envConfig,
                              onTap: () => setState(() => _activeTab = _PageTab.envConfig),
                            ),
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.desktop_windows_outlined,
                              title: '模拟器运行环境',
                              subtitle: 'Hyper-V/WHPX 管理 · 硬件/虚拟化/软件环境全面诊断',
                              selected: _activeTab == _PageTab.hyperV,
                              onTap: () => setState(() => _activeTab = _PageTab.hyperV),
                            ),
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.build_outlined,
                              title: 'SDK 一键安装',
                              subtitle: '自动配置 Android SDK 核心组件（无需安装 Android Studio）',
                              selected: _activeTab == _PageTab.sdkSetup,
                              onTap: () => setState(() => _activeTab = _PageTab.sdkSetup),
                            ),
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.health_and_safety_outlined,
                              title: '环境诊断',
                              subtitle: _diagQuickDone
                                  ? (_hasDiagIssues
                                      ? '发现 ${_diagErrorCount + _diagWarningCount} 个问题'
                                      : '全部正常')
                                  : '正在检查…',
                              selected: _activeTab == _PageTab.diagnostics,
                              badge: _hasDiagIssues
                                  ? _diagErrorCount + _diagWarningCount
                                  : null,
                              onTap: () =>
                                  setState(() => _activeTab = _PageTab.diagnostics),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: switch (_activeTab) {
              _PageTab.install => const InstallTab(),
              _PageTab.storage => const StorageTab(),
              _PageTab.download => const DownloadTab(),
              _PageTab.envConfig => const EnvConfigTab(),
              _PageTab.hyperV => const HyperVTab(),
              _PageTab.sdkSetup => const SdkSetupTab(),
              _PageTab.diagnostics =>
                DiagnosticsTab(onNavigateTab: _navigateToTab),
            },
          ),
        ],
      ),
    );
  }
}

class _TabTile extends StatelessWidget {
  const _TabTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: selected
          ? colorScheme.primaryContainer.withValues(alpha: 0.55)
          : colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? colorScheme.primary
                  : colorScheme.outlineVariant,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: selected ? colorScheme.primary : colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                  decoration: BoxDecoration(
                    color: colorScheme.error,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$badge',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colorScheme.onError,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              if (selected)
                Icon(Icons.chevron_right, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
