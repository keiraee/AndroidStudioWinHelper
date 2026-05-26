import 'dart:io';

import 'package:flutter/services.dart';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/data_dir_scanner.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/studio_version_service.dart';
import 'package:flutter/material.dart';

Future<void> _openInExplorer(String path) async {
  await Process.start('explorer', [path]);
}

Future<void> _openUrl(String url) async {
  await Process.start('cmd', ['/c', 'start', '', url]);
}

enum _PageTab { install, storage, download }

class DetectPage extends StatefulWidget {
  const DetectPage({super.key});

  @override
  State<DetectPage> createState() => _DetectPageState();
}

class _DetectPageState extends State<DetectPage> {
  final _detector = AndroidStudioDetector();
  final _dataScanner = DataDirScanner();

  _PageTab _activeTab = _PageTab.install;

  bool _installLoading = false;
  bool _storageLoading = false;
  bool _versionLoading = false;
  AndroidStudioDetectionResult? _installResult;
  DataDirScanResult? _storageResult;
  List<StudioVersion>? _versionResult;
  String? _selectedChannel; // null = all
  ScanProgress? _installProgress;
  ScanProgress? _storageProgress;
  ScanProgress? _versionProgress;
  String? _error;

  final _versionService = StudioVersionService();

  bool get _hasCache => _storageResult != null;

  @override
  void initState() {
    super.initState();
    _storageResult = ScanCache.load();
    _installResult = ScanCache.loadInstall();
    _versionResult = ScanCache.loadVersions();
  }

