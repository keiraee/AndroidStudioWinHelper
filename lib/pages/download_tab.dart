import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:androidstudiowinhelper/core/app_settings.dart';
import 'package:androidstudiowinhelper/core/download/reachability.dart';
import 'package:androidstudiowinhelper/core/download_license_consent.dart';
import 'package:androidstudiowinhelper/core/download_manager.dart';
import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/models/download_task.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/platform_utils.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/studio_version_service.dart';
import 'package:androidstudiowinhelper/core/version/version_catalog.dart';
import 'package:androidstudiowinhelper/pages/download_progress_card.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class DownloadTab extends StatefulWidget {
  const DownloadTab({super.key});

  @override
  State<DownloadTab> createState() => _DownloadTabState();
}

enum _DownloadPane { catalog, downloading, completed }

class _DownloadTabState extends State<DownloadTab> {
  final _versionService = StudioVersionService();
  final _downloadManager = DownloadManager();
  final _reachability = Reachability();
  late final AppSettings _settings;

  bool _loading = false;
  bool _probingArchive = false;
  bool _probingDownload = false;
  bool _archiveFailed = false;
  List<StudioVersion>? _versions;
  ScanProgress? _progress;
  String? _error;
  List<String>? _warnings;
  String? _selectedChannel = VersionCatalog.defaultChannel;
  bool _showHistory = false;
  _DownloadPane _pane = _DownloadPane.catalog;
  ProbeResult? _archiveProbe;
  ProbeResult? _downloadProbe;
  final Set<String> _copyLinkKeys = {};
  String? _checkingKey;

