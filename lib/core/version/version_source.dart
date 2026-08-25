import 'package:androidstudiowinhelper/core/models/studio_version.dart';

/// 版本数据源抽象接口
abstract class VersionSource {
  /// 数据源名称（用于日志和警告）
  String get name;

  /// 获取版本列表
  Future<VersionSourceResult> fetch();
}

/// 数据源返回结果
class VersionSourceResult {
  const VersionSourceResult({
    required this.versions,
    this.urls = const {},
    this.warnings = const [],
  });

  final List<StudioVersion> versions;
  final Map<String, String> urls; // key: 4段版本号如 "2026.1.2.1"
  final List<String> warnings;
}
