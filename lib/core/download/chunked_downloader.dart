import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:androidstudiowinhelper/core/download/chunk_state.dart';
import 'package:androidstudiowinhelper/core/download/meta_store.dart';
import 'package:androidstudiowinhelper/core/download/retry_engine.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 带 HTTP 状态码的异常，用于 [RetryEngine] 精确分类。
class _HttpError implements Exception {
  final int statusCode;
  final String message;
  _HttpError(this.statusCode, this.message);
  @override
  String toString() => 'HTTP $statusCode: $message';
}

/// 单个分片的运行时状态。
class _ChunkWork {
  _ChunkWork({
    required this.state,
    this.downloadedBytes = 0,
    this.status = ChunkStatus.pending,
  });

  final ChunkState state;
  int downloadedBytes;
  ChunkStatus status;
  int retryCount = 0;
  StreamSubscription<List<int>>? subscription;
}

/// 分片下载器，使用 `RandomAccessFile` + `Range` 请求实现多线程分片下载。
///
/// 每个分片独立用 `Range` 请求下载，通过 `RandomAccessFile.setPosition` 写入
/// 对应偏移。支持自适应分片、暂停/恢复、智能重试。
class ChunkedDownloader {
  ChunkedDownloader({http.Client? client, String? proxyUrl})
      : _client = client ?? _createDefaultClient(proxyUrl: proxyUrl);

  static http.Client _createDefaultClient({String? proxyUrl}) {
    final httpClient = HttpClient()
      ..autoUncompress = false
      ..userAgent =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

    final resolvedProxy = proxyUrl?.trim().isNotEmpty == true
        ? proxyUrl!.trim()
        : _envProxy();
    if (resolvedProxy != null && resolvedProxy.isNotEmpty) {
      final proxyUri = _parseProxyUri(resolvedProxy);
      if (proxyUri != null && proxyUri.host.isNotEmpty) {
        final port = proxyUri.hasPort ? proxyUri.port : 80;
        httpClient.findProxy = (_) => 'PROXY ${proxyUri.host}:$port';
      }
    }

    return IOClient(httpClient);
  }

