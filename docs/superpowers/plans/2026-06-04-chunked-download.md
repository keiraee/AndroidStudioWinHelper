# 多线程分片下载 + 智能重试 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将单线程流式下载改造为多线程分片下载，加入智能重试引擎，提升下载速度和可靠性。

**Architecture:** `DownloadManager` 退化为编排层，新增 `ChunkedDownloader` 负责分片并发下载，`RetryEngine` 负责按错误类型智能重试。分片状态通过 `.part.meta` JSON 文件持久化，支持细粒度续传。使用 `RandomAccessFile` 写入各分片对应 offset。

**Tech Stack:** Dart, `http` package, `RandomAccessFile`, JSON

---

## File Structure

| 操作 | 文件 | 职责 |
|------|------|------|
| Create | `lib/core/retry_engine.dart` | 智能重试引擎：错误分类 + 策略选择 |
| Create | `lib/core/chunk_state.dart` | 分片状态模型 + `.part.meta` 读写 |
| Create | `lib/core/chunked_downloader.dart` | 分片下载核心：带宽探测、并发下载、分片写入 |
| Modify | `lib/core/models/download_task.dart` | 扩展分片状态和重试状态字段 |
| Modify | `lib/core/download_manager.dart` | 集成 ChunkedDownloader，替换单线程下载 |
| Modify | `lib/pages/download_progress_card.dart` | 显示分片进度和重试状态 |

---

### Task 1: 分片状态模型 + `.part.meta` 读写

**Files:**
- Create: `lib/core/chunk_state.dart`
- Modify: `lib/core/models/download_task.dart`

- [ ] **Step 1: 创建 `chunk_state.dart`**

```dart
// lib/core/chunk_state.dart
import 'dart:convert';
import 'dart:io';

enum ChunkStatus { pending, downloading, completed, failed }

class ChunkState {
  const ChunkState({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.status = ChunkStatus.pending,
    this.retryCount = 0,
    this.lastError,
  });

  final int index;
  final int startByte;
  final int endByte; // 含
  final int downloadedBytes;
  final ChunkStatus status;
  final int retryCount;
  final String? lastError;

  int get totalBytes => endByte - startByte + 1;
  bool get isCompleted => status == ChunkStatus.completed;
  bool get isFailed => status == ChunkStatus.failed;
  bool get isPending => status == ChunkStatus.pending;
  bool get isDownloading => status == ChunkStatus.downloading;

  int get remainingBytes => totalBytes - downloadedBytes;

  ChunkState copyWith({
    int? downloadedBytes,
    ChunkStatus? status,
    int? retryCount,
    String? lastError,
  }) {
    return ChunkState(
      index: index,
      startByte: startByte,
      endByte: endByte,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': startByte,
        'end': endByte,
        'downloaded': downloadedBytes,
        'status': status.name,
        'retryCount': retryCount,
        if (lastError != null) 'lastError': lastError,
      };

  factory ChunkState.fromJson(Map<String, dynamic> json) {
    return ChunkState(
      index: json['index'] as int,
      startByte: json['start'] as int,
      endByte: json['end'] as int,
      downloadedBytes: json['downloaded'] as int? ?? 0,
      status: ChunkStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => ChunkStatus.pending,
      ),
      retryCount: json['retryCount'] as int? ?? 0,
      lastError: json['lastError'] as String?,
    );
  }
}

class DownloadMeta {
  const DownloadMeta({
    required this.url,
    required this.totalBytes,
    required this.chunks,
    this.version = 2,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int version;
  final String url;
  final int totalBytes;
  final List<ChunkState> chunks;
  final DateTime createdAt;

  int get chunkCount => chunks.length;
  int get completedChunks => chunks.where((c) => c.isCompleted).length;
  int get downloadedBytes =>
      chunks.fold(0, (sum, c) => sum + c.downloadedBytes);
  bool get allCompleted => chunks.every((c) => c.isCompleted);

  Map<String, dynamic> toJson() => {
        'version': version,
        'url': url,
        'totalBytes': totalBytes,
        'chunkCount': chunkCount,
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory DownloadMeta.fromJson(Map<String, dynamic> json) {
    final rawChunks = json['chunks'] as List?;
    return DownloadMeta(
      version: json['version'] as int? ?? 2,
      url: json['url'] as String? ?? '',
      totalBytes: json['totalBytes'] as int? ?? 0,
      chunks: rawChunks != null
          ? rawChunks
              .whereType<Map<String, dynamic>>()
              .map(ChunkState.fromJson)
              .toList()
          : [],
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  /// 保存到 .part.meta 文件
  void saveTo(String partPath) {
    final metaPath = '$partPath.meta';
    final json = const JsonEncoder.withIndent('  ').convert(toJson());
    File(metaPath).writeAsStringSync(json);
  }

  /// 从 .part.meta 文件加载
  static DownloadMeta? loadFrom(String partPath) {
    final metaPath = '$partPath.meta';
    final file = File(metaPath);
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return DownloadMeta.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  /// 删除 .part.meta 文件
  static void deleteFrom(String partPath) {
    final metaPath = '$partPath.meta';
    final file = File(metaPath);
    if (file.existsSync()) file.deleteSync();
  }
}
```

