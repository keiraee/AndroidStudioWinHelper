import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:http/http.dart' as http;

/// CDN URL 探测器 — 通过 HEAD 请求验证下载 URL 是否存在
class CdnProbe {
  CdnProbe({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// 探测 URL 是否存在，返回文件大小或 null
  Future<int?> probe(String url) async {
    try {
      final request = http.Request('HEAD', Uri.parse(url));
      request.headers['User-Agent'] = 'Mozilla/5.0';
      request.headers['Accept-Encoding'] = 'identity';
      final response = await _client.send(request).timeout(
        const Duration(seconds: 15),
      );
      if (response.statusCode == 200) {
        return response.contentLength;
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
