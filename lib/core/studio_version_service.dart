import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/version/cdn_probe.dart';
import 'package:androidstudiowinhelper/core/version/chocolatey_version_source.dart';
import 'package:androidstudiowinhelper/core/version/url_guesser.dart';
import 'package:androidstudiowinhelper/core/version/version_source.dart';
import 'package:androidstudiowinhelper/core/version/xml_version_source.dart';
import 'package:http/http.dart' as http;

/// 版本服务编排器 — 按优先级调用各数据源并合并结果
class StudioVersionService {
  StudioVersionService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;
  late final XmlVersionSource _xmlSource = XmlVersionSource(client: _client);
  late final ChocolateyVersionSource _chocoSource = ChocolateyVersionSource(client: _client);
  late final CdnProbe _cdnProbe = CdnProbe(client: _client);

  void dispose() => _client.close();

  Future<FetchVersionsResult> fetchVersions() async {
    final versions = <StudioVersion>[];
    final warnings = <String>[];
    final knownBaseVers = <String>{};

    // 1. XML 数据源（主数据源）
    final xmlResult = await _fetchSource(_xmlSource, warnings);
    if (xmlResult != null) {
      for (final v in xmlResult.versions) {
        final base = UrlGuesser.extractBaseVersion(v.version);
        if (base.isNotEmpty) knownBaseVers.add(base);
        versions.add(v);
      }
    }

    // 2. 尝试从页面抓取下载链接
    final downloadUrls = <String, String>{};
    final scrapeWarnings = await _scrapeDownloadUrls(downloadUrls);
    warnings.addAll(scrapeWarnings);
    LogManager.instance.write('VersionService', '从页面抓到 ${downloadUrls.length} 个下载链接');

    // 3. 如果页面抓取失败，从 XML buildNumber 反推 URL 并通过 CDN 探测验证
    if (downloadUrls.isEmpty && versions.isNotEmpty) {
      LogManager.instance.write('VersionService', '页面抓取无结果，从 XML buildNumber 反推 URL 并探测 CDN');
      for (final v in versions) {
        if (v.downloadUrl.isNotEmpty) continue;
        final guessed = UrlGuesser.guess(v);
        if (guessed == null) continue;

        final (guessedUrl, decodedVer) = guessed;
        LogManager.instance.write('VersionService',
            '反推 URL: ${v.version} (build=${v.buildNumber}, 解码=$decodedVer) -> $guessedUrl');

        final probeResult = await _cdnProbe.probe(guessedUrl);
        if (probeResult != null) {
          LogManager.instance.write('VersionService',
              '  CDN 探测通过: ${probeResult ~/ 1024 ~/ 1024}MB');
          downloadUrls[decodedVer] = guessedUrl;
          final base = UrlGuesser.extractBaseVersion(v.version);
          if (base.isNotEmpty && !downloadUrls.containsKey(base)) {
            downloadUrls[base] = guessedUrl;
          }
        } else {
          LogManager.instance.write('VersionService', '  CDN 探测失败，跳过');
        }
      }
    }

    // 4. 匹配下载链接到 XML 版本
    for (var i = 0; i < versions.length; i++) {
      final v = versions[i];
      final base = UrlGuesser.extractBaseVersion(v.version);
      final decodedVer = UrlGuesser.decodeBuildNumberToVersion(v.buildNumber, v.version);

      String? matchedUrl;
      if (decodedVer != null && downloadUrls.containsKey(decodedVer)) {
        matchedUrl = downloadUrls[decodedVer];
      }
      // 注意：移除了 base fallback，因为不同版本（stable/canary/RC）
      // 共享同一个 base（如 "2026.1.1"），fallback 会导致错误匹配
      if (matchedUrl != null) {
        versions[i] = _copyWithUrl(v, matchedUrl);
      }
    }

    // 5. Chocolatey 数据源（历史版本补充）
    final chocoResult = await _fetchSource(_chocoSource, warnings);
    if (chocoResult != null) {
      for (final cv in chocoResult.versions) {
        final base = UrlGuesser.extractChocoBase(cv.version);
        if (base.isEmpty) continue;
        if (knownBaseVers.any((k) => k.startsWith(base) || base.startsWith(k))) {
          continue;
        }
        knownBaseVers.add(base);
        versions.add(cv);
      }
    }

    // 6. 排序
    versions.sort((a, b) => b.version.compareTo(a.version));

    return FetchVersionsResult(versions: versions, warnings: warnings);
  }

  Future<VersionSourceResult?> _fetchSource(
    VersionSource source,
    List<String> warnings,
  ) async {
    try {
      LogManager.instance.write('VersionService', '获取 ${source.name} 数据源...');
      final result = await source.fetch();
      warnings.addAll(result.warnings);
      LogManager.instance.write('VersionService',
          '${source.name} 获取到 ${result.versions.length} 个版本');
      return result;
    } catch (e) {
      LogManager.instance.write('VersionService', '${source.name} 失败: $e');
      warnings.add('${source.name} 数据源获取失败: $e');
      return null;
    }
  }

  Future<List<String>> _scrapeDownloadUrls(Map<String, String> urls) async {
    final warnings = <String>[];
    const pages = [
      'https://developer.android.google.cn/studio?hl=zh-cn&download',
      'https://developer.android.google.cn/studio/preview?hl=zh-cn',
    ];

    for (final page in pages) {
      try {
        final response = await _client
            .get(Uri.parse(page))
            .timeout(const Duration(seconds: 15), onTimeout: () {
          throw StateError('下载页面请求超时: $page');
        });
        if (response.statusCode != 200) {
          warnings.add('下载页面获取失败 (HTTP ${response.statusCode}): $page');
          continue;
        }

        final matches = RegExp(
          r'https://[^"\s]*android-studio[^"\s]*windows[^"\s]*\.exe',
        ).allMatches(response.body);

        for (final m in matches) {
          final url = m.group(0)!;
          final verMatch =
              RegExp(r'/(\d+\.\d+\.\d+\.?\d*)/').firstMatch(url);
          if (verMatch != null) {
            final ver = verMatch.group(1)!;
            if (!urls.containsKey(ver)) urls[ver] = url;
            final parts = ver.split('.');
            if (parts.length >= 3) {
              final baseVer = '${parts[0]}.${parts[1]}.${parts[2]}';
              if (!urls.containsKey(baseVer)) urls[baseVer] = url;
            }
          }
        }
      } catch (e) {
        warnings.add('下载页面抓取异常: $page ($e)');
      }
    }
    return warnings;
  }

  StudioVersion _copyWithUrl(StudioVersion v, String url) {
    return StudioVersion(
      version: v.version,
      codename: v.codename,
      buildNumber: v.buildNumber,
      channel: v.channel,
      channelLabel: v.channelLabel,
      releaseNotes: v.releaseNotes,
      downloadVersion: v.downloadVersion,
      downloadUrl: url,
      isHistorical: v.isHistorical,
    );
  }
}
