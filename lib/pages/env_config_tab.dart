import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/pages/shared_widgets.dart';

class EnvConfigTab extends StatefulWidget {
  const EnvConfigTab({super.key});

  @override
  State<EnvConfigTab> createState() => _EnvConfigTabState();
}

class _EnvConfigTabState extends State<EnvConfigTab> {
  final _envManager = EnvPathManager();

  bool _loading = false;
  bool _writing = false;
  bool _rollingBack = false;
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
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _writeVariable(
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
      _writing = true;
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

  Future<void> _oneClickRewrite() async {
    if (_result == null) return;

    final changes = <MapEntry<String, String>>[];
    for (final item in _result!.items) {
      if (item.variable == 'GRADLE_USER_HOME') continue;
      final controller = _controllers[item.variable];
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
      _writing = true;
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

    setState(() => _writing = false);
    if (mounted) await _loadConfig();
  }

  Future<void> _rollback() async {
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
      _rollingBack = true;
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
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _rollingBack = false);
      if (mounted) await _loadConfig();
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
            icon: Icons.tune_outlined,
            title: '环境变量配置',
            trailing: _result != null
                ? '${_result!.items.length} 项变量 · ${_result!.pathEntries.length} 项 PATH'
                : null,
            action: ActionButton(
              label: _result != null ? '重新检测' : '检测环境',
              icon: Icons.refresh,
              loading: _loading,
              onPressed: _loading ? null : _loadConfig,
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

  Widget _buildResult() {
    if (_result == null && !_loading) {
      return const EmptyPanel(
        hint: '点击右上角「检测环境」查看当前环境变量配置',
      );
    }

    if (_result == null) return const SizedBox.shrink();

    final items = _result!.items;
    final pathEntries = _result!.pathEntries;

    return ListView(
      children: [
        for (final item in items)
          _EnvPathCard(
            item: item,
            controller: _controllers[item.variable],
            onApply: (value) => _writeVariable(item.variable, value),
            onApplyWithDir: (value) =>
                _writeVariable(item.variable, value, createDir: true),
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
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (items.any((item) =>
                  item.variable != 'GRADLE_USER_HOME' &&
                  _controllers[item.variable]?.text.trim().isNotEmpty ==
                      true))
                FilledButton.icon(
                  onPressed: _writing ? null : _oneClickRewrite,
                  icon: _writing
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
                  onPressed: (_writing || _rollingBack) ? null : _rollback,
                  icon: _rollingBack
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
    if (item.source == 'NotSet') return '未配置';
    if (item.exists) return '正常';
    return '路径不存在';
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
            if (controller != null) ...[
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
