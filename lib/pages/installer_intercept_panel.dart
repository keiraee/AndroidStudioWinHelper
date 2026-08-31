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
        phase == InstallerInterceptPhase.interrupted ||
        phase == InstallerInterceptPhase.error;
  }

  String _hintForPhase(InstallerInterceptPhase phase) {
    return switch (phase) {
      InstallerInterceptPhase.waitingWizard ||
      InstallerInterceptPhase.alignedInstallDir ||
      InstallerInterceptPhase.installDirMiss ||
      InstallerInterceptPhase.alignedSdkTmp =>
        '请在官方 NSIS 安装向导中操作。我们会纠正安装目录、SDK 与用户配置路径。',
      InstallerInterceptPhase.installerFinished ||
      InstallerInterceptPhase.waitingStudioLaunch ||
      InstallerInterceptPhase.launchingStudio =>
        '安装向导关闭后仍需启动 Android Studio 完成首次 SDK 配置，这与 NSIS 解压是不同阶段。',
      InstallerInterceptPhase.studioRunning ||
      InstallerInterceptPhase.writingOtherXml =>
        'Android Studio 首次启动向导请在 IDE 内完成；本工具已预写 SDK 路径。',
      InstallerInterceptPhase.interrupted =>
        '监视已暂停。关闭此窗口后，可在下载页点击「继续安装」恢复。',
      _ => '安装监视运行中…',
    };
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
      title: const Text('安装监视'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_finished)
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
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
              _hintForPhase(_status.phase),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (_status.phase == InstallerInterceptPhase.alignedInstallDir)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '请确认安装向导中的路径已变为目标目录后再点 Next。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (!_finished &&
            _status.phase != InstallerInterceptPhase.studioRunning &&
            _status.phase != InstallerInterceptPhase.launchingStudio)
          TextButton(
            onPressed: _stopMonitoring,
            child: const Text('暂停监视'),
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
