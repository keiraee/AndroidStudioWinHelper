import 'dart:async';

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
import 'package:androidstudiowinhelper/core/diagnostics/mirror_source.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class DiagnosticsTab extends StatefulWidget {
  const DiagnosticsTab({super.key, this.onNavigateTab});

  /// 由父级提供，用于跳转到其他 Tab（传入 relatedTabId）
  final void Function(String tabId)? onNavigateTab;

  @override
  State<DiagnosticsTab> createState() => _DiagnosticsTabState();
}

class _DiagnosticsTabState extends State<DiagnosticsTab> {
  late final DiagnosticOrchestrator _orchestrator;
  late final NetworkCheck _networkCheck;

  List<DiagnosticResult> _results = [];
  bool _quickLoading = false;
  bool _fullLoading = false;
  bool _mirrorLoading = false;
  String? _error;

  // 镜像测试结果
  List<MirrorTestResult> _mirrorResults = [];
  String? _currentMirror;
  bool? _googleReachable;

  // 记录每个 check 的展开状态
  final Map<String, bool> _expanded = {};

  @override
  void initState() {
    super.initState();
    _networkCheck = NetworkCheck();
    _orchestrator = DiagnosticOrchestrator(checks: [
      JdkCheck(),
      SdkCheck(),
      GradleCheck(),
      AdbPathCheck(),
      RuntimeCheck(),
      _networkCheck,
      CrossValidationCheck(),
    ]);
    // 加载缓存并立即执行快速检查
    _loadCachedStatuses();
    _runQuickCheck();
  }

  void _loadCachedStatuses() {
    final cached = ScanCache.loadDiagnosticsStatus();
    if (cached != null && cached.isNotEmpty) {
      // 用缓存构造占位结果，以便快速展示上一次状态
      _results = cached.entries.map((e) {
        final check = _orchestrator.checks.firstWhere(
          (c) => c.checkId == e.key,
          orElse: () => _orchestrator.checks.first,
        );
        return DiagnosticResult(
          checkId: e.key,
          title: check.title,
          status: e.value,
        );
      }).toList();
    }
  }

