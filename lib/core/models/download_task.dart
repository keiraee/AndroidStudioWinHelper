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
    this.totalChunks,
    this.completedChunks,
    this.totalRetryCount,
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

  /// 总分片数（仅在分片下载时有值）。
  final int? totalChunks;

  /// 已完成的分片数。
  final int? completedChunks;

  /// 所有分片累计重试次数之和。
  final int? totalRetryCount;

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
    int? totalChunks,
    int? completedChunks,
    int? totalRetryCount,
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
      totalChunks: totalChunks ?? this.totalChunks,
      completedChunks: completedChunks ?? this.completedChunks,
      totalRetryCount: totalRetryCount ?? this.totalRetryCount,
    );
  }
}
