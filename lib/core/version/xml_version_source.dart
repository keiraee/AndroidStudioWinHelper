import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/version/version_source.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

/// 从 updates.xml 获取当前版本元数据
class XmlVersionSource implements VersionSource {
  XmlVersionSource({http.Client? client}) : _client = client ?? http.Client();

  static const _updatesUrl =
      'https://dl.google.com/dl/android/studio/patches/updates.xml';
  static const _updatesMirrorUrl =
      'https://edgedl.me.gvt1.com/dl/android/studio/patches/updates.xml';
  static const _cacheFileName = 'updates.xml.cache';

  final http.Client _client;

  @override
  String get name => 'XML';

  @override
  Future<VersionSourceResult> fetch() async {
    final xmlBody = await _fetchUpdatesXml();
    return _parseXml(xmlBody);
  }

  /// 三层容错获取 XML：主 URL → 镜像 URL → 本地缓存
  Future<String> _fetchUpdatesXml() async {
    for (final entry in [
      ('主站', _updatesUrl),
      ('镜像', _updatesMirrorUrl),
    ]) {
      final (label, url) = entry;
      try {
        LogManager.instance.write('VersionService', '尝试 $label: $url');
        final resp = await _client
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        if (resp.statusCode == 200 && resp.body.contains('<product')) {
          LogManager.instance.write('VersionService', '$label 获取成功 (${resp.body.length} bytes)');
          _saveCache(resp.body);
          return resp.body;
        }
        LogManager.instance.write('VersionService', '$label 响应异常: HTTP ${resp.statusCode}');
      } catch (e) {
        LogManager.instance.write('VersionService', '$label 失败: $e');
      }
    }

    LogManager.instance.write('VersionService', '网络全部失败，尝试本地缓存');
    final cached = _loadCache();
    if (cached != null) {
      LogManager.instance.write('VersionService', '使用本地缓存 (${cached.length} bytes)');
      return cached;
    }

    throw StateError(
      '无法获取版本列表：网络超时且无本地缓存。\n'
      '请检查网络连接或代理设置后重试。'
    );
  }

  VersionSourceResult _parseXml(String xmlBody) {
    LogManager.instance.write('VersionService', '解析 XML (${xmlBody.length} bytes)');

    final document = XmlDocument.parse(xmlBody);
    final products = document.findAllElements('product').toList();

    final product = products.where(
      (e) => e.getAttribute('name') == 'Android Studio',
    ).firstOrNull;

    if (product == null) {
      for (final p in products) {
        LogManager.instance.write('VersionService', '  product: name=${p.getAttribute('name')}, id=${p.getAttribute('id')}');
      }
      throw StateError('XML 中未找到 Android Studio 产品（找到 ${products.length} 个 product）');
    }

    LogManager.instance.write('VersionService', '找到 Android Studio product，解析 channel...');
    final versions = <StudioVersion>[];
    final channels = product.findAllElements('channel').toList();
    LogManager.instance.write('VersionService', '找到 ${channels.length} 个 channel');

    for (final channel in channels) {
      final status = channel.getAttribute('status') ?? '';
      final channelLabel = _channelLabel(status);
      final builds = channel.findAllElements('build').toList();
      LogManager.instance.write('VersionService', '  channel: $status ($channelLabel), ${builds.length} 个 build');

      for (final build in builds) {
        final version = build.getAttribute('version') ?? '';
        final number = build.getAttribute('number') ?? '';
        final messageElement = build.findAllElements('message').firstOrNull;
        final notes =
            messageElement != null ? _stripHtml(messageElement.innerText) : '';

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

    return VersionSourceResult(versions: versions);
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

  static String get _cachePath {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    return '$localAppData\\AndroidStudioWinHelper\\$_cacheFileName';
  }

  void _saveCache(String body) {
    try {
      File(_cachePath).writeAsStringSync(body);
    } catch (_) {}
  }

  String? _loadCache() {
    try {
      final file = File(_cachePath);
      if (file.existsSync()) return file.readAsStringSync();
    } catch (_) {}
    return null;
  }
}
