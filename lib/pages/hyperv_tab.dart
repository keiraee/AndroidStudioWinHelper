import 'dart:io';

import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/emulator_check_manager.dart';
import 'package:androidstudiowinhelper/core/hyperv_manager.dart';
import 'package:androidstudiowinhelper/core/models/emulator_check_result.dart';
import 'package:androidstudiowinhelper/core/models/hyperv_result.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class HyperVTab extends StatefulWidget {
  const HyperVTab({super.key});

  @override
  State<HyperVTab> createState() => _HyperVTabState();
}

class _HyperVTabState extends State<HyperVTab> {
  final _hypervManager = HypervManager();
  final _emuCheckManager = EmulatorCheckManager();

  bool _hypervLoading = false;
  bool _hypervToggling = false;
  bool _whpxToggling = false;
  bool _emuCheckLoading = false;
  HypervResult? _hypervResult;
  EmulatorCheckResult? _emuCheckResult;
  ScanProgress? _hypervProgress;
  ScanProgress? _hypervToggleProgress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHyperV();
    _runEmulatorCheck();
  }

  Future<void> _loadHyperV() async {
    setState(() {
      _hypervLoading = true;
      _hypervProgress = const ScanProgress(percent: 0, message: '正在启动检测…');
      _error = null;
    });

    try {
      final result = await _hypervManager.detect(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _hypervProgress = progress);
        },
      );
      setState(() {
        _hypervResult = result;
        _hypervProgress = const ScanProgress(percent: 100, message: '检测完成');
      });
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _hypervLoading = false);
    }
  }

  Future<void> _runEmulatorCheck() async {
    setState(() {
      _emuCheckLoading = true;
      _error = null;
    });

    try {
      final result = await _emuCheckManager.runChecks();
      if (!mounted) return;
      setState(() => _emuCheckResult = result);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _emuCheckLoading = false);
    }
  }

  Future<void> _toggleHyperV(bool enable) async {
    setState(() {
      _hypervToggling = true;
      _hypervToggleProgress = const ScanProgress(percent: 5, message: '准备中...');
      _error = null;
    });

    try {
      final result = await _hypervManager.toggle(
        enable: enable,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _hypervToggleProgress = progress);
        },
      );
      if (!mounted) return;

      if (result.success) {
        await _loadHyperV();
        if (!mounted) return;
        final hasFailed = result.details.contains('FAILED');
        if (hasFailed) {
          _showToggleResult(result);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message)),
          );
        }
      } else {
        _showToggleResult(result);
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _hypervToggling = false;
          _hypervToggleProgress = null;
        });
      }
    }
  }

  Future<void> _toggleWHPX(bool enable) async {
    setState(() {
      _whpxToggling = true;
      _error = null;
    });

    try {
      final features = enable
          ? ['VirtualMachinePlatform', 'HypervisorPlatform']
          : ['HypervisorPlatform', 'VirtualMachinePlatform'];

      var lastResult = await _hypervManager.toggleFeature(
        featureName: features[0],
        enable: enable,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _hypervToggleProgress = progress);
        },
      );

      if (!mounted) return;
      if (!lastResult.success) {
        _showToggleResult(lastResult);
        return;
      }

      if (features.length > 1) {
        lastResult = await _hypervManager.toggleFeature(
          featureName: features[1],
          enable: enable,
          onProgress: (progress) {
            if (!mounted) return;
            setState(() => _hypervToggleProgress = progress);
          },
        );
        if (!mounted) return;
      }

      if (lastResult.success) {
        await _loadHyperV();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(lastResult.message)),
        );
      } else {
        _showToggleResult(lastResult);
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _whpxToggling = false;
          _hypervToggleProgress = null;
        });
      }
    }
  }

  void _showToggleResult(HypervToggleResult result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(result.message),
        content: SingleChildScrollView(
          child: SelectableText(result.details.isNotEmpty ? result.details : '无详细信息'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _confirmRestart() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认重启'),
        content: const Text('系统将立即重启以使 Hyper-V 配置生效，未保存的数据可能会丢失。确定要重启吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Process.run('shutdown', ['/r', '/t', '0']);
            },
            child: const Text('立即重启'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.desktop_windows_outlined,
            title: '模拟器运行环境',
            trailing: _hypervResult?.osEdition,
            action: ActionButton(
              label: '全部重新检测',
              icon: Icons.refresh,
              loading: _hypervLoading || _emuCheckLoading,
              onPressed: (_hypervLoading || _emuCheckLoading)
                  ? null
                  : () { _loadHyperV(); _runEmulatorCheck(); },
            ),
          ),
          const SizedBox(height: 16),
          if (_hypervToggling && _hypervToggleProgress != null)
            ProgressPanel(progress: _hypervToggleProgress!),
          if (_hypervLoading && _hypervProgress != null)
            ProgressPanel(progress: _hypervProgress!),
          if (_error != null) ErrorPanel(message: _error!),
          Expanded(child: _buildResult()),
        ],
      ),
    );
  }

  Widget _buildResult() {
    if (_hypervResult == null && !_hypervLoading) {
      return const EmptyPanel(
        hint: '点击右上角「检测状态」查看 Hyper-V 各组件状态',
      );
    }

    if (_hypervResult == null) return const SizedBox.shrink();

    final result = _hypervResult!;

    return ListView(
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('系统版本：${result.osEdition}', style: Theme.of(context).textTheme.titleSmall),
                      if (result.isHomeEdition)
                        Text(
                          'Windows 家庭版 — 启用 Hyper-V 时会自动安装所需组件',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.tertiary,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('组件状态', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 12),
                for (final feature in result.features)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          feature.state == 'Enabled'
                              ? Icons.check_circle
                              : feature.state == 'EnablePending'
                                  ? Icons.hourglass_top
                                  : Icons.cancel_outlined,
                          size: 18,
                          color: feature.state == 'Enabled'
                              ? Colors.green
                              : feature.state == 'EnablePending'
                                  ? Colors.blue
                                  : Colors.orange,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(feature.label, style: Theme.of(context).textTheme.bodyMedium)),
                        Text(
                          feature.state == 'Enabled'
                              ? '已启用'
                              : feature.state == 'EnablePending'
                                  ? '待重启生效'
                                  : '已关闭',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: feature.state == 'Enabled'
                                    ? Colors.green
                                    : feature.state == 'EnablePending'
                                        ? Colors.blue
                                        : Colors.orange,
                              ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        _buildEmulatorCheckSection(),
        _buildOperationsCard(result),
      ],
    );
  }

  Widget _buildEmulatorCheckSection() {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_emuCheckLoading) {
      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text('正在检测系统环境...', style: textTheme.bodyMedium),
            ],
          ),
        ),
      );
    }

    final mergedResult = _buildMergedCheckResult();
    if (mergedResult == null) return const SizedBox.shrink();

    final groups = mergedResult.groupedByCategory;
    if (groups.isEmpty) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.checklist, size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Text('运行环境全面检测', style: textTheme.titleSmall),
                const Spacer(),
                if (mergedResult.warningCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      '${mergedResult.warningCount} 个问题',
                      style: textTheme.labelSmall?.copyWith(
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            for (final group in groups) ...[
              Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Row(
                  children: [
                    Icon(_categoryIcon(group.key), size: 16, color: colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Text(group.key, style: textTheme.labelLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    )),
                    const SizedBox(width: 8),
                    Expanded(child: Container(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.5))),
                  ],
                ),
              ),
              for (final check in group.value)
                _EmulatorCheckTile(check: check),
            ],
          ],
        ),
      ),
    );
  }

  IconData _categoryIcon(String category) => switch (category) {
        '硬件环境' => Icons.memory,
        '虚拟化配置' => Icons.dns_outlined,
        '模拟器配置' => Icons.phone_android,
        '软件环境' => Icons.apps,
        _ => Icons.checklist,
      };

  EmulatorCheckResult? _buildMergedCheckResult() {
    if (_emuCheckResult == null) return null;

    final merged = <EmulatorCheck>[];
    final hypervFeatureNames = <String>{};

    if (_hypervResult != null) {
      for (final f in _hypervResult!.features) {
        hypervFeatureNames.add(f.name);
        final (status, detail) = switch (f.state) {
          'Enabled' => ('ok', '已启用'),
          'EnablePending' => ('warning', '待重启生效'),
          _ => ('warning', '未启用'),
        };
        final suggestion = f.name == 'HypervisorPlatform' && f.state != 'Enabled'
            ? 'WHPX 让第三方模拟器通过标准 API 使用 Hyper-V 虚拟化能力，启用后模拟器可与 Hyper-V 共存'
            : '';
        merged.add(EmulatorCheck(
          name: f.name,
          category: '虚拟化配置',
          label: f.label,
          status: status,
          detail: detail,
          suggestion: suggestion,
        ));
      }
    }

    for (final check in _emuCheckResult!.checks) {
      if (check.name == 'virtual_machine_platform' || check.name == 'windows_sandbox') continue;
      if (check.name == 'system_ram' || check.name == 'disk_space') continue;
      merged.add(check);
    }

    return EmulatorCheckResult(checks: merged);
  }

  Widget _buildOperationsCard(HypervResult result) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final hypervFeatures = result.features
        .where((f) => f.name.startsWith('Microsoft-Hyper-V'))
        .toList();
    final hypervEnabled = hypervFeatures.isNotEmpty &&
        hypervFeatures.every((f) => f.state == 'Enabled' || f.state == 'EnablePending');

    final whpxFeature = result.features
        .where((f) => f.name == 'HypervisorPlatform')
        .firstOrNull;
    final whpxEnabled = whpxFeature?.state == 'Enabled' || whpxFeature?.state == 'EnablePending';

    final isToggling = _hypervToggling || _whpxToggling;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('操作', style: textTheme.titleSmall),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.dns_outlined, size: 18, color: hypervEnabled ? Colors.green : colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text('Hyper-V', style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (hypervEnabled ? Colors.green : colorScheme.outline).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    hypervEnabled ? '已启用' : '已关闭',
                    style: textTheme.labelSmall?.copyWith(
                      color: hypervEnabled ? Colors.green : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('用于运行 WSL2、Docker Desktop 等基于 Hyper-V 的服务',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (hypervEnabled)
              OutlinedButton.icon(
                onPressed: isToggling ? null : () => _toggleHyperV(false),
                icon: isToggling
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('关闭 Hyper-V'),
              )
            else
              FilledButton.icon(
                onPressed: isToggling ? null : () => _toggleHyperV(true),
                icon: isToggling
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_circle_outlined, size: 18),
                label: const Text('启用 Hyper-V'),
              ),
            const SizedBox(height: 20),
            Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(Icons.phone_android, size: 18, color: whpxEnabled ? Colors.green : colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text('WHPX (Hypervisor Platform)', style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: (whpxEnabled ? Colors.green : colorScheme.outline).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    whpxEnabled ? '已启用' : '已关闭',
                    style: textTheme.labelSmall?.copyWith(
                      color: whpxEnabled ? Colors.green : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text('让 Android 模拟器通过标准 API 使用 Hyper-V 虚拟化能力，实现与 Hyper-V 共存',
                style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            if (whpxEnabled)
              OutlinedButton.icon(
                onPressed: isToggling ? null : () => _toggleWHPX(false),
                icon: isToggling
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.stop_circle_outlined, size: 18),
                label: const Text('关闭 WHPX'),
              )
            else
              FilledButton.icon(
                onPressed: isToggling ? null : () => _toggleWHPX(true),
                icon: isToggling
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_circle_outlined, size: 18),
                label: const Text('启用 WHPX'),
              ),
            const SizedBox(height: 20),
            Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Hyper-V 与 WHPX 的关系', style: textTheme.labelLarge),
                  const SizedBox(height: 6),
                  Text(
                    '• 两者独立控制，可单独开关\n'
                    '• Hyper-V 是底层虚拟化平台，WHPX 是它的访问接口\n'
                    '• 想用 Android 模拟器 + Hyper-V 共存 → 两者都开\n'
                    '• 想用 VirtualBox/VMware → 两者都关\n'
                    '• 只用 WSL/Docker 不用模拟器 → 只开 Hyper-V，不开 WHPX',
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.6),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.restart_alt, size: 18, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(child: Text('开启或关闭后必须重启计算机才能生效。', style: textTheme.bodySmall)),
                OutlinedButton.icon(
                  onPressed: _confirmRestart,
                  icon: const Icon(Icons.restart_alt, size: 18),
                  label: const Text('立即重启'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmulatorCheckTile extends StatefulWidget {
  const _EmulatorCheckTile({required this.check});

  final EmulatorCheck check;

  @override
  State<_EmulatorCheckTile> createState() => _EmulatorCheckTileState();
}

class _EmulatorCheckTileState extends State<_EmulatorCheckTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final check = widget.check;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final hasSuggestion = check.suggestion.isNotEmpty &&
        (check.status == 'warning' || check.status == 'error');

    IconData icon;
    Color iconColor;
    switch (check.status) {
      case 'ok':
        icon = Icons.check_circle;
        iconColor = Colors.green;
      case 'warning':
        icon = Icons.warning_amber_rounded;
        iconColor = Colors.orange;
      case 'error':
        icon = Icons.error_outline;
        iconColor = Colors.red;
      case 'info':
        icon = Icons.info_outline;
        iconColor = Colors.blue;
      default:
        icon = Icons.help_outline;
        iconColor = colorScheme.outline;
    }

    return InkWell(
      onTap: hasSuggestion ? () => setState(() => _expanded = !_expanded) : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(check.label, style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                      if (check.detail.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          check.detail,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            fontFamily: 'Consolas',
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (hasSuggestion)
                  Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: colorScheme.onSurfaceVariant),
              ],
            ),
            if (hasSuggestion && _expanded)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 6),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: iconColor.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    check.suggestion,
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant, height: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
