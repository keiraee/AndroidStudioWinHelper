import 'dart:io';

import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/data_dir_scanner.dart';
import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class StorageTab extends StatefulWidget {
  const StorageTab({super.key});

  @override
  State<StorageTab> createState() => _StorageTabState();
}

class _StorageTabState extends State<StorageTab> {
  final _dataScanner = DataDirScanner();

  bool _loading = false;
  DataDirScanResult? _result;
  ScanProgress? _progress;
  String? _error;

  bool get _hasCache => _result != null;

  @override
  void initState() {
    super.initState();
    _result = ScanCache.load();
  }

  Future<void> _runScan() async {
    setState(() {
      _loading = true;
      _progress = const ScanProgress(percent: 0, message: '准备开始…');
      _error = null;
    });

    try {
      final result = await _dataScanner.scanAll(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _progress = const ScanProgress(percent: 100, message: '扫描完成');
      });
      ScanCache.save(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.pie_chart_outline,
            title: '目录占用报告',
            trailing: _result != null
                ? '${_result!.foundCount} 项目 · ${_result!.totalSizeHuman}'
                : null,
            action: ActionButton(
              label: _hasCache ? '重新扫描' : '开始扫描',
              icon: Icons.refresh,
              loading: _loading,
              onPressed: _loading ? null : _runScan,
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
        hint: '点击右上角「开始扫描」分析磁盘占用情况',
      );
    }

    if (_result == null) return const SizedBox.shrink();

    if (_result!.entries.isEmpty) {
      return const EmptyPanel(hint: '未找到相关目录。');
    }

    final visibleEntries = _result!.sortedEntries
        .where((e) => Directory(e.path).existsSync())
        .toList();

    if (visibleEntries.isEmpty) {
      return const EmptyPanel(hint: '未找到相关目录。');
    }

    return ListView(
      children: [
        for (final entry in visibleEntries)
          _StorageEntryTile(entry: entry),
      ],
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
                  OpenFolderRow(path: entry.path),
                if (entry.notes.isNotEmpty)
                  InfoRow(label: '说明', value: entry.notes),
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
                              child: CopyButton(value: sub.path),
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
                                ? FolderButton(onTap: () => openInExplorer(sub.path))
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