  Future<void> _runInstallDetect() async {
    setState(() {
      _installLoading = true;
      _installProgress = const ScanProgress(percent: 0, message: '正在启动检测…');
      _error = null;
    });

    try {
      final result = await _detector.detectAll(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _installProgress = progress);
        },
      );
      setState(() {
        _installResult = result;
        _installProgress = const ScanProgress(percent: 100, message: '检测完成');
      });
      ScanCache.saveInstall(result);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _installLoading = false);
    }
  }

  Future<void> _runStorageScan() async {
    setState(() {
      _storageLoading = true;
      _storageProgress = const ScanProgress(percent: 0, message: '准备开始…');
      _error = null;
      // 不清空 _storageResult，保留旧缓存数据继续展示
    });

    try {
      final result = await _dataScanner.scanAll(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _storageProgress = progress);
        },
      );
      setState(() {
        _storageResult = result;
        _storageProgress = const ScanProgress(percent: 100, message: '扫描完成');
      });
      ScanCache.save(result);
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _storageLoading = false);
    }
  }

  Future<void> _fetchVersions() async {
    setState(() {
      _versionLoading = true;
      _versionProgress = const ScanProgress(percent: 0, message: '正在获取版本列表…');
      _error = null;
    });

    try {
      final versions = await _versionService.fetchVersions();
      if (!mounted) return;
      setState(() {
        _versionResult = versions;
        _versionProgress = const ScanProgress(percent: 100, message: '获取完成');
      });
      ScanCache.saveVersions(versions);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _versionLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('androidstudiowinhelper'),
        centerTitle: false,
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
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: switch (_activeTab) {
              _PageTab.install => _buildInstallTab(),
              _PageTab.storage => _buildStorageTab(),
              _PageTab.download => _buildDownloadTab(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInstallTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            icon: Icons.desktop_windows_outlined,
            title: '安装检测',
            trailing: _installResult != null && _installResult!.hasInstalls
                ? '${_installResult!.installs.length} 个安装'
                : null,
            action: _ActionButton(
              label: _installResult != null ? '重新检测' : '开始检测',
              icon: Icons.refresh,
              loading: _installLoading,
              onPressed: _installLoading ? null : _runInstallDetect,
            ),
          ),
          const SizedBox(height: 16),
          if (_installLoading && _installProgress != null)
            _ProgressPanel(progress: _installProgress!),
          if (_error != null)
            _ErrorPanel(message: _error!),
          Expanded(
            child: _buildInstallResult(),
          ),
        ],
      ),
    );
  }

  Widget _buildStorageTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            icon: Icons.pie_chart_outline,
            title: '目录占用报告',
            trailing: _storageResult != null
                ? '${_storageResult!.foundCount} 项目 · ${_storageResult!.totalSizeHuman}'
                : null,
            action: _ActionButton(
              label: _hasCache ? '重新扫描' : '开始扫描',
              icon: Icons.refresh,
              loading: _storageLoading,
              onPressed: _storageLoading ? null : _runStorageScan,
            ),
          ),
          const SizedBox(height: 16),
          if (_storageLoading && _storageProgress != null)
            _ProgressPanel(progress: _storageProgress!),
          if (_error != null)
            _ErrorPanel(message: _error!),
          Expanded(
            child: _buildStorageResult(),
          ),
        ],
      ),
    );
  }

  Widget _buildInstallResult() {
    if (_installResult == null && !_installLoading) {
      return const _EmptyPanel(
        hint: '点击右上角「开始检测」查找已安装的 Android Studio',
      );
    }

    if (_installResult == null) return const SizedBox.shrink();

    if (!_installResult!.hasInstalls) {
      return const _EmptyPanel(hint: '未检测到 Android Studio 安装。');
    }

    return ListView(
      children: [
        for (var i = 0; i < _installResult!.installs.length; i++)
          _InstallCard(
            index: i + 1,
            install: _installResult!.installs[i],
            isSelected:
                _installResult!.selected == _installResult!.installs[i],
          ),
      ],
    );
  }

  Widget _buildStorageResult() {
    if (_storageResult == null && !_storageLoading) {
      return const _EmptyPanel(
        hint: '点击右上角「开始扫描」分析磁盘占用情况',
      );
    }

    if (_storageResult == null) return const SizedBox.shrink();

    if (_storageResult!.entries.isEmpty) {
      return const _EmptyPanel(hint: '未找到相关目录。');
    }

    final visibleEntries = _storageResult!.sortedEntries
        .where((e) => Directory(e.path).existsSync())
        .toList();

    if (visibleEntries.isEmpty) {
      return const _EmptyPanel(hint: '未找到相关目录。');
    }

    return ListView(
      children: [
        for (final entry in visibleEntries)
          _StorageEntryTile(entry: entry),
      ],
    );
  }

  Widget _buildDownloadTab() {
    final channels = <String>[];
    final seen = <String>{};
    if (_versionResult != null) {
      for (final v in _versionResult!) {
        if (seen.add(v.channel)) {
          channels.add(v.channel);
        }
      }
    }

    final filtered = _versionResult
        ?.where((v) =>
            _selectedChannel == null || v.channel == _selectedChannel)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            icon: Icons.download_outlined,
            title: '版本下载',
            trailing: _versionResult != null
                ? '${_versionResult!.length} 个版本'
                : null,
            action: _ActionButton(
              label: _versionResult != null ? '重新获取' : '获取版本',
              icon: Icons.refresh,
              loading: _versionLoading,
              onPressed: _versionLoading ? null : _fetchVersions,
            ),
          ),
          const SizedBox(height: 12),
          if (channels.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      children: [
                        FilterChip(
                          label: const Text('全部'),
                          selected: _selectedChannel == null,
                          onSelected: (_) =>
                              setState(() => _selectedChannel = null),
                        ),
                        for (final ch in channels)
                          FilterChip(
                            label: Text(_channelDisplayName(ch)),
                            selected: _selectedChannel == ch,
                            onSelected: (sel) => setState(() =>
                                _selectedChannel = sel ? ch : null),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _openUrl(
                          'https://developer.android.google.cn/studio/archive?hl=zh-cn',
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history,
                                  size: 16,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary),
                              const SizedBox(width: 6),
                              Text(
                                '历史版本归档',
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary,
                                    ),
                              ),
                              const SizedBox(width: 4),
                              Icon(Icons.open_in_new,
                                  size: 14,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.6)),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 10, top: 2),
                        child: Text(
                          '仅近期版本，更多请访问归档',
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.4),
                              ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_versionLoading && _versionProgress != null)
            _ProgressPanel(progress: _versionProgress!),
          if (_error != null) _ErrorPanel(message: _error!),
          Expanded(
            child: _versionResult == null && !_versionLoading
                ? const _EmptyPanel(
                    hint: '点击右上角「获取版本」获取 Android Studio 官方版本列表',
                  )
                : filtered == null || filtered.isEmpty
                    ? const _EmptyPanel(hint: '该渠道暂无版本。')
                    : ListView(
                        children: [
                          for (final v in filtered) _VersionCard(version: v),
                        ],
                      ),
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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

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
              if (selected)
                Icon(Icons.chevron_right, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.loading,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: onPressed,
      icon: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : Icon(icon, size: 18),
      label: Text(loading ? '进行中…' : label),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    this.trailing,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String? trailing;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          Text(
            trailing!,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
        const Spacer(),
        action,
      ],
    );
  }
}

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({required this.progress});

  final ScanProgress progress;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final value = progress.percent / 100;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colorScheme.primary.withValues(alpha: 0.25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  progress.percent >= 100 ? '已完成' : '扫描中',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                Text(
                  '${progress.percent}%',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: colorScheme.primary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: value),
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              builder: (context, animatedValue, child) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: animatedValue.clamp(0, 1),
                    minHeight: 10,
                    backgroundColor: colorScheme.surface,
                  ),
                );
              },
            ),
            const SizedBox(height: 14),
            Text(progress.message, style: Theme.of(context).textTheme.bodyLarge),
            if (progress.path.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  progress.path,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'Consolas',
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.travel_explore,
            size: 56,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text(
            hint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
        ),
      ),
    );
  }
}

class _InstallCard extends StatelessWidget {
  const _InstallCard({
    required this.index,
    required this.install,
    required this.isSelected,
  });

  final int index;
  final AndroidStudioInstall install;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final sources = install.source.split('；').where((s) => s.trim().isNotEmpty).toList();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '[$index] ${install.name.isEmpty ? 'Android Studio' : install.name}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (isSelected) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.star, color: Colors.amber, size: 20),
                ],
              ],
            ),
            const SizedBox(height: 10),
            _InfoChipRow(label: '安装路径', value: install.path),
            _InfoChipRow(label: '版本', value: install.version),
            _InfoChipRow(label: '构建号', value: install.build),
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
                children: sources.map((source) => _SourceChip(label: source.trim())).toList(),
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

