import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/version/archive_version_source.dart';
import 'package:androidstudiowinhelper/core/version/xml_version_source.dart';
import 'package:http/http.dart' as http;

/// 版本服务编排器
///
/// 主数据源：官方归档页 iframe（含完整 Windows 下载 URL + SHA-256）
/// 辅数据源：updates.xml（补充 release notes / 渠道元数据）
class StudioVersionService {
  StudioVersionService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  late final ArchiveVersionSource _archiveSource =
      ArchiveVersionSource(client: _client);
  late final XmlVersionSource _xmlSource = XmlVersionSource(client: _client);

  void dispose() => _client.close();

  Future<FetchVersionsResult> fetchVersions() async {
    final warnings = <String>[];

    // 1. 归档页：完整可下载列表（点击即可下）
    final archive = await _archiveSource.fetch();
    warnings.addAll(archive.warnings);
    final versions = List<StudioVersion>.from(archive.versions);
    LogManager.instance.write(
      'VersionService',
      '归档主数据源: ${versions.length} 个版本',
    );

    if (versions.isEmpty) {
      warnings.add('未能从归档页获取版本列表，请检查网络或代理后重试');
      return FetchVersionsResult(versions: versions, warnings: warnings);
    }

    // 2. XML：把 release notes 合并到同名/同号条目
    try {
      LogManager.instance.write('VersionService', '获取 XML 元数据以合并说明...');
      final xmlResult = await _xmlSource.fetch();
      warnings.addAll(xmlResult.warnings);
      _mergeXmlNotes(versions, xmlResult.versions);
    } catch (e) {
      LogManager.instance.write('VersionService', 'XML 合并跳过: $e');
      warnings.add('XML 元数据获取失败（不影响下载）: $e');
    }

    // 3. 排序：优先新版本号，其次展示名
    versions.sort((a, b) {
      final av = a.downloadVersion.isNotEmpty ? a.downloadVersion : a.version;
      final bv = b.downloadVersion.isNotEmpty ? b.downloadVersion : b.version;
      final byVer = bv.compareTo(av);
      if (byVer != 0) return byVer;
      return b.version.compareTo(a.version);
    });

    final withUrl = versions.where((v) => v.downloadUrl.isNotEmpty).length;
    LogManager.instance.write(
      'VersionService',
      '完成: ${versions.length} 个版本, 其中 $withUrl 个可直接下载',
    );

    return FetchVersionsResult(versions: versions, warnings: warnings);
  }

  void _mergeXmlNotes(
    List<StudioVersion> archiveVersions,
    List<StudioVersion> xmlVersions,
  ) {
    for (var i = 0; i < archiveVersions.length; i++) {
      final a = archiveVersions[i];
      if (a.releaseNotes.isNotEmpty) continue;

      StudioVersion? matched;
      for (final x in xmlVersions) {
        final sameCodename = x.codename.isNotEmpty &&
            a.codename.toLowerCase() == x.codename.toLowerCase();
        final aBase = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(a.version)?.group(1);
        final xBase = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(x.version)?.group(1);
        final sameBase = aBase != null && aBase == xBase;
        if (sameCodename || sameBase) {
          matched = x;
          break;
        }
      }
      if (matched == null || matched.releaseNotes.isEmpty) continue;

      archiveVersions[i] = StudioVersion(
        version: a.version,
        codename: a.codename,
        buildNumber: a.buildNumber,
        channel: a.channel,
        channelLabel: a.channelLabel,
        releaseNotes: matched.releaseNotes,
        downloadUrl: a.downloadUrl,
        downloadVersion: a.downloadVersion,
        sha256: a.sha256,
        isHistorical: a.isHistorical,
      );
    }
  }
}
