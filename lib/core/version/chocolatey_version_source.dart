import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/version/version_source.dart';
import 'package:http/http.dart' as http;

/// 从 Chocolatey API 获取历史版本
class ChocolateyVersionSource implements VersionSource {
  ChocolateyVersionSource({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  @override
  String get name => 'Chocolatey';

  @override
  Future<VersionSourceResult> fetch() async {
    final vers = <String>[];
    final warnings = <String>[];
    var page = 0;

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
    } catch (e) {
      warnings.add('Chocolatey 版本获取异常: $e');
    }

    LogManager.instance.write('VersionService', 'Chocolatey 获取到 ${vers.length} 个版本');

    // 转为 StudioVersion 列表
    final versions = vers.map((cv) {
      return StudioVersion(
        version: cv,
        codename: '',
        buildNumber: '',
        channel: 'archive',
        channelLabel: '历史',
        releaseNotes: '',
        downloadVersion: cv,
        downloadUrl: 'https://edgedl.me.gvt1.com/android/studio/install/$cv/android-studio-$cv-windows.exe',
        isHistorical: true,
      );
    }).toList();

    return VersionSourceResult(versions: versions, warnings: warnings);
  }
}