  @override
  void initState() {
    super.initState();
    _settings = AppSettings.load();
    if (_settings.hasDownloadDirectory) {
      _downloadManager.useDownloadsDir(_settings.downloadDirectory!);
      _downloadManager.recoverFromDisk();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loading) return;
      _loadPage();
    });
  }

  @override
  void dispose() {
    _versionService.dispose();
    _downloadManager.dispose();
    super.dispose();
  }

  Future<void> _loadPage() async {
    setState(() {
      _loading = true;
      _probingArchive = true;
      _archiveFailed = false;
      _error = null;
      _warnings = null;
      _progress = const ScanProgress(percent: 10, message: '正在检测归档页…');
    });

    final archive = await _reachability.probeArchive();
    if (!mounted) return;
    setState(() {
      _archiveProbe = archive;
      _probingArchive = false;
    });

    if (!archive.ok) {
      setState(() {
        _archiveFailed = true;
        _versions = null;
        _loading = false;
        _progress = null;
      });
      return;
    }

    setState(() {
      _versions ??= ScanCache.loadVersions();
      _progress = const ScanProgress(percent: 40, message: '正在获取版本列表…');
    });
    if (_versions != null) {
      await _downloadManager.recoverFromDisk(_versions!);
    }

    try {
      final result = await _versionService.fetchVersions();
      if (!mounted) return;
      setState(() {
        _versions = result.versions;
        _warnings = result.warnings.isEmpty ? null : result.warnings;
        _progress = const ScanProgress(percent: 80, message: '正在检测下载直链…');
      });
      ScanCache.saveVersions(result.versions);
      await _downloadManager.recoverFromDisk(result.versions);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }

    await _probeDownloadSource();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _progress = const ScanProgress(percent: 100, message: '获取完成');
    });
  }

  Future<void> _probeDownloadSource() async {
    final versions = _versions;
    if (versions == null || versions.isEmpty) return;
    final featured = VersionCatalog.featured(versions);
    final url = featured?.downloadUrl ??
        versions
            .where((v) => v.downloadUrl.isNotEmpty)
            .map((v) => v.downloadUrl)
            .firstOrNull;
    if (url == null || url.isEmpty) return;

    setState(() => _probingDownload = true);
    final result = await _reachability.probeDownload(url);
    if (!mounted) return;
    setState(() {
      _downloadProbe = result;
      _probingDownload = false;
    });
  }

  void _handleDownloadAction(StudioVersion v, DownloadAction action) {
    switch (action) {
      case DownloadAction.start:
        _startDownload(v);
      case DownloadAction.pause:
        _downloadManager.pause(v.version);
      case DownloadAction.resume:
        _startDownload(v);
      case DownloadAction.cancel:
        _downloadManager.cancel(v.version);
      case DownloadAction.open:
        _downloadManager.openFile(v.version);
      case DownloadAction.install:
        _runInstallerKey(v.version);
      case DownloadAction.copy:
        _copyUrl(v.downloadUrl);
    }
  }

  Future<void> _runInstallerKey(String versionKey) async {
    try {
      await _downloadManager.runInstaller(versionKey);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法启动安装程序: $e')),
      );
    }
  }

  Future<void> _copyUrl(String url) async {
    if (url.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('下载链接已复制')),
    );
  }

  Future<String?> _pickFolder() {
    return FilePicker.getDirectoryPath(dialogTitle: '选择下载文件夹');
  }

  Future<void> _applyDownloadDir(String path) async {
    _settings.setDownloadDirectory(path);
    _downloadManager.useDownloadsDir(path);
    await _downloadManager.recoverFromDisk(_versions ?? const []);
    if (!mounted) return;
    setState(() {});
  }

  Future<bool> _confirmDownloadFolder() async {
    var path = _settings.downloadDirectory;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('选择下载文件夹'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('下载前需要指定安装包保存位置，选好之后才能继续。'),
                  const SizedBox(height: 12),
                  Text(
                    path ?? '尚未配置',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                          fontFamily: 'Consolas',
                        ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                OutlinedButton(
                  onPressed: () async {
                    final picked = await _pickFolder();
                    if (picked == null || picked.isEmpty) return;
                    setLocal(() => path = picked);
                  },
                  child: const Text('选择文件夹'),
                ),
                FilledButton(
                  onPressed: (path == null || path!.isEmpty)
                      ? null
                      : () => Navigator.pop(ctx, path),
                  child: const Text('开始下载'),
                ),
              ],
            );
          },
        );
      },
    );
    if (result == null || result.isEmpty) return false;
    await _applyDownloadDir(result);
    return true;
  }

  Future<void> _openDownloadFolder() async {
    if (!_settings.hasDownloadDirectory) {
      if (!mounted) return;
      final goPick = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('还没有配置下载文件夹'),
          content: const Text('需要先选择一个保存位置，才能打开下载文件夹。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('去选择'),
            ),
          ],
        ),
      );
      if (goPick != true) return;
      final picked = await _pickFolder();
      if (picked == null || picked.isEmpty) return;
      await _applyDownloadDir(picked);
    }
    final dir = _settings.downloadDirectory;
    if (dir == null || dir.isEmpty) return;
    await openInExplorer(dir);
  }

  Future<void> _startDownload(StudioVersion v) async {
    if (v.downloadUrl.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该版本没有可用的 Windows 下载链接')),
      );
      return;
    }

    if (!await _confirmDownloadFolder()) return;

    setState(() => _checkingKey = v.version);
    final reachable = await _reachability.verifyDownload(v.downloadUrl);
    if (!mounted) return;
    setState(() => _checkingKey = null);

    if (!reachable) {
      setState(() => _copyLinkKeys.add(v.version));
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('当前无法下载'),
          content: const Text(
            '安装包直链连续 3 次无法访问。可复制链接后用浏览器自行下载。',
          ),
          actions: [
            TextButton(
              onPressed: () {
                _copyUrl(v.downloadUrl);
                Navigator.pop(context);
              },
              child: const Text('复制下载链接'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('确定'),
            ),
          ],
        ),
      );
      return;
    }

    if (!DownloadLicenseConsent.hasAccepted()) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('下载前需同意许可'),
          content: const SingleChildScrollView(
            child: Text(
              'Android Studio 安装包受 Android Software Development Kit '
              'License Agreement 约束。\n\n'
              '继续下载即表示你同意该协议条款（与官网归档页点击 '
              '“I agree to the terms” 等效）。\n\n'
              '协议原文：https://developer.android.com/studio/terms',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('同意并下载'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      await DownloadLicenseConsent.accept();
    }

    _downloadManager.start(
      v.version,
      v.downloadUrl,
      expectedSha256: v.sha256.isEmpty ? null : v.sha256,
    );
  }

  Future<void> _resumeTask(DownloadTask task) async {
    if (!await _confirmDownloadFolder()) return;
    final matched = _versionFor(task.versionKey);
    if (matched != null) {
      await _startDownload(matched);
      return;
    }
    if (task.url.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('找不到该任务的下载链接，无法续传')),
      );
      return;
    }
    _downloadManager.start(task.versionKey, task.url);
  }

  StudioVersion? _versionFor(String key) {
    final versions = _versions;
    if (versions == null) return null;
    for (final v in versions) {
      if (v.version == key) return v;
    }
    return null;
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
    final featured = _versions == null
        ? null
        : VersionCatalog.featured(_versions!, channel: _selectedChannel);
    final listed = _versions == null
        ? const <StudioVersion>[]
        : VersionCatalog.listForDisplay(
            versions: _versions!,
            channel: _selectedChannel,
            showHistory: _showHistory,
          );
    final hasMoreHistory = _versions != null &&
        VersionCatalog.hasMoreHistory(
          versions: _versions!,
          channel: _selectedChannel,
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.download_outlined,
            title: '版本下载',
            trailing: _versions != null ? '${_versions!.length} 个版本' : null,
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _openDownloadFolder,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('打开下载文件夹'),
                ),
                const SizedBox(width: 8),
                ActionButton(
                  label: _versions != null || _archiveFailed ? '重新获取' : '获取版本',
                  icon: Icons.refresh,
                  loading: _loading,
                  onPressed: _loading ? null : _loadPage,
                ),
              ],
            ),
          ),
          if (_settings.hasDownloadDirectory)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '保存到 ${_settings.downloadDirectory}',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.55),
                    ),
              ),
            ),
          const SizedBox(height: 12),
          _buildLatencyRow(),
          _buildPaneChips(channels),
          if (_pane == _DownloadPane.catalog &&
              channels.length > 1 &&
              !_archiveFailed)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Align(
                alignment: Alignment.centerRight,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => openUrl(Reachability.archiveFallbackUrl),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.history,
                                  size: 16,
                                  color: Theme.of(context).colorScheme.primary),
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
                              Icon(
                                Icons.open_in_new,
                                size: 14,
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.6),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 10, top: 2),
                        child: Text(
                          '默认显示近期版本，完整历史可展开或打开归档',
                          style:
                              Theme.of(context).textTheme.labelSmall?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.4),
                                  ),
                        ),
                      ),
                    ],
                  ),
              ),
            ),
          if (_pane == _DownloadPane.catalog &&
              _loading &&
              _progress != null)
            ProgressPanel(progress: _progress!),
          if (_pane == _DownloadPane.catalog && _error != null)
            ErrorPanel(message: _error!),
          if (_pane == _DownloadPane.catalog) _buildSystemVersionBanner(),
          if (_pane == _DownloadPane.catalog && _warnings != null)
            WarningPanel(messages: _warnings!),
          Expanded(
            child: _buildBody(
              featured: featured,
              listed: listed,
              hasMoreHistory: hasMoreHistory,
              channelEmpty: filtered != null && filtered.isEmpty,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPaneChips(List<String> channels) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilterChip(
            label: const Text('全部'),
            selected:
                _pane == _DownloadPane.catalog && _selectedChannel == null,
            onSelected: (_) => setState(() {
              _pane = _DownloadPane.catalog;
              _selectedChannel = null;
              _showHistory = false;
            }),
          ),
          for (final ch in channels)
            FilterChip(
              label: Text(channelDisplayName(ch)),
              selected:
                  _pane == _DownloadPane.catalog && _selectedChannel == ch,
              onSelected: (sel) => setState(() {
                _pane = _DownloadPane.catalog;
                _selectedChannel = sel ? ch : null;
                _showHistory = false;
              }),
            ),
          FilterChip(
            label: const Text('下载中'),
            selected: _pane == _DownloadPane.downloading,
            onSelected: (_) =>
                setState(() => _pane = _DownloadPane.downloading),
          ),
          FilterChip(
            label: const Text('已完成'),
            selected: _pane == _DownloadPane.completed,
            onSelected: (_) => setState(() => _pane = _DownloadPane.completed),
          ),
        ],
      ),
    );
  }

  void _goToAllVersions() {
    setState(() {
      _pane = _DownloadPane.catalog;
      _selectedChannel = null;
      _showHistory = false;
    });
  }

  Widget _buildLatencyRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _LatencyBadge(
            label: '归档',
            probing: _probingArchive,
            result: _archiveProbe,
          ),
          _LatencyBadge(
            label: '下载',
            probing: _probingDownload,
            result: _downloadProbe,
          ),
        ],
      ),
    );
  }

  Widget _buildBody({
    required StudioVersion? featured,
    required List<StudioVersion> listed,
    required bool hasMoreHistory,
    required bool channelEmpty,
  }) {
    return ListenableBuilder(
      listenable: _downloadManager,
      builder: (context, _) {
        if (_pane == _DownloadPane.downloading ||
            _pane == _DownloadPane.completed) {
          return _buildLocalPane();
        }

        return ListView(
          children: [
            if (_archiveFailed)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: EmptyPanel(
                  icon: Icons.wifi_off_outlined,
                  title: '网络出现错误',
                  hint: '无法访问 Android Studio 归档页。可打开浏览器前往官方归档。',
                  actionLabel: '打开归档页',
                  actionIcon: Icons.open_in_browser,
                  onAction: () => openUrl(Reachability.archiveFallbackUrl),
                ),
              ),
            if (!_archiveFailed)
              ..._versionListChildren(
                featured: featured,
                listed: listed,
                hasMoreHistory: hasMoreHistory,
                channelEmpty: channelEmpty,
              ),
          ],
        );
      },
    );
  }

  Widget _buildLocalPane() {
    final inProgress = _downloadManager.inProgressTasks.toList();
    final completed = _downloadManager.completedTasks.toList();
    final downloading = _pane == _DownloadPane.downloading;
    final items = downloading ? inProgress : completed;

    if (inProgress.isEmpty && completed.isEmpty) {
      return EmptyPanel(
        title: '还没有下载？',
        hint: '下载中和已完成的安装包会出现在这里',
        actionLabel: '去下载',
        actionIcon: Icons.download_outlined,
        onAction: _goToAllVersions,
      );
    }

    if (items.isEmpty) {
      return EmptyPanel(
        title: '还没有下载？',
        hint: downloading ? '当前没有进行中的下载' : '下载文件夹里还没有安装包',
        actionLabel: '去下载',
        actionIcon: Icons.download_outlined,
        onAction: _goToAllVersions,
      );
    }

    return ListView(
      children: [
        _ShelfHeader(
          title: downloading ? '下载中' : '已完成',
          subtitle: downloading
              ? '包含暂停或关闭软件后未完成的任务'
              : '来自本地下载文件夹中的安装包',
          count: items.length,
        ),
        for (final task in items)
          downloading
              ? _ShelfTaskCard(
                  task: task,
                  onResume: () => _resumeTask(task),
                  onPause: () => _downloadManager.pause(task.versionKey),
                  onCancel: () => _downloadManager.cancel(task.versionKey),
                )
              : _ShelfTaskCard(
                  task: task,
                  onInstall: () => _runInstallerKey(task.versionKey),
                  onOpen: () => _downloadManager.openFile(task.versionKey),
                ),
      ],
    );
  }

  List<Widget> _versionListChildren({
    required StudioVersion? featured,
    required List<StudioVersion> listed,
    required bool hasMoreHistory,
    required bool channelEmpty,
  }) {
    if (_loading && _versions == null) return const [];
    if (_versions == null) {
      return const [
        EmptyPanel(hint: '正在获取官方版本列表。也可点击右上角「获取版本」手动重试。'),
      ];
    }
    if (channelEmpty && featured == null) {
      return const [EmptyPanel(hint: '该渠道暂无版本。')];
    }

    return [
      if (featured != null)
        _FeaturedVersionCard(
          version: featured,
          downloadTask: _downloadManager.taskFor(featured.version),
          checking: _checkingKey == featured.version,
          showCopyLink: _copyLinkKeys.contains(featured.version),
          onDownloadAction: (action) => _handleDownloadAction(featured, action),
        ),
      for (final v in listed)
        _VersionCard(
          version: v,
          downloadTask: _downloadManager.taskFor(v.version),
          showCopyLink: _copyLinkKeys.contains(v.version),
          onDownloadAction: (action) => _handleDownloadAction(v, action),
        ),
      if (hasMoreHistory)
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 16),
          child: Center(
            child: TextButton(
              onPressed: () => setState(() => _showHistory = !_showHistory),
              child: Text(_showHistory ? '收起历史版本' : '显示更多历史版本'),
            ),
          ),
        ),
    ];
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

