import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class InstallTab extends StatefulWidget {
  const InstallTab({super.key, this.onNavigateTab});

  final void Function(String tabId)? onNavigateTab;

  @override
  State<InstallTab> createState() => _InstallTabState();
}

class _InstallTabState extends State<InstallTab> {
  final _detector = AndroidStudioDetector();

  bool _loading = false;
  bool _deepScan = false;
  AndroidStudioDetectionResult? _result;
  ScanProgress? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _result = ScanCache.loadInstall();
  }

  Future<void> _runDetect() async {
    setState(() {
      _loading = true;
      _progress = const ScanProgress(percent: 0, message: '正在启动检测…');
      _error = null;
    });

    try {
      final result = await _detector.detectAll(
        deepScan: _deepScan,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _progress = const ScanProgress(percent: 100, message: '检测完成');
      });
      ScanCache.saveInstall(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final installCount = _result?.installs.length ?? 0;
    final residueCount = _result?.residues.length ?? 0;
    String? trailing;
    if (_result != null) {
      final parts = <String>[];
      if (installCount > 0) parts.add('$installCount 个安装');
      if (residueCount > 0) parts.add('$residueCount 处残留');
      if (parts.isNotEmpty) trailing = parts.join(' · ');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.desktop_windows_outlined,
            title: '安装检测',
            trailing: trailing,
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Tooltip(
                  message: '全盘搜索 studio.exe，可能需要数分钟',
                  child: FilterChip(
                    label: const Text('深度扫描'),
                    selected: _deepScan,
                    onSelected: _loading
                        ? null
                        : (value) => setState(() => _deepScan = value),
                  ),
                ),
                const SizedBox(width: 8),
                ActionButton(
                  label: _result != null ? '重新检测' : '开始检测',
                  icon: Icons.refresh,
                  loading: _loading,
                  onPressed: _loading ? null : _runDetect,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_loading && _progress != null)
            ProgressPanel(progress: _progress!),
          if (_error != null) ErrorPanel(message: _error!),
          Expanded(child: _buildResult()),
        ],
      ),
    );
  }

  Widget _buildResult() {
    if (_result == null && !_loading) {
      return const EmptyPanel(
        hint: '点击右上角「开始检测」查找已安装的 Android Studio 与卸载残留',
      );
    }

    if (_result == null) return const SizedBox.shrink();

    if (!_result!.hasInstalls && !_result!.hasResidues) {
      return EmptyPanel(
        title: '还没有安装？',
        hint: '本机未检测到 Android Studio',
        actionLabel: '去安装',
        actionIcon: Icons.download_outlined,
        onAction: () => widget.onNavigateTab?.call('download'),
      );
    }

    return ListView(
      children: [
        if (_result!.hasInstalls) ...[
          _SectionLabel(
            title: '有效安装',
            subtitle: '本机仍可识别的 Android Studio',
            count: _result!.installs.length,
          ),
          for (var i = 0; i < _result!.installs.length; i++)
            _InstallCard(
              index: i + 1,
              install: _result!.installs[i],
              isSelected: identical(_result!.selected, _result!.installs[i]) ||
                  (_result!.selected?.path == _result!.installs[i].path),
              selectionReason: _result!.selectionReason,
            ),
        ],
        if (_result!.hasResidues) ...[
          if (_result!.hasInstalls) const SizedBox(height: 8),
          _SectionLabel(
            title: '卸载残留',
            subtitle: '无法关联到有效安装的注册表项或运行时配置',
            count: _result!.residues.length,
            emphasize: true,
          ),
          for (var i = 0; i < _result!.residues.length; i++)
            _ResidueCard(index: i + 1, residue: _result!.residues[i]),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.title,
    required this.subtitle,
    required this.count,
    this.emphasize = false,
  });

  final String title;
  final String subtitle;
  final int count;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Row(
        children: [
          Icon(
            emphasize ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 18,
            color: emphasize ? colorScheme.error : colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title（$count）',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: emphasize ? colorScheme.error : null,
                      ),
                ),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InstallCard extends StatelessWidget {
  const _InstallCard({
    required this.index,
    required this.install,
    required this.isSelected,
    this.selectionReason,
  });

  final int index;
  final AndroidStudioInstall install;
  final bool isSelected;
  final AndroidStudioSelectionReason? selectionReason;

  bool get _androidHomeActive {
    if (install.sdkPath.isEmpty) return false;
    final sdk = _normalizeWindowsPath(install.sdkPath);
    for (final key in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final value = Platform.environment[key];
      if (value == null || value.trim().isEmpty) continue;
      if (_normalizeWindowsPath(value) == sdk) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final sources =
        install.source.split('；').where((s) => s.trim().isNotEmpty).toList();
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '[$index] ${install.name.isEmpty ? 'Android Studio' : install.name}',
                    style: Theme.of(context).textTheme.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_androidHomeActive) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'ANDROID_HOME',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
                if (isSelected) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.star, color: Colors.amber, size: 20),
                  if (selectionReason != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      selectionReason!.label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ],
              ],
            ),
            const SizedBox(height: 10),
            InfoChipRow(label: '安装路径', value: install.path),
            InfoChipRow(label: '版本', value: install.version),
            InfoChipRow(label: '构建号', value: install.build),
            if (install.channel.isNotEmpty)
              InfoChipRow(label: '渠道', value: install.channel),
            if (install.dataDirectoryName.isNotEmpty)
              InfoChipRow(label: '数据目录', value: install.dataDirectoryName),
            if (install.sdkPath.isNotEmpty)
              InfoChipRow(label: 'SDK 路径', value: install.sdkPath),
            if (sources.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '检测来源',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: sources
                    .map((source) => _SourceChip(label: source.trim()))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _normalizeWindowsPath(String path) {
  var normalized = path.trim().replaceAll('/', r'\');
  while (normalized.endsWith(r'\') && normalized.length > 3) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.toLowerCase();
}

class _ResidueCard extends StatelessWidget {
  const _ResidueCard({
    required this.index,
    required this.residue,
  });

  final int index;
  final AndroidStudioResidue residue;

  Future<void> _copy(String value) async {
    if (value.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: colorScheme.errorContainer.withValues(alpha: 0.25),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.delete_forever_outlined,
                    size: 18, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '[$index] ${residue.name}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colorScheme.error,
                        ),
                  ),
                ),
                Text(
                  residue.kindLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colorScheme.error,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              residue.reason,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 10),
            if (residue.path.isNotEmpty)
              InfoChipRow(label: '原安装路径', value: residue.path),
            if (residue.version.isNotEmpty)
              InfoChipRow(label: '登记版本', value: residue.version),
            if (residue.registryKey.isNotEmpty) ...[
              InfoChipRow(label: '注册表键', value: residue.registryKey),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () async {
                    await _copy(residue.registryKey);
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制注册表路径')),
                    );
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('复制注册表路径'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceChip extends StatelessWidget {
  const _SourceChip({required this.label});

  final String label;
  bool get _isRunning => label.contains('运行中进程');

  @override
  Widget build(BuildContext context) {
    if (_isRunning) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.green.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.green.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_fill, size: 14, color: Colors.green.shade700),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
