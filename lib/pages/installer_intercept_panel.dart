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
  static const _panelHeight = 188.0;

  InstallerInterceptStatus _status = const InstallerInterceptStatus(
    phase: InstallerInterceptPhase.listingPayload,
    message: '正在准备解包…',
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

  bool _isExtractPhase(InstallerInterceptPhase phase) {
    return phase == InstallerInterceptPhase.listingPayload ||
        phase == InstallerInterceptPhase.extracting ||
        phase == InstallerInterceptPhase.deploying ||
        phase == InstallerInterceptPhase.writingRegistry;
  }

  String _phaseLabel(InstallerInterceptPhase phase) {
    return switch (phase) {
      InstallerInterceptPhase.listingPayload => '扫描载荷',
      InstallerInterceptPhase.extracting => '解压中',
      InstallerInterceptPhase.deploying => '部署文件',
      InstallerInterceptPhase.writingRegistry => '注册表/快捷方式',
      InstallerInterceptPhase.installerFinished => '验证安装',
      InstallerInterceptPhase.writingOtherXml => '写入 SDK 配置',
      InstallerInterceptPhase.waitingStudioLaunch ||
      InstallerInterceptPhase.launchingStudio =>
        '启动 Studio',
      InstallerInterceptPhase.studioRunning => 'IDE 首次配置',
      InstallerInterceptPhase.done => '完成',
      InstallerInterceptPhase.error => '失败',
      InstallerInterceptPhase.cancelled => '已取消',
      _ => '进行中',
    };
  }

  String _hintForPhase(InstallerInterceptPhase phase) {
    return switch (phase) {
      InstallerInterceptPhase.listingPayload ||
      InstallerInterceptPhase.extracting ||
      InstallerInterceptPhase.deploying ||
      InstallerInterceptPhase.writingRegistry =>
        r'使用内置 7-Zip 直接解压 NSIS 安装包内的 $_31_ 载荷到指定目录。',
      InstallerInterceptPhase.installerFinished ||
      InstallerInterceptPhase.waitingStudioLaunch ||
      InstallerInterceptPhase.launchingStudio =>
        '解包部署结束后仍需启动 Android Studio 完成首次 SDK 配置。',
      InstallerInterceptPhase.studioRunning ||
      InstallerInterceptPhase.writingOtherXml =>
        'Android Studio 首次启动向导请在 IDE 内完成；本工具已预写 SDK 路径。',
      InstallerInterceptPhase.done =>
        '安装流程已完成。若 IDE 仍提示路径，请确认环境变量后重启 Studio。',
      InstallerInterceptPhase.error =>
        '安装未成功，请查看日志后重试。',
      InstallerInterceptPhase.cancelled => '安装已取消。',
      _ => '',
    };
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }

  Widget _ellipsisText({
    required String text,
    required TextStyle? style,
    int maxLines = 1,
  }) {
    return Text(
      text,
      style: style,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildExtractProgress(ThemeData theme, ColorScheme colorScheme) {
    final percent = _status.extractPercent.clamp(0, 100);
    final hasFileStats = _status.extractTotalFiles > 0;
    final hasByteStats = _status.extractTotalBytes > 0;
    final currentFile = _status.extractCurrentFile?.trim() ?? '';
    final targetDir = _status.nsisDirArg?.trim() ?? '';

    return Container(
      width: double.infinity,
      height: _panelHeight,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '解包进度',
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                _phaseLabel(_status.phase),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent > 0 ? percent / 100.0 : null,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),
          _ellipsisText(
            text: [
              '$percent%',
              if (hasFileStats)
                '文件 ${_status.extractDoneFiles}/${_status.extractTotalFiles}',
              if (hasByteStats)
                '${_formatBytes(_status.extractDoneBytes)} / ${_formatBytes(_status.extractTotalBytes)}',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'Consolas',
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '目标目录',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          _ellipsisText(
            text: targetDir.isEmpty ? '—' : targetDir,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'Consolas'),
          ),
          const SizedBox(height: 8),
          Text(
            '当前文件',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: _ellipsisText(
                text: currentFile.isEmpty ? '—' : currentFile,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'Consolas',
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPostInstallChecklist(ThemeData theme, ColorScheme colorScheme) {
    final userHome = _status.androidUserHome?.trim() ?? '';

    return Container(
      width: double.infinity,
      height: _panelHeight,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '装后配置',
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          _checkRow(
            theme: theme,
            colorScheme: colorScheme,
            label: '注册表 InstallLocation',
            ok: _status.registryPrimed ? true : null,
          ),
          _checkRow(
            theme: theme,
            colorScheme: colorScheme,
            label: 'ANDROID_USER_HOME → Sdk_userhome',
            ok: userHome.isNotEmpty ? true : null,
            detail: userHome.isEmpty ? null : userHome,
          ),
          _checkRow(
            theme: theme,
            colorScheme: colorScheme,
            label: 'other.xml + 启动 Studio 首次向导',
            ok: _status.phase == InstallerInterceptPhase.done
                ? true
                : (_finished ? false : null),
          ),
        ],
      ),
    );
  }

  Widget _checkRow({
    required ThemeData theme,
    required ColorScheme colorScheme,
    required String label,
    required bool? ok,
    String? detail,
  }) {
    final IconData icon;
    final Color color;
    if (ok == true) {
      icon = Icons.check_circle_outline;
      color = colorScheme.primary;
    } else if (ok == false) {
      icon = Icons.error_outline;
      color = colorScheme.error;
    } else {
      icon = Icons.hourglass_empty;
      color = colorScheme.outline;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                if (detail != null && detail.isNotEmpty)
                  _ellipsisText(
                    text: detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'Consolas',
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final showExtract = _isExtractPhase(_status.phase);
    final showPostChecklist =
        _status.phase == InstallerInterceptPhase.installerFinished ||
        _status.phase == InstallerInterceptPhase.writingOtherXml ||
        _status.phase == InstallerInterceptPhase.waitingStudioLaunch ||
        _status.phase == InstallerInterceptPhase.launchingStudio ||
        _status.phase == InstallerInterceptPhase.studioRunning ||
        _status.phase == InstallerInterceptPhase.done;
    final hint = _hintForPhase(_status.phase);

    return AlertDialog(
      title: const Text('解包安装监视'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 44,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
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
                    child: _ellipsisText(
                      text: _status.message,
                      style: theme.textTheme.bodyMedium,
                      maxLines: 2,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 32,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _ellipsisText(
                  text: _status.detail ?? '',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFamily: 'Consolas',
                  ),
                  maxLines: 2,
                ),
              ),
            ),
            if (showExtract)
              _buildExtractProgress(theme, colorScheme)
            else if (showPostChecklist)
              _buildPostInstallChecklist(theme, colorScheme)
            else
              SizedBox(height: _panelHeight),
            if (hint.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 40,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _ellipsisText(
                    text: hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_finished)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
      ],
    );
  }
}