class _LatencyBadge extends StatelessWidget {
  const _LatencyBadge({
    required this.label,
    required this.probing,
    this.result,
  });

  final String label;
  final bool probing;
  final ProbeResult? result;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bars = result?.signalBars ?? 0;
    final Color color;
    final String text;
    if (probing) {
      color = colorScheme.outline;
      text = '检测中';
    } else if (result == null) {
      color = colorScheme.outline;
      text = '未检测';
    } else if (!result!.ok) {
      color = colorScheme.error;
      text = '不可用';
    } else {
      color = bars >= 3
          ? Colors.green
          : bars == 2
              ? Colors.orange
              : colorScheme.error;
      text = '${result!.latencyMs} ms';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        color: color.withValues(alpha: 0.08),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (probing)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: color,
              ),
            )
          else
            Icon(_signalIcon(bars, result?.ok ?? false), size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$label $text',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  IconData _signalIcon(int bars, bool ok) {
    if (!ok) return Icons.signal_cellular_off;
    return switch (bars) {
      4 => Icons.signal_cellular_alt,
      3 => Icons.signal_cellular_alt_2_bar,
      2 => Icons.signal_cellular_alt_1_bar,
      _ => Icons.signal_cellular_0_bar,
    };
  }
}

class _ShelfHeader extends StatelessWidget {
  const _ShelfHeader({
    required this.title,
    required this.subtitle,
    required this.count,
  });

