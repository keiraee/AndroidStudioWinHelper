import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

class StudioVersionService {
  static const _updatesUrl =
      'https://dl.google.com/dl/android/studio/patches/updates.xml';

  static const _downloadPage =
      'https://developer.android.google.cn/studio?hl=zh-cn&download';
  static const _previewPage =
      'https://developer.android.google.cn/studio/preview?hl=zh-cn';

  static const _oldDlBase =
      'https://redirector.gvt1.com/edgedl/android/studio/install';

  final http.Client _client;

  StudioVersionService({http.Client? client})
      : _client = client ?? http.Client();

  void dispose() => _client.close();

  Future<List<StudioVersion>> fetchVersions() async {
    // 1. 解析 XML 获取当前版本元数据
    final versions = <StudioVersion>[];
    final xmlResponse = await _client.get(Uri.parse(_updatesUrl));
    if (xmlResponse.statusCode != 200) {
      throw StateError('获取版本列表失败：HTTP ${xmlResponse.statusCode}');
    }

    final document = XmlDocument.parse(xmlResponse.body);
    final product = document.findAllElements('product').firstWhere(
          (e) => e.getAttribute('name') == 'Android Studio',
          orElse: () => throw StateError('XML 中未找到 Android Studio 产品'),
        );

    final knownBaseVers = <String>{};

    for (final channel in product.findAllElements('channel')) {
      final status = channel.getAttribute('status') ?? '';
      final channelLabel = _channelLabel(status);

      for (final build in channel.findAllElements('build')) {
        final version = build.getAttribute('version') ?? '';
        final number = build.getAttribute('number') ?? '';
        final messageElement = build.findAllElements('message').firstOrNull;
        final notes =
            messageElement != null ? _stripHtml(messageElement.innerText) : '';

        final base = _extractBaseVersion(version);
        if (base.isNotEmpty) knownBaseVers.add(base);

        versions.add(StudioVersion(
          version: version,
          codename: _extractCodename(version),
          buildNumber: number,
          channel: status,
          channelLabel: channelLabel,
          releaseNotes: notes,
          downloadVersion: '',
          downloadUrl: '',
        ));
      }
    }

    // 2. 抓取下载页面获取实际下载链接（最新版本）
    final downloadUrls = <String, String>{};
    await _scrapeDownloadUrls(downloadUrls);

    // 3. 匹配下载链接到 XML 版本
    for (var i = 0; i < versions.length; i++) {
      final v = versions[i];
      final base = _extractBaseVersion(v.version);
      if (base.isNotEmpty && downloadUrls.containsKey(base)) {
        versions[i] = _copyWithUrl(v, downloadUrls[base]!);
      }
    }

    // 4. 从 Chocolatey 补充历史版本
    final chocoVers = await _fetchChocolateyVersions();
    for (final cv in chocoVers) {
      final base = _extractChocoBase(cv);
      if (base.isEmpty) continue;
      // 跳过已存在于 XML 的版本（按主版本号避免重复）
      if (knownBaseVers.any((k) => k.startsWith(base) || base.startsWith(k))) {
        continue;
      }
      knownBaseVers.add(base);

      final dlUrl =
          '$_oldDlBase/$cv/android-studio-$cv-windows.exe';

      versions.add(StudioVersion(
        version: cv,
        codename: '',
        buildNumber: '',
        channel: 'archive',
        channelLabel: '历史',
        releaseNotes: '',
        downloadVersion: cv,
        downloadUrl: dlUrl,
        isHistorical: true,
      ));
    }

    // 按 version 排序列（新版在前）
    versions.sort((a, b) => b.version.compareTo(a.version));

    return versions;
  }

  Future<void> _scrapeDownloadUrls(Map<String, String> urls) async {
    for (final page in [_downloadPage, _previewPage]) {
      try {
        final response = await _client.get(Uri.parse(page));
        if (response.statusCode != 200) continue;

        final matches = RegExp(
          r'https://[^"\s]*android-studio[^"\s]*windows[^"\s]*\.exe',
        ).allMatches(response.body);

        for (final m in matches) {
          final url = m.group(0)!;
          final baseMatch =
              RegExp(r'/(\d+\.\d+\.\d+)\.\d+/').firstMatch(url);
          if (baseMatch != null) {
            final baseVer = baseMatch.group(1)!;
            if (!urls.containsKey(baseVer)) {
              urls[baseVer] = url;
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<List<String>> _fetchChocolateyVersions() async {
    final vers = <String>[];
    var page = 0;

    // Chocolatey API XML 分页
    try {
      String? nextUrl =
          'https://community.chocolatey.org/api/v2/Packages()?\$filter=Id%20eq%20%27androidstudio%27';

      while (nextUrl != null && page < 20) {
        final uri = Uri.parse(nextUrl);
        final secureUrl = uri.replace(scheme: 'https').toString();

        final response = await _client.get(Uri.parse(secureUrl));
        if (response.statusCode != 200) break;

        final body = response.body;
        final entryPattern = RegExp(
          r'<d:Version[^>]*>([^<]+)</d:Version>',
        );
        for (final m in entryPattern.allMatches(body)) {
          final ver = m.group(1)!.trim();
          if (ver.isNotEmpty && !vers.contains(ver)) {
            vers.add(ver);
          }
        }

        final nextMatch =
            RegExp(r'<link rel="next" href="([^"]+)"').firstMatch(body);
        nextUrl = nextMatch?.group(1)?.replaceAll('&amp;', '&');
        page++;
      }
    } catch (_) {}

    return vers;
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
    );
  }

  static String _extractChocoBase(String ver) {
    // 4-part version like "2024.2.1.11" → base "2024.2"
    final parts = ver.split('.');
    if (parts.length >= 2) return '${parts[0]}.${parts[1]}';
    return ver;
  }

  static String _channelLabel(String status) => switch (status) {
        'release' => 'Stable',
        'beta' => 'Beta',
        'eap' => 'Canary',
        'milestone' => 'Dev',
        _ => status,
      };

  static String _extractCodename(String version) {
    final parts = version.split('|');
    return parts.isNotEmpty ? parts.first.trim() : '';
  }

  static String _extractBaseVersion(String version) {
    final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(version);
    return match?.group(1) ?? '';
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll(RegExp(r'\n\s*\n+'), '\n\n')
        .trim();
  }
}
