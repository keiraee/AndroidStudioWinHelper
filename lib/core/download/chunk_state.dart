enum ChunkStatus { pending, downloading, completed, failed }

/// 单个分片的状态。
class ChunkState {
  const ChunkState({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.status = ChunkStatus.pending,
    this.retryCount = 0,
  });

  final int index;
  final int startByte;
  final int endByte;
  final int downloadedBytes;
  final ChunkStatus status;
  final int retryCount;

  /// 分片总字节数（含两端）。
  int get totalBytes => endByte - startByte + 1;

  /// 分片是否已完成。
  bool get isCompleted => status == ChunkStatus.completed;

  ChunkState copyWith({
    int? downloadedBytes,
    ChunkStatus? status,
    int? retryCount,
  }) {
    return ChunkState(
      index: index,
      startByte: startByte,
      endByte: endByte,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      status: status ?? this.status,
      retryCount: retryCount ?? this.retryCount,
    );
  }

  factory ChunkState.fromJson(Map<String, dynamic> json) {
    return ChunkState(
      index: json['index'] as int,
      startByte: json['start'] as int,
      endByte: json['end'] as int,
      downloadedBytes: json['downloaded'] as int? ?? 0,
      status: _parseStatus(json['status'] as String? ?? 'pending'),
      retryCount: json['retryCount'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': startByte,
        'end': endByte,
        'downloaded': downloadedBytes,
        'status': status.name,
        'retryCount': retryCount,
      };

  static ChunkStatus _parseStatus(String value) {
    return ChunkStatus.values.firstWhere(
      (s) => s.name == value,
      orElse: () => ChunkStatus.pending,
    );
  }
}

/// 完整的下载元数据，对应 `.part.meta` JSON 文件。
class DownloadMeta {
  const DownloadMeta({
    required this.url,
    required this.totalBytes,
    required this.chunks,
    required this.createdAt,
    this.version = 2,
  });

  /// 元数据格式版本，当前固定为 2。
  final int version;
  final String url;
  final int totalBytes;
  final List<ChunkState> chunks;
  final DateTime createdAt;

  /// 分片数量（派生自 chunks.length）。
  int get chunkCount => chunks.length;

  /// 所有分片已下载字节之和。
  int get downloadedBytes =>
      chunks.fold<int>(0, (sum, c) => sum + c.downloadedBytes);

  /// 下载进度，0.0 ~ 1.0。
  double get progress =>
      totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;

  /// 所有分片是否均已完成。
  bool get allCompleted =>
      chunks.isNotEmpty && chunks.every((c) => c.isCompleted);

  /// 获取失败的分片列表。
  List<ChunkState> get failedChunks =>
      chunks.where((c) => c.status == ChunkStatus.failed).toList();

  /// 获取待下载的分片列表。
  List<ChunkState> get pendingChunks =>
      chunks.where((c) => c.status == ChunkStatus.pending).toList();

  DownloadMeta copyWith({
    String? url,
    int? totalBytes,
    List<ChunkState>? chunks,
    DateTime? createdAt,
  }) {
    return DownloadMeta(
      version: version,
      url: url ?? this.url,
      totalBytes: totalBytes ?? this.totalBytes,
      chunks: chunks ?? this.chunks,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  factory DownloadMeta.fromJson(Map<String, dynamic> json) {
    final url = json['url'] as String?;
    final totalBytes = json['totalBytes'] as int?;
    if (url == null || url.isEmpty) {
      throw FormatException('DownloadMeta.fromJson: 缺失必需字段 "url"');
    }
    if (totalBytes == null) {
      throw FormatException('DownloadMeta.fromJson: 缺失必需字段 "totalBytes"');
    }
    final chunksJson = json['chunks'] as List<dynamic>? ?? [];
    return DownloadMeta(
      version: json['version'] as int? ?? 2,
      url: url,
      totalBytes: totalBytes,
      chunks: chunksJson
          .map((c) => ChunkState.fromJson(c as Map<String, dynamic>))
          .toList(),
      createdAt: _parseDateTime(json['createdAt'] as String?),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'url': url,
        'totalBytes': totalBytes,
        'chunkCount': chunkCount,
        'chunks': chunks.map((c) => c.toJson()).toList(),
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  static DateTime _parseDateTime(String? value) {
    if (value == null || value.isEmpty) return DateTime(0);
    return DateTime.tryParse(value) ?? DateTime(0);
  }
}