- [ ] **Step 2: 修改 `download_task.dart` 添加新字段**

```dart
// lib/core/models/download_task.dart — 在现有类基础上添加字段

enum DownloadState {
  idle,
  connecting,
  downloading,
  paused,
  completed,
  error,
}

class DownloadTask {
  const DownloadTask({
    required this.versionKey,
    required this.url,
    required this.fileName,
    required this.filePath,
    this.state = DownloadState.idle,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.speedBytesPerSec = 0,
    this.errorMessage = '',
    this.startTime,
    // 新增字段
    this.chunks = const [],
    this.chunkCount = 0,
    this.completedChunks = 0,
    this.retryState,
  });

  final String versionKey;
  final String url;
  final String fileName;
  final String filePath;
  final DownloadState state;
  final int totalBytes;
  final int downloadedBytes;
  final int speedBytesPerSec;
  final String errorMessage;
  final DateTime? startTime;

  // 新增字段
  final List<dynamic> chunks; // List<ChunkState> — 用 dynamic 避免循环导入
  final int chunkCount;
  final int completedChunks;
  final RetryStateData? retryState;

  double get percent =>
      totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  int get percentInt => (percent * 100).round();

  Duration? get eta {
    if (speedBytesPerSec <= 0 || totalBytes <= 0) return null;
    final remaining = totalBytes - downloadedBytes;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / speedBytesPerSec).ceil());
  }

  bool get canPause => state == DownloadState.downloading;
  bool get canResume =>
      state == DownloadState.paused || state == DownloadState.error;
  bool get canCancel =>
      state == DownloadState.downloading ||
      state == DownloadState.paused ||
      state == DownloadState.connecting;
  bool get canOpen => state == DownloadState.completed;

  DownloadTask copyWith({
    DownloadState? state,
    int? totalBytes,
    int? downloadedBytes,
    int? speedBytesPerSec,
    String? errorMessage,
    DateTime? startTime,
    String? filePath,
    List<dynamic>? chunks,
    int? chunkCount,
    int? completedChunks,
    RetryStateData? retryState,
  }) {
    return DownloadTask(
      versionKey: versionKey,
      url: url,
      fileName: fileName,
      filePath: filePath ?? this.filePath,
      state: state ?? this.state,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      speedBytesPerSec: speedBytesPerSec ?? this.speedBytesPerSec,
      errorMessage: errorMessage ?? this.errorMessage,
      startTime: startTime ?? this.startTime,
      chunks: chunks ?? this.chunks,
      chunkCount: chunkCount ?? this.chunkCount,
      completedChunks: completedChunks ?? this.completedChunks,
      retryState: retryState ?? this.retryState,
    );
  }
}

class RetryStateData {
  const RetryStateData({
    required this.currentRetry,
    required this.maxRetries,
    required this.lastError,
    required this.errorType,
    this.nextRetryAt,
  });

  final int currentRetry;
  final int maxRetries;
  final String lastError;
  final String errorType;
  final DateTime? nextRetryAt;
}
```

- [ ] **Step 3: 热重载验证**

运行 `flutter run -d windows`，确认无编译错误。

- [ ] **Step 4: Commit**

```
feat(download): add ChunkState model and extend DownloadTask with chunk/retry fields
```

---

### Task 2: 智能重试引擎

**Files:**
- Create: `lib/core/retry_engine.dart`

- [ ] **Step 1: 创建 `retry_engine.dart`**

