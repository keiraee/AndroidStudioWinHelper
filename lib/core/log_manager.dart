import 'dart:io';

/// 日志管理器：所有日志实时写入 log/ 目录，按日期分文件
class LogManager {
  static final LogManager instance = LogManager._();
  LogManager._();

  late final Directory _logDir;
  IOSink? _currentSink;
  String? _currentDate;

  /// 初始化日志目录（与 exe 同级）
  void init() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    _logDir = Directory('$exeDir/log');
    if (!_logDir.existsSync()) {
      _logDir.createSync(recursive: true);
    }
  }

  /// 写入一行日志（同时打印到控制台）
  void write(String tag, String message) {
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';

    final line = '[$tag $timeStr] $message';

    // 打印到控制台
    print(line);

    // 写入文件（未 init 时仅打印，不抛错）
    try {
      _ensureSink(dateStr);
      _currentSink?.writeln(line);
    } catch (_) {}
  }

  void _ensureSink(String dateStr) {
    if (_currentDate == dateStr && _currentSink != null) return;

    // 关闭旧的
    _currentSink?.close();

    _currentDate = dateStr;
    final logFile = File('${_logDir.path}/$dateStr.log');
    _currentSink = logFile.openWrite(mode: FileMode.append);
  }

  /// 清理 N 天前的日志
  void cleanupOldLogs({int keepDays = 30}) {
    if (!_logDir.existsSync()) return;
    final cutoff = DateTime.now().subtract(Duration(days: keepDays));
    for (final file in _logDir.listSync()) {
      if (file is! File || !file.path.endsWith('.log')) continue;
      final stat = file.statSync();
      if (stat.modified.isBefore(cutoff)) {
        file.deleteSync();
      }
    }
  }

  /// 获取当前日志目录路径
  String get logDirPath => _logDir.path;

  /// 关闭日志写入
  void dispose() {
    _currentSink?.flush();
    _currentSink?.close();
    _currentSink = null;
  }
}
