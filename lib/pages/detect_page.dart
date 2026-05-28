import 'dart:io';

import 'package:flutter/services.dart';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/data_dir_scanner.dart';
import 'package:androidstudiowinhelper/core/download_manager.dart';
import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/download_task.dart';
import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/studio_version_service.dart';
import 'package:androidstudiowinhelper/pages/download_progress_card.dart';
import 'package:flutter/material.dart';

Future<void> _openInExplorer(String path) async {
  await Process.start('explorer', [path]);
}

Future<void> _openUrl(String url) async {
  await Process.start('cmd', ['/c', 'start', '', url]);
}

enum _PageTab { install, storage, download, envConfig }

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
  List<String>? _versionWarnings;

  final _versionService = StudioVersionService();
  final _downloadManager = DownloadManager();

  final _envManager = EnvPathManager();
  bool _envLoading = false;
  bool _envWriting = false;
  bool _envRollingBack = false;
  EnvPathConfigResult? _envResult;
  ScanProgress? _envProgress;
  final Map<String, TextEditingController> _envControllers = {};

  bool get _hasCache => _storageResult != null;

  @override
  void initState() {
    super.initState();
    _storageResult = ScanCache.load();
    _installResult = ScanCache.loadInstall();
    _versionResult = ScanCache.loadVersions();
  }

  @override
  void dispose() {
    _versionService.dispose();
    _downloadManager.dispose();
    for (final c in _envControllers.values) {
      c.dispose();
    }
    _envControllers.clear();
    super.dispose();
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
      _versionWarnings = null;
    });

    try {
      final result = await _versionService.fetchVersions();
      if (!mounted) return;
      setState(() {
        _versionResult = result.versions;
        _versionWarnings = result.warnings.isEmpty ? null : result.warnings;
        _versionProgress = const ScanProgress(percent: 100, message: '获取完成');
      });
      ScanCache.saveVersions(result.versions);
      _recoverDownloads(result.versions);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _versionLoading = false);
    }
  }

  void _recoverDownloads(List<StudioVersion> versions) {
    _downloadManager.recoverCompleted(
      versions.map((v) => v.version).toList(),
      (vk) => versions.firstWhere((v) => v.version == vk).downloadUrl,
    );
  }

  void _handleDownloadAction(StudioVersion v, DownloadAction action) {
    switch (action) {
      case DownloadAction.start:
        _downloadManager.start(v.version, v.downloadUrl);
      case DownloadAction.pause:
        _downloadManager.pause(v.version);
      case DownloadAction.resume:
        _downloadManager.start(v.version, v.downloadUrl);
      case DownloadAction.cancel:
        _downloadManager.cancel(v.version);
      case DownloadAction.open:
        _downloadManager.openFile(v.version);
    }
  }

  Future<void> _loadEnvConfig() async {
    setState(() {
      _envLoading = true;
      _envProgress = const ScanProgress(percent: 0, message: '正在检测环境变量…');
      _error = null;
    });

    try {
      final result = await _envManager.readConfig(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _envProgress = progress);
        },
      );
      setState(() {
        _envResult = result;
        _envProgress = const ScanProgress(percent: 100, message: '检测完成');
        // 初始化 TextEditingController
        for (final item in result.items) {
          if (!_envControllers.containsKey(item.variable)) {
            _envControllers[item.variable] = TextEditingController(
              text: item.currentValue,
            );
          }
        }
      });
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _envLoading = false);
    }
  }

  Future<void> _writeEnvVariable(
    String variable,
    String value, {
    bool createDir = false,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认修改环境变量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('变量：$variable'),
            const SizedBox(height: 4),
            Text('新值：$value'),
            if (createDir) ...[
              const SizedBox(height: 4),
              const Text('将自动创建目标目录（如不存在）'),
            ],
            const SizedBox(height: 12),
            const Text(
              '此操作需要管理员权限，将修改系统级环境变量。',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认修改'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _envWriting = true;
      _error = null;
    });

    try {
      await _envManager.backupCurrentConfig();
      final result = await _envManager.writeVariable(
        variable: variable,
        value: value,
        createDir: createDir,
      );

      if (!mounted) return;

      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$variable 已更新为 $value'),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        );
        await _loadEnvConfig();
      } else {
        setState(() => _error = '写入失败：${result.error}');
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _envWriting = false);
    }
  }

  Future<void> _appendPathToSystem(String path, {bool createDir = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认追加 PATH'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('将以下路径追加到系统 PATH：'),
            const SizedBox(height: 4),
            Text(path, style: const TextStyle(fontFamily: 'Consolas')),
            if (createDir) ...[
              const SizedBox(height: 4),
              const Text('将自动创建目标目录（如不存在）'),
            ],
            const SizedBox(height: 12),
            const Text(
              '此操作需要管理员权限。',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认追加'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _envWriting = true;
      _error = null;
    });

    try {
      await _envManager.backupCurrentConfig();
      final result = await _envManager.appendToPath(
        path: path,
        createDir: createDir,
      );

      if (!mounted) return;

      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.error.isNotEmpty
                ? result.error
                : '已将 $path 追加到系统 PATH'),
            backgroundColor: result.error.isNotEmpty
                ? Theme.of(context).colorScheme.tertiaryContainer
                : Theme.of(context).colorScheme.primaryContainer,
          ),
        );
        await _loadEnvConfig();
      } else {
        setState(() => _error = '追加 PATH 失败：${result.error}');
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _envWriting = false);
    }
  }

  Future<void> _oneClickRewrite() async {
    if (_envResult == null) return;

    final changes = <MapEntry<String, String>>[];
    for (final item in _envResult!.items) {
      if (item.variable == 'GRADLE_USER_HOME') continue; // 跳过默认路径展示项
      final controller = _envControllers[item.variable];
      if (controller == null) continue;
      final newValue = controller.text.trim();
      if (newValue.isEmpty || newValue == item.currentValue) continue;
      changes.add(MapEntry(item.variable, newValue));
    }

    if (changes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有需要修改的变量')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('一键配置环境变量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将修改以下系统环境变量：'),
            const SizedBox(height: 8),
            for (final entry in changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${entry.key} → ${entry.value}',
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              '此操作需要管理员权限，并将自动创建目标目录。',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认配置'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _envWriting = true;
      _error = null;
    });

    await _envManager.backupCurrentConfig();

    final errors = <String>[];
    for (final entry in changes) {
      try {
        final result = await _envManager.writeVariable(
          variable: entry.key,
          value: entry.value,
          createDir: true,
        );
        if (!result.success) {
          errors.add('${entry.key}: ${result.error}');
        }
      } catch (error) {
        errors.add('${entry.key}: $error');
      }
    }

    if (!mounted) return;

    if (errors.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已成功配置 ${changes.length} 个环境变量'),
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        ),
      );
    } else {
      setState(() => _error = '部分写入失败：\n${errors.join('\n')}');
    }

    setState(() => _envWriting = false);
    await _loadEnvConfig();
  }

  Future<void> _rollbackEnvConfig() async {
    final backup = _envManager.loadBackup();
    if (backup == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可回退的配置缓存')),
      );
      return;
    }

    final items = backup.items
        .where((item) =>
            item.variable != 'GRADLE_USER_HOME' &&
            item.source != 'NotSet' &&
            item.currentValue.isNotEmpty)
        .toList();

    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('缓存中没有可回退的变量')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认回退环境变量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将恢复为上一次的配置：'),
            const SizedBox(height: 8),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${item.variable} → ${item.currentValue}',
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              '此操作需要管理员权限。',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认回退'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _envRollingBack = true;
      _error = null;
    });

    try {
      final results = await _envManager.rollback();

      if (!mounted) return;

      final failures = results.where((r) => !r.success).toList();
      if (failures.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功回退 ${results.length} 个环境变量'),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        );
      } else {
        setState(() =>
            _error = '部分回退失败：\n${failures.map((r) => '${r.variable}: ${r.error}').join('\n')}');
      }
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      setState(() => _envRollingBack = false);
      await _loadEnvConfig();
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
                    const SizedBox(height: 12),
                    _TabTile(
                      icon: Icons.tune_outlined,
                      title: '环境配置',
                      subtitle: '检测并配置 ANDROID_HOME、GRADLE_HOME 等环境变量',
                      selected: _activeTab == _PageTab.envConfig,
                      onTap: () {
                        setState(() => _activeTab = _PageTab.envConfig);
                        if (_envResult == null) _loadEnvConfig();
                      },
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
              _PageTab.envConfig => _buildEnvConfigTab(),
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
          if (_versionWarnings != null)
            _WarningPanel(messages: _versionWarnings!),
          Expanded(
            child: _versionResult == null && !_versionLoading
                ? const _EmptyPanel(
                    hint: '点击右上角「获取版本」获取 Android Studio 官方版本列表',
                  )
                : filtered == null || filtered.isEmpty
                    ? const _EmptyPanel(hint: '该渠道暂无版本。')
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

  Widget _buildEnvConfigTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            icon: Icons.tune_outlined,
            title: '环境变量配置',
            trailing: _envResult != null
                ? '${_envResult!.items.length} 项变量 · ${_envResult!.pathEntries.length} 项 PATH'
                : null,
            action: _ActionButton(
              label: _envResult != null ? '重新检测' : '检测环境',
              icon: Icons.refresh,
              loading: _envLoading,
              onPressed: _envLoading ? null : _loadEnvConfig,
            ),
          ),
          const SizedBox(height: 16),
          if (_envWriting)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '正在写入环境变量（请在 UAC 弹窗中确认）…',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          if (_envLoading && _envProgress != null)
            _ProgressPanel(progress: _envProgress!),
          if (_error != null) _ErrorPanel(message: _error!),
          Expanded(child: _buildEnvConfigResult()),
        ],
      ),
    );
  }

  Widget _buildEnvConfigResult() {
    if (_envResult == null && !_envLoading) {
      return const _EmptyPanel(
        hint: '点击右上角「检测环境」查看当前环境变量配置',
      );
    }

    if (_envResult == null) return const SizedBox.shrink();

    final items = _envResult!.items;
    final pathEntries = _envResult!.pathEntries;

    return ListView(
      children: [
        for (final item in items)
          _EnvPathCard(
            item: item,
            controller: _envControllers[item.variable],
            onApply: (value) => _writeEnvVariable(
              item.variable,
              value,
            ),
            onApplyWithDir: (value) => _writeEnvVariable(
              item.variable,
              value,
              createDir: true,
            ),
          ),
        if (pathEntries.isNotEmpty) ...[
          const SizedBox(height: 16),
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.alt_route_outlined,
                          size: 20,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'PATH 中的 SDK 子目录',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  for (final entry in pathEntries)
                    _PathEntryTile(
                      entry: entry,
                      onAppend: () => _appendPathToSystem(entry.fullPath),
                      onAppendWithDir: () =>
                          _appendPathToSystem(entry.fullPath, createDir: true),
                    ),
                ],
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (items.any((item) =>
                  item.variable != 'GRADLE_USER_HOME' &&
                  _envControllers[item.variable]?.text.trim().isNotEmpty ==
                      true))
                FilledButton.icon(
                  onPressed: _envWriting ? null : _oneClickRewrite,
                  icon: _envWriting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_fix_high),
                  label: const Text('一键配置所有环境变量'),
                ),
              if (_envManager.loadBackup() != null)
                OutlinedButton.icon(
                  onPressed: (_envWriting || _envRollingBack)
                      ? null
                      : _rollbackEnvConfig,
                  icon: _envRollingBack
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.undo),
                  label: const Text('回退上一次配置'),
                ),
            ],
          ),
        ),
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