```dart
// lib/core/retry_engine.dart
import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 错误类型枚举
enum DownloadErrorType {
  timeout,        // TimeoutException / SocketException 超时
  serverError,    // HTTP 5xx
  connectionReset, // Connection reset by peer
  rateLimited,    // HTTP 429
  clientError,    // HTTP 4xx (非 429) — 不重试
  dnsFailure,     // Failed host lookup
  unknown,        // 其他
}

/// 重试策略
class RetryPolicy {
  const RetryPolicy({
    required this.maxRetries,
    required this.intervals,
    this.canRetry = true,
  });

  final int maxRetries;
  final List<Duration> intervals; // 每次重试的间隔
  final bool canRetry;

  Duration intervalForRetry(int retryCount) {
    if (retryCount <= 0) return Duration.zero;
    final idx = (retryCount - 1).clamp(0, intervals.length - 1);
    return intervals[idx];
  }

  /// 不重试的策略
  static const noRetry = RetryPolicy(
    maxRetries: 0,
    intervals: [],
    canRetry: false,
  );
}

/// 智能重试引擎
class RetryEngine {
  static const _policies = <DownloadErrorType, RetryPolicy>{
    DownloadErrorType.timeout: RetryPolicy(
      maxRetries: 5,
      intervals: [
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
        Duration(seconds: 32),
      ],
    ),
    DownloadErrorType.serverError: RetryPolicy(
      maxRetries: 4,
      intervals: [
        Duration(seconds: 5),
        Duration(seconds: 15),
        Duration(seconds: 30),
        Duration(seconds: 60),
      ],
    ),
    DownloadErrorType.connectionReset: RetryPolicy(
      maxRetries: 5,
      intervals: [
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
        Duration(seconds: 16),
      ],
    ),
    DownloadErrorType.rateLimited: RetryPolicy(
      maxRetries: 3,
      intervals: [
        Duration(seconds: 30),
        Duration(seconds: 60),
        Duration(seconds: 120),
      ],
    ),
    DownloadErrorType.clientError: RetryPolicy.noRetry,
    DownloadErrorType.dnsFailure: RetryPolicy(
      maxRetries: 3,
      intervals: [
        Duration(seconds: 10),
        Duration(seconds: 30),
        Duration(seconds: 60),
      ],
    ),
    DownloadErrorType.unknown: RetryPolicy(
      maxRetries: 3,
      intervals: [
        Duration(seconds: 5),
        Duration(seconds: 15),
        Duration(seconds: 30),
      ],
    ),
  };

  /// 分类错误
  static DownloadErrorType classify(Object error, int? httpStatusCode) {
    // HTTP 状态码分类
    if (httpStatusCode != null) {
      if (httpStatusCode == 429) return DownloadErrorType.rateLimited;
      if (httpStatusCode >= 500) return DownloadErrorType.serverError;
      if (httpStatusCode >= 400) return DownloadErrorType.clientError;
    }

    final msg = error.toString().toLowerCase();

    // DNS 失败
    if (msg.contains('failed host lookup') || msg.contains('nodename nor servname')) {
      return DownloadErrorType.dnsFailure;
    }

    // 连接重置
    if (msg.contains('connection reset') || msg.contains('connection abort') ||
        msg.contains('broken pipe')) {
      return DownloadErrorType.connectionReset;
    }

    // 超时
    if (error is TimeoutException) return DownloadErrorType.timeout;
    if (error is SocketException) {
      if (msg.contains('timeout') || msg.contains('信号灯超时')) {
        return DownloadErrorType.timeout;
      }
      // 一般性 SocketException 也归为超时
      return DownloadErrorType.timeout;
    }

    return DownloadErrorType.unknown;
  }

  /// 获取重试策略
  static RetryPolicy policyFor(DownloadErrorType errorType) {
    return _policies[errorType] ?? RetryPolicy.noRetry;
  }

  /// 判断是否应该重试
  static bool shouldRetry(Object error, int? httpStatusCode, int currentRetry) {
    final errorType = classify(error, httpStatusCode);
    final policy = policyFor(errorType);
    return policy.canRetry && currentRetry < policy.maxRetries;
  }

  /// 获取重试间隔
  static Duration retryDelay(Object error, int? httpStatusCode, int currentRetry) {
    final errorType = classify(error, httpStatusCode);
    final policy = policyFor(errorType);
    return policy.intervalForRetry(currentRetry);
  }

  /// 获取 HTTP 429 的 Retry-After 头（如果有）
  static Duration? parseRetryAfter(Map<String, String> headers) {
    final retryAfter = headers['retry-after'];
    if (retryAfter == null) return null;
    final seconds = int.tryParse(retryAfter);
    if (seconds != null) return Duration(seconds: seconds);
    return null;
  }

  /// 日志：记录错误分类
  static void logClassification(String tag, Object error, int? httpStatusCode, int retryCount) {
    final errorType = classify(error, httpStatusCode);
    final policy = policyFor(errorType);
    LogManager.instance.write('Retry',
        '[$tag] 错误类型: ${errorType.name}, 重试: $retryCount/${policy.maxRetries}, '
        '可重试: ${policy.canRetry}');
  }
}
```

