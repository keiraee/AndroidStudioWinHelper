import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/installer_path_interceptor.dart';

Future<void> showInstallerInterceptPanel({
  required BuildContext context,
  required InstallerPathInterceptor interceptor,
}) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _InstallerInterceptDialog(interceptor: interceptor),
  );
}

class _InstallerInterceptDialog extends StatefulWidget {
  const _InstallerInterceptDialog({required this.interceptor});

  final InstallerPathInterceptor interceptor;

  @override
  State<_InstallerInterceptDialog> createState() =>
      _InstallerInterceptDialogState();
}

class _InstallerInterceptDialogState extends State<_InstallerInterceptDialog> {
  InstallerInterceptStatus _status = const InstallerInterceptStatus(
    phase: InstallerInterceptPhase.waitingWizard,
    message: '正在等待安装向导…',
  );

  bool _finished = false;

  @override
  void initState() {
    super.initState();
    widget.interceptor.statusStream.listen((status) {
      if (!mounted) return;
      setState(() {
        _status = status;
        _finished = _isTerminal(status.phase);
      });
    });
  }

  bool _isTerminal(InstallerInterceptPhase phase) {
    return phase == InstallerInterceptPhase.done ||
        phase == InstallerInterceptPhase.cancelled ||
        phase == InstallerInterceptPhase.error;
  }

  Future<void> _stopMonitoring() async {
    widget.interceptor.stopMonitoring();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: const Text('安装路径对齐'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (!_finished)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    _status.phase == InstallerInterceptPhase.done
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    color: _status.phase == InstallerInterceptPhase.done
                        ? colorScheme.primary
                        : colorScheme.outline,
                    size: 20,
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _status.message,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
            if (_status.detail != null && _status.detail!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _status.detail!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontFamily: 'Consolas',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              '请继续在官方安装向导中操作。我们会在进入下一步前自动纠正安装目录、SDK 与用户配置路径。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!_finished)
          TextButton(
            onPressed: _stopMonitoring,
            child: const Text('停止监视'),
          ),
        if (_finished)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
      ],
    );
  }
}
