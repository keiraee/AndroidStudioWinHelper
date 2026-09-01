import 'dart:io';

/// 日志管理器：写入 %LOCALAPPDATA%\AndroidStudioWinHelper\log，按日期分文件
class LogManager {
  static final LogManager instance = LogManager._();
  LogManager._();

  late Directory _logDir = Directory.systemTemp;
  IOSink? _currentSink;
  String? _currentDate;

  /// 初始化日志目录（用户 AppData，避免 Program Files 无写权限）
  void init() {
    final base = Platform.environment['LOCALAPPDATA']?.trim() ?? '';
    final dir = base.isEmpty
        ? Directory.systemTemp.createTempSync('aswh_logs')
        : Directory('$base\\AndroidStudioWinHelper\\log');
    _logDir = dir;
    try {
      if (!_logDir.existsSync()) {
        _logDir.createSync(recursive: true);
      }
    } catch (_) {
      // 兜底：无法创建时仍允许控制台输出
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
      _currentSink?.flush();
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

  /// 当天日志文件路径（供 PowerShell 子进程追加写入）
  String get currentLogFilePath {
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return '${_logDir.path}/$dateStr.log';
  }

  /// 关闭日志写入
  void dispose() {
    _currentSink?.flush();
    _currentSink?.close();
    _currentSink = null;
  }
}
