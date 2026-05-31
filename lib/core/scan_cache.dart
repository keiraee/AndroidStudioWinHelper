import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/env_path_config.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';

class ScanCache {
  static String get basePath {
    return '${Platform.environment['LOCALAPPDATA'] ?? ''}\\AndroidStudioWinHelper';
  }

  static Directory get _cacheDir {
    final dir = Directory(basePath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static File get _storageFile =>
      File('${_cacheDir.path}\\scan_cache.json');

  static File get _installFile =>
      File('${_cacheDir.path}\\install_cache.json');

  static File get _versionFile =>
      File('${_cacheDir.path}\\version_cache.json');

  static File get _envConfigFile =>
      File('${Directory.current.path}\\env_config_cache.json');

  // ── 磁盘扫描缓存 ──

  static DataDirScanResult? load() {
    try {
      final file = _storageFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return DataDirScanResult.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static void save(DataDirScanResult result) {
    try {
      final file = _storageFile;
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.toJson()));
    } catch (_) {
      // 缓存写入失败不阻塞主流程
    }
  }

  // ── 安装检测缓存 ──

  static AndroidStudioDetectionResult? loadInstall() {
    try {
      final file = _installFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return AndroidStudioDetectionResult.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static void saveInstall(AndroidStudioDetectionResult result) {
    try {
      final file = _installFile;
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.toJson()));
    } catch (_) {
      // 缓存写入失败不阻塞主流程
    }
  }

  // ── 版本下载缓存 ──

  static List<StudioVersion>? loadVersions() {
    try {
      final file = _versionFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as List<dynamic>;
      return json
          .whereType<Map<String, dynamic>>()
          .map(StudioVersion.fromJson)
          .toList();
    } catch (_) {
      return null;
    }
  }

  static void saveVersions(List<StudioVersion> versions) {
    try {
      final file = _versionFile;
      final json =
          versions.map((v) => v.toJson()).toList();
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
    } catch (_) {
      // 缓存写入失败不阻塞主流程
    }
  }

  // ── 环境配置缓存（用于回退） ──

  static EnvPathConfigResult? loadEnvConfig() {
    try {
      final file = _envConfigFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return EnvPathConfigResult.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static void saveEnvConfig(EnvPathConfigResult result) {
    try {
      final file = _envConfigFile;
      file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result.toJson()));
    } catch (_) {
      // 缓存写入失败不阻塞主流程
    }
  }
}
