import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/download/chunk_state.dart';
import 'package:androidstudiowinhelper/core/download/chunked_downloader.dart';
import 'package:androidstudiowinhelper/core/download/download_shelf.dart';
import 'package:androidstudiowinhelper/core/download/meta_store.dart';
import 'package:androidstudiowinhelper/core/file_utils.dart';
import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
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

  Iterable<DownloadTask> get inProgressTasks => _tasks.values.where(
        (t) =>
            t.state == DownloadState.downloading ||
            t.state == DownloadState.paused ||
            t.state == DownloadState.connecting ||
            t.state == DownloadState.error,
      );

  Iterable<DownloadTask> get completedTasks => _tasks.values.where(
        (t) => t.state == DownloadState.completed,
      );

  // ── 路径工具 ──

  String? _downloadsDir;

  String? get downloadsDir => _downloadsDir;

  void useDownloadsDir(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _downloadsDir = dir.path;
  }

  String _requireDownloadsDir() {
    final dir = _downloadsDir;
    if (dir == null || dir.isEmpty) {
      throw StateError('未配置下载文件夹');
    }
    return dir;
  }

  static String fileNameFromUrl(String url) =>
      DownloadShelf.fileNameFromUrl(url);

  static String generateFileName(String versionKey, String url) =>
      DownloadShelf.generateFileName(versionKey, url);

  // ── 启动时恢复已有的下载 ──

  Future<void> recoverFromDisk([
    List<StudioVersion> versions = const [],
  ]) async {
    LogManager.instance.write('Download', '===== 恢复本地下载目录 =====');
    final downloadsDir = _downloadsDir;
    if (downloadsDir == null || downloadsDir.isEmpty) {
      _tasks.removeWhere((k, _) => !_downloaders.containsKey(k));
      LogManager.instance.write('Download', '未配置下载文件夹，跳过恢复');
      if (!_disposed) notifyListeners();
      return;
    }

    _tasks.removeWhere((k, _) => !_downloaders.containsKey(k));
    final dir = Directory(downloadsDir);
    if (!dir.existsSync()) {
      LogManager.instance.write('Download', '下载目录不存在，跳过恢复');
      return;
    }

    final files = dir.listSync().whereType<File>().toList();
    LogManager.instance.write(
      'Download',
      '下载目录: ${dir.path}, 文件数: ${files.length}',
    );

    var recoveredComplete = 0;
    var recoveredPaused = 0;

    for (final file in files) {
      final name = file.uri.pathSegments.isEmpty
          ? file.path.split(Platform.pathSeparator).last
          : file.uri.pathSegments.last;

      if (DownloadShelf.isCompletedExe(name)) {
        if (_occupiedByActiveDownload(name)) continue;
        final matched = DownloadShelf.matchVersionKey(
          fileName: name,
          versions: versions,
        );
        // 未匹配到版本列表时，仅保留文件名像 AS 安装包的 exe
        if (matched == null &&
            !DownloadShelf.looksLikeAndroidStudioInstaller(name)) {
          continue;
        }
        final key = matched ?? name;
        if (_downloaders.containsKey(key)) continue;
        final size = file.lengthSync();
        _putRecovered(
          key,
          DownloadTask(
            versionKey: key,
            url: _urlFor(key, versions),
            fileName: name,
            filePath: file.path,
            state: DownloadState.completed,
            totalBytes: size,
            downloadedBytes: size,
          ),
        );
        recoveredComplete++;
        continue;
      }

      if (!DownloadShelf.isPartFile(name)) continue;

      final exeName = DownloadShelf.exeNameFromPart(name);
      if (_occupiedByActiveDownload(exeName)) continue;
      final matchedPart = DownloadShelf.matchVersionKey(
        fileName: exeName,
        versions: versions,
      );
      if (matchedPart == null &&
          !DownloadShelf.looksLikeAndroidStudioInstaller(exeName)) {
        continue;
      }
      final key = matchedPart ?? exeName;
      if (_downloaders.containsKey(key)) continue;

      final meta = await MetaStore.load(file.path);
      final downloadedBytes = meta?.downloadedBytes ?? file.lengthSync();
      _putRecovered(
        key,
        DownloadTask(
          versionKey: key,
          url: meta?.url ?? _urlFor(key, versions),
          fileName: exeName,
          filePath: file.path,
          state: DownloadState.paused,
          totalBytes: meta?.totalBytes ?? 0,
          downloadedBytes: downloadedBytes,
        ),
      );
      recoveredPaused++;
    }

    LogManager.instance.write(
      'Download',
      '恢复完成: $recoveredComplete 个已完成, $recoveredPaused 个可续传',
    );
    if (!_disposed) notifyListeners();
  }

  bool _occupiedByActiveDownload(String fileName) {
    return _downloaders.keys.any((key) {
      final task = _tasks[key];
      return task != null &&
          (task.fileName == fileName ||
              task.filePath.endsWith(fileName) ||
              task.filePath.endsWith('$fileName.part'));
    });
  }

  String _urlFor(String key, List<StudioVersion> versions) {
    for (final v in versions) {
      if (v.version == key) return v.downloadUrl;
    }
    return '';
  }

  void _putRecovered(String key, DownloadTask task) {
    _tasks.removeWhere(
      (k, t) =>
          k != key &&
          !_downloaders.containsKey(k) &&
          t.filePath == task.filePath,
    );
    _tasks[key] = task;
  }

  // ── 文件名生成（兼容旧调用） ──

  Future<void> start(
    String versionKey,
    String url, {
    String? proxyUrl,
    String? expectedSha256,
  }) async {
    if (url.isEmpty) {
      LogManager.instance.write('Download', '[$versionKey] 缺少下载 URL，跳过');
      return;
    }

    if (_downloaders.containsKey(versionKey)) {
      LogManager.instance.write('Download', '[$versionKey] 已在下载中，跳过');
      return;
    }

    LogManager.instance.write('Download', '===== 开始下载 =====');
    LogManager.instance.write('Download', '版本: $versionKey');
    LogManager.instance.write('Download', 'URL: $url');

    final dir = _requireDownloadsDir();
    final existing = _tasks[versionKey];
    final fileName = (existing != null && existing.fileName.isNotEmpty)
        ? existing.fileName
        : generateFileName(versionKey, url);
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
        // 与官网归档页一致，降低被当成异常爬虫的概率
        'Referer': 'https://developer.android.com/studio/archive',
        'Accept': '*/*',
      };

      final downloader = ChunkedDownloader(proxyUrl: proxyUrl);
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
                  '下载的文件不是有效的安装包（可能被 Google 服务器拦截或返回了错误页）。请检查代理后重试，或在浏览器打开归档页手动下载。');
              return;
            }

            // 若归档页提供了 SHA-256，则强制校验
            LogManager.instance.write('Download', '[$versionKey] 计算 SHA256...');
            final sha256 = await FileUtils.sha256(finalPath);
            LogManager.instance.write('Download',
                '[$versionKey] SHA256: $sha256');
            final expected = expectedSha256?.trim().toLowerCase() ?? '';
            if (expected.isNotEmpty && sha256.isNotEmpty && sha256 != expected) {
              LogManager.instance.write('Download',
                  '[$versionKey] SHA256 不匹配: expected=$expected actual=$sha256');
              try { File(finalPath).deleteSync(); } catch (_) {}
              _setError(versionKey,
                  '安装包校验失败（SHA-256 与官方归档不一致），已删除损坏文件。请重试下载。');
              return;
            }

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
            ? '${_requireDownloadsDir()}\\${task.fileName}.part'
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

  /// 静默安装到指定目录。NSIS：`/S` 静默，`/D=` 必须为最后一个参数且不加引号。
  Future<Process?> runInstaller(
    String versionKey, {
    String? installHome,
  }) async {
    final task = _tasks[versionKey];
    if (task == null || task.state != DownloadState.completed) return null;

    final home = installHome
        ?.trim()
        .replaceAll('/', r'\')
        .replaceAll(RegExp(r'[\\/]+$'), '');
    final args = <String>['/S'];
    if (home != null && home.isNotEmpty) {
      args.add('/D=$home');
    }

    LogManager.instance.write(
      'Download',
      '[$versionKey] 静默启动安装程序: ${task.filePath} ${args.join(' ')}',
    );
    final workingDirectory = File(task.filePath).parent.path;

    return Process.start(
      task.filePath,
      args,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.normal,
    );
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