  final String title;
  final String subtitle;
  final int count;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              subtitle,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfTaskCard extends StatelessWidget {
  const _ShelfTaskCard({
    required this.task,
    this.onResume,
    this.onPause,
    this.onCancel,
    this.onInstall,
    this.onOpen,
  });

  final DownloadTask task;
  final VoidCallback? onResume;
  final VoidCallback? onPause;
  final VoidCallback? onCancel;
  final VoidCallback? onInstall;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = task.fileName.isNotEmpty ? task.fileName : task.versionKey;
    final isDone = task.state == DownloadState.completed;
    final sizeText = isDone
        ? FormatUtils.bytes(task.totalBytes)
        : '${FormatUtils.bytes(task.downloadedBytes)} / ${FormatUtils.bytes(task.totalBytes)}';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              sizeText,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'Consolas',
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
            if (!isDone) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: task.percent),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (isDone) ...[
                  FilledButton.icon(
                    onPressed: onInstall,
                    icon: const Icon(Icons.play_arrow, size: 16),
                    label: const Text('运行安装程序'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: onOpen,
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('打开文件'),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ] else ...[
                  if (task.state == DownloadState.downloading ||
                      task.state == DownloadState.connecting)
                    OutlinedButton.icon(
                      onPressed: onPause,
                      icon: const Icon(Icons.pause, size: 16),
                      label: const Text('暂停'),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: onResume,
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('继续下载'),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('取消'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FeaturedVersionCard extends StatelessWidget {
  const _FeaturedVersionCard({
    required this.version,
    this.downloadTask,
    required this.onDownloadAction,
    this.showCopyLink = false,
    this.checking = false,
  });

  final StudioVersion version;
  final DownloadTask? downloadTask;
  final void Function(DownloadAction action) onDownloadAction;
  final bool showCopyLink;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final title =
        version.codename.isEmpty ? version.version : version.codename;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '推荐安装',
              style: textTheme.labelMedium?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Flexible(
                  child: Text(title, style: textTheme.titleMedium),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
            const SizedBox(height: 4),
            Text(
              version.version,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (version.buildNumber.isNotEmpty) ...[
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
            if (checking) ...[
              const SizedBox(height: 8),
              Text(
                '正在验证下载链接…',
                style: textTheme.labelSmall?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ],
            const SizedBox(height: 12),
            if (version.downloadUrl.isNotEmpty)
              DownloadProgressCard(
                task: downloadTask,
                onAction: onDownloadAction,
                hasUrl: version.downloadUrl.isNotEmpty,
                showCopyLink: showCopyLink,
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
    this.showCopyLink = false,
  });

  final StudioVersion version;
  final DownloadTask? downloadTask;
  final void Function(DownloadAction action) onDownloadAction;
  final bool showCopyLink;

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
                    showCopyLink: showCopyLink,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
