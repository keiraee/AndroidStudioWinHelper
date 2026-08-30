import 'package:androidstudiowinhelper/core/models/studio_version.dart';

/// 本地下载目录里的文件分类与版本匹配。
class DownloadShelf {
  static const verifyAttempts = 3;

  static String fileNameFromUrl(String url) {
    final uri = Uri.parse(url);
    if (uri.pathSegments.isEmpty) return url.split('/').last;
    return uri.pathSegments.last;
  }

  /// 从版本显示名生成文件名，如：
  /// "Panda 4 | 2025.3.4" → "android-studio-panda4-windows.exe"
  static String generateFileName(String versionKey, String url) {
    final urlFileName = fileNameFromUrl(url);
    final ext = urlFileName.contains('.')
        ? '.${urlFileName.split('.').last}'
        : '.exe';

    final parts = versionKey.split('|');
    final codename = (parts.isNotEmpty ? parts.first : versionKey).trim();
    final versionPart = parts.length > 1 ? parts[1].trim() : '';
    final safeCodename = codename.toLowerCase().replaceAll(RegExp(r'\s+'), '');

    var channelSuffix = '';
    final withoutVersion =
        versionPart.replaceFirst(RegExp(r'^[\d.]+\s*'), '').trim();
    if (withoutVersion.isNotEmpty) {
      final normalized =
          withoutVersion.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
      channelSuffix =
          '-${normalized.replaceAllMapped(RegExp(r'\b(\w+)-(\d)\b'), (m) => '${m.group(1)}${m.group(2)}')}';
    }

    return 'android-studio-$safeCodename$channelSuffix$ext';
  }

  static bool isCompletedExe(String fileName) {
    final lower = fileName.toLowerCase();
    if (!lower.endsWith('.exe')) return false;
    if (lower.endsWith('.part')) return false;
    if (lower.contains('.part.')) return false;
    return true;
  }

  static bool isPartFile(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.part.meta')) return false;
    return lower.endsWith('.part');
  }

  static String exeNameFromPart(String partFileName) {
    if (partFileName.toLowerCase().endsWith('.part')) {
      return partFileName.substring(0, partFileName.length - '.part'.length);
    }
    return partFileName;
  }

  static String? matchVersionKey({
    required String fileName,
    required List<StudioVersion> versions,
  }) {
    for (final v in versions) {
      if (v.downloadUrl.isEmpty) continue;
      if (generateFileName(v.version, v.downloadUrl) == fileName) {
        return v.version;
      }
    }
    for (final v in versions) {
      if (v.downloadUrl.isEmpty) continue;
      if (fileNameFromUrl(v.downloadUrl) == fileName) {
        return v.version;
      }
    }
    return null;
  }

  static bool showCopyLink(int consecutiveFailures) =>
      consecutiveFailures >= verifyAttempts;
}
