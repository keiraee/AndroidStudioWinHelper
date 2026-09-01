import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/install_env_defaults.dart';
import 'package:androidstudiowinhelper/core/install_env_resolver.dart';

Future<Map<String, String>?> showInstallEnvWizard(
  BuildContext context, {
  EnvPathManager? envManager,
}) async {
  final result = await showDialog<Map<String, String>?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) =>
        InstallEnvWizardDialog(envManager: envManager ?? EnvPathManager()),
  );
  return result;
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
  bool _initializing = true;
  String _busyMessage = '';
  String? _error;
  String? _selectedLetter;
  List<InstallDriveInfo> _drives = const [];

  /// Machine 级已存在的路径（安装向导 4 个变量）。
  final Map<String, String> _existingMachinePaths = {};

  /// 是否已解析出可继续安装的现有路径（环境变量 / 注册表 / 本机检测）。
  bool _hasExistingSetup = false;

  /// 用户点击「修改路径」或「使用推荐默认路径」后为 true，允许编辑并可能写入。
  bool _editUnlocked = false;

  late final Map<String, TextEditingController> _controllers = {
    for (final key in _pathKeys) key: TextEditingController(),
  };

  bool get _usingExistingWithoutWrite => _hasExistingSetup && !_editUnlocked;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _initialize() async {
    await Future.wait([_loadDrives(), _loadResolvedPaths()]);
    if (!mounted) return;
    setState(() => _initializing = false);
  }

  Future<void> _loadResolvedPaths() async {
    try {
      final resolved = await InstallEnvResolver.resolve(
        envManager: widget.envManager,
      );
      if (!mounted) return;

      _existingMachinePaths
        ..clear()
        ..addAll(resolved.machinePaths);

      for (final key in _pathKeys) {
        final value = resolved.paths[key];
        if (value != null && value.isNotEmpty) {
          _controllers[key]!.text = value;
        }
      }

      if (resolved.hasExistingInstallSetup) {
        _inferDriveFromPaths(resolved.paths['AS_INSTALL_HOME']);
        _hasExistingSetup = true;
        _step = 1;
      }
    } catch (_) {
      // 读取失败时按新安装流程继续。
    }
  }

  void _inferDriveFromPaths(String? installHome) {
    if (installHome == null || installHome.length < 2 || installHome[1] != ':') {
      return;
    }
    _selectedLetter = installHome[0].toUpperCase();
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
        _selectedLetter ??= preferred?.letter;
      });
    } catch (e) {
      if (!mounted) return;
      final found = _fallbackLetters();
      setState(() {
        _drives = found;
        _selectedLetter ??= found.isEmpty ? null : found.first.letter;
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

  bool _isFieldLocked(String key) {
    if (_editUnlocked || _busy) return false;
    if (!_hasExistingSetup) return false;
    return _controllers[key]!.text.trim().isNotEmpty;
  }

  bool get _hasPrefilledPaths =>
      _pathKeys.any((key) => _controllers[key]!.text.trim().isNotEmpty);

  Map<String, String> _variablesToWrite(Map<String, String> paths) {
    if (_usingExistingWithoutWrite) return const {};

    if (!_hasExistingSetup) {
      return Map<String, String>.from(paths);
    }

    final toWrite = <String, String>{};
    for (final key in _pathKeys) {
      final newVal = paths[key] ?? '';
      final oldVal = _existingMachinePaths[key] ?? '';
      if (newVal != oldVal) {
        toWrite[key] = newVal;
      }
    }
    return toWrite;
  }

  Map<String, ({String old, String newVal})> _conflicts(
    Map<String, String> toWrite,
  ) {
    final conflicts = <String, ({String old, String newVal})>{};
    for (final entry in toWrite.entries) {
      final old = _existingMachinePaths[entry.key] ?? '';
      if (old.isNotEmpty && old != entry.value) {
        conflicts[entry.key] = (old: old, newVal: entry.value);
      }
    }
    return conflicts;
  }

  void _applyDefaults(InstallDriveInfo drive, {bool onlyEmpty = false}) {
    final paths = InstallEnvDefaults.pathsFor(drive);
    for (final key in _pathKeys) {
      if (onlyEmpty && _controllers[key]!.text.trim().isNotEmpty) continue;
      _controllers[key]!.text = paths[key] ?? '';
    }
  }

  void _unlockForEdit() {
    setState(() {
      _editUnlocked = true;
      _error = null;
    });
  }

  Future<void> _useRecommendedDefaults() async {
    if (_busy) return;

    if (_selectedDrive == null) {
      final picked = await _pickDriveForDefaults();
      if (picked == null || !mounted) return;
      setState(() => _selectedLetter = picked);
    }

    final drive = _selectedDrive;
    if (drive == null) return;

    setState(() {
      _editUnlocked = true;
      _error = null;
    });
    _applyDefaults(drive);
    setState(() {});
  }

  Future<String?> _pickDriveForDefaults() async {
    if (_drives.isEmpty) {
      setState(() => _error = '没有可用磁盘，无法生成推荐路径');
      return null;
    }
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择推荐路径所在磁盘'),
        content: SizedBox(
          width: 360,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final drive in _drives)
                ListTile(
                  title: Text('${drive.letter}:  ${drive.kind}'),
                  subtitle: Text(
                    '可用 ${FormatUtils.bytes(drive.freeBytes)}',
                  ),
                  onTap: () => Navigator.pop(ctx, drive.letter),
                ),
            ],
          ),
        ),
      ),
    );
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
      _applyDefaults(drive, onlyEmpty: _hasPrefilledPaths);
      setState(() => _step = 1);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmEnvConflicts(
    Map<String, ({String old, String newVal})> conflicts,
  ) async {
    if (conflicts.isEmpty) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认覆盖已有环境变量'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '下列系统环境变量已存在且值不同。继续将覆盖原有配置，是否继续？',
                ),
                const SizedBox(height: 12),
                for (final entry in conflicts.entries) ...[
                  Text(
                    entry.key,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '当前：${entry.value.old}',
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '将改为：${entry.value.newVal}',
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认覆盖并继续'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<bool> _confirmWriteDialog({
    required Map<String, String> toWrite,
    required List<String> appendPath,
  }) async {
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
                Text(
                  toWrite.length == _pathKeys.length
                      ? '将以管理员权限写入下列系统级（Machine）变量，并回读校验。校验失败不会启动安装程序。'
                      : '将以管理员权限写入下列已变更的系统级（Machine）变量，并回读校验。未变更的变量不会修改。',
                ),
                const SizedBox(height: 12),
                for (final entry in toWrite.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${entry.key}\n${entry.value}',
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (appendPath.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'PATH 追加（官方建议）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  for (final entry in appendPath)
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
    return confirmed == true;
  }

  Future<void> _finishPathStep() async {
    if (_busy) return;
    final paths = _currentPaths();
    final missing = paths.entries.where((e) => e.value.isEmpty).toList();
    if (missing.isNotEmpty) {
      setState(() => _error = '请填写全部路径后再继续');
      return;
    }

    final toWrite = _variablesToWrite(paths);
    if (toWrite.isEmpty) {
      if (!mounted) return;
      Navigator.of(context).pop(paths);
      return;
    }

    final conflicts = _conflicts(toWrite);
    if (!await _confirmEnvConflicts(conflicts)) return;

    final appendPath = toWrite.containsKey('ANDROID_HOME')
        ? InstallEnvDefaults.pathEntriesForAndroidHome(
            toWrite['ANDROID_HOME'] ?? '',
          )
        : const <String>[];

    if (!await _confirmWriteDialog(toWrite: toWrite, appendPath: appendPath)) {
      return;
    }
    if (!mounted) return;

    setState(() {
      _busy = true;
      _busyMessage = '正在写入并校验系统环境变量…';
      _error = null;
    });
    try {
      await widget.envManager.backupCurrentConfig();
      final result = await widget.envManager.writeBatch(
        variables: toWrite,
        appendPath: appendPath,
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
      Navigator.of(context).pop(paths);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickPath(String key) async {
    if (_isFieldLocked(key)) return;
    final picked = await FilePicker.getDirectoryPath(
      dialogTitle: '选择 ${InstallEnvDefaults.labels[key] ?? key}',
    );
    if (picked == null || picked.isEmpty) return;
    _controllers[key]!.text = picked;
    setState(() {});
  }

  String get _stepDescription {
    if (_step == 0) {
      return '先选定 Android 工具链所在磁盘。下一步会请求管理员权限，在该盘创建 Android 目录并确认可写。';
    }
    if (_usingExistingWithoutWrite) {
      return '检测到本机已有 Android 安装/SDK 路径（系统环境变量、注册表或已装 Studio），'
          '将直接使用现有路径继续安装，不会修改环境变量。'
          '如需调整，请点击「修改路径」或「使用推荐默认路径」。';
    }
    if (_editUnlocked && _hasExistingSetup) {
      return '已解锁编辑。仅会写入您修改过的环境变量；覆盖已有值前会再次确认。';
    }
    return '确认各目录用途与路径，将写入系统环境变量。之后仍可在「环境配置」页调整。';
  }

  String get _primaryActionLabel {
    if (_step == 0) return '下一步';
    if (_usingExistingWithoutWrite) return '继续安装';
    return '确认并继续';
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
                  Text(_stepDescription),
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
                    child: _initializing
                        ? const Center(
                            child: ExcludeSemantics(
                              child: SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          )
                        : _step == 0
                        ? _buildDriveStep()
                        : _buildPathStep(),
                  ),
                ],
              ),
              if (_busy) _busyOverlay(colorScheme),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context, null),
            child: const Text('取消'),
          ),
          if (_step == 1 && !_usingExistingWithoutWrite)
            TextButton(
              onPressed: _busy ? null : () => setState(() => _step = 0),
              child: const Text('上一步'),
            ),
          FilledButton(
            onPressed: _busy || _initializing
                ? null
                : _step == 0
                ? (_selectedLetter == null ? null : _goToPaths)
                : _finishPathStep,
            child: Text(_primaryActionLabel),
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
        if (_usingExistingWithoutWrite)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: colorScheme.secondary.withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lock_outline, size: 18, color: colorScheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '已识别本机现有路径（环境变量 / 注册表 / 已装 Studio），路径已锁定。'
                    '点击「继续安装」将直接使用，不会写入环境变量。',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
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
                Icon(
                  Icons.tips_and_updates_outlined,
                  size: 18,
                  color: colorScheme.primary,
                ),
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
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            if (_usingExistingWithoutWrite) ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _unlockForEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('修改路径'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _useRecommendedDefaults,
                icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                label: const Text('使用推荐默认路径'),
              ),
            ] else if (_editUnlocked && _selectedDrive != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () {
                        _applyDefaults(_selectedDrive!);
                        setState(() {});
                      },
                child: const Text('恢复默认路径'),
              ),
          ],
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
                  enabled: !_busy && !_isFieldLocked(key),
                  readOnly: _isFieldLocked(key),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    hintText: '目录路径',
                    suffixIcon: _isFieldLocked(key)
                        ? Icon(Icons.lock_outline, size: 16, color: colorScheme.outline)
                        : null,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '选择文件夹',
                onPressed: _busy || _isFieldLocked(key)
                    ? null
                    : () => _pickPath(key),
                icon: const Icon(Icons.folder_open),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
        if (!_usingExistingWithoutWrite) ...[
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
      ],
    );
  }
}
