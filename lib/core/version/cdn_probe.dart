import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:http/http.dart' as http;

/// CDN URL 探测器 — HEAD 优先，失败时回退到 Range GET
class CdnProbe {
  CdnProbe({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const _headers = {
    'User-Agent': 'Mozilla/5.0',
    'Accept-Encoding': 'identity',
  };

  /// 探测 URL 是否存在，返回文件大小或 null
  Future<int?> probe(String url) async {
    final headSize = await _probeHead(url);
    if (headSize != null) return headSize;
    return _probeRangeGet(url);
  }

  Future<int?> _probeHead(String url) async {
    try {
      final request = http.Request('HEAD', Uri.parse(url));
      request.headers.addAll(_headers);
      final response = await _client.send(request).timeout(
            const Duration(seconds: 15),
          );
      if (response.statusCode == 200 || response.statusCode == 206) {
        final length = response.contentLength;
        if (length != null && length > 0) return length;
        final headerLen = response.headers['content-length'];
        if (headerLen != null) return int.tryParse(headerLen);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 部分 CDN 拒绝 HEAD 或不返回 Content-Length；用 1 字节 Range GET 确认。
  Future<int?> _probeRangeGet(String url) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(_headers);
      request.headers['Range'] = 'bytes=0-0';
      final response = await _client.send(request).timeout(
            const Duration(seconds: 15),
          );

      if (response.statusCode != 200 && response.statusCode != 206) {
        await response.stream.drain<void>();
        return null;
      }

      final contentRange = response.headers['content-range'];
      if (contentRange != null) {
        // bytes 0-0/123456789
        final total = contentRange.split('/').last;
        final size = int.tryParse(total);
        if (size != null && size > 0) {
          await response.stream.drain<void>();
          return size;
        }
      }

      final length = response.contentLength;
      await response.stream.drain<void>();
      if (length != null && length > 0) return length;
      // 200 且无长度时至少认为 URL 存在
      if (response.statusCode == 200 || response.statusCode == 206) {
        return 1;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 批量探测 URL 列表，返回存在的 URL 映射
  Future<Map<String, int>> probeBatch(Map<String, String> urlMap) async {
    final results = <String, int>{};
    for (final entry in urlMap.entries) {
      final size = await probe(entry.value);
      if (size != null) {
        LogManager.instance.write('VersionService',
            '  CDN 探测通过: ${entry.key} -> ${size ~/ 1024 ~/ 1024}MB');
        results[entry.key] = size;
      } else {
        LogManager.instance.write('VersionService',
            '  CDN 探测失败: ${entry.key}');
      }
    }
    return results;
  }
}
