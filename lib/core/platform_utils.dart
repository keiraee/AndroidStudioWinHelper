import 'dart:io';

/// 平台工具 — 系统版本检测
class PlatformUtils {
  PlatformUtils._();

  static Map<String, String> getSystemVersion() {
    final buildNumber = Platform.operatingSystemVersion;
    return {
      'os': Platform.operatingSystem,
      'version': buildNumber,
      'build': RegExp(r'(\d{5,})').firstMatch(buildNumber)?.group(1) ?? '',
    };
  }

  static bool isWindows10Plus() {
    final sysInfo = getSystemVersion();
    final build = int.tryParse(sysInfo['build'] ?? '') ?? 0;
    return build >= 19041; // Win10 2004
  }

  static bool isWindows11() {
    final sysInfo = getSystemVersion();
    final build = int.tryParse(sysInfo['build'] ?? '') ?? 0;
    return build >= 22000; // Win11
  }
}
