import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/data_dir_scanner.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:flutter/material.dart';

enum _PageTab { install, storage }

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
  AndroidStudioDetectionResult? _installResult;
  DataDirScanResult? _storageResult;
  ScanProgress? _installProgress;
  ScanProgress? _storageProgress;
  String? _error;

  Future<void> _runInstallDetect() async {
    setState(() {
      _installLoading = true;
      _error = null;
      _installResult = null;
      _installProgress = const ScanProgress(percent: 0, message: '正在启动检测…');
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
    } catch (error) {
      setState(() {
        _installResult = null;
        _error = error.toString();
      });
    } finally {
      setState(() => _installLoading = false);
    }
  }

  Future<void> _runStorageScan() async {
    setState(() {
      _storageLoading = true;
      _storageProgress = const ScanProgress(percent: 0, message: '准备开始…');
      _error = null;
      _storageResult = null;
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
    } catch (error) {
      setState(() {
        _storageResult = null;
        _error = error.toString();
      });
    } finally {
      setState(() => _storageLoading = false);
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
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: _activeTab == _PageTab.install
                ? _buildInstallTab()
                : _buildStorageTab(),
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
              label: '开始检测',
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
              label: '开始扫描',
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

    return ListView(
      children: [
        for (final entry in _storageResult!.sortedEntries)
          _StorageEntryTile(entry: entry),
      ],
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

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: _CategoryIcon(category: entry.category),
        title: Row(
          children: [
            Flexible(
              child: Text(
                entry.label,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (entry.isActive) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: Colors.green.withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  '使用中',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.green.shade700,
                        fontWeight: FontWeight.w600,
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
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontFamily: 'Consolas',
                color: colorScheme.onSurfaceVariant,
              ),
        ),
        trailing: Text(
          entry.exists ? entry.sizeHuman : '—',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: entry.exists
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
              ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entry.isActive && entry.activeSource.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle,
                            size: 16, color: Colors.green.shade600),
                        const SizedBox(width: 6),
                        Text(
                          '当前使用（来源：${entry.activeSource}）',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: Colors.green.shade700,
                                  ),
                        ),
                      ],
                    ),
                  ),
                if (entry.notes.isNotEmpty)
                  _InfoRow(label: '说明', value: entry.notes),
                if (entry.subEntries.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '子目录',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 6),
                  for (final sub in entry.subEntries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        children: [
                          Expanded(child: Text(sub.name)),
                          Text(
                            sub.sizeHuman,
                            style: Theme.of(context).textTheme.labelMedium,
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
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.2,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'Consolas',
                    height: 1.2,
                  ),
            ),
          ),
          const Spacer(),
        ],
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
