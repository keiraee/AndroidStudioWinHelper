import 'dart:io';

import 'package:flutter/services.dart';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/data_dir_scanner.dart';
import 'package:androidstudiowinhelper/core/download_manager.dart';
import 'package:androidstudiowinhelper/core/emulator_check_manager.dart';
import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/hyperv_manager.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/emulator_check_result.dart';
import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/download_task.dart';
import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/hyperv_result.dart';
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

enum _PageTab { install, storage, download, envConfig, hyperV }

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

  final _hypervManager = HypervManager();
  bool _hypervLoading = false;
  bool _hypervToggling = false;
  bool _whpxToggling = false;
  HypervResult? _hypervResult;
  ScanProgress? _hypervProgress;
  ScanProgress? _hypervToggleProgress;

  final _emuCheckManager = EmulatorCheckManager();
  bool _emuCheckLoading = false;
  EmulatorCheckResult? _emuCheckResult;

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
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
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
                            const SizedBox(height: 12),
                            _TabTile(
                              icon: Icons.desktop_windows_outlined,
                              title: '模拟器运行环境',
                              subtitle: 'Hyper-V/WHPX 管理 · 硬件/虚拟化/软件环境全面诊断',
                              selected: _activeTab == _PageTab.hyperV,
                              onTap: () {
                                setState(() => _activeTab = _PageTab.hyperV);
                                if (_hypervResult == null) _loadHyperV();
                                if (_emuCheckResult == null) _runEmulatorCheck();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
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
              _PageTab.hyperV => _buildHyperVTab(),
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

  Widget _buildOperationsCard(HypervResult result) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    // Hyper-V status
    final hypervFeatures = result.features
        .where((f) => f.name.startsWith('Microsoft-Hyper-V'))
        .toList();
    final hypervEnabled = hypervFeatures.isNotEmpty &&
        hypervFeatures.every((f) => f.state == 'Enabled' || f.state == 'EnablePending');

    // WHPX status
    final whpxFeature = result.features
        .where((f) => f.name == 'HypervisorPlatform')
        .firstOrNull;
    final whpxEnabled = whpxFeature?.state == 'Enabled' ||
        whpxFeature?.state == 'EnablePending';

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

            // --- Hyper-V section ---
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
            Text(
              '用于运行 WSL2、Docker Desktop 等基于 Hyper-V 的服务',
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
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

            // --- WHPX section ---
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
            Text(
              '让 Android 模拟器通过标准 API 使用 Hyper-V 虚拟化能力，实现与 Hyper-V 共存',
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
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

            // --- Relationship explanation ---
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
                Expanded(
                  child: Text(
                    '开启或关闭后必须重启计算机才能生效。',
                    style: textTheme.bodySmall,
                  ),
                ),
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
              const SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
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
                    Icon(
                      _categoryIcon(group.key),
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      group.key,
                      style: textTheme.labelLarge?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        height: 1,
                        color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                      ),
                    ),
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

  /// Merges Hyper-V feature data into emulator check results,
  /// replacing "unknown" VirtualMachinePlatform/Windows Sandbox items
  /// and adding HypervisorPlatform status from elevated detection.
  EmulatorCheckResult? _buildMergedCheckResult() {
    if (_emuCheckResult == null) return null;

    final merged = <EmulatorCheck>[];
    final hypervFeatureNames = <String>{};

    // Build EmulatorCheck items from Hyper-V features
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

    // Add remaining checks from emulator check result, skipping hyperv duplicates and hidden items
    for (final check in _emuCheckResult!.checks) {
      // Skip checks that hyperv already provides better data for
      if (check.name == 'virtual_machine_platform' ||
          check.name == 'windows_sandbox') {
        continue; // hyperv features cover these
      }
      // Hide redundant system info that clutters the UI
      if (check.name == 'system_ram' || check.name == 'disk_space') {
        continue;
      }
      merged.add(check);
    }

    return EmulatorCheckResult(checks: merged);
  }

  // --- Hyper-V ---

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
      setState(() {
        _emuCheckResult = result;
      });
    } catch (error) {
      // silently ignore - emulator check is supplementary
    } finally {
      if (mounted) setState(() => _emuCheckLoading = false);
    }
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
        // 操作成功后重新检测状态
        await _loadHyperV();
        if (!mounted) return;
        final hasFailed = result.details.contains('FAILED');
        if (hasFailed) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(result.message),
              content: SingleChildScrollView(
                child: SelectableText(result.details),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('确定'),
                ),
              ],
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message)),
          );
        }
      } else {
        // 操作失败，弹窗显示详情
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
      // WHPX depends on VirtualMachinePlatform, toggle both
      final features = enable
          ? ['VirtualMachinePlatform', 'HypervisorPlatform'] // enable dependency first
          : ['HypervisorPlatform', 'VirtualMachinePlatform']; // disable WHPX first

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
        _showToggleError(lastResult);
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
        _showToggleError(lastResult);
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

  void _showToggleError(HypervToggleResult result) {
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

  Widget _buildHyperVTab() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeader(
            icon: Icons.desktop_windows_outlined,
            title: '模拟器运行环境',
            trailing: _hypervResult?.osEdition,
            action: _ActionButton(
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
            _ProgressPanel(progress: _hypervToggleProgress!),
          if (_hypervLoading && _hypervProgress != null)
            _ProgressPanel(progress: _hypervProgress!),
          if (_error != null) _ErrorPanel(message: _error!),
          Expanded(child: _buildHyperVResult()),
        ],
      ),
    );
  }

  Widget _buildHyperVResult() {
    if (_hypervResult == null && !_hypervLoading) {
      return const _EmptyPanel(
        hint: '点击右上角「检测状态」查看 Hyper-V 各组件状态',
      );
    }

    if (_hypervResult == null) return const SizedBox.shrink();

    final result = _hypervResult!;

    return ListView(
      children: [
        // OS 版本信息卡片
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '系统版本：${result.osEdition}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
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
        // 各功能状态卡片
        Card(
          margin: const EdgeInsets.only(bottom: 10),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '组件状态',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
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
                        Expanded(
                          child: Text(
                            feature.label,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
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
        // 系统环境检测结果
        _buildEmulatorCheckSection(),
        // 操作：Hyper-V / WHPX 独立控制
        _buildOperationsCard(result),
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
                      Text(
                        check.label,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: colorScheme.onSurfaceVariant,
                  ),
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
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
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
