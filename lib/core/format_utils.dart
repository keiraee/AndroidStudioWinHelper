/// 格式化工具 — 统一的字节、速度、时长显示
class FormatUtils {
  FormatUtils._();

  static String bytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String speed(int bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec < 1024) return '$bytesPerSec B/s';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  static String duration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}小时${d.inMinutes % 60}分';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}分${d.inSeconds % 60}秒';
    }
    return '${d.inSeconds}秒';
  }
}
