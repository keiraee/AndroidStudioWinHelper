import 'package:flutter/material.dart';

import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/models/download_task.dart';

enum DownloadAction { start, pause, resume, cancel, open }

class DownloadProgressCard extends StatelessWidget {
  const DownloadProgressCard({
    super.key,
    required this.task,
    required this.onAction,
    this.hasUrl = true,
  });

  final DownloadTask? task;
  final void Function(DownloadAction action) onAction;
  final bool hasUrl;

  @override
  Widget build(BuildContext context) {
    if (!hasUrl) return const SizedBox.shrink();

    final state = task?.state ?? DownloadState.idle;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return switch (state) {
      DownloadState.idle => _buildIdleButton(context),
      DownloadState.connecting => _buildConnecting(context),
      DownloadState.downloading => _buildDownloading(context),
      DownloadState.paused => _buildPaused(context),
      DownloadState.completed => _buildCompleted(context, colorScheme),
      DownloadState.error => _buildError(context, colorScheme, textTheme),
    };
  }

  Widget _buildIdleButton(BuildContext context) {
    return FilledButton.icon(
      onPressed: () => onAction(DownloadAction.start),
      icon: const Icon(Icons.download, size: 18),
      label: const Text('下载安装包'),
    );
  }

  Widget _buildConnecting(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          '连接中…',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildDownloading(BuildContext context) {
    final t = task!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: t.percent,
            minHeight: 6,
            backgroundColor: colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              '${t.percentInt}%  ${FormatUtils.bytes(t.downloadedBytes)} / ${FormatUtils.bytes(t.totalBytes)}',
              style: textTheme.bodySmall?.copyWith(
                fontFamily: 'Consolas',
                fontSize: 12,
              ),
            ),
            const Spacer(),
            if (t.speedBytesPerSec > 0)
              Text(
                '${FormatUtils.speed(t.speedBytesPerSec)}  ',
                style: textTheme.bodySmall?.copyWith(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            if (t.eta != null)
              Text(
                '剩余 ${FormatUtils.duration(t.eta!)}',
                style: textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        // 分片与重试信息
        if (t.totalChunks != null && t.totalChunks! > 1) ...[
          const SizedBox(height: 4),
          _buildChunkRetryLine(context, colorScheme, textTheme),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => onAction(DownloadAction.pause),
              icon: const Icon(Icons.pause, size: 16),
              label: const Text('暂停'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => onAction(DownloadAction.cancel),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: colorScheme.error,
              ),
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建分片/重试状态行。
  Widget _buildChunkRetryLine(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final t = task!;
    final completed = t.completedChunks ?? 0;
    final total = t.totalChunks ?? 0;
    final retries = t.totalRetryCount ?? 0;

    final parts = <String>[];
    parts.add('分片: $completed/$total 完成');
    if (retries > 0) {
      parts.add('重试: $retries 次');
    }

    return Text(
      parts.join(' · '),
      style: textTheme.bodySmall?.copyWith(
        fontSize: 11,
        color: retries > 0
            ? colorScheme.tertiary
            : colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildPaused(BuildContext context) {
    final t = task!;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: t.percent,
            minHeight: 6,
            backgroundColor: colorScheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '已暂停  ${t.percentInt}%  ${FormatUtils.bytes(t.downloadedBytes)} / ${FormatUtils.bytes(t.totalBytes)}',
          style: textTheme.bodySmall?.copyWith(
            fontFamily: 'Consolas',
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => onAction(DownloadAction.resume),
              icon: const Icon(Icons.play_arrow, size: 16),
              label: const Text('继续'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => onAction(DownloadAction.cancel),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: colorScheme.error,
              ),
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCompleted(BuildContext context, ColorScheme colorScheme) {
    return Row(
      children: [
        Icon(Icons.check_circle, size: 18, color: Colors.green),
        const SizedBox(width: 8),
        Text(
          '下载完成',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.green,
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(width: 12),
        OutlinedButton.icon(
          onPressed: () => onAction(DownloadAction.open),
          icon: const Icon(Icons.folder_open, size: 16),
          label: const Text('打开文件'),
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
    );
  }

  Widget _buildError(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
  ) {
    final t = task!;
    final hasChunkInfo = t.totalChunks != null && t.totalChunks! > 1;
    final retries = t.totalRetryCount ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: colorScheme.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '下载失败: ${t.errorMessage}',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        // 分片失败详情
        if (hasChunkInfo) ...[
          const SizedBox(height: 4),
          Text(
            _buildErrorChunkDetail(t),
            style: textTheme.bodySmall?.copyWith(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        // 重试信息
        if (retries > 0) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 14, color: colorScheme.tertiary),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  '自动重试已尝试 $retries 次',
                  style: textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: colorScheme.tertiary,
                  ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => onAction(DownloadAction.resume),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => onAction(DownloadAction.cancel),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: colorScheme.error,
              ),
              child: const Text('取消'),
            ),
          ],
        ),
      ],
    );
  }

  /// 构建错误状态下的分片详情文字。
  String _buildErrorChunkDetail(DownloadTask t) {
    final completed = t.completedChunks ?? 0;
    final total = t.totalChunks ?? 0;
    final failed = total - completed;
    return '分片进度: $completed/$total 完成, $failed 个失败';
  }

}