- [ ] **Step 2: 热重载验证**

运行 `flutter run -d windows`，确认无编译错误。

- [ ] **Step 3: Commit**

```
feat(download): add RetryEngine with error classification and smart retry policies
```

---

### Task 3: 分片下载核心

**Files:**
- Create: `lib/core/chunked_downloader.dart`

- [ ] **Step 1: 创建 `chunked_downloader.dart`**

```dart
// lib/core/chunked_downloader.dart
import 'dart:async';
import 'dart:io';

import 'package:androidstudiowinhelper/core/chunk_state.dart';
import 'package:androidstudiowinhelper/core/format_utils.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/retry_engine.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 分片下载进度回调
typedef ChunkProgressCallback = void Function(int downloadedBytes, int speedBytesPerSec);
typedef ChunkCompleteCallback = void Function(int chunkIndex);
typedef AllCompleteCallback = void Function();

/// 分片下载器
class ChunkedDownloader {
  ChunkedDownloader({http.Client? client})
      : _client = client ?? _createDefaultClient();

  static http.Client _createDefaultClient() {
    final httpClient = HttpClient()
      ..autoUncompress = false
      ..userAgent =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
    return IOClient(httpClient);
  }

  final http.Client _client;
  final Map<String, bool> _paused = {};
  final Map<String, bool> _cancelled = {};
  final Map<String, List<StreamSubscription<List<int>>>> _chunkSubscriptions = {};

  static const _speedSampleWindowMs = 800;

  void _log(String msg) => LogManager.instance.write('ChunkDL', msg);

  // ── 带宽探测 ──

  /// 探测带宽，返回建议的分片数
  Future<int> probeAndDecideChunks(String url) async {
    _log('带宽探测: 下载前 2MB 测速...');
    final stopwatch = Stopwatch()..start();
    int downloaded = 0;
    const probeBytes = 2 * 1024 * 1024; // 2MB

    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Range'] = 'bytes=0-${probeBytes - 1}';
      request.headers['Accept-Encoding'] = 'identity';
      request.headers['Referer'] = 'https://developer.android.google.cn/studio';
      final response = await _client.send(request).timeout(
        const Duration(seconds: 15),
      );

      await for (final chunk in response.stream) {
        downloaded += chunk.length;
        if (downloaded >= probeBytes) break;
      }
    } catch (e) {
      _log('带宽探测失败: $e，使用默认 2 分片');
      return 2;
    }

    stopwatch.stop();
    final elapsedSec = stopwatch.elapsedMilliseconds / 1000;
    if (elapsedSec <= 0) return 4;

    final speedMBps = downloaded / 1024 / 1024 / elapsedSec;
    _log('带宽探测结果: ${speedMBps.toStringAsFixed(1)} MB/s (${downloaded} bytes in ${elapsedSec.toStringAsFixed(1)}s)');

    int chunks;
    if (speedMBps < 2) {
      chunks = 2;
    } else if (speedMBps < 5) {
      chunks = 4;
    } else if (speedMBps < 10) {
      chunks = 8;
    } else {
      chunks = 16;
    }
    _log('决定分片数: $chunks');
    return chunks;
  }

  // ── HEAD 请求获取文件大小 ──

  Future<int> getContentLength(String url) async {
    final request = http.Request('HEAD', Uri.parse(url));
    request.headers['Accept-Encoding'] = 'identity';
    request.headers['Referer'] = 'https://developer.android.google.cn/studio';
    final response = await _client.send(request).timeout(
      const Duration(seconds: 15),
    );
    return response.contentLength ?? 0;
  }

  // ── 分片切分 ──

  static List<ChunkState> splitChunks(int totalBytes, int chunkCount) {
    final chunkSize = totalBytes ~/ chunkCount;
    final chunks = <ChunkState>[];

    for (var i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (i == chunkCount - 1) ? totalBytes - 1 : (i + 1) * chunkSize - 1;
      chunks.add(ChunkState(
        index: i,
        startByte: start,
        endByte: end,
      ));
    }

    return chunks;
  }

  // ── 并发下载 ──

  /// 下载单个文件（分片模式）
  Future<void> download({
    required String url,
    required String partPath,
    required String finalPath,
    required DownloadMeta meta,
    required void Function(DownloadMeta updatedMeta) onMetaUpdate,
    required ChunkProgressCallback onProgress,
    required AllCompleteCallback onComplete,
    required void Function(Object error, int? httpStatusCode) onError,
    required String versionKey,
  }) async {
    _log('[$versionKey] ===== 分片下载开始 =====');
    _log('[$versionKey] 分片数: ${meta.chunkCount}, 总大小: ${FormatUtils.bytes(meta.totalBytes)}');

    _paused[versionKey] = false;
    _cancelled[versionKey] = false;
    _chunkSubscriptions[versionKey] = [];

    // 预分配文件（确保文件大小正确）
    final file = File(partPath);
    final raf = await file.open(mode: FileMode.write);
    await raf.setPosition(meta.totalBytes - 1);
    await raf.writeByte(0);
    await raf.close();

    // 为每个未完成的分片启动下载
    final futures = <Future<void>>[];
    for (var i = 0; i < meta.chunks.length; i++) {
      final chunk = meta.chunks[i];
      if (chunk.isCompleted) {
        _log('[$versionKey] 分片 $i 已完成，跳过');
        continue;
      }
      futures.add(_downloadChunk(
        url: url,
        partPath: partPath,
        meta: meta,
        chunkIndex: i,
        onMetaUpdate: onMetaUpdate,
        onProgress: onProgress,
        versionKey: versionKey,
      ));
    }

    // 等待所有分片完成
    try {
      await Future.wait(futures);
    } catch (e) {
      // 检查是否是暂停/取消导致的
      if (_cancelled[versionKey] == true) return;
      if (_paused[versionKey] == true) return;

      // 检查是否所有分片都完成了（可能某个分片的重试成功了）
      if (meta.allCompleted) {
        _log('[$versionKey] 所有分片已完成（忽略错误）');
      } else {
        rethrow;
      }
    }

    if (_cancelled[versionKey] == true) return;
    if (_paused[versionKey] == true) return;

    // 全部分片完成
    _log('[$versionKey] 全部分片下载完成');
    onComplete();
  }

  /// 下载单个分片（含智能重试）
  Future<void> _downloadChunk({
    required String url,
    required String partPath,
    required DownloadMeta meta,
    required int chunkIndex,
    required void Function(DownloadMeta updatedMeta) onMetaUpdate,
    required ChunkProgressCallback onProgress,
    required String versionKey,
  }) async {
    var chunk = meta.chunks[chunkIndex];
    int retryCount = 0;

    while (true) {
      if (_paused[versionKey] == true || _cancelled[versionKey] == true) return;

      try {
        await _doChunkDownload(
          url: url,
          partPath: partPath,
          meta: meta,
          chunk: chunk,
          chunkIndex: chunkIndex,
          onMetaUpdate: onMetaUpdate,
          onProgress: onProgress,
          versionKey: versionKey,
        );
        return; // 成功
      } catch (e) {
        final statusCode = _extractStatusCode(e);
        RetryEngine.logClassification('[$versionKey] 分片$chunkIndex', e, statusCode, retryCount);

        if (!RetryEngine.shouldRetry(e, statusCode, retryCount)) {
          _log('[$versionKey] 分片 $chunkIndex 不可重试，标记失败');
          chunk = chunk.copyWith(status: ChunkStatus.failed, lastError: e.toString());
          meta.chunks[chunkIndex] = chunk;
          onMetaUpdate(meta);
          rethrow;
        }

        retryCount++;
        final delay = RetryEngine.retryDelay(e, statusCode, retryCount);
        _log('[$versionKey] 分片 $chunkIndex 重试 $retryCount，等待 ${delay.inSeconds}s');

        // 更新重试状态
        chunk = chunk.copyWith(
          status: ChunkStatus.failed,
          retryCount: retryCount,
          lastError: e.toString(),
        );
        meta.chunks[chunkIndex] = chunk;
        onMetaUpdate(meta);

        await Future.delayed(delay);

        if (_paused[versionKey] == true || _cancelled[versionKey] == true) return;

        // 更新 chunk 引用（meta 可能已被其他分片更新）
        chunk = meta.chunks[chunkIndex];
      }
    }
  }

  /// 执行单个分片的实际下载
  Future<void> _doChunkDownload({
    required String url,
    required String partPath,
    required DownloadMeta meta,
    required ChunkState chunk,
    required int chunkIndex,
    required void Function(DownloadMeta updatedMeta) onMetaUpdate,
    required ChunkProgressCallback onProgress,
    required String versionKey,
  }) async {
    final startByte = chunk.startByte + chunk.downloadedBytes;
    final endByte = chunk.endByte;

    if (startByte > endByte) {
      // 分片已完成
      meta.chunks[chunkIndex] = chunk.copyWith(status: ChunkStatus.completed);
      onMetaUpdate(meta);
      return;
    }

    _log('[$versionKey] 分片 $chunkIndex: 请求 bytes=$startByte-$endByte');

    final request = http.Request('GET', Uri.parse(url));
    request.headers['Range'] = 'bytes=$startByte-$endByte';
    request.headers['Accept-Encoding'] = 'identity';
    request.headers['Referer'] = 'https://developer.android.google.cn/studio';

    final response = await _client.send(request).timeout(
      const Duration(seconds: 30),
    );

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
    }

    // 标记分片为下载中
    meta.chunks[chunkIndex] = chunk.copyWith(status: ChunkStatus.downloading);
    onMetaUpdate(meta);

    // 打开文件写入
    final raf = await File(partPath).open(mode: FileMode.writeOnly);
    await raf.setPosition(startByte);

    var chunkDownloaded = chunk.downloadedBytes;
    final stopwatch = Stopwatch()..start();
    var sampleBytes = 0;

    final completer = Completer<void>();
    final subscription = response.stream.listen(
      (data) async {
        if (_paused[versionKey] == true || _cancelled[versionKey] == true) {
          if (!completer.isCompleted) completer.complete();
          return;
        }

        await raf.writeFrom(data);
        chunkDownloaded += data.length;
        sampleBytes += data.length;

        // 计算速度
        int speed = 0;
        if (stopwatch.elapsedMilliseconds >= _speedSampleWindowMs) {
          speed = (sampleBytes / stopwatch.elapsedMilliseconds * 1000).round();
          stopwatch.reset();
          stopwatch.start();
          sampleBytes = 0;
        }

        onProgress(chunkDownloaded, speed);

        // 更新 meta
        meta.chunks[chunkIndex] = meta.chunks[chunkIndex].copyWith(
          downloadedBytes: chunkDownloaded,
        );
      },
      onDone: () async {
        await raf.close();
        meta.chunks[chunkIndex] = meta.chunks[chunkIndex].copyWith(
          status: ChunkStatus.completed,
          downloadedBytes: chunkDownloaded,
        );
        onMetaUpdate(meta);
        _log('[$versionKey] 分片 $chunkIndex 完成 (${FormatUtils.bytes(chunkDownloaded)})');
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object error) async {
        await raf.close();
        if (!completer.isCompleted) completer.completeError(error);
      },
      cancelOnError: true,
    );

    _chunkSubscriptions[versionKey]?.add(subscription);
    await completer.future;
    await subscription.cancel();
  }

  /// 暂停下载
  void pause(String versionKey) {
    _log('[$versionKey] 暂停分片下载');
    _paused[versionKey] = true;
    // 取消所有活跃的分片订阅
    for (final sub in _chunkSubscriptions[versionKey] ?? []) {
      sub.cancel();
    }
    _chunkSubscriptions.remove(versionKey);
  }

  /// 取消下载
  void cancel(String versionKey) {
    _log('[$versionKey] 取消分片下载');
    _cancelled[versionKey] = true;
    pause(versionKey);
  }

  /// 释放资源
  void dispose() {
    for (final subs in _chunkSubscriptions.values) {
      for (final sub in subs) {
        sub.cancel();
      }
    }
    _chunkSubscriptions.clear();
    _client.close();
  }

  /// 从异常中提取 HTTP 状态码
  int? _extractStatusCode(Object error) {
    final msg = error.toString();
    final match = RegExp(r'HTTP (\d{3})').firstMatch(msg);
    if (match != null) return int.tryParse(match.group(1)!);
    if (error is HttpException) {
      final match2 = RegExp(r'(\d{3})').firstMatch(error.message);
      if (match2 != null) return int.tryParse(match2.group(1)!);
    }
    return null;
  }
}
```

