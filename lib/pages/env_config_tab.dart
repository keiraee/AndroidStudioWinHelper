import 'dart:io';

import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

/// 旧目录已有内容时用户的选择。
enum _MigrationChoice { move, keepInPlace, cancel }

class _DirProbe {
  const _DirProbe({
    required this.files,
    required this.bytes,
    required this.truncated,
  });

  final int files;
  final int bytes;

  /// 扫描因超时/权限中断，files/bytes 是下限值。
  final bool truncated;

  bool get isEmpty => files == 0;
}

class EnvConfigTab extends StatefulWidget {
  const EnvConfigTab({super.key});

  @override
  State<EnvConfigTab> createState() => _EnvConfigTabState();
}

class _EnvConfigTabState extends State<EnvConfigTab> {
  /// 改这些变量时需要同步 PATH 里的 SDK 子目录。
  static const _pathSyncVariables = {'ANDROID_HOME'};

  final _envManager = EnvPathManager();

  bool _loading = false;
  bool _writing = false;
  EnvPathConfigResult? _result;
  ScanProgress? _progress;
  String? _error;
  final Map<String, TextEditingController> _controllers = {};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  void _log(String message) => LogManager.instance.write('EnvConfigTab', message);

  Future<void> _loadConfig() async {
    setState(() {
      _loading = true;
      _progress = const ScanProgress(percent: 0, message: '正在检测环境变量…');
      _error = null;
    });

    try {
      final result = await _envManager.readConfig(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      _log(
        '检测完成：${result.items.length} 项变量，'
        '废弃项 ${result.items.where((i) => i.deprecated).map((i) => i.variable).join(',')}',
      );
      setState(() {
        _result = result;
        _progress = const ScanProgress(percent: 100, message: '检测完成');
        for (final item in result.items) {
          final existing = _controllers[item.variable];
          if (existing == null) {
            _controllers[item.variable] = TextEditingController(
              text: item.currentValue,
            );
          } else if (existing.text != item.currentValue) {
            existing.text = item.currentValue;
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      _log('检测失败：$error');
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ==================== 目录探测 ====================

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 统计目录内容，最多扫 1.5 秒，避免大 SDK 目录卡住 UI。
  _DirProbe _probeDirectory(String path) {
    if (path.isEmpty) return const _DirProbe(files: 0, bytes: 0, truncated: false);
    final dir = Directory(path);
    if (!dir.existsSync()) {
      return const _DirProbe(files: 0, bytes: 0, truncated: false);
    }

    var files = 0;
    var bytes = 0;
    var seen = 0;
    var truncated = false;
    final deadline = DateTime.now().add(const Duration(milliseconds: 1500));

    try {
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        seen++;
        if (entity is File) {
          files++;
          try {
            bytes += entity.lengthSync();
          } catch (_) {}
        }
        if (seen % 500 == 0 && DateTime.now().isAfter(deadline)) {
          truncated = true;
          break;
        }
      }
    } on FileSystemException {
      truncated = true;
    }

    return _DirProbe(files: files, bytes: bytes, truncated: truncated);
  }

  /// Windows 路径比较：忽略大小写和尾部分隔符。
  static bool _samePath(String a, String b) {
    String norm(String p) => p
        .trim()
        .replaceAll('/', '\\')
        .replaceAll(RegExp(r'\\+$'), '')
        .toLowerCase();
    return norm(a) == norm(b);
  }

  static String _joinWindowsPath(String base, String sub) {
    final left = base.replaceAll('/', '\\');
    final trimmed = left.endsWith('\\')
        ? left.substring(0, left.length - 1)
        : left;
    return '$trimmed\\$sub';
  }

  // ==================== 单个变量应用 ====================

  Future<_MigrationChoice?> _askMigration(
    String variable,
    String oldValue,
    String newValue,
    _DirProbe probe,
  ) {
    final approx = probe.truncated ? '至少 ' : '';
    return showDialog<_MigrationChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('旧目录里已有数据'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$variable 当前指向的目录不是空的：'),
            const SizedBox(height: 6),
            Text(
              oldValue,
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
            Text('$approx${probe.files} 个文件 · $approx${_formatBytes(probe.bytes)}'),
            const SizedBox(height: 12),
            const Text(
              '只改环境变量的话，这些内容不会跟着走：SDK 组件、AVD、'
              'Gradle 缓存都会被认为"不存在"，工具会在新路径重新下载一份，'
              '旧目录则变成占磁盘的孤儿数据。',
            ),
            const SizedBox(height: 12),
            Text(
              '目标目录：$newValue',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _MigrationChoice.cancel),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _MigrationChoice.keepInPlace),
            child: const Text('仅改变量，不迁移'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _MigrationChoice.move),
            child: const Text('迁移数据并改变量'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmApply({
    required String variable,
    required String oldValue,
    required String newValue,
    required bool willMove,
    required List<String> removePath,
    required List<String> appendPath,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认修改环境变量'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('变量：$variable'),
              const SizedBox(height: 4),
              if (oldValue.isNotEmpty)
                Text(
                  '原值：$oldValue',
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                ),
              Text(
                '新值：$newValue',
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
              ),
              if (willMove) ...[
                const SizedBox(height: 10),
                const Text('· 将把旧目录内容迁移到新目录（robocopy /MOVE）'),
              ],
              if (removePath.isNotEmpty || appendPath.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('同时同步系统 PATH：'),
                for (final p in removePath)
                  Text(
                    '  − $p',
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  ),
                for (final p in appendPath)
                  Text(
                    '  + $p',
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
                  ),
              ],
              const SizedBox(height: 12),
              const Text(
                '此操作需要管理员权限，修改的是系统级环境变量。'
                '已打开的终端和 IDE 需要重启才会读到新值。',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
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
    return confirmed == true;
  }

  Future<void> _applyVariable(
    EnvPathItem item,
    String rawValue, {
    bool createDir = false,
  }) async {
    final newValue = rawValue.trim();
    if (newValue.isEmpty) return;

    final oldValue = item.currentValue.trim();
    if (_samePath(newValue, oldValue)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('值未发生变化')),
      );
      return;
    }

    var migration = _MigrationChoice.keepInPlace;
    if (oldValue.isNotEmpty && Directory(oldValue).existsSync()) {
      final probe = _probeDirectory(oldValue);
      if (!probe.isEmpty) {
        _log(
          '${item.variable} 旧目录 $oldValue 非空：'
          '${probe.files} 文件 / ${probe.bytes} 字节 truncated=${probe.truncated}',
        );
        final choice = await _askMigration(
          item.variable,
          oldValue,
          newValue,
          probe,
        );
        if (!mounted) return;
        if (choice == null || choice == _MigrationChoice.cancel) {
          _log('${item.variable} 用户取消修改');
          return;
        }
        migration = choice;
      }
    }

    final removePath = <String>[];
    final appendPath = <String>[];
    if (_pathSyncVariables.contains(item.variable)) {
      for (final entry in _result?.pathEntries ?? const <EnvPathEntry>[]) {
        if (!entry.inPath || entry.fullPath.isEmpty) continue;
        removePath.add(entry.fullPath);
        appendPath.add(_joinWindowsPath(newValue, entry.subDir));
      }
    }

    final willMove = migration == _MigrationChoice.move;
    final confirmed = await _confirmApply(
      variable: item.variable,
      oldValue: oldValue,
      newValue: newValue,
      willMove: willMove,
      removePath: removePath,
      appendPath: appendPath,
    );
    if (!mounted || !confirmed) return;

    setState(() {
      _writing = true;
      _error = null;
    });

    try {
      if (willMove) {
        final moveResult = await _envManager.moveDirectory(
          from: oldValue,
          to: newValue,
        );
        if (!moveResult.success) {
          if (!mounted) return;
          setState(() => _error = '数据迁移失败，环境变量未修改：${moveResult.error}');
          return;
        }
      }

      final result = await _envManager.writeBatch(
        variables: {item.variable: newValue},
        removePath: removePath,
        appendPath: appendPath,
        createDir: createDir || willMove,
      );

      if (!mounted) return;

      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${item.variable} 已更新为 $newValue'),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        );
        await _loadConfig();
      } else {
        setState(() => _error = '写入失败：${result.error}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  // ==================== 清除废弃变量 ====================

  Future<void> _clearVariable(EnvPathItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除废弃变量'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('变量：${item.variable}'),
            Text(
              '当前值：${item.currentValue}',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
            const SizedBox(height: 10),
            if (item.deprecationHint.isNotEmpty) Text(item.deprecationHint),
            const SizedBox(height: 10),
            const Text('只删除变量本身，不会动磁盘上的任何目录。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _writing = true;
      _error = null;
    });

    try {
      final scope = item.source == 'User' ? 'User' : 'Machine';
      final result = await _envManager.writeVariable(
        variable: item.variable,
        value: '',
        unset: true,
        scope: scope,
      );
      if (!mounted) return;
      if (result.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清除 ${item.variable}')),
        );
        await _loadConfig();
      } else {
        setState(() => _error = '清除失败：${result.error}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  // ==================== 填入推荐值（不写系统） ====================

  /// 把推荐值填进输入框，需要用户再点「应用」或「一键应用」才会真正写入。
  Future<void> _useRecommended() async {
    final result = _result;
    if (result == null) return;

    final fills = <String, String>{};
    for (final item in result.items) {
      if (item.deprecated || item.suggestedDefault.isEmpty) continue;
      final controller = _controllers[item.variable];
      if (controller == null) continue;
      if (_samePath(controller.text, item.suggestedDefault)) continue;
      fills[item.variable] = item.suggestedDefault;
    }

    if (fills.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('输入框里已经是推荐配置')),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用推荐配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('将把以下推荐值填入输入框：'),
              const SizedBox(height: 8),
              for (final entry in fills.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${entry.key} → ${entry.value}',
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 13,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                '这一步只改输入框，不会写入系统环境变量，'
                '也不会动磁盘上的任何目录。确认后还要点「一键应用当前所有环境变量」'
                '或各卡片的「应用」才会真正生效。',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认填入'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    _log('填入推荐值：${fills.entries.map((e) => '${e.key}=${e.value}').join('; ')}');
    setState(() {
      for (final entry in fills.entries) {
        _controllers[entry.key]?.text = entry.value;
      }
    });
  }

  /// 单个卡片的「使用默认值」，同样先确认再填。
  Future<void> _useDefaultFor(EnvPathItem item) async {
    final controller = _controllers[item.variable];
    if (controller == null || item.suggestedDefault.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('使用默认值'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('变量：${item.variable}'),
            const SizedBox(height: 4),
            Text(
              '填入：${item.suggestedDefault}',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
            const SizedBox(height: 10),
            const Text('只改输入框，不会写入系统。'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认填入'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;
    setState(() => controller.text = item.suggestedDefault);
  }

  // ==================== 一键应用输入框里的所有改动 ====================

  Future<void> _applyAllPending() async {
    final result = _result;
    if (result == null) return;

    final changes = <EnvPathItem>[];
    final newValues = <String, String>{};
    for (final item in result.items) {
      if (item.deprecated) continue;
      final controller = _controllers[item.variable];
      if (controller == null) continue;
      final newValue = controller.text.trim();
      if (newValue.isEmpty || _samePath(newValue, item.currentValue)) continue;
      changes.add(item);
      newValues[item.variable] = newValue;
    }

    if (changes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有修改，无需应用')),
      );
      return;
    }

    final nonEmptyOld = <String, _DirProbe>{};
    for (final item in changes) {
      final oldValue = item.currentValue.trim();
      if (oldValue.isEmpty) continue;
      final probe = _probeDirectory(oldValue);
      if (!probe.isEmpty) nonEmptyOld[item.variable] = probe;
    }

    final removePath = <String>[];
    final appendPath = <String>[];
    final newSdk = newValues['ANDROID_HOME'];
    if (newSdk != null) {
      for (final entry in result.pathEntries) {
        if (!entry.inPath || entry.fullPath.isEmpty) continue;
        removePath.add(entry.fullPath);
        appendPath.add(_joinWindowsPath(newSdk, entry.subDir));
      }
    }

    var migrate = nonEmptyOld.isNotEmpty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('一键应用环境变量'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('将修改以下系统环境变量：'),
                const SizedBox(height: 8),
                for (final item in changes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${item.variable}\n  ${item.currentValue.isEmpty ? '(未设置)' : item.currentValue}'
                      ' → ${newValues[item.variable]}',
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (removePath.isNotEmpty || appendPath.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text('同时同步系统 PATH：'),
                  for (final p in removePath)
                    Text(
                      '  − $p',
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                      ),
                    ),
                  for (final p in appendPath)
                    Text(
                      '  + $p',
                      style: const TextStyle(
                        fontFamily: 'Consolas',
                        fontSize: 12,
                      ),
                    ),
                ],
                if (nonEmptyOld.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  const Text('以下变量的旧目录里已有数据：'),
                  for (final entry in nonEmptyOld.entries)
                    Text(
                      '· ${entry.key}：'
                      '${entry.value.truncated ? '至少 ' : ''}${entry.value.files} 个文件 / '
                      '${_formatBytes(entry.value.bytes)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: migrate,
                    onChanged: (v) => setDialogState(() => migrate = v ?? false),
                    title: const Text('把旧目录内容迁移到新目录（推荐）'),
                    subtitle: const Text(
                      '不勾选则只改变量，旧数据留在原地，工具会在新路径重新下载。',
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                const Text(
                  '此操作需要管理员权限，并将自动创建目标目录。'
                  '已打开的终端和 IDE 需要重启才会读到新值。',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认应用'),
            ),
          ],
        ),
      ),
    );

    if (!mounted || confirmed != true) return;

    setState(() {
      _writing = true;
      _error = null;
    });

    final errors = <String>[];
    try {
      if (migrate) {
        for (final variable in nonEmptyOld.keys) {
          final from = changes
              .firstWhere((i) => i.variable == variable)
              .currentValue
              .trim();
          try {
            final moveResult = await _envManager.moveDirectory(
              from: from,
              to: newValues[variable]!,
            );
            if (!moveResult.success) {
              errors.add('$variable 数据迁移失败：${moveResult.error}');
            }
          } catch (error) {
            errors.add('$variable 数据迁移失败：$error');
          }
        }
      }

      if (errors.isNotEmpty) {
        if (!mounted) return;
        setState(() => _error = '迁移未完成，已中止变量写入：\n${errors.join('\n')}');
        return;
      }

      final batch = await _envManager.writeBatch(
        variables: newValues,
        removePath: removePath,
        appendPath: appendPath,
      );

      if (!mounted) return;
      if (batch.success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功配置 ${newValues.length} 个环境变量'),
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          ),
        );
      } else {
        setState(() => _error = '部分写入失败：${batch.error}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _writing = false);
      if (mounted) await _loadConfig();
    }
  }

  // ==================== PATH 追加 ====================

  Future<void> _appendPath(String path, {bool createDir = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认追加 PATH'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('将以下路径追加到系统 PATH：'),
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
      _writing = true;
      _error = null;
    });

    try {
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
        await _loadConfig();
      } else {
        setState(() => _error = '追加 PATH 失败：${result.error}');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            icon: Icons.tune_outlined,
            title: '环境变量配置',
            trailing: _result != null
                ? '${_result!.items.length} 项变量 · ${_result!.pathEntries.length} 项 PATH'
                : null,
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_result != null) ...[
                  OutlinedButton.icon(
                    onPressed: (_loading || _writing) ? null : _useRecommended,
                    icon: const Icon(Icons.recommend_outlined, size: 18),
                    label: const Text('使用推荐配置'),
                  ),
                  const SizedBox(width: 12),
                ],
                ActionButton(
                  label: _result != null ? '重新检测' : '检测环境',
                  icon: Icons.refresh,
                  loading: _loading,
                  onPressed: _loading ? null : _loadConfig,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_writing)
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
          if (_loading && _progress != null)
            ProgressPanel(progress: _progress!),
          if (_error != null) ErrorPanel(message: _error!),
          Expanded(child: _buildResult()),
        ],
      ),
    );
  }

  Widget _groupTitle(String text, {String? subtitle}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    if (_result == null && !_loading) {
      return const EmptyPanel(
        hint: '点击右上角「检测环境」查看当前环境变量配置',
      );
    }

    if (_result == null) return const SizedBox.shrink();

    final items = _result!.items;
    final pathEntries = _result!.pathEntries;

    final core = items.where((i) => i.isCore && !i.deprecated).toList();
    final others = items.where((i) => !i.isCore && !i.deprecated).toList();
    final deprecated = items.where((i) => i.deprecated).toList();

    return ListView(
      children: [
        if (core.isNotEmpty)
          _groupTitle(
            '推荐变量',
            subtitle: '与安装向导写入的口径一致，建议同一套 Android 根目录',
          ),
        for (final item in core)
          _EnvPathCard(
            item: item,
            controller: _controllers[item.variable],
            onApply: (value) => _applyVariable(item, value),
            onApplyWithDir: (value) =>
                _applyVariable(item, value, createDir: true),
            onClear: null,
            onUseDefault: () => _useDefaultFor(item),
          ),
        if (others.isNotEmpty)
          _groupTitle(
            '其他相关变量',
            subtitle: '系统里检测到的安卓/Java 相关变量，按需调整',
          ),
        for (final item in others)
          _EnvPathCard(
            item: item,
            controller: _controllers[item.variable],
            onApply: (value) => _applyVariable(item, value),
            onApplyWithDir: (value) =>
                _applyVariable(item, value, createDir: true),
            onClear: null,
            onUseDefault: () => _useDefaultFor(item),
          ),
        if (deprecated.isNotEmpty)
          _groupTitle(
            '已废弃变量（建议清除）',
            subtitle: '这些变量新版 Android Studio 已不再使用，留着反而会引发冲突',
          ),
        for (final item in deprecated)
          _EnvPathCard(
            item: item,
            controller: null,
            onApply: (_) {},
            onApplyWithDir: (_) {},
            onClear: () => _clearVariable(item),
            onUseDefault: null,
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
                  const SizedBox(height: 4),
                  Text(
                    '修改 ANDROID_HOME 时，这里已在 PATH 的条目会自动跟着改到新路径。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 12),
                  for (final entry in pathEntries)
                    _PathEntryTile(
                      entry: entry,
                      onAppend: () => _appendPath(entry.fullPath),
                      onAppendWithDir: () =>
                          _appendPath(entry.fullPath, createDir: true),
                    ),
                ],
              ),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 24),
          child: FilledButton.icon(
            onPressed: _writing ? null : _applyAllPending,
            icon: _writing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_fix_high),
            label: const Text('一键应用当前所有环境变量'),
          ),
        ),
      ],
    );
  }
}

class _EnvPathCard extends StatelessWidget {
  const _EnvPathCard({
    required this.item,
    required this.controller,
    required this.onApply,
    required this.onApplyWithDir,
    required this.onClear,
    required this.onUseDefault,
  });

  final EnvPathItem item;
  final TextEditingController? controller;
  final void Function(String value) onApply;
  final void Function(String value) onApplyWithDir;
  final VoidCallback? onClear;
  final VoidCallback? onUseDefault;

  Color _statusColor(BuildContext context) {
    if (item.deprecated) return Theme.of(context).colorScheme.error;
    if (item.source == 'NotSet') return Theme.of(context).colorScheme.outline;
    if (item.exists) return Colors.green;
    return Theme.of(context).colorScheme.error;
  }

  String _statusLabel() {
    if (item.deprecated) return '已废弃';
    if (item.source == 'NotSet') return '未配置';
    if (item.exists) return '正常';
    return '路径不存在';
  }

  IconData _varIcon() {
    if (item.deprecated) return Icons.warning_amber_outlined;
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
            if (item.deprecationHint.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                item.deprecationHint,
                style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
              ),
            ],
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
                  CopyButton(value: item.currentValue),
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
            if (onClear != null)
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('清除该变量'),
              ),
            if (onClear == null && controller != null) ...[
              TextField(
                controller: controller,
                style: textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
                decoration: InputDecoration(
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
                  if (onUseDefault != null &&
                      item.suggestedDefault.isNotEmpty &&
                      item.suggestedDefault != controller!.text)
                    TextButton(
                      onPressed: onUseDefault,
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