class _StorageEntryTile extends StatelessWidget {
  const _StorageEntryTile({required this.entry});

  final DataDirEntry entry;
  static const _sizeWidth = 80.0;
  static const _actionWidth = 28.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _CategoryIcon(category: entry.category),
        title: Row(
          children: [
            Flexible(
              child: Text(entry.label, style: textTheme.titleSmall),
            ),
            if (entry.isActive && entry.activeSource.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Text(
                  entry.activeSource,
                  style: textTheme.labelSmall?.copyWith(
                    fontFamily: 'Consolas',
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(
          entry.path,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall?.copyWith(
            fontFamily: 'Consolas',
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Text(
          entry.exists ? entry.sizeHuman : '—',
          style: textTheme.labelLarge?.copyWith(
            color: entry.exists ? colorScheme.primary : colorScheme.onSurfaceVariant,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.path.isNotEmpty && Directory(entry.path).existsSync())
                  _OpenFolderRow(path: entry.path),
                if (entry.notes.isNotEmpty)
                  _InfoRow(label: '说明', value: entry.notes),
                if (entry.subEntries.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '子目录',
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  for (final sub in entry.subEntries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          if (sub.path.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: _CopyButton(value: sub.path),
                            ),
                          Flexible(child: Text(sub.name)),
                          SizedBox(
                            width: _sizeWidth,
                            child: Text(
                              sub.exists ? sub.sizeHuman : '—',
                              textAlign: TextAlign.right,
                              style: textTheme.labelMedium?.copyWith(
                                color: sub.exists ? null : colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: _actionWidth,
                            child: sub.path.isNotEmpty && Directory(sub.path).existsSync()
                                ? _FolderButton(onTap: () => _openInExplorer(sub.path))
                                : null,
                          ),
                        ],
                      ),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OpenFolderRow extends StatelessWidget {
  const _OpenFolderRow({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _openInExplorer(path),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.folder_outlined, size: 18,
                  color: colorScheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(
                    fontFamily: 'Consolas',
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.open_in_new, size: 16, color: colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderButton extends StatelessWidget {
  const _FolderButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '打开文件夹',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            Icons.folder_open,
            size: 16,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}

class _CategoryIcon extends StatelessWidget {
  const _CategoryIcon({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final icon = switch (category) {
      'config' => Icons.settings_outlined,
      'cache' => Icons.storage_outlined,
      'log' => Icons.article_outlined,
      'android' => Icons.android,
      'gradle' => Icons.build_outlined,
      'sdk' => Icons.developer_mode,
      _ => Icons.folder_outlined,
    };

    return Icon(icon, color: Theme.of(context).colorScheme.primary);
  }
}

class _InfoChipRow extends StatelessWidget {
  const _InfoChipRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'Consolas',
                    height: 1.4,
                  ),
            ),
          ),
          const SizedBox(width: 6),
          _CopyButton(value: value),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.value});

  final String value;

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已复制'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        width: 120,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _copy(context),
        child: Icon(
          Icons.copy,
          size: 16,
          color: Theme.of(context)
              .colorScheme
              .onSurfaceVariant
              .withValues(alpha: 0.45),
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          SelectableText(value),
        ],
      ),
    );
  }
}

String _channelDisplayName(String channel) => switch (channel) {
      'release' => 'Stable',
      'beta' => 'Beta',
      'eap' => 'Canary',
      'milestone' => 'Dev',
      'archive' => '历史',
      _ => channel,
    };

class _VersionCard extends StatelessWidget {
  const _VersionCard({required this.version});

  final StudioVersion version;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Icon(
          switch (version.channel) {
            'release' => Icons.check_circle_outline,
            'beta' => Icons.science_outlined,
            'eap' => Icons.flash_on_outlined,
            'archive' => Icons.history,
            _ => Icons.build_circle_outlined,
          },
          color: switch (version.channel) {
            'release' => Colors.green,
            'beta' => Colors.orange,
            'eap' => Colors.deepPurple,
            'archive' => Colors.blueGrey,
            _ => colorScheme.primary,
          },
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                version.codename.isEmpty ? version.version : version.codename,
                style: textTheme.titleSmall,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: colorScheme.outlineVariant),
              ),
              child: Text(
                version.channelLabel,
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFamily: 'Consolas',
                ),
              ),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              version.version,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              version.buildNumber,
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'Consolas',
                fontSize: 11,
                color: colorScheme.outline,
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (version.releaseNotes.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: colorScheme.surfaceContainerLow,
                      child: Text(
                        version.releaseNotes,
                        maxLines: 8,
                        overflow: TextOverflow.fade,
                        style: textTheme.bodySmall?.copyWith(height: 1.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (version.downloadUrl.isNotEmpty)
                  FilledButton.icon(
                    onPressed: () => _openUrl(version.downloadUrl),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('下载安装包'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
