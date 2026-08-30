import 'dart:convert';
import 'dart:io';

/// 用户偏好（下载目录等）。
///
/// 后续会做独立的「配置修改」页面；现在先集中写在这里，避免各功能页各存一份。
class AppSettings {
  AppSettings({this.downloadDirectory, Directory? configDir})
      : _configDir = configDir;

  final Directory? _configDir;
  String? downloadDirectory;

  bool get hasDownloadDirectory {
    final path = downloadDirectory;
    return path != null && path.trim().isNotEmpty;
  }

  static String defaultConfigDirPath() {
    return '${Platform.environment['LOCALAPPDATA'] ?? ''}\\AndroidStudioWinHelper';
  }

  static File settingsFileFor(Directory dir) =>
      File('${dir.path}\\app_settings.json');

  static AppSettings load({Directory? configDir}) {
    final dir = configDir ?? Directory(defaultConfigDirPath());
    try {
      final file = settingsFileFor(dir);
      if (!file.existsSync()) {
        return AppSettings(configDir: dir);
      }
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final path = json['downloadDirectory'] as String?;
      return AppSettings(
        downloadDirectory: (path == null || path.trim().isEmpty) ? null : path,
        configDir: dir,
      );
    } catch (_) {
      return AppSettings(configDir: dir);
    }
  }

  void setDownloadDirectory(String path) {
    downloadDirectory = path.trim();
    save();
  }

  void save() {
    try {
      final dir = _configDir ?? Directory(defaultConfigDirPath());
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      settingsFileFor(dir).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'downloadDirectory': downloadDirectory,
        }),
      );
    } catch (_) {
      // 配置写入失败不阻塞下载主流程
    }
  }
}