  Future<void> _runQuickCheck() async {
    setState(() {
      _quickLoading = true;
      _error = null;
    });
    try {
      final results = await _orchestrator.runQuickCheck();
      if (!mounted) return;
      setState(() => _results = results);
      _saveCache();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '快速检查失败：$e');
    } finally {
      if (mounted) setState(() => _quickLoading = false);
    }
  }

  Future<void> _runFullScan() async {
    setState(() {
      _fullLoading = true;
      _results = [];
      _error = null;
    });
    try {
      await for (final result in _orchestrator.runFullScan()) {
        if (!mounted) return;
        setState(() {
          _results.removeWhere((r) => r.checkId == result.checkId);
          _results.add(result);
        });
      }
      _saveCache();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '深度扫描失败：$e');
    } finally {
      if (mounted) setState(() => _fullLoading = false);
    }
  }

  void _saveCache() {
    final map = <String, DiagnosticStatus>{};
    for (final r in _results) {
      map[r.checkId] = r.status;
    }
    ScanCache.saveDiagnosticsStatus(map);
  }

  Future<void> _testMirrors() async {
    setState(() {
      _mirrorLoading = true;
      _mirrorResults = [];
      _googleReachable = null;
      _currentMirror = null;
    });
    try {
      final results = await _networkCheck.testMirrors();
      final googleOk = await _networkCheck.testGoogleSdk();
      final current = _networkCheck.readCurrentMirror();
      if (!mounted) return;
      setState(() {
        _mirrorResults = results;
        _googleReachable = googleOk;
        _currentMirror = current;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '镜像测试失败：$e');
    } finally {
      if (mounted) setState(() => _mirrorLoading = false);
    }
  }

  Future<void> _applyMirror(MirrorSource mirror) async {
    try {
      await _networkCheck.applyMirror(mirror);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已切换到 ${mirror.name} 镜像源'),
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        ),
      );
      setState(() => _currentMirror = mirror.name);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('应用镜像失败：$e'),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  Future<void> _executeFix(FixAction fix) async {
    if (fix.risk == FixRisk.risky) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认操作'),
          content: Text('即将执行：${fix.label}\n\n此操作可能影响系统配置，确认继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认执行'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      await fix.execute();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已执行：${fix.label}'),
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        ),
      );
      // 修复后重新检查
      await _runQuickCheck();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('执行失败：$e'),
          backgroundColor: Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  void _navigateToTab(String? tabId) {
    if (tabId == null) return;
    widget.onNavigateTab?.call(tabId);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final errorResults =
        _results.where((r) => r.status == DiagnosticStatus.error).toList();
    final warningResults =
        _results.where((r) => r.status == DiagnosticStatus.warning).toList();
    final okResults =
        _results.where((r) => r.status == DiagnosticStatus.ok).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部标题栏
          SectionHeader(
            icon: Icons.health_and_safety_outlined,
            title: '环境诊断',
            trailing: _results.isNotEmpty
                ? '${errorResults.length} 错误 · ${warningResults.length} 警告 · ${okResults.length} 正常'
                : null,
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _quickLoading ? null : _runQuickCheck,
                  icon: _quickLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.bolt, size: 18),
                  label: const Text('快速检查'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _fullLoading ? null : _runFullScan,
                  icon: _fullLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.radar, size: 18),
                  label: const Text('深度扫描'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 错误提示
          if (_error != null) ...[
            ErrorPanel(message: _error!),
          ],

          // 内容区域
          Expanded(
            child: _results.isEmpty && !_quickLoading
                ? const EmptyPanel(hint: '正在准备诊断…')
                : ListView(
                    children: [
                      // 错误区
                      if (errorResults.isNotEmpty) ...[
                        _buildSectionLabel(
                          context,
                          icon: Icons.error_outline,
                          title: '错误',
                          color: colorScheme.error,
                          count: errorResults.length,
                        ),
                        for (final r in errorResults) _buildResultCard(r),
                        const SizedBox(height: 12),
                      ],
                      // 警告区
                      if (warningResults.isNotEmpty) ...[
                        _buildSectionLabel(
                          context,
                          icon: Icons.warning_amber_rounded,
                          title: '警告',
                          color: colorScheme.tertiary,
                          count: warningResults.length,
                        ),
                        for (final r in warningResults) _buildResultCard(r),
                        const SizedBox(height: 12),
                      ],
                      // 正常区
                      if (okResults.isNotEmpty) ...[
                        _buildSectionLabel(
                          context,
                          icon: Icons.check_circle_outline,
                          title: '正常',
                          color: Colors.green,
                          count: okResults.length,
                        ),
                        for (final r in okResults) _buildOkTile(r),
                        const SizedBox(height: 12),
                      ],

                      // 网络 / 镜像区
                      _buildNetworkSection(),

                      const SizedBox(height: 24),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ── 区域标题 ──

  Widget _buildSectionLabel(
    BuildContext context, {
    required IconData icon,
    required String title,
    required Color color,
    required int count,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 错误/警告结果卡片 ──

  Widget _buildResultCard(DiagnosticResult result) {
    final colorScheme = Theme.of(context).colorScheme;
    final isError = result.status == DiagnosticStatus.error;
    final cardColor = isError
        ? colorScheme.errorContainer.withValues(alpha: 0.35)
        : colorScheme.tertiaryContainer.withValues(alpha: 0.35);
    final borderColor = isError
        ? colorScheme.error.withValues(alpha: 0.3)
        : colorScheme.tertiary.withValues(alpha: 0.3);
    final iconColor = isError ? colorScheme.error : colorScheme.tertiary;

    final isExpanded = _expanded[result.checkId] ?? true;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: cardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () =>
            setState(() => _expanded[result.checkId] = !isExpanded),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题行
              Row(
                children: [
                  Icon(
                    isError
                        ? Icons.error_outline
                        : Icons.warning_amber_rounded,
                    size: 20,
                    color: iconColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                  // 跳转按钮
                  if (result.relatedTabId != null)
                    TextButton.icon(
                      onPressed: () => _navigateToTab(result.relatedTabId),
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text('前往处理'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  const SizedBox(width: 4),
                  Icon(
                    isExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 20,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),

              // 展开的 issue 列表
              if (isExpanded && result.issues.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final issue in result.issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: issue.severity == IssueSeverity.error
                                ? colorScheme.error
                                : issue.severity == IssueSeverity.warning
                                    ? colorScheme.tertiary
                                    : colorScheme.outline,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                issue.message,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(height: 1.4),
                              ),
                              if (issue.fix != null) ...[
                                const SizedBox(height: 6),
                                _buildFixButton(issue.fix!),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── 修复按钮 ──

  Widget _buildFixButton(FixAction fix) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSafe = fix.risk == FixRisk.safe;

    return SizedBox(
      height: 30,
      child: OutlinedButton.icon(
        onPressed: () => _executeFix(fix),
        icon: Icon(
          isSafe ? Icons.build_outlined : Icons.warning_amber_rounded,
          size: 15,
          color: isSafe ? colorScheme.primary : colorScheme.error,
        ),
        label: Text(
          fix.label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: isSafe ? colorScheme.primary : colorScheme.error,
              ),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          side: BorderSide(
            color: isSafe
                ? colorScheme.primary.withValues(alpha: 0.4)
                : colorScheme.error.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  // ── 正常结果 tile ──

  Widget _buildOkTile(DiagnosticResult result) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.check_circle_outline,
                size: 18, color: Colors.green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                result.title,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '正常',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Colors.green,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 网络 / 镜像区 ──

  Widget _buildNetworkSection() {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行
            Row(
              children: [
                Icon(Icons.wifi_tethering_outlined,
                    size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('网络与镜像源',
                    style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: _mirrorLoading ? null : _testMirrors,
                  icon: _mirrorLoading
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed, size: 16),
                  label: const Text('测试镜像'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),

            // 当前镜像源
            if (_currentMirror != null) ...[
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer
                      .withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check,
                        size: 16, color: colorScheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      '当前镜像：$_currentMirror',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurface,
                          ),
                    ),
                  ],
                ),
              ),
            ],

            // Google SDK 状态
            if (_googleReachable != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    _googleReachable!
                        ? Icons.check_circle_outline
                        : Icons.cancel_outlined,
                    size: 16,
                    color:
                        _googleReachable! ? Colors.green : colorScheme.error,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Google SDK 服务器：${_googleReachable! ? "可达" : "不可达"}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _googleReachable!
                              ? Colors.green
                              : colorScheme.error,
                        ),
                  ),
                ],
              ),
            ],

            // 镜像源列表
            if (_mirrorResults.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final mr in _mirrorResults)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      // 状态指示
                      Icon(
                        mr.reachable
                            ? Icons.check_circle_outline
                            : Icons.cancel_outlined,
                        size: 16,
                        color: mr.reachable
                            ? Colors.green
                            : colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      // 名称
                      SizedBox(
                        width: 64,
                        child: Text(
                          mr.source.name,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 延迟
                      SizedBox(
                        width: 60,
                        child: Text(
                          mr.reachable ? '${mr.latencyMs}ms' : '超时',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'Consolas',
                                color: mr.reachable
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.error,
                              ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 主机名
                      Expanded(
                        child: Text(
                          mr.source.host,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'Consolas',
                                color: colorScheme.onSurfaceVariant,
                              ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 应用按钮
                      if (mr.reachable &&
                          _currentMirror != mr.source.name) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () => _applyMirror(mr.source),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('应用'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
