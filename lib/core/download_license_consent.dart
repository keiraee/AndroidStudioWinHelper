import 'dart:io';

/// 下载前 Android SDK License 同意状态（对应官网归档页 TOS 墙）。
class DownloadLicenseConsent {
  DownloadLicenseConsent._();

  static String get _path =>
      '${Platform.environment['LOCALAPPDATA'] ?? ''}\\AndroidStudioWinHelper\\download_license_accepted';

  static bool hasAccepted() {
    try {
      return File(_path).existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<void> accept() async {
    final file = File(_path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      'accepted_at=${DateTime.now().toIso8601String()}\n'
      'source=https://developer.android.com/studio/archive\n',
    );
  }
}