  static String? _envProxy() {
    const keys = [
      'HTTPS_PROXY',
      'https_proxy',
      'HTTP_PROXY',
      'http_proxy',
      'ALL_PROXY',
      'all_proxy',
    ];
    for (final key in keys) {
      final value = Platform.environment[key];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static Uri? _parseProxyUri(String raw) {
    try {
      if (raw.contains('://')) return Uri.parse(raw);
      return Uri.parse('http://$raw');
    } catch (_) {
      return null;
    }
  }

  final http.Client _client;

  // ── 运行时状态 ──
  RandomAccessFile? _raf;
  final List<_ChunkWork> _chunkWorks = [];
  final List<StreamSubscription<List<int>>> _activeSubscriptions = [];
  Completer<void>? _downloadCompleter;

  void Function(DownloadMeta meta)? _onProgress;
  void Function(String error)? _onError;
  void Function()? _onComplete;

  Map<String, String> _headers = {};

  String _partPath = '';
  String _finalPath = '';
  DownloadMeta? _currentMeta;
  bool _isPaused = false;
  bool _isCancelled = false;
  bool _isResume = false;
  int _lastProgressNotifyMs = 0;
  Completer<void>? _pauseCompleter;

  // ── 全局写入队列（CRITICAL: 防止并发 setPosition/writeFrom 交错） ──
  Completer<void> _writeQueue = Completer<void>()..complete();
  Completer<void> get _currentWriteFuture => _writeQueue;

  // ── 常量 ──
  static const int _probeChunkSize = 2 * 1024 * 1024; // 2 MB
  static const int _progressThrottleMs = 500;
  static const int _minChunkSize = 256 * 1024; // 256 KB

  // ── 公开 API ──

  /// 将写入操作排入全局写入队列，确保所有 chunk 的 setPosition+writeFrom 原子执行。
  Future<void> _queueWrite(Future<void> Function() writeOp) {
    final prev = _writeQueue;
    final next = Completer<void>();
    _writeQueue = next;
    prev.future
        .then((_) => writeOp())
        .then((_) {
          if (!next.isCompleted) next.complete();
        })
        .catchError((Object e) {
          if (!next.isCompleted) next.completeError(e);
        });
    return next.future;
  }

  /// 释放资源：关闭 HTTP 客户端和文件句柄。
  void dispose() {
    _client.close();
    _raf?.close();
    _raf = null;
  }

  /// 开始下载。
  ///
  /// [existingMeta] 不为 `null` 时从该 meta 恢复下载。
  Future<void> start({
    required String url,
    required String partPath,
    required String finalPath,
    DownloadMeta? existingMeta,
    Map<String, String>? headers,
    void Function(DownloadMeta meta)? onProgress,
    void Function(String error)? onError,
    void Function()? onComplete,
  }) async {
    _onProgress = onProgress;
    _onError = onError;
    _onComplete = onComplete;
    _isPaused = false;
    _isCancelled = false;
    _partPath = partPath;
    _finalPath = finalPath;
    _headers = headers ?? {};
    _downloadCompleter = Completer<void>();

    try {
      // 加载已有 meta 或探测服务器
      DownloadMeta meta;
      if (existingMeta != null && existingMeta.url == url && existingMeta.totalBytes > 0) {
        meta = existingMeta;
        LogManager.instance.write(
          'ChunkedDownloader',
          '从已有 meta 恢复: ${meta.chunkCount} 分片, '
              '${(meta.downloadedBytes / 1024 / 1024).toStringAsFixed(1)}MB '
              '/ ${(meta.totalBytes / 1024 / 1024).toStringAsFixed(1)}MB',
        );
      } else {
        if (existingMeta != null) {
          LogManager.instance.write(
            'ChunkedDownloader',
            'existingMeta URL 不匹配: '
                'meta.url=${existingMeta.url}, 请求 url=$url，视为全新下载',
          );
          existingMeta = null;
        }

        // 一次性探测：带宽 + 文件大小 + Range 支持
        // 从实际下载响应的 Content-Range 头获取文件大小，
        // 避免单独 HEAD/Range 探测因 CDN 缓存层返回错误大小
        final probeResult = await _probeBandwidthWithSize(url);
        if (probeResult == null) {
          _handleError('探测失败: $url');
          return;
        }

        final (bandwidth, totalBytes, supportsRange) = probeResult;

        LogManager.instance.write(
          'ChunkedDownloader',
          '探测结果: totalBytes=$totalBytes, supportsRange=$supportsRange, '
              '带宽=${(bandwidth / 1024 / 1024).toStringAsFixed(1)} MB/s',
        );

        // 自适应分片
        int chunkCount;
        if (supportsRange) {
          chunkCount = _decideChunkCount(bandwidth, totalBytes);
          LogManager.instance.write(
            'ChunkedDownloader',
            '分片决策: $chunkCount 分片',
          );
        } else {
          chunkCount = 1;
          LogManager.instance.write(
            'ChunkedDownloader',
            '服务器不支持 Range，退回单流下载',
          );
        }

        // 创建分片
        final chunks = _createChunks(chunkCount, totalBytes);

        // 如果是从旧格式迁移的（existingMeta.totalBytes == 0 但有已下载数据），
        // 将已下载字节记入第一个分片
        if (existingMeta != null && existingMeta.downloadedBytes > 0 && chunks.isNotEmpty) {
          final legacyDownloaded = existingMeta.downloadedBytes;
          LogManager.instance.write(
            'ChunkedDownloader',
            '旧格式迁移: 保留已下载 ${(legacyDownloaded / 1024 / 1024).toStringAsFixed(1)}MB',
          );
          chunks[0] = ChunkState(
            index: 0,
            startByte: chunks[0].startByte,
            endByte: chunks[0].endByte,
            downloadedBytes: legacyDownloaded,
            status: ChunkStatus.pending, // 从断点继续
          );
        }

        meta = DownloadMeta(
          url: url,
          totalBytes: totalBytes,
          chunks: chunks,
          createdAt: DateTime.now(),
        );
      }

      _currentMeta = meta;

      // 预分配文件
      _isResume = existingMeta != null;
      await _preallocateFile(
        partPath,
        meta.totalBytes,
        isResume: _isResume,
      );

      // 过滤并准备分片任务
      _prepareChunkWorks(meta);

      if (_chunkWorks.isEmpty) {
        // 所有分片已完成
        await _finalize();
        return;
      }

      // 保存 meta 并开始下载
      await MetaStore.save(partPath, meta);
      _notifyProgress();

      await _downloadChunks();

      if (_isCancelled) {
        await _cleanupFiles();
      } else if (!_isPaused) {
        await _finalize();
      }
      // 暂停时 meta 已在 pause() 中保存
    } catch (e, st) {
      LogManager.instance.write('ChunkedDownloader', '下载异常: $e\n$st');
      _handleError(e.toString());
    }
  }

  /// 暂停下载。
  ///
  /// 将进行中的分片重置为 pending 并保存 meta，然后取消所有 HTTP 请求。
  /// 之后可调用 [start] 并传入已保存的 meta 恢复下载。
  Future<void> pause() async {
    if (_isPaused) return;
    _isPaused = true;
    LogManager.instance.write('ChunkedDownloader', '暂停下载');

    // ① 将正在下载的分片状态回退为 pending（保留 downloadedBytes）
    for (final work in _chunkWorks) {
      if (work.status == ChunkStatus.downloading) {
        work.status = ChunkStatus.pending;
      }
    }

    // ② 构建并保存当前 meta，确保进度不丢失
    _currentMeta = _buildCurrentMeta();
    if (_partPath.isNotEmpty) {
      try {
        await MetaStore.save(_partPath, _currentMeta!);
      } catch (e) {
        LogManager.instance.write('ChunkedDownloader', '暂停保存 meta 失败: $e');
      }
    }

    // ③ 完成暂停 Completer，解除 _downloadChunks 的等待
    if (_pauseCompleter != null && !_pauseCompleter!.isCompleted) {
      _pauseCompleter!.complete();
    }

    // ③½ 等待全局写入队列中当前正在进行的写入操作完成，
    //    确保暂停时不会中途截断写入导致数据损坏
    try {
      await _currentWriteFuture.future;
    } catch (_) {
      // 写入过程中可能有错误，暂停时忽略
    }

    // ④ 取消所有活跃的 stream 订阅
    for (final sub in List.of(_activeSubscriptions)) {
      try {
        await sub.cancel();
      } catch (_) {}
    }
    _activeSubscriptions.clear();

    // ⑤ 完成主 Completer（如果尚未完成）
    if (_downloadCompleter != null && !_downloadCompleter!.isCompleted) {
      _downloadCompleter!.complete();
    }
  }

  /// 取消下载。
  ///
  /// 暂停下载并直接删除 .part 和 .part.meta 文件。
  Future<void> cancel() async {
    if (_isCancelled) return;
    _isCancelled = true;
    LogManager.instance.write('ChunkedDownloader', '取消下载');
    await pause();

    // 直接删除文件，不依赖 start() 中的 _cleanupFiles()
    await _raf?.close();
    _raf = null;
    try {
      final partFile = File(_partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }
      await MetaStore.delete(_partPath);
    } catch (e) {
      LogManager.instance.write('ChunkedDownloader', '取消清理文件失败: $e');
    }
  }

  // ── HEAD 探测 ──

  // ── 带宽 + 文件大小探测 ──

  /// 一次性探测：带宽、文件大小、Range 支持。
  ///
  /// 直接从带宽探测的 HTTP 响应 Content-Range 头获取文件大小，
  /// 避免单独探测请求因 CDN 缓存层返回错误大小。
  Future<(int bandwidth, int totalBytes, bool supportsRange)?> _probeBandwidthWithSize(String url) async {
    try {
      // 用第一个带宽探测请求同时获取文件大小
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(_headers);
      request.headers['Range'] = 'bytes=0-${_probeChunkSize - 1}';
      request.headers['Accept-Encoding'] = 'identity';

      final sw = Stopwatch()..start();
      final response = await _client.send(request).timeout(
        const Duration(seconds: 15),
      );

      // 从 Content-Range 提取真实文件大小
      int totalBytes;
      bool supportsRange;

      final contentRange = response.headers['content-range'] ?? '';
      final rangeMatch = RegExp(r'/(\d+)').firstMatch(contentRange);

      if (rangeMatch != null) {
        totalBytes = int.parse(rangeMatch.group(1)!);
        supportsRange = true;
      } else {
        totalBytes = response.contentLength ?? 0;
        supportsRange = response.statusCode == 206;
      }

      // 读取探测数据并计时
      int downloadedBytes = 0;
      await for (final chunk in response.stream) {
        downloadedBytes += chunk.length;
      }
      sw.stop();

      if (totalBytes <= 0) {
        LogManager.instance.write('ChunkedDownloader', '探测失败: 无法获取文件大小');
        return null;
      }

      final elapsedSec = sw.elapsedMilliseconds / 1000.0;
      final bandwidth = elapsedSec > 0 ? (downloadedBytes / elapsedSec).toInt() : 0;

      LogManager.instance.write(
        'ChunkedDownloader',
        '探测完成: totalBytes=$totalBytes (${(totalBytes / 1024 / 1024).toStringAsFixed(1)}MB), '
            'Range=$supportsRange, 带宽=${(bandwidth / 1024 / 1024).toStringAsFixed(1)} MB/s',
      );

      return (bandwidth, totalBytes, supportsRange);
    } catch (e) {
      LogManager.instance.write('ChunkedDownloader', '探测异常: $e');
      return null;
    }
  }

  // ── 自适应分片 ──

  /// 根据带宽（bytes/sec）和文件大小决定分片数。
  ///
  /// I-2: 如果 `totalBytes / chunkCount < 256KB`，则减少分片数以保证每片足够大。
  int _decideChunkCount(int bytesPerSecond, int totalBytes) {
    final mbps = bytesPerSecond / (1024 * 1024);
    int chunkCount;
    if (mbps < 2) {
      chunkCount = 2;
    } else if (mbps < 5) {
      chunkCount = 4;
    } else if (mbps < 10) {
      chunkCount = 8;
    } else {
      chunkCount = 16;
    }

    // 保证每片至少 _minChunkSize（256 KB）
    while (chunkCount > 1 &&
        totalBytes ~/ chunkCount < _minChunkSize) {
      chunkCount--;
    }
    return chunkCount;
  }

  /// 按 [chunkCount] 均匀切分 [totalBytes]，返回 [ChunkState] 列表。
  List<ChunkState> _createChunks(int chunkCount, int totalBytes) {
    final chunkSize = totalBytes ~/ chunkCount;
    final chunks = <ChunkState>[];

    for (int i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      // 最后一个分片包含余下的所有字节
      final end =
          (i == chunkCount - 1) ? totalBytes - 1 : start + chunkSize - 1;

      chunks.add(ChunkState(
        index: i,
        startByte: start,
        endByte: end,
      ));
    }

    return chunks;
  }

  // ── 文件预分配 ──

  /// 使用 `RandomAccessFile` 打开或创建 `.part` 文件。
  ///
  /// 新下载：使用 [FileMode.write] 截断并预分配。
  /// 恢复下载：使用 [FileMode.append]（不截断），保留已有数据。
  ///   Windows 上 [FileMode.append] 使用 `OPEN_ALWAYS` + `FILE_WRITE_DATA`，
  ///   `setPosition` + `writeFrom` 仍可在任意偏移写入。
  Future<void> _preallocateFile(
    String partPath,
    int totalBytes, {
    required bool isResume,
  }) async {
    // 关闭上一次可能残留的文件句柄（暂停后重新 start 时）
    if (_raf != null) {
      try {
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }

    final file = File(partPath);

    if (isResume && await file.exists()) {
      // 恢复下载：不截断已有文件
      _raf = await file.open(mode: FileMode.append);
      LogManager.instance.write(
        'ChunkedDownloader',
        '恢复打开文件: $partPath '
            '(${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } else {
      // 新下载：截断并预分配
      _raf = await file.open(mode: FileMode.write);
      if (totalBytes > 0) {
        await _raf!.setPosition(totalBytes - 1);
        await _raf!.writeFrom([0]);
      }
      await _raf!.flush();
      LogManager.instance.write(
        'ChunkedDownloader',
        '预分配文件: $partPath '
            '(${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    }
  }

  // ── 分片准备 ──

  /// 从 [meta] 中过滤出未完成的分片，创建 [_ChunkWork] 列表。
  ///
  /// 已完成的分片跳过；处于 downloading 状态的分片（上次暂停中断的）
  /// 重置为 pending 并从已下载处恢复。
  void _prepareChunkWorks(DownloadMeta meta) {
    _chunkWorks.clear();
    _activeSubscriptions.clear();

    for (final chunk in meta.chunks) {
      if (chunk.isCompleted) continue;

      // 上次中断的分片：重置状态但从已下载处继续
      final downloaded = chunk.downloadedBytes;
      final effectiveChunk = downloaded > 0
          ? chunk.copyWith(
              downloadedBytes: downloaded,
              status: ChunkStatus.pending,
              retryCount: 0,
            )
          : chunk;

      _chunkWorks.add(_ChunkWork(
        state: effectiveChunk,
        downloadedBytes: downloaded,
        status: ChunkStatus.pending,
      ));
    }

    LogManager.instance.write(
      'ChunkedDownloader',
      '准备下载 ${_chunkWorks.length} 个分片 '
          '(跳过 ${meta.chunks.length - _chunkWorks.length} 个已完成)',
    );
  }

  // ── 并发下载 ──

  /// 并发下载所有未完成的分片。
  Future<void> _downloadChunks() async {
    _pauseCompleter = Completer<void>();

    final futures = _chunkWorks.map((work) async {
      if (_isPaused || _isCancelled) return;
      try {
        await _downloadSingleChunk(work);
      } catch (e, st) {
        if (_isPaused || _isCancelled) return;
        LogManager.instance.write(
          'ChunkedDownloader',
          '分片 ${work.state.index} 顶层异常: $e\n$st',
        );
        work.status = ChunkStatus.failed;
        _onChunkDone(work);
      }
    }).toList();

    // 任意一个完成即可退出：所有分片完成 _或者_ 暂停/取消触发
    await Future.any([
      Future.wait(futures, eagerError: false),
      if (!_pauseCompleter!.isCompleted) _pauseCompleter!.future,
    ]);

    // 等待所有分片完成（包括重试中的），但暂停/取消时直接跳过
    if (!_isPaused && !_isCancelled &&
        _downloadCompleter != null && !_downloadCompleter!.isCompleted) {
      await _downloadCompleter!.future;
    }
  }

  /// 下载单个分片，包含重试循环。
  Future<void> _downloadSingleChunk(_ChunkWork work) async {
    while (!_isPaused && !_isCancelled) {
      work.status = ChunkStatus.downloading;

      try {
        await _downloadChunkStream(work);
        return; // 成功
      } catch (e) {
        if (_isPaused || _isCancelled) {
          work.status = ChunkStatus.pending;
          return;
        }

        // 检查是否已经在流回调中被标记为完成
        if (work.status == ChunkStatus.completed) return;

        final statusCode = _extractStatusCode(e);
        final decision = RetryEngine.shouldRetry(
          e,
          statusCode,
          work.retryCount,
        );

        if (decision.shouldRetry) {
          work.retryCount = decision.attemptNumber;
          LogManager.instance.write(
            'ChunkedDownloader',
            '分片 ${work.state.index} 重试 '
                '${decision.attemptNumber}/${decision.maxRetries}',
          );
          // 通知 UI 更新重试状态（绕过节流）
          _lastProgressNotifyMs = 0;
          _notifyProgress();
          await RetryEngine.waitBeforeRetry(decision);

          if (_isPaused || _isCancelled) {
            work.status = ChunkStatus.pending;
            return;
          }
        } else {
          LogManager.instance.write(
            'ChunkedDownloader',
            '分片 ${work.state.index} 永久失败: ${decision.reason}',
          );
          work.status = ChunkStatus.failed;
          _onChunkDone(work);
          return;
        }
      }
    }
  }

  /// 执行单个分片的 HTTP 下载流。
  ///
  /// 使用写入队列确保 [RandomAccessFile] 的 setPosition/writeFrom 操作
  /// 严格按序执行，避免并发写入导致的数据错位。
  Future<void> _downloadChunkStream(_ChunkWork work) async {
    final startByte = work.state.startByte + work.downloadedBytes;
    final endByte = work.state.endByte;

    // 分片已完成
    if (startByte > endByte) {
      work.status = ChunkStatus.completed;
      _onChunkDone(work);
      return;
    }

    final request = http.Request('GET', Uri.parse(_currentMeta!.url));
    request.headers.addAll(_headers);
    request.headers['Range'] = 'bytes=$startByte-$endByte';
    request.headers['Accept-Encoding'] = 'identity';

    final response = await _client.send(request).timeout(
          const Duration(seconds: 30),
        );

    if (response.statusCode == 416) {
      throw _HttpError(416, 'Range Not Satisfiable');
    }

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw _HttpError(response.statusCode, 'Unexpected status');
    }

    // 使用全局写入队列确保 setPosition + writeFrom 严格按序执行
    // 所有 chunk 的写入通过 _queueWrite 串行化，防止并发交错写入
    int writeOffset = work.state.startByte + work.downloadedBytes;
    Future<void> lastWrite = Future.value();
    final streamDone = Completer<void>();
    bool hasError = false;

    work.subscription = response.stream.listen(
      (chunk) {
        if (_isPaused || _isCancelled || hasError) return;

        final capturedOffset = writeOffset;
        writeOffset += chunk.length;

        // 通过全局写入队列提交，保证所有 chunk 的 setPosition+writeFrom 原子执行
        lastWrite = _queueWrite(() async {
          if (_isPaused || _isCancelled || hasError) return;
          try {
            await _raf!.setPosition(capturedOffset);
            await _raf!.writeFrom(chunk);
            work.downloadedBytes += chunk.length;
            _notifyProgress();
          } catch (e) {
            hasError = true;
            LogManager.instance.write(
              'ChunkedDownloader',
              '分片 ${work.state.index} 写入错误: $e',
            );
            work.subscription?.cancel();
            work.status = ChunkStatus.failed;
            _onChunkDone(work);
            if (!streamDone.isCompleted) streamDone.completeError(e);
          }
        });
      },
      onError: (Object e) {
        if (work.status == ChunkStatus.completed) return;
        // 等最后的写入完成后标记失败
        lastWrite.whenComplete(() {
          if (!streamDone.isCompleted) {
            work.status = ChunkStatus.failed;
            _onChunkDone(work);
            streamDone.completeError(e);
          }
        });
      },
      onDone: () {
        // 等最后的写入完成后校验分片字节数再标记完成
        lastWrite.whenComplete(() {
          if (!streamDone.isCompleted) {
            if (work.status != ChunkStatus.completed &&
                work.status != ChunkStatus.failed) {
              final expected = work.state.totalBytes;
              if (work.downloadedBytes >= expected) {
                work.status = ChunkStatus.completed;
                _onChunkDone(work);
                streamDone.complete();
              } else {
                LogManager.instance.write(
                  'ChunkedDownloader',
                  '分片 ${work.state.index} 未下完: '
                  '${work.downloadedBytes}/$expected，标记失败以便重试',
                );
                work.status = ChunkStatus.failed;
                _onChunkDone(work);
                streamDone.completeError(
                  StateError(
                    'Chunk ${work.state.index} incomplete: '
                    '${work.downloadedBytes}/$expected',
                  ),
                );
              }
            } else {
              streamDone.complete();
            }
          }
        });
      },
      cancelOnError: true,
    );

    _activeSubscriptions.add(work.subscription!);

    await streamDone.future;
  }

  // ── 进度与回调 ──

  /// 节流进度通知：每 [_progressThrottleMs] 最多一次。
  void _notifyProgress() {
    if (_currentMeta == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastProgressNotifyMs < _progressThrottleMs) return;
    _lastProgressNotifyMs = now;

    _currentMeta = _buildCurrentMeta();
    _onProgress?.call(_currentMeta!);
  }

  /// 从当前 [_chunkWorks] 构建最新的 [DownloadMeta]。
  DownloadMeta _buildCurrentMeta() {
    final base = _currentMeta!;
    final workMap = <int, _ChunkWork>{};
    for (final w in _chunkWorks) {
      workMap[w.state.index] = w;
    }

    final updatedChunks = base.chunks.map((chunk) {
      final work = workMap[chunk.index];
      if (work != null) {
        return chunk.copyWith(
          downloadedBytes: work.downloadedBytes,
          status: work.status,
          retryCount: work.retryCount,
        );
      }
      return chunk;
    }).toList();

    return base.copyWith(chunks: updatedChunks);
  }

  /// 单个分片完成时调用。
  ///
  /// 更新 meta 并保存。所有分片完成后通知主 Completer。
  void _onChunkDone(_ChunkWork work) {
    _currentMeta = _buildCurrentMeta();

    // 异步保存 meta
    if (_partPath.isNotEmpty) {
      MetaStore.save(_partPath, _currentMeta!).catchError((e) {
        LogManager.instance.write(
          'ChunkedDownloader',
          '保存 meta 失败: $e',
        );
      });
    }

    // 进度通知（完成时强制通知，绕过节流）
    _lastProgressNotifyMs = 0;
    _notifyProgress();

    // 检查是否所有分片已完成
    final allDone = _chunkWorks.every(
      (w) =>
          w.status == ChunkStatus.completed ||
          w.status == ChunkStatus.failed,
    );

    if (allDone &&
        _downloadCompleter != null &&
        !_downloadCompleter!.isCompleted) {
      _downloadCompleter!.complete();
    }
  }

  /// 处理错误：调用 onError 回调。
  void _handleError(String error) {
    LogManager.instance.write('ChunkedDownloader', '错误: $error');
    _onError?.call(error);
    if (_downloadCompleter != null && !_downloadCompleter!.isCompleted) {
      _downloadCompleter!.complete();
    }
  }

  // ── 完成与清理 ──

  /// 下载完成：关闭文件，重命名 .part -> 最终文件，清理 meta。
  Future<void> _finalize() async {
    await _raf?.flush();
    await _raf?.close();
    _raf = null;

    // 检查是否所有分片确实完成，且总字节一致
    final meta = _buildCurrentMeta();
    if (!meta.allCompleted ||
        (meta.totalBytes > 0 && meta.downloadedBytes != meta.totalBytes)) {
      _handleError(
          '下载未完成: ${meta.downloadedBytes}/${meta.totalBytes} 字节');
      return;
    }

    // 重命名 .part -> final
    try {
      final partFile = File(_partPath);
      final finalFile = File(_finalPath);

      if (await finalFile.exists()) {
        await finalFile.delete();
      }

      await partFile.rename(_finalPath);
      LogManager.instance.write(
        'ChunkedDownloader',
        '下载完成: $_partPath -> $_finalPath',
      );
    } catch (e) {
      LogManager.instance.write(
        'ChunkedDownloader',
        '重命名文件失败: $e',
      );
      _handleError('重命名文件失败: $e');
      return;
    }

    // 清理 meta
    await MetaStore.delete(_partPath);

    _onComplete?.call();
  }

  /// 清理取消下载的文件。
  Future<void> _cleanupFiles() async {
    await _raf?.close();
    _raf = null;

    try {
      final partFile = File(_partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }
      await MetaStore.delete(_partPath);
    } catch (e) {
      LogManager.instance.write(
        'ChunkedDownloader',
        '清理文件失败: $e',
      );
    }
  }

  /// 从异常中提取 HTTP 状态码。
  int? _extractStatusCode(Object error) {
    if (error is _HttpError) return error.statusCode;
    return null;
  }
}