class _WarningPanel extends StatelessWidget {
  const _WarningPanel({required this.messages});

  final List<String> messages;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: colorScheme.tertiaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.tertiary.withValues(alpha: 0.3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 18, color: colorScheme.tertiary),
                const SizedBox(width: 8),
                Text(
                  '部分数据源获取失败',
                  style: TextStyle(
                    color: colorScheme.onTertiaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final msg in messages)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  msg,
                  style: TextStyle(
                    color:
                        colorScheme.onTertiaryContainer.withValues(alpha: 0.8),
                    fontSize: 13,
                  ),
                ),
              ),
          ],
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

class _EnvPathCard extends StatelessWidget {
  const _EnvPathCard({
    required this.item,
    required this.controller,
    required this.onApply,
    required this.onApplyWithDir,
  });

  final EnvPathItem item;
  final TextEditingController? controller;
  final void Function(String value) onApply;
  final void Function(String value) onApplyWithDir;

  Color _statusColor(BuildContext context) {
    if (item.source == 'NotSet') return Theme.of(context).colorScheme.outline;
    if (item.exists) return Colors.green;
    return Theme.of(context).colorScheme.error;
  }

  String _statusLabel() {
    if (item.source == 'NotSet') return '未设置 [source=NotSet]';
    if (item.exists) return '正常 [exists=true]';
    return '路径不存在 [exists=false]';
  }

