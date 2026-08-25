import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:http/http.dart' as http;

/// 从官方归档页 iframe 解析全部 Windows 安装包（含 SHA-256）。
///
/// 归档壳页 https://developer.android.com/studio/archive 本身几乎无链接，
/// 完整列表在内嵌 `/frame/studio/archive_*.frame` 中；页面上的 TOS 墙只是
/// 前端隐藏 `.all-downloads`，链接仍在 HTML 里，CDN 不要求先点同意。
class ArchiveVersionSource {
  ArchiveVersionSource({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const archivePages = [
    'https://developer.android.com/studio/archive',
    'https://developer.android.google.cn/studio/archive?hl=zh-cn',
  ];

  Future<ArchiveFetchResult> fetch() async {
    final warnings = <String>[];

    for (final page in archivePages) {
      try {
        LogManager.instance.write('VersionService', '抓取归档页: $page');
        final html = await _getHtml(page, timeoutSeconds: 30);
        final frameUrl = extractArchiveFrameUrl(html, page);
        if (frameUrl == null) {
          warnings.add('归档页未找到 iframe: $page');
          continue;
        }

        LogManager.instance.write('VersionService', '抓取归档 iframe: $frameUrl');
        final frameHtml = await _getHtml(frameUrl, timeoutSeconds: 60);
        final versions = parseArchiveFrame(frameHtml);
        LogManager.instance.write(
          'VersionService',
          '归档解析到 ${versions.length} 个 Windows 安装包',
        );
        if (versions.isNotEmpty) {
          return ArchiveFetchResult(versions: versions, warnings: warnings);
        }
        warnings.add('归档 iframe 未解析到 Windows 安装包: $frameUrl');
      } catch (e) {
        warnings.add('归档页抓取异常: $page ($e)');
      }
    }

    return ArchiveFetchResult(versions: const [], warnings: warnings);
  }

  Future<String> _getHtml(String url, {int timeoutSeconds = 15}) async {
    final response = await _client.get(
      Uri.parse(url),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    ).timeout(
      Duration(seconds: timeoutSeconds),
      onTimeout: () => throw StateError('请求超时: $url'),
    );
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}: $url');
    }
    return response.body;
  }

  /// 从归档壳页面提取 iframe 地址（hash 会变，必须动态解析）。
  static String? extractArchiveFrameUrl(String html, String pageUrl) {
    final match = RegExp(
      r'''(?:src|data-src)=["']([^"']*frame/studio/archive_[^"']+\.frame)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) return null;

    final raw = match.group(1)!;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;

    final pageUri = Uri.parse(pageUrl);
    if (raw.startsWith('//')) return '${pageUri.scheme}:$raw';
    if (raw.startsWith('/')) {
      return '${pageUri.scheme}://${pageUri.host}$raw';
    }
    return '${pageUri.scheme}://${pageUri.host}/$raw';
  }

  /// 解析 iframe HTML 中每个 expandable section 的 Windows exe + SHA-256。
  static List<StudioVersion> parseArchiveFrame(String html) {
    final versions = <StudioVersion>[];
    final sectionRe = RegExp(
      r'<section\s+class="expandable([^"]*)">([\s\S]*?)</section>',
      caseSensitive: false,
    );

    for (final section in sectionRe.allMatches(html)) {
      final classHint = section.group(1) ?? '';
      final body = section.group(2) ?? '';

      final titleMatch = RegExp(
        r'class="expand-control"[^>]*>([\s\S]*?)</p>',
        caseSensitive: false,
      ).firstMatch(body);
      if (titleMatch == null) continue;

      final titleHtml = titleMatch.group(1)!;
      final titleText = titleHtml
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      // "Android Studio Quail 3 | 2026.1.3 July 30, 2026"
      final nameMatch = RegExp(
        r'Android Studio\s+(.+?)\s*\|\s*([\d.]+(?:\s+[A-Za-z]+\s*\d+)?)',
        caseSensitive: false,
      ).firstMatch(titleText);
      if (nameMatch == null) continue;

      final codename = nameMatch.group(1)!.trim();
      final versionPart = nameMatch.group(2)!.trim();
      final displayVersion = '$codename | $versionPart';

      final exeMatch = RegExp(
        r'Windows\s*\(64-bit\):\s*<a\s+href="(https://[^"]+android-studio[^"]*windows\.exe)"',
        caseSensitive: false,
      ).firstMatch(body);
      if (exeMatch == null) continue;
      final url = exeMatch.group(1)!;

      final fileName = url.split('/').last;
      final shaMatch = RegExp(
        '([0-9a-fA-F]{64})\\s+$fileName',
        caseSensitive: false,
      ).firstMatch(body);
      final sha256 = shaMatch?.group(1)?.toLowerCase() ?? '';

      final urlVerMatch = RegExp(r'/(\d+\.\d+\.\d+\.\d+)/').firstMatch(url);
      final downloadVersion = urlVerMatch?.group(1) ?? '';

      final channelInfo = _classifyChannel(classHint, versionPart);

      versions.add(StudioVersion(
        version: displayVersion,
        codename: codename,
        buildNumber: downloadVersion,
        channel: channelInfo.$1,
        channelLabel: channelInfo.$2,
        releaseNotes: '',
        downloadUrl: url,
        downloadVersion: downloadVersion,
        sha256: sha256,
        isHistorical: true,
      ));
    }

    // 去重：同一 downloadUrl 只保留一条
    final seen = <String>{};
    return versions.where((v) => seen.add(v.downloadUrl)).toList();
  }

  static (String channel, String label) _classifyChannel(
    String classHint,
    String versionPart,
  ) {
    final lower = versionPart.toLowerCase();
    if (lower.contains('canary')) return ('eap', 'Canary');
    if (lower.contains('rc')) return ('beta', 'RC');
    if (lower.contains('beta')) return ('beta', 'Beta');
    if (lower.contains('patch')) return ('release', 'Patch');
    if (lower.contains('nightly') || lower.contains('dev')) {
      return ('milestone', 'Dev');
    }
    if (classHint.contains('stable')) return ('release', 'Stable');
    return ('release', 'Stable');
  }
}

class ArchiveFetchResult {
  const ArchiveFetchResult({
    required this.versions,
    this.warnings = const [],
  });

  final List<StudioVersion> versions;
  final List<String> warnings;
}
