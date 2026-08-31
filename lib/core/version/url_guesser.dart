import 'package:androidstudiowinhelper/core/models/studio_version.dart';

/// 从 XML buildNumber 反推下载 URL
///
/// 经过 CDN 实际探测确认的规律:
///   Canary  → 2026.1.2.{N}/quail2-canary{N}-windows.exe   (N = canary 编号)
///   Stable  → 2025.3.4.6/panda4-windows.exe               (固定 .6)
///   Patch   → 2025.3.4.7/panda4-patch1-windows.exe        (固定 .7)
///   旧版号  → 2024.3.2.15/android-studio-2024.3.2.15-windows.exe (Chocolatey 风格)
class UrlGuesser {
  static const _dlBase =
      'https://edgedl.me.gvt1.com/android/studio/install';

  /// 反推下载 URL 和对应的 4 段版本号
  static (String url, String versionKey)? guess(StudioVersion v) {
    final codename = v.codename.toLowerCase().replaceAll(' ', '');
    if (codename.isEmpty) return null;

    final base3 = decodeBuildBase3(v.buildNumber);
    if (base3 == null) return null;

    final versionPart = v.version.split('|').length > 1
        ? v.version.split('|')[1].trim()
        : '';
    final canaryMatch = RegExp(r'[Cc]anary\s*(\d+)').firstMatch(versionPart);
    final patchMatch = RegExp(r'Patch\s*(\d+)').firstMatch(versionPart);
    final rcMatch = RegExp(r'RC\s*(\d+)').firstMatch(versionPart);

    String channelSuffix;
    String urlVer;

    if (canaryMatch != null) {
      final n = canaryMatch.group(1)!;
      channelSuffix = '-canary$n';
      urlVer = '$base3.$n';
    } else if (rcMatch != null) {
      final n = rcMatch.group(1)!;
      channelSuffix = '-rc$n';
      urlVer = '$base3.$n';
    } else if (patchMatch != null) {
      channelSuffix = '-patch${patchMatch.group(1)}';
      urlVer = '$base3.7';
    } else {
      // 稳定版：用 .6 后缀（如 panda4 → 2025.3.4.6/panda4-windows.exe）
      // 对于无法识别 channel 的版本（如 Nightly/Dev），返回 null
      // 因为无法确定正确的下载文件名
      final isStable = v.channel == 'release';
      if (!isStable) return null;
      channelSuffix = '';
      urlVer = '$base3.6';
    }

    final fileName = 'android-studio-$codename$channelSuffix-windows.exe';
    final url = '$_dlBase/$urlVer/$fileName';
    return (url, urlVer);
  }

  /// 从 buildNumber 解码 3 段基础版本 (年.大.小)
  /// 如 AI-261.23567.138.2612 → seg4=2612 → 26=2026, 1=major, 2=minor → "2026.1.2"
  static String? decodeBuildBase3(String buildNumber) {
    final match = RegExp(r'(\d+)\.(\d+)\.(\d+)\.(\d+)').firstMatch(buildNumber);
    if (match == null) return null;

    final seg4 = match.group(4)!;
    if (seg4.length < 4) return null;

    final year = 2000 + int.parse(seg4[0]) * 10 + int.parse(seg4[1]);
    if (year < 2014 || year > 2035) return null;
    final major = int.parse(seg4[2]);
    final minor = int.parse(seg4[3]);

    return '$year.$major.$minor';
  }

  /// 从 buildNumber 解码 4 段 URL 版本号（兼容旧调用）
  static String? decodeBuildNumberToVersion(String buildNumber, String versionStr) {
    final base3 = decodeBuildBase3(buildNumber);
    if (base3 == null) return null;

    final versionPart = versionStr.split('|').length > 1
        ? versionStr.split('|')[1].trim()
        : '';

    final canaryMatch = RegExp(r'[Cc]anary\s*(\d+)').firstMatch(versionPart);
    if (canaryMatch != null) return '$base3.${canaryMatch.group(1)}';

    final rcMatch = RegExp(r'RC\s*(\d+)').firstMatch(versionPart);
    if (rcMatch != null) return '$base3.${rcMatch.group(1)}';

    final patchMatch = RegExp(r'Patch\s*(\d+)').firstMatch(versionPart);
    if (patchMatch != null) return '$base3.7';

    return '$base3.6';
  }

  /// 提取 3 段 base 版本
  static String extractBaseVersion(String version) {
    final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(version);
    return match?.group(1) ?? '';
  }

  /// 提取 Chocolatey 版本的 base
  static String extractChocoBase(String ver) {
    final parts = ver.split('.');
    if (parts.length >= 2) return '${parts[0]}.${parts[1]}';
    return ver;
  }
}