- [ ] **Step 2: 热重载验证**

运行 `flutter run -d windows`，确认无编译错误。

- [ ] **Step 3: Commit**

```
feat(download): add ChunkedDownloader with adaptive chunking and per-chunk retry
```

---

### Task 4: 集成到 DownloadManager

**Files:**
- Modify: `lib/core/download_manager.dart`

- [ ] **Step 1: 重构 `start()` 方法使用 `ChunkedDownloader`**

在 `download_manager.dart` 中：

1. 添加 `_chunkedDownloader` 字段
2. 添加 `_activeDownloaders` map 跟踪每个任务的 downloader
3. 替换 `start()` 方法的核心下载逻辑
4. 更新 `pause()` 和 `cancel()` 使用分片暂停/取消
5. 更新 `recoverCompleted()` 支持读取 `.part.meta`

关键变更点：

```dart
// 在类顶部添加
final ChunkedDownloader _chunkedDownloader = ChunkedDownloader();
final Map<String, ChunkedDownloader> _activeDownloaders = {};

// start() 方法核心逻辑替换为：
Future<void> start(String versionKey, String url) async {
  // ... 保留文件名生成、已完成检查 ...

  // 检查是否有 .part.meta（新格式续传）
  final meta = DownloadMeta.loadFrom(partPath);
  DownloadMeta currentMeta;

  if (meta != null && meta.url == url) {
    // 新格式续传
    LogManager.instance.write('Download', '[$versionKey] 发现 .part.meta，续传 (${meta.completedChunks}/${meta.chunkCount} 分片完成)');
    currentMeta = meta;
  } else if (File(partPath).existsSync()) {
    // 旧格式续传 → 转换为新格式
    final existingBytes = File(partPath).lengthSync();
    LogManager.instance.write('Download', '[$versionKey] 旧格式 .part 文件，转换为分片格式');
    currentMeta = DownloadMeta(
      url: url,
      totalBytes: existingBytes, // 临时，HEAD 请求后更新
      chunks: [ChunkState(index: 0, startByte: 0, endByte: existingBytes - 1, downloadedBytes: existingBytes, status: ChunkStatus.completed)],
    );
  } else {
    // 全新下载
    LogManager.instance.write('Download', '[$versionKey] 全新下载');

    // HEAD 请求获取文件大小
    final totalBytes = await _chunkedDownloader.getContentLength(url);
    LogManager.instance.write('Download', '[$versionKey] 文件大小: ${FormatUtils.bytes(totalBytes)}');

    // 带宽探测
    final chunkCount = await _chunkedDownloader.probeAndDecideChunks(url);

    // 切分分片
    final chunks = ChunkedDownloader.splitChunks(totalBytes, chunkCount);
    currentMeta = DownloadMeta(url: url, totalBytes: totalBytes, chunks: chunks);
    currentMeta.saveTo(partPath);
  }

  // 更新任务状态
  _updateTask(versionKey, DownloadTask(...));

  // 启动分片下载
  await _chunkedDownloader.download(
    url: url,
    partPath: partPath,
    finalPath: finalPath,
    meta: currentMeta,
    onMetaUpdate: (updatedMeta) {
      updatedMeta.saveTo(partPath);
      // 更新任务的下载字节数
      final task = _tasks[versionKey];
      if (task != null) {
        _tasks[versionKey] = task.copyWith(
          downloadedBytes: updatedMeta.downloadedBytes,
          completedChunks: updatedMeta.completedChunks,
          chunkCount: updatedMeta.chunkCount,
        );
        if (!_disposed) notifyListeners();
      }
    },
    onProgress: (downloaded, speed) {
      // 更新速度
    },
    onComplete: () async {
      // rename → 校验 → SHA256（保留现有逻辑）
    },
    onError: (error, statusCode) {
      _setError(versionKey, error.toString());
    },
    versionKey: versionKey,
  );
}
```

