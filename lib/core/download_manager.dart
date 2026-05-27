import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'models/download_task.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager({http.Client? client})
      : _client = client ?? _createDefaultClient();

  static http.Client _createDefaultClient() {
    final httpClient = HttpClient()..autoUncompress = false;
    return IOClient(httpClient);
  }

  final http.Client _client;
  final Map<String, DownloadTask> _tasks = {};
  final Map<String, StreamSubscription<List<int>>> _subscriptions = {};
  final Map<String, IOSink> _sinks = {};
  final Map<String, Stopwatch> _speedWatchers = {};
  final Map<String, int> _speedSamples = {};

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
    return uri.pathSegments.last;
  }

  // ── 启动时恢复已有的下载 ──

  void recoverCompleted(
    List<String> knownVersionKeys,
    String Function(String) urlForKey,
  ) {
    final dir = Directory(getDownloadsDir());
    if (!dir.existsSync()) return;

    final files = dir.listSync().whereType<File>().toList();

    // 恢复已完成的 .exe 文件
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
          break;
        }
      }
    }

    // 恢复未完成的 .part 文件（可续传）
    for (final file in files) {
      if (!file.path.endsWith('.part')) continue;
      for (final vk in knownVersionKeys) {
        final expectedName = fileNameFromUrl(urlForKey(vk));
        if (file.path.endsWith('$expectedName.part')) {
          _tasks[vk] = DownloadTask(
            versionKey: vk,
            url: urlForKey(vk),
            fileName: expectedName,
            filePath: file.path,
            state: DownloadState.paused,
            downloadedBytes: file.lengthSync(),
          );
          break;
        }
      }
    }
    notifyListeners();
  }

  // ── 开始/续传下载 ──

  Future<void> start(String versionKey, String url) async {
    if (_subscriptions.containsKey(versionKey)) return;

    final dir = getDownloadsDir();
    final fileName = fileNameFromUrl(url);
    final partPath = '$dir\\$fileName.part';
    final finalPath = '$dir\\$fileName';

    // 已有完成文件
    if (File(finalPath).existsSync()) {
      _tasks[versionKey] = DownloadTask(
        versionKey: versionKey,
        url: url,
        fileName: fileName,
        filePath: finalPath,
        state: DownloadState.completed,
        totalBytes: File(finalPath).lengthSync(),
        downloadedBytes: File(finalPath).lengthSync(),
      );
      notifyListeners();
      return;
    }

    // 计算续传偏移
    int existingBytes = 0;
    if (File(partPath).existsSync()) {
      existingBytes = File(partPath).lengthSync();
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
      final request = http.Request('GET', Uri.parse(url));
      if (existingBytes > 0) {
        request.headers['Range'] = 'bytes=$existingBytes-';
      }

      final response = await _client.send(request);

      if (response.statusCode != 200 && response.statusCode != 206) {
        _setError(versionKey, 'HTTP ${response.statusCode}');
        return;
      }

      final contentLength = response.contentLength ?? 0;
      final totalBytes =
          response.statusCode == 206 ? existingBytes + contentLength : contentLength;

      // 服务器忽略了 Range，重新开始
      if (response.statusCode == 200 && existingBytes > 0) {
        existingBytes = 0;
      }

      _updateTask(
        versionKey,
        _tasks[versionKey]!.copyWith(
          state: DownloadState.downloading,
          totalBytes:
              totalBytes > 0 ? totalBytes : _tasks[versionKey]!.totalBytes,
          downloadedBytes: existingBytes,
        ),
      );

      final sink = File(partPath).openWrite(
        mode: existingBytes > 0 ? FileMode.append : FileMode.write,
      );
      _sinks[versionKey] = sink;

      final stopwatch = Stopwatch()..start();
      _speedWatchers[versionKey] = stopwatch;
      _speedSamples[versionKey] = 0;

      final subscription = response.stream.listen(
        (chunk) {
          sink.add(chunk);
          final task = _tasks[versionKey];
          if (task == null) return;

          final newDownloaded = task.downloadedBytes + chunk.length;
          _speedSamples[versionKey] =
              (_speedSamples[versionKey] ?? 0) + chunk.length;

          int speed = task.speedBytesPerSec;
          if (stopwatch.elapsedMilliseconds >= _speedSampleWindowMs) {
            final sampleBytes = _speedSamples[versionKey] ?? 0;
            speed =
                (sampleBytes / stopwatch.elapsedMilliseconds * 1000).round();
            stopwatch.reset();
            stopwatch.start();
            _speedSamples[versionKey] = 0;
          }

          _tasks[versionKey] = task.copyWith(
            downloadedBytes: newDownloaded,
            speedBytesPerSec: speed,
          );
          notifyListeners();
        },
        onDone: () async {
          await sink.close();
          _sinks.remove(versionKey);
          _subscriptions.remove(versionKey);
          _speedWatchers.remove(versionKey);
          _speedSamples.remove(versionKey);

          final partFile = File(partPath);
          if (await partFile.exists()) {
            await partFile.rename(finalPath);
          }

          _updateTask(
            versionKey,
            _tasks[versionKey]!.copyWith(
              state: DownloadState.completed,
              filePath: finalPath,
              speedBytesPerSec: 0,
            ),
          );
        },
        onError: (Object error) async {
          await sink.close();
          _sinks.remove(versionKey);
          _subscriptions.remove(versionKey);
          _speedWatchers.remove(versionKey);
          _speedSamples.remove(versionKey);
          _setError(versionKey, error.toString());
        },
        cancelOnError: true,
      );

      _subscriptions[versionKey] = subscription;
    } catch (e) {
      _setError(versionKey, e.toString());
    }
  }

  // ── 暂停 ──

  Future<void> pause(String versionKey) async {
    final sub = _subscriptions.remove(versionKey);
    await sub?.cancel();
    final sink = _sinks.remove(versionKey);
    await sink?.flush();
    await sink?.close();
    _speedWatchers.remove(versionKey);
    _speedSamples.remove(versionKey);

    final task = _tasks[versionKey];
    if (task != null) {
      _tasks[versionKey] = task.copyWith(
        state: DownloadState.paused,
        speedBytesPerSec: 0,
      );
      notifyListeners();
    }
  }

  // ── 取消 ──

  Future<void> cancel(String versionKey) async {
    await pause(versionKey);
    final task = _tasks[versionKey];
    if (task != null) {
      final file = File(task.filePath);
      if (await file.exists()) {
        await file.delete();
      }
      _tasks.remove(versionKey);
      notifyListeners();
    }
  }

  // ── 打开文件 ──

  Future<void> openFile(String versionKey) async {
    final task = _tasks[versionKey];
    if (task == null || task.state != DownloadState.completed) return;
    await Process.start('explorer', ['/select,', task.filePath]);
  }

  // ── 内部工具 ──

  void _updateTask(String key, DownloadTask task) {
    _tasks[key] = task;
    notifyListeners();
  }

  void _setError(String key, String message) {
    final task = _tasks[key];
    if (task != null) {
      _tasks[key] = task.copyWith(
        state: DownloadState.error,
        errorMessage: message,
        speedBytesPerSec: 0,
      );
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subscriptions.values) {
      sub.cancel();
    }
    for (final sink in _sinks.values) {
      sink.close();
    }
    _client.close();
    super.dispose();
  }
}