  IconData _varIcon() {
    if (item.variable.contains('SDK') || item.variable.contains('ANDROID_HOME')) {
      return Icons.phone_android;
    }
    if (item.variable.contains('GRADLE')) {
      return Icons.build_circle_outlined;
    }
    return Icons.settings_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_varIcon(), size: 20, color: colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    item.variable,
                    style: textTheme.titleSmall?.copyWith(
                      fontFamily: 'Consolas',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _statusColor(context).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _statusColor(context).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    _statusLabel(),
                    style: textTheme.labelSmall?.copyWith(
                      color: _statusColor(context),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              item.label,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            if (item.currentValue.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    '当前值：',
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      item.currentValue,
                      style: textTheme.bodySmall?.copyWith(
                        fontFamily: 'Consolas',
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  _CopyButton(value: item.currentValue),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                children: [
                  Text(
                    '来源：${item.source}',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (item.exists && item.sizeHuman.isNotEmpty)
                    Text(
                      '大小：${item.sizeHuman}',
                      style: textTheme.labelSmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ],
            if (item.currentValue.isEmpty)
              Text(
                '未设置',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            const SizedBox(height: 12),
            if (controller != null) ...[
              TextField(
                controller: controller,
                style: textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: const OutlineInputBorder(),
                  labelText: '新路径',
                  hintText: item.suggestedDefault.isNotEmpty
                      ? item.suggestedDefault
                      : '输入新路径',
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final value = controller!.text.trim();
                      if (value.isNotEmpty) onApply(value);
                    },
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('应用'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      final value = controller!.text.trim();
                      if (value.isNotEmpty) onApplyWithDir(value);
                    },
                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: const Text('创建目录并应用'),
                  ),
                  if (item.suggestedDefault.isNotEmpty &&
                      item.suggestedDefault != controller!.text)
                    TextButton(
                      onPressed: () {
                        controller!.text = item.suggestedDefault;
                      },
                      child: const Text('使用默认值'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PathEntryTile extends StatelessWidget {
  const _PathEntryTile({
    required this.entry,
    required this.onAppend,
    required this.onAppendWithDir,
  });

  final EnvPathEntry entry;
  final VoidCallback onAppend;
  final VoidCallback onAppendWithDir;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Color statusColor;
    String statusLabel;
    if (entry.inPath) {
      statusColor = Colors.green;
      statusLabel = '已在 PATH';
    } else if (entry.exists) {
      statusColor = colorScheme.tertiary;
      statusLabel = '未在 PATH';
    } else {
      statusColor = colorScheme.outline;
      statusLabel = '目录不存在';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: statusColor.withValues(alpha: 0.35)),
            ),
            child: Text(
              statusLabel,
              style: textTheme.labelSmall?.copyWith(
                color: statusColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.subDir, style: textTheme.bodySmall),
                if (entry.fullPath.isNotEmpty)
                  Text(
                    entry.fullPath,
                    style: textTheme.labelSmall?.copyWith(
                      fontFamily: 'Consolas',
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (!entry.inPath && entry.exists) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onAppend,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('追加到 PATH'),
            ),
          ],
          if (!entry.inPath && !entry.exists) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onAppendWithDir,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('创建并追加'),
            ),
          ],
        ],
      ),
    );
  }
}