- [ ] **Step 2: 更新 `pause()` 和 `cancel()`**

```dart
Future<void> pause(String versionKey) async {
  _chunkedDownloader.pause(versionKey);
  final task = _tasks[versionKey];
  if (task != null) {
    _tasks[versionKey] = task.copyWith(
      state: DownloadState.paused,
      speedBytesPerSec: 0,
    );
    if (!_disposed) notifyListeners();
  }
  LogManager.instance.write('Download', '[$versionKey] 暂停完成');
}

Future<void> cancel(String versionKey) async {
  _chunkedDownloader.cancel(versionKey);
  // 删除 .part 和 .part.meta 文件
  final task = _tasks[versionKey];
  if (task != null) {
    File(task.filePath).deleteSync(); // .part
    DownloadMeta.deleteFrom(task.filePath); // .part.meta
    _tasks.remove(versionKey);
    if (!_disposed) notifyListeners();
  }
}
```

- [ ] **Step 3: 更新 `recoverCompleted()` 支持 `.part.meta`**

在恢复 `.part` 文件时，同时检查 `.part.meta`：
- 如果有 `.part.meta`，读取分片状态，恢复为 paused（有未完成分片）
- 如果没有 `.part.meta`（旧格式），恢复为 paused（整个文件作为单分片）

