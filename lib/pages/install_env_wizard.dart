import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/install_env_defaults.dart';

Future<bool> showInstallEnvWizard(
  BuildContext context, {
  EnvPathManager? envManager,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) =>
        InstallEnvWizardDialog(envManager: envManager ?? EnvPathManager()),
  );
  return result == true;
}

class InstallEnvWizardDialog extends StatefulWidget {
  const InstallEnvWizardDialog({super.key, required this.envManager});

  final EnvPathManager envManager;

  @override
  State<InstallEnvWizardDialog> createState() => _InstallEnvWizardDialogState();
}

class _InstallEnvWizardDialogState extends State<InstallEnvWizardDialog> {
  static const _pathKeys = InstallEnvDefaults.variables;

  int _step = 0;
  bool _busy = false;
  bool _scanning = true;
  String _busyMessage = '';
  String? _error;
  String? _selectedLetter;
  List<InstallDriveInfo> _drives = const [];

  late final Map<String, TextEditingController> _controllers = {
    for (final key in _pathKeys) key: TextEditingController(),
  };

  @override
  void initState() {
    super.initState();
    _loadDrives();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDrives() async {
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          r'Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DriveType -in 2,3,4 } | Select-Object DeviceID,FreeSpace,Size,DriveType,ProviderName | ConvertTo-Json -Compress',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (!mounted) return;
      final stdout = (result.stdout as String? ?? '').replaceFirst(
        '\uFEFF',
        '',
      );
      Object? decoded;
      if (stdout.trim().isNotEmpty) {
        decoded = jsonDecode(stdout);
      }
      var found = InstallEnvDefaults.parseLogicalDisks(decoded);
      if (found.isEmpty) {
        found = _fallbackLetters();
      }
      InstallDriveInfo? preferred;
      for (final d in found) {
        if (preferred == null || d.freeBytes > preferred.freeBytes) {
          preferred = d;
        }
      }
      setState(() {
        _drives = found;
        _selectedLetter = preferred?.letter;
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      final found = _fallbackLetters();
      setState(() {
        _drives = found;
        _selectedLetter = found.isEmpty ? null : found.first.letter;
        _scanning = false;
        if (found.isEmpty) {
          _error = '扫描磁盘失败：$e';
        }
      });
    }
  }

  List<InstallDriveInfo> _fallbackLetters() {
    final found = <InstallDriveInfo>[];
    for (var code = 65; code <= 90; code++) {
      final letter = String.fromCharCode(code);
      if (Directory('$letter:\\').existsSync()) {
        found.add(
          InstallDriveInfo(
            letter: letter,
            freeBytes: 0,
            totalBytes: 0,
            kind: '磁盘',
          ),
        );
      }
    }
    return found;
  }

  InstallDriveInfo? get _selectedDrive {
    final letter = _selectedLetter;
    if (letter == null) return null;
    for (final d in _drives) {
      if (d.letter == letter) return d;
    }
    return InstallDriveInfo(
      letter: letter,
      freeBytes: 0,
      totalBytes: 0,
      kind: '磁盘',
    );
  }

  Map<String, String> _currentPaths() {
    return {for (final key in _pathKeys) key: _controllers[key]!.text.trim()};
  }

  void _applyDefaults(InstallDriveInfo drive) {
    final paths = InstallEnvDefaults.pathsFor(drive);
    for (final key in _pathKeys) {
      _controllers[key]!.text = paths[key] ?? '';
    }
  }

  String? _preflightWritableRoot(String root) {
    try {
      final kind = FileSystemEntity.typeSync(root);
      if (kind == FileSystemEntityType.file) {
        return '路径已存在但不是文件夹：$root';
      }
      final dir = Directory(root);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final probe = File('${dir.path}\\.aswh_write_probe');
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _goToPaths() async {
    final drive = _selectedDrive;
    if (drive == null || _busy) return;
    setState(() {
      _busy = true;
      _busyMessage = '正在检查磁盘是否可写…';
      _error = null;
    });
    try {
      final root = InstallEnvDefaults.androidRootFor(drive);
      final preflight = _preflightWritableRoot(root);
      if (!mounted) return;
      if (preflight != null) {
        setState(() => _error = preflight);
        return;
      }

      setState(() => _busyMessage = '正在请求管理员权限并准备磁盘…');
      final result = await widget.envManager.prepareAndroidRoot(root);
      if (!mounted) return;
      if (!result.success) {
        setState(() {
          _error = result.error.isEmpty ? '无法在 $root 创建目录' : result.error;
        });
        return;
      }
      _applyDefaults(drive);
      setState(() => _step = 1);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmAndWrite() async {
    if (_busy) return;
    final paths = _currentPaths();
    final missing = paths.entries.where((e) => e.value.isEmpty).toList();
    if (missing.isNotEmpty) {
      setState(() => _error = '请填写全部路径后再继续');
      return;
    }

    final pathEntries = InstallEnvDefaults.pathEntriesForAndroidHome(
      paths['ANDROID_HOME'] ?? '',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认写入系统环境变量'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('将以管理员权限写入下列系统级（Machine）变量，并回读校验。校验失败不会启动安装程序。'),
                const SizedBox(height: 12),
                for (final key in _pathKeys)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '$key\n${paths[key]}',
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (pathEntries.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'PATH 追加（官方建议）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  for (final entry in pathEntries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        entry,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回修改'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认写入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _busy = true;
      _busyMessage = '正在写入并校验系统环境变量…';
      _error = null;
    });
    try {
      await widget.envManager.backupCurrentConfig();
      final result = await widget.envManager.writeBatch(
        variables: paths,
        appendPath: pathEntries,
        createDir: true,
      );
      if (!mounted) return;
      if (!result.success) {
        final failed = result.items
            .where((i) => !i.success)
            .map((i) => '${i.variable}: ${i.error}')
            .join('\n');
        setState(() {
          _error = failed.isEmpty
              ? (result.error.isEmpty ? '写入或校验失败' : result.error)
              : failed;
        });
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPath(String key) async {
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: '选择 ${InstallEnvDefaults.labels[key] ?? key}',
    );
    if (picked == null || picked.isEmpty) return;
    _controllers[key]!.text = picked;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(_step == 0 ? '安装前准备：选择磁盘' : '安装前准备：确认路径'),
        content: SizedBox(
          width: 560,
          height: _step == 0 ? 440 : 500,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _step == 0
                        ? '先选定 Android 工具链所在磁盘。下一步会请求管理员权限，在该盘创建 Android 目录并确认可写。'
                        : '确认各目录用途与路径，将写入系统环境变量。之后仍可在「环境配置」页调整。',
                  ),
                  const SizedBox(height: 12),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(color: colorScheme.error),
                      ),
                    ),
                  Expanded(
                    child: _step == 0 ? _buildDriveStep() : _buildPathStep(),
                  ),
                ],
              ),
              if (_busy) _busyOverlay(colorScheme),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          if (_step == 1)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _step = 0),
              child: const Text('上一步'),
            ),
          FilledButton(
            onPressed: _busy
                ? null
                : _step == 0
                ? (_scanning || _selectedLetter == null ? null : _goToPaths)
                : _confirmAndWrite,
            child: const Text('下一步'),
          ),
        ],
      ),
    );
  }

  Widget _busyOverlay(ColorScheme colorScheme) {
    return Positioned.fill(
      child: ColoredBox(
        color: colorScheme.surface.withValues(alpha: 0.78),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ExcludeSemantics(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              const SizedBox(height: 12),
              Text(_busyMessage),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDriveStep() {
    if (_scanning) {
      return const Center(
        child: ExcludeSemantics(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_drives.isEmpty) {
      return const Text('没有找到可用的本地磁盘。');
    }
    return RadioGroup<String>(
      groupValue: _selectedLetter,
      onChanged: (value) {
        if (value == null || _busy) return;
        setState(() => _selectedLetter = value);
      },
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final drive in _drives)
            RadioListTile<String>(
              value: drive.letter,
              title: Text('${drive.letter}:  ${drive.kind}'),
              subtitle: Text(
                '可用 ${FormatUtils.bytes(drive.freeBytes)} / 共 ${FormatUtils.bytes(drive.totalBytes)}',
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPathStep() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return ListView(
      shrinkWrap: true,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.tips_and_updates_outlined, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  InstallEnvDefaults.pathRecommendHint,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy || _selectedDrive == null
                ? null
                : () {
                    _applyDefaults(_selectedDrive!);
                    setState(() {});
                  },
            child: const Text('恢复默认路径'),
          ),
        ),
        for (final key in _pathKeys) ...[
          Text(
            InstallEnvDefaults.labels[key] ?? key,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            InstallEnvDefaults.descriptions[key] ?? '',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            key,
            style: theme.textTheme.labelSmall?.copyWith(
              fontFamily: 'Consolas',
              color: colorScheme.outline,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controllers[key],
                  enabled: !_busy,
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: '目录路径',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '选择文件夹',
                onPressed: _busy ? null : () => _pickPath(key),
                icon: const Icon(Icons.folder_open),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        const SizedBox(height: 4),
        Text('系统 PATH（官方建议）', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          InstallEnvDefaults.pathAppendHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (final entry in InstallEnvDefaults.pathEntriesForAndroidHome(
          _controllers['ANDROID_HOME']!.text.trim(),
        ))
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              entry,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'Consolas',
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
