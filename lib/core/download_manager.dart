import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/download/chunk_state.dart';
import 'package:androidstudiowinhelper/core/download/chunked_downloader.dart';
import 'package:androidstudiowinhelper/core/download/meta_store.dart';
import 'package:androidstudiowinhelper/core/file_utils.dart';
import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:flutter/foundation.dart';

import 'models/download_task.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager();

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, ChunkedDownloader> _downloaders = {};
  final Map<String, Stopwatch> _speedWatchers = {};
  final Map<String, int> _speedSamples = {};
  bool _disposed = false;

  static const int _speedSampleWindowMs = 800;

  DownloadTask? taskFor(String versionKey) => _tasks[versionKey];

  // ── 路径工具 ──

  static String getDownloadsDir() {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final dir = Directory(
      '$localAppData\\AndroidStudioWinHelper\\downloads',
    );
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir.path;
  }

  static String fileNameFromUrl(String url) {
    final uri = Uri.parse(url);
    if (uri.pathSegments.isEmpty) return url.split('/').last;
    return uri.pathSegments.last;
  }

  // ── 启动时恢复已有的下载 ──

  Future<void> recoverCompleted(
    List<String> knownVersionKeys,
    String Function(String) urlForKey,
  ) async {
    LogManager.instance.write('Download', '===== 恢复已有的下载任务 =====');
    final dir = Directory(getDownloadsDir());
    if (!dir.existsSync()) {
      LogManager.instance.write('Download', '下载目录不存在，跳过恢复');
      return;
    }

    final files = dir.listSync().whereType<File>().toList();
    LogManager.instance.write('Download', '下载目录: ${dir.path}, 文件数: ${files.length}');

    // 恢复已完成的 .exe 文件
    int recoveredComplete = 0;
    for (final file in files) {
      if (!file.path.endsWith('.exe') || file.path.endsWith('.part')) continue;
      for (final vk in knownVersionKeys) {
        final expectedName = fileNameFromUrl(urlForKey(vk));
        if (file.path.endsWith(expectedName)) {
          _tasks[vk] = DownloadTask(
            versionKey: vk,
            url: urlForKey(vk),
            fileName: expectedName,
            filePath: file.path,
            state: DownloadState.completed,
            totalBytes: file.lengthSync(),
            downloadedBytes: file.lengthSync(),
          );
          LogManager.instance.write('Download',
              '恢复已完成: $vk -> ${file.path} (${(file.lengthSync() / 1024 / 1024).toStringAsFixed(1)}MB)');
          recoveredComplete++;
          break;
        }
      }
    }

    // 恢复未完成的 .part 文件（可续传）
    int recoveredPaused = 0;
    for (final file in files) {
      if (!file.path.endsWith('.part') || file.path.endsWith('.part.meta')) continue;
      for (final vk in knownVersionKeys) {
        final expectedName = fileNameFromUrl(urlForKey(vk));
        if (file.path.endsWith('$expectedName.part')) {
          // 检查 .part.meta 是否存在以获取准确的已下载字节数
          final meta = await MetaStore.load(file.path);
          int downloadedBytes;
          if (meta != null) {
            downloadedBytes = meta.downloadedBytes;
            LogManager.instance.write('Download',
                '找到 .part.meta: $vk (${meta.chunkCount} 分片, '
                '已下载 ${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)}MB)');
          } else {
            downloadedBytes = file.lengthSync();
          }

          _tasks[vk] = DownloadTask(
            versionKey: vk,
            url: urlForKey(vk),
            fileName: expectedName,
            filePath: file.path,
            state: DownloadState.paused,
            downloadedBytes: downloadedBytes,
          );
          LogManager.instance.write('Download',
              '恢复可续传: $vk -> ${file.path} (已下载 ${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)}MB)');
          recoveredPaused++;
          break;
        }
      }
    }

    LogManager.instance.write('Download',
        '恢复完成: $recoveredComplete 个已完成, $recoveredPaused 个可续传');
    if (!_disposed) notifyListeners();
  }

  // ── 文件名生成 ──

  /// 从版本显示名生成文件名，如：
  /// "Quail 2 | 2026.1.2 Nightly 2026-06-04" → "android-studio-quail2-nightly-2026-06-04-windows.exe"
  /// "Panda 4 | 2025.3.4 Patch 1" → "android-studio-panda4-patch1-windows.exe"
  /// "Quail 2 | 2026.1.2 Canary 4" → "android-studio-quail2-canary4-windows.exe"
  /// "Panda 4 | 2025.3.4" → "android-studio-panda4-windows.exe"
  static String generateFileName(String versionKey, String url) {
    // 从 URL 提取扩展名
    final urlFileName = fileNameFromUrl(url);
    final ext = urlFileName.contains('.') ? '.${urlFileName.split('.').last}' : '.exe';

    // 解析版本名: "Codename | Version Channel"
    final parts = versionKey.split('|');
    final codename = (parts.isNotEmpty ? parts.first : versionKey).trim();
    final versionPart = parts.length > 1 ? parts[1].trim() : '';

    // codename 转安全文件名: "Quail 2" → "quail2", "Panda 4" → "panda4"
    final safeCodename = codename.toLowerCase().replaceAll(RegExp(r'\s+'), '');

    // 从 versionPart 提取 channel 标识
    // 如 "2026.1.2 Nightly 2026-06-04" → "nightly-2026-06-04"
    // 如 "2025.3.4 Patch 1" → "patch1"
    // 如 "2026.1.2 Canary 4" → "canary4"
    // 如 "2025.3.4" → "" (stable)
    String channelSuffix = '';

    // 移除版本号部分 (如 "2026.1.2", "2025.3.4")
    final withoutVersion = versionPart.replaceFirst(RegExp(r'^[\d.]+\s*'), '').trim();

    if (withoutVersion.isNotEmpty) {
      // "Nightly 2026-06-04" → "nightly-2026-06-04"
      // "Canary 4" → "canary4"
      // "Patch 1" → "patch1"
      // "RC 2" → "rc2"
      final normalized = withoutVersion.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
      // 只把 "word-N"（单词后跟连字符和单个数字）的连字符去掉
      // 保留 "2026-06-04" 这种日期格式的连字符
      channelSuffix = '-${normalized.replaceAllMapped(RegExp(r'\b(\w+)-(\d)\b'), (m) => '${m.group(1)}${m.group(2)}')}';
    }

    return 'android-studio-$safeCodename$channelSuffix$ext';
  }

  // ── 开始/续传下载 ──

  Future<void> start(String versionKey, String url) async {
    if (_downloaders.containsKey(versionKey)) {
      LogManager.instance.write('Download', '[$versionKey] 已在下载中，跳过');
      return;
    }

    LogManager.instance.write('Download', '===== 开始下载 =====');
    LogManager.instance.write('Download', '版本: $versionKey');
    LogManager.instance.write('Download', 'URL: $url');

    final dir = getDownloadsDir();
    final fileName = generateFileName(versionKey, url);
    final partPath = '$dir\\$fileName.part';
    final finalPath = '$dir\\$fileName';
    LogManager.instance.write('Download', '文件名: $fileName');
    LogManager.instance.write('Download', '目标路径: $finalPath');
    LogManager.instance.write('Download', '临时路径: $partPath');

    // 已有完成文件
    if (File(finalPath).existsSync()) {
      final size = File(finalPath).lengthSync();
      LogManager.instance.write('Download',
          '已存在完成文件，跳过下载 (${(size / 1024 / 1024).toStringAsFixed(1)}MB)');
      _tasks[versionKey] = DownloadTask(
        versionKey: versionKey,
        url: url,
        fileName: fileName,
        filePath: finalPath,
        state: DownloadState.completed,
        totalBytes: size,
        downloadedBytes: size,
      );
      if (!_disposed) notifyListeners();
      return;
    }

    // 检查是否有 .part.meta（可恢复的分片下载）
    DownloadMeta? existingMeta;
    int existingBytes = 0;
    if (File(partPath).existsSync()) {
      existingMeta = await MetaStore.load(partPath);
      if (existingMeta != null) {
        // 验证 URL 匹配
        if (existingMeta.url != url) {
          LogManager.instance.write('Download',
              '[$versionKey] .part.meta URL 不匹配，视为全新下载');
          existingMeta = null;
          existingBytes = File(partPath).lengthSync();
        } else {
          existingBytes = existingMeta.downloadedBytes;
          LogManager.instance.write('Download',
              '发现 .part.meta，准备恢复 (${existingMeta.chunkCount} 分片, '
              '已下载 ${(existingBytes / 1024 / 1024).toStringAsFixed(1)}MB)');
        }
      } else {
        // 旧格式 .part 文件（无 meta），迁移到新格式
        existingBytes = File(partPath).lengthSync();
        if (existingBytes > 0) {
          LogManager.instance.write('Download',
              '发现旧格式 .part 文件，迁移到分片格式 (已下载 ${(existingBytes / 1024 / 1024).toStringAsFixed(1)}MB)');
          existingMeta = await MetaStore.migrateFromLegacy(partPath, url);
        }
      }
    } else {
      LogManager.instance.write('Download', '全新下载');
    }

    _updateTask(
      versionKey,
      DownloadTask(
        versionKey: versionKey,
        url: url,
        fileName: fileName,
        filePath: partPath,
        state: DownloadState.connecting,
        downloadedBytes: existingBytes,
        startTime: DateTime.now(),
      ),
    );

    try {
      LogManager.instance.write('Download', '构建分片下载器...');

      final customHeaders = {
        'Referer': 'https://developer.android.google.cn/studio',
        'Accept': '*/*',
      };

      final downloader = ChunkedDownloader();
      _downloaders[versionKey] = downloader;

      // 启动速度计量
      final stopwatch = Stopwatch()..start();
      _speedWatchers[versionKey] = stopwatch;
      _speedSamples[versionKey] = 0;

      int lastLoggedPercent = -1;

      // 不阻塞调用方，fire-and-forget
      unawaited(downloader.start(
        url: url,
        partPath: partPath,
        finalPath: finalPath,
        existingMeta: existingMeta,
        headers: customHeaders,
        onProgress: (DownloadMeta meta) {
          if (_disposed) return;
          final task = _tasks[versionKey];
          if (task == null) return;

          final newDownloaded = meta.downloadedBytes;
          final totalBytes = meta.totalBytes;
          _speedSamples[versionKey] =
              (_speedSamples[versionKey] ?? 0) +
              (newDownloaded - task.downloadedBytes);

          int speed = task.speedBytesPerSec;
          if (stopwatch.elapsedMilliseconds >= _speedSampleWindowMs) {
            final sampleBytes = _speedSamples[versionKey] ?? 0;
            speed =
                (sampleBytes / stopwatch.elapsedMilliseconds * 1000).round();
            stopwatch.reset();
            stopwatch.start();
            _speedSamples[versionKey] = 0;
          }

          final completedChunks =
              meta.chunks.where((c) => c.isCompleted).length;
          final totalRetryCount =
              meta.chunks.fold<int>(0, (sum, c) => sum + c.retryCount);

          _tasks[versionKey] = task.copyWith(
            downloadedBytes: newDownloaded,
            totalBytes: totalBytes > 0 ? totalBytes : task.totalBytes,
            speedBytesPerSec: speed,
            totalChunks: meta.chunkCount,
            completedChunks: completedChunks,
            totalRetryCount: totalRetryCount,
          );

          // 每 10% 打印一次进度日志
          if (totalBytes > 0) {
            final percent = (newDownloaded * 100 ~/ totalBytes);
            if (percent >= lastLoggedPercent + 10) {
              lastLoggedPercent = percent;
              LogManager.instance.write('Download',
                  '[$versionKey] $percent% (${(newDownloaded / 1024 / 1024).toStringAsFixed(1)}/${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB) ${FormatUtils.speed(speed)} ${meta.chunkCount}分片');
            }
          }

          if (!_disposed) notifyListeners();
        },
        onComplete: () async {
          try {
            LogManager.instance.write('Download', '[$versionKey] 分片下载完成，清理状态...');
            _downloaders.remove(versionKey);
            _speedWatchers.remove(versionKey);
            _speedSamples.remove(versionKey);

            // ChunkedDownloader._finalize 已重命名 .part -> finalPath

            // 校验下载文件是否为有效的 PE 可执行文件
            LogManager.instance.write('Download', '[$versionKey] 开始文件完整性校验...');
            final valid = await FileUtils.validatePeFile(finalPath);
            if (!valid) {
              LogManager.instance.write('Download', '[$versionKey] 文件校验失败，删除无效文件');
              try { File(finalPath).deleteSync(); } catch (_) {}
              _setError(versionKey,
                  '下载的文件不是有效的安装包（可能被 Google 服务器拦截）。请尝试在浏览器中手动下载。');
              return;
            }

            // 下载完成，计算 SHA256 记入日志
            LogManager.instance.write('Download', '[$versionKey] 计算 SHA256...');
            final sha256 = await FileUtils.sha256(finalPath);
            LogManager.instance.write('Download',
                '[$versionKey] 下载完成: $finalPath (${File(finalPath).lengthSync()} bytes, SHA256: $sha256)');

            final task = _tasks[versionKey];
            if (task == null) return; // cancelled during async operation
            _updateTask(
              versionKey,
              task.copyWith(
                state: DownloadState.completed,
                filePath: finalPath,
                downloadedBytes: File(finalPath).lengthSync(),
                speedBytesPerSec: 0,
              ),
            );
          } catch (e) {
            LogManager.instance.write('Download', '[$versionKey] onComplete 异常: $e');
            _setError(versionKey, e.toString());
          }
        },
        onError: (String error) {
          LogManager.instance.write('Download', '[$versionKey] 下载错误: $error');
          _downloaders.remove(versionKey);
          _speedWatchers.remove(versionKey);
          _speedSamples.remove(versionKey);
          _setError(versionKey, error);
        },
      ));

      // 立即切换到 downloading 状态
      _updateTask(
        versionKey,
        _tasks[versionKey]!.copyWith(
          state: DownloadState.downloading,
        ),
      );

      LogManager.instance.write('Download', '[$versionKey] 分片下载器已启动');
    } catch (e) {
      LogManager.instance.write('Download', '[$versionKey] 下载异常: $e');
      _downloaders.remove(versionKey);
      _speedWatchers.remove(versionKey);
      _speedSamples.remove(versionKey);
      _setError(versionKey, e.toString());
    }
  }

  // ── 暂停 ──

  Future<void> pause(String versionKey) async {
    final task = _tasks[versionKey];
    LogManager.instance.write('Download',
        '[$versionKey] 暂停下载 (已下载 ${(task?.downloadedBytes ?? 0) / 1024 / 1024}MB)');

    final downloader = _downloaders.remove(versionKey);
    if (downloader != null) {
      await downloader.pause();
    }
    _speedWatchers.remove(versionKey);
    _speedSamples.remove(versionKey);

    if (task != null) {
      _tasks[versionKey] = task.copyWith(
        state: DownloadState.paused,
        speedBytesPerSec: 0,
      );
      if (!_disposed) notifyListeners();
    }
    LogManager.instance.write('Download', '[$versionKey] 暂停完成');
  }

  // ── 取消 ──

  Future<void> cancel(String versionKey) async {
    LogManager.instance.write('Download', '[$versionKey] 取消下载');
    final task = _tasks[versionKey];
    final downloader = _downloaders.remove(versionKey);
    if (downloader != null) {
      await downloader.cancel();
    } else if (task != null) {
      // 恢复出的暂停任务没有活跃 downloader，需手动清理 .part / .part.meta
      await _cleanupPartFiles(task);
    }
    _speedWatchers.remove(versionKey);
    _speedSamples.remove(versionKey);

    _tasks.remove(versionKey);
    if (!_disposed) notifyListeners();
    LogManager.instance.write('Download', '[$versionKey] 取消完成');
  }

  Future<void> _cleanupPartFiles(DownloadTask task) async {
    final partPath = task.filePath.endsWith('.part')
        ? task.filePath
        : (task.fileName.isNotEmpty
            ? '${getDownloadsDir()}\\${task.fileName}.part'
            : null);
    if (partPath == null || partPath.isEmpty) return;

    try {
      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.delete();
        LogManager.instance.write('Download', '已删除临时文件: $partPath');
      }
      await MetaStore.delete(partPath);
    } catch (e) {
      LogManager.instance.write('Download', '清理临时文件失败 ($partPath): $e');
    }
  }

  // ── 打开文件 ──

  Future<void> openFile(String versionKey) async {
    final task = _tasks[versionKey];
    if (task == null || task.state != DownloadState.completed) return;
    await Process.start('explorer', ['/select,', task.filePath]);
  }

  void _updateTask(String key, DownloadTask task) {
    _tasks[key] = task;
    if (!_disposed) notifyListeners();
  }

  void _setError(String key, String message) {
    LogManager.instance.write('Download', '[$key] 错误: $message');
    final task = _tasks[key];
    if (task != null) {
      _tasks[key] = task.copyWith(
        state: DownloadState.error,
        errorMessage: message,
        speedBytesPerSec: 0,
      );
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final downloader in _downloaders.values) {
      downloader.pause();
      downloader.dispose();
    }
    _downloaders.clear();
    super.dispose();
  }
}