- [ ] **Step 4: 更新 `dispose()`**

```dart
@override
void dispose() {
  _disposed = true;
  _chunkedDownloader.dispose();
  for (final sub in _subscriptions.values) {
    sub.cancel();
  }
  for (final sink in _sinks.values) {
    sink.close();
  }
  _client.close();
  super.dispose();
}
```

- [ ] **Step 5: 热重载验证**

运行 `flutter run -d windows`，开始一个下载，验证：
1. 带宽探测日志输出
2. 分片数日志输出
3. 多个分片并发下载
4. 暂停/恢复正常工作
5. `.part.meta` 文件正确生成

- [ ] **Step 6: Commit**

```
feat(download): integrate ChunkedDownloader into DownloadManager
```

---

### Task 5: UI 更新

**Files:**
- Modify: `lib/pages/download_progress_card.dart`

- [ ] **Step 1: 更新下载中状态显示**

在 `_buildDownloading()` 方法中添加分片信息：

```dart
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
      // 新增：分片进度
      if (t.chunkCount > 0) ...[
        const SizedBox(height: 4),
        Text(
          '分片: ${t.completedChunks}/${t.chunkCount} 完成${t.retryState != null ? ' · 重试: ${t.retryState!.currentRetry} 次' : ''}',
          style: textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: colorScheme.onSurfaceVariant,
            fontFamily: 'Consolas',
          ),
        ),
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
```

