import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/diagnostics/proxy_manager.dart';
import 'package:androidstudiowinhelper/core/download_manager.dart';
import 'package:androidstudiowinhelper/core/models/download_task.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/platform_utils.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/studio_version_service.dart';
import 'package:androidstudiowinhelper/pages/download_progress_card.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class DownloadTab extends StatefulWidget {
  const DownloadTab({super.key});

  @override
  State<DownloadTab> createState() => _DownloadTabState();
}

class _DownloadTabState extends State<DownloadTab> {
  final _versionService = StudioVersionService();
  final _downloadManager = DownloadManager();
  final _proxyManager = ProxyManager();

  bool _loading = false;
  List<StudioVersion>? _versions;
  String? _selectedChannel;
  ScanProgress? _progress;
  String? _error;
  List<String>? _warnings;
  bool _proxyReady = false;

  @override
  void initState() {
    super.initState();
    _versions = ScanCache.loadVersions();
    if (_versions != null) _recoverDownloads(_versions!);
    _loadProxySchemes();
  }

  Future<void> _loadProxySchemes() async {
    await _proxyManager.load();
    if (!mounted) return;
    setState(() => _proxyReady = true);
  }

  String? _activeProxyUrl() {
    final scheme = _proxyManager.activeScheme;
    final raw = scheme.httpsProxy ?? scheme.httpProxy;
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  @override
  void dispose() {
    _versionService.dispose();
    _downloadManager.dispose();
    super.dispose();
  }

  Future<void> _fetchVersions() async {
    setState(() {
      _loading = true;
      _progress = const ScanProgress(percent: 0, message: '正在获取版本列表…');
      _error = null;
      _warnings = null;
    });

    try {
      final result = await _versionService.fetchVersions();
      if (!mounted) return;
      setState(() {
        _versions = result.versions;
        _warnings = result.warnings.isEmpty ? null : result.warnings;
        _progress = const ScanProgress(percent: 100, message: '获取完成');
      });
      ScanCache.saveVersions(result.versions);
      _recoverDownloads(result.versions);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _recoverDownloads(List<StudioVersion> versions) {
    _downloadManager.recoverCompleted(
      versions.map((v) => v.version).toList(),
      (vk) => versions.firstWhere((v) => v.version == vk).downloadUrl,
    );
  }

  void _handleDownloadAction(StudioVersion v, DownloadAction action) {
    final proxyUrl = _activeProxyUrl();
    switch (action) {
      case DownloadAction.start:
        _downloadManager.start(v.version, v.downloadUrl, proxyUrl: proxyUrl);
      case DownloadAction.pause:
        _downloadManager.pause(v.version);
      case DownloadAction.resume:
        _downloadManager.start(v.version, v.downloadUrl, proxyUrl: proxyUrl);
      case DownloadAction.cancel:
        _downloadManager.cancel(v.version);
      case DownloadAction.open:
        _downloadManager.openFile(v.version);
    }
  }

  @override
  Widget build(BuildContext context) {
    final channels = <String>[];
    final seen = <String>{};
    if (_versions != null) {
      for (final v in _versions!) {
        if (seen.add(v.channel)) {
          channels.add(v.channel);
        }
      }
    }

    final filtered = _versions
        ?.where((v) =>
            _selectedChannel == null || v.channel == _selectedChannel)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.download_outlined,
            title: '版本下载',
            trailing: _versions != null
                ? '${_versions!.length} 个版本'
                : null,
            action: ActionButton(
              label: _versions != null ? '重新获取' : '获取版本',
              icon: Icons.refresh,
              loading: _loading,
              onPressed: _loading ? null : _fetchVersions,
            ),
          ),
          const SizedBox(height: 12),
          if (_proxyReady)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Text(
                    '下载代理',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _proxyManager.activeSchemeName,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      ),
                      items: [
                        for (final scheme in _proxyManager.schemes)
                          DropdownMenuItem(
                            value: scheme.name,
                            child: Text(scheme.name),
                          ),
                      ],
                      onChanged: (name) async {
                        if (name == null) return;
                        _proxyManager.setActive(name);
                        await _proxyManager.save();
                        if (!mounted) return;
                        setState(() {});
                      },
                    ),
                  ),
                ],
              ),
            ),
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
                            label: Text(channelDisplayName(ch)),
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
                        onTap: () => openUrl(
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
          if (_loading && _progress != null)
            ProgressPanel(progress: _progress!),
          if (_error != null) ErrorPanel(message: _error!),
          _buildSystemVersionBanner(),
          if (_warnings != null)
            WarningPanel(messages: _warnings!),
          Expanded(
            child: _versions == null && !_loading
                ? const EmptyPanel(
                    hint: '点击右上角「获取版本」获取 Android Studio 官方版本列表',
                  )
                : filtered == null || filtered.isEmpty
                    ? const EmptyPanel(hint: '该渠道暂无版本。')
                    : ListenableBuilder(
                        listenable: _downloadManager,
                        builder: (context, _) {
                          return ListView(
                            children: [
                              for (final v in filtered)
                                _VersionCard(
                                  version: v,
                                  downloadTask:
                                      _downloadManager.taskFor(v.version),
                                  onDownloadAction: (action) =>
                                      _handleDownloadAction(v, action),
                                ),
                            ],
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemVersionBanner() {
    final info = PlatformUtils.getSystemVersion();
    final buildStr = info['build'] ?? '';
    final build = int.tryParse(buildStr) ?? 0;
    final isWin11 = PlatformUtils.isWindows11();
    final sysLabel = isWin11 ? 'Windows 11' : 'Windows 10';

    if (build == 0) return const SizedBox.shrink();

    final isOld = !PlatformUtils.isWindows10Plus();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isOld
          ? Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.3)
          : Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              isOld ? Icons.warning_amber_outlined : Icons.info_outline,
              size: 18,
              color: isOld
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                isOld
                    ? '$sysLabel Build $buildStr — 版本过低，新版 Android Studio (2024.3+) 需要 Win10 2004 (Build 19041) 及以上'
                    : '$sysLabel Build $buildStr — 兼容所有版本',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: isOld
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.version,
    this.downloadTask,
    required this.onDownloadAction,
  });

  final StudioVersion version;
  final DownloadTask? downloadTask;
  final void Function(DownloadAction action) onDownloadAction;

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
                  DownloadProgressCard(
                    task: downloadTask,
                    onAction: onDownloadAction,
                    hasUrl: version.downloadUrl.isNotEmpty,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
