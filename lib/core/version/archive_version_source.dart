import 'dart:isolate';

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
        final versions = await parseArchiveFrameOffUi(frameHtml);
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

  /// 归档 HTML 约 1MB、六百多段，放到后台 isolate，避免卡住界面。
  static Future<List<StudioVersion>> parseArchiveFrameOffUi(String html) async {
    final maps = await Isolate.run(
      () => parseArchiveFrame(html).map((v) => v.toJson()).toList(),
    );
    return [for (final map in maps) StudioVersion.fromJson(map)];
  }

  /// 解析 iframe HTML 中每个 expandable section 的 Windows 安装包 + SHA-256。
  ///
  /// 2020 年起是 `Codename | 2024.2.1` + `android-studio-*-windows.exe`；
  /// 更早是 `Android Studio 3.6.3` / `2.3.3`，链接可能是 ide/bundle exe 或 zip。
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
        r'class="expand-control"[^>]*>([\s\S]*?)</(?:p|h[1-6]|div|button|span)>',
        caseSensitive: false,
      ).firstMatch(body);
      if (titleMatch == null) continue;

      final titleHtml = titleMatch.group(1)!;
      final titleText = titleHtml
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final parsed = parseTitle(titleText);
      if (parsed == null) continue;

      final url = extractWindowsDownloadUrl(body);
      if (url == null) continue;

      final fileName = url.split('/').last;
      final shaMatch = RegExp(
        '([0-9a-fA-F]{64})\\s+$fileName',
        caseSensitive: false,
      ).firstMatch(body);
      final sha256 = shaMatch?.group(1)?.toLowerCase() ?? '';

      final urlVerMatch =
          RegExp(r'/(\d+\.\d+\.\d+(?:\.\d+)?)/').firstMatch(url);
      final downloadVersion = urlVerMatch?.group(1) ?? '';

      final channelInfo = classifyChannel(classHint, parsed.versionPart);

      versions.add(StudioVersion(
        version: parsed.display,
        codename: parsed.codename,
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

    final seen = <String>{};
    return versions.where((v) => seen.add(v.downloadUrl)).toList();
  }

  static ({String codename, String versionPart, String display})? parseTitle(
    String titleText,
  ) {
    final cleaned = titleText.trim();
    if (!RegExp(r'^Android Studio\b', caseSensitive: false)
        .hasMatch(cleaned)) {
      return null;
    }
    var rest = cleaned
        .replaceFirst(RegExp(r'^Android Studio\s*', caseSensitive: false), '')
        .trim();
    rest = stripReleaseDate(rest);
    if (rest.isEmpty) return null;
    final pipe = rest.indexOf('|');
    if (pipe >= 0) {
      final codename = rest.substring(0, pipe).trim();
      final versionPart = stripReleaseDate(rest.substring(pipe + 1).trim());
      if (codename.isEmpty || versionPart.isEmpty) return null;
      return (
        codename: codename,
        versionPart: versionPart,
        display: '$codename | $versionPart',
      );
    }
    return (codename: rest, versionPart: rest, display: rest);
  }

  /// 归档标题末尾的 `August 10, 2026` 是发布日，不是版本号。
  static String stripReleaseDate(String text) {
    return text
        .replaceFirst(
          RegExp(
            r'\s+(January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2},\s+\d{4}\s*$',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  static String? extractWindowsDownloadUrl(String body) {
    const patterns = [
      r'Windows\s*\((?:64-bit|64\s*bit)\)\s*:\s*<a\s+href="(https://[^"]+windows\.exe)"',
      r'Windows\s*:\s*<a\s+href="(https://[^"]+windows\.exe)"',
      r'href="(https://[^"]*android-studio[^"]*windows\.exe)"',
      r'Windows\s*\((?:64-bit|64\s*bit)\)\s*:\s*<a\s+href="(https://[^"]+windows\.zip)"',
      r'Windows\s*:\s*<a\s+href="(https://[^"]+windows\.zip)"',
      r'href="(https://[^"]*android-studio[^"]*windows\.zip)"',
    ];
    for (final pattern in patterns) {
      final match = RegExp(pattern, caseSensitive: false).firstMatch(body);
      if (match != null) return match.group(1);
    }
    return null;
  }

  /// 对照官网归档标题关键字。渠道按 Android Studio 更新通道归并：
  /// Canary/Preview → Canary，Beta/RC → Beta，Patch/正式版 → Stable。
  /// 必须按词边界匹配，否则 `March` 会命中 `rc`。
  static (String channel, String label) classifyChannel(
    String classHint,
    String versionPart,
  ) {
    if (_wordCanary.hasMatch(versionPart)) return ('eap', 'Canary');
    if (_wordPreview.hasMatch(versionPart)) return ('eap', 'Preview');
    if (_wordRc.hasMatch(versionPart)) return ('beta', 'RC');
    if (_wordBeta.hasMatch(versionPart)) return ('beta', 'Beta');
    if (_wordPatch.hasMatch(versionPart)) return ('release', 'Patch');
    if (_wordNightly.hasMatch(versionPart) || _wordDev.hasMatch(versionPart)) {
      return ('milestone', 'Dev');
    }

    final tokens = classHint
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toSet();
    if (tokens.contains('canary') || tokens.contains('eap')) {
      return ('eap', 'Canary');
    }
    if (tokens.contains('beta')) return ('beta', 'Beta');
    if (tokens.contains('dev') || tokens.contains('milestone')) {
      return ('milestone', 'Dev');
    }
    return ('release', 'Stable');
  }

  static final _wordCanary = RegExp(r'\bcanary\b', caseSensitive: false);
  static final _wordPreview = RegExp(r'\bpreview\b', caseSensitive: false);
  static final _wordRc = RegExp(r'\brc\b', caseSensitive: false);
  static final _wordBeta = RegExp(r'\bbeta\b', caseSensitive: false);
  static final _wordPatch = RegExp(r'\bpatch\b', caseSensitive: false);
  static final _wordNightly = RegExp(r'\bnightly\b', caseSensitive: false);
  static final _wordDev = RegExp(r'\bdev\b', caseSensitive: false);
}

class ArchiveFetchResult {
  const ArchiveFetchResult({
    required this.versions,
    this.warnings = const [],
  });

  final List<StudioVersion> versions;
  final List<String> warnings;
}