- [ ] **Step 2: 更新错误状态显示重试信息**

在 `_buildError()` 方法中，如果 `retryState` 存在，显示重试信息：

```dart
Widget _buildError(BuildContext context, ColorScheme colorScheme, TextTheme textTheme) {
  final t = task!;
  final retry = t.retryState;

  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              retry != null
                  ? '分片失败: ${t.errorMessage}'
                  : '下载失败: ${t.errorMessage}',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.error,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      // 新增：重试状态
      if (retry != null) ...[
        const SizedBox(height: 4),
        Text(
          '自动重试中... (${retry.currentRetry}/${retry.maxRetries})',
          style: textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: colorScheme.onSurfaceVariant,
          ),
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
      ],
    ],
  );
}
```

- [ ] **Step 3: 热重载验证**

运行 `flutter run -d windows`，开始下载，验证：
1. 分片进度正确显示
2. 重试时显示重试信息
3. 其他状态（idle、completed、paused）不受影响

- [ ] **Step 4: Commit**

```
feat(download): update DownloadProgressCard to show chunk progress and retry state
```

---

### Task 6: 清理旧代码 + 向后兼容验证

**Files:**
- Modify: `lib/core/download_manager.dart`

- [ ] **Step 1: 清理不再需要的旧代码**

移除 `DownloadManager` 中不再需要的字段和方法：
- `_subscriptions` map（单线程流订阅）
- `_sinks` map（单线程 IOSink）
- `_speedWatchers` 和 `_speedSamples`（速度计算已移至 ChunkedDownloader）
- `fileNameFromUrl` 方法（保留，其他地方可能用到）

保留 `_client`（用于 `recoverCompleted` 等场景）。

- [ ] **Step 2: 验证向后兼容**

1. 确保旧格式 `.part` 文件能正确恢复（作为单分片）
2. 确保新格式 `.part.meta` 能正确读取
3. 确保取消操作同时删除 `.part` 和 `.part.meta`

- [ ] **Step 3: 完整功能测试**

1. 全新下载 → 验证分片并发、带宽探测、进度显示
2. 暂停 → 恢复 → 验证分片续传
3. 网络中断 → 验证自动重试
4. 取消 → 验证文件清理
5. 应用重启 → 验证 `.part.meta` 恢复

- [ ] **Step 4: Commit**

```
refactor(download): clean up legacy single-stream download code
```
