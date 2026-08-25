import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class InstallTab extends StatefulWidget {
  const InstallTab({super.key});

  @override
  State<InstallTab> createState() => _InstallTabState();
}

class _InstallTabState extends State<InstallTab> {
  final _detector = AndroidStudioDetector();

  bool _loading = false;
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.desktop_windows_outlined,
            title: '安装检测',
            trailing: _result != null && _result!.hasInstalls
                ? '${_result!.installs.length} 个安装'
                : null,
            action: ActionButton(
              label: _result != null ? '重新检测' : '开始检测',
              icon: Icons.refresh,
              loading: _loading,
              onPressed: _loading ? null : _runDetect,
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
        hint: '点击右上角「开始检测」查找已安装的 Android Studio',
      );
    }

    if (_result == null) return const SizedBox.shrink();

    if (!_result!.hasInstalls) {
      return const EmptyPanel(hint: '未检测到 Android Studio 安装。');
    }

    return ListView(
      children: [
        for (var i = 0; i < _result!.installs.length; i++)
          _InstallCard(
            index: i + 1,
            install: _result!.installs[i],
            isSelected: _result!.selected == _result!.installs[i],
          ),
      ],
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
            InfoChipRow(label: '安装路径', value: install.path),
            InfoChipRow(label: '版本', value: install.version),
            InfoChipRow(label: '构建号', value: install.build),
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
