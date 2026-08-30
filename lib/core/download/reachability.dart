import 'dart:io';

enum ProbeMode { page, file }

class ProbeResult {
  const ProbeResult({
    required this.ok,
    this.latencyMs,
    this.statusCode,
    this.url,
  });

  final bool ok;
  final int? latencyMs;
  final int? statusCode;
  final String? url;

  /// 0 = 不通，1–4 = 信号格（延迟越低格数越多）。
  int get signalBars {
    if (!ok || latencyMs == null) return 0;
    final ms = latencyMs!;
    if (ms < 150) return 4;
    if (ms < 400) return 3;
    if (ms < 800) return 2;
    return 1;
  }
}

abstract class ProbeTransport {
  Future<ProbeResult> probe(String url, ProbeMode mode);
}

/// 对归档页 / 安装包直链做短请求测延迟。不用 ICMP ping（CDN 经常禁 ping）。
class Reachability {
  Reachability({
    ProbeTransport? transport,
    this.timeout = const Duration(seconds: 8),
  }) : transport = transport ?? HttpProbeTransport(timeout: timeout);

  final ProbeTransport transport;
  final Duration timeout;

  static const archiveUrls = [
    'https://developer.android.com/studio/archive',
    'https://developer.android.google.cn/studio/archive?hl=zh-cn',
  ];

  static const archiveFallbackUrl =
      'https://developer.android.google.cn/studio/archive?hl=zh-cn';

  static const verifyAttempts = 3;

  Future<ProbeResult> probeArchive() async {
    ProbeResult? last;
    for (final url in archiveUrls) {
      last = await transport.probe(url, ProbeMode.page);
      if (last.ok) {
        return ProbeResult(
          ok: true,
          latencyMs: last.latencyMs,
          statusCode: last.statusCode,
          url: url,
        );
      }
    }
    return last ?? const ProbeResult(ok: false);
  }

  Future<ProbeResult> probeDownload(String url) async {
    final result = await transport.probe(url, ProbeMode.file);
    return ProbeResult(
      ok: result.ok,
      latencyMs: result.latencyMs,
      statusCode: result.statusCode,
      url: url,
    );
  }

  Future<bool> verifyDownload(String url) async {
    for (var i = 0; i < verifyAttempts; i++) {
      final result = await probeDownload(url);
      if (result.ok) return true;
    }
    return false;
  }
}

class HttpProbeTransport implements ProbeTransport {
  HttpProbeTransport({this.timeout = const Duration(seconds: 8)});

  final Duration timeout;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  @override
  Future<ProbeResult> probe(String url, ProbeMode mode) async {
    final sw = Stopwatch()..start();
    final client = HttpClient();
    client.userAgent = _ua;
    client.connectionTimeout = timeout;
    try {
      final request = await client.getUrl(Uri.parse(url)).timeout(timeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      if (mode == ProbeMode.file) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      }
      final response = await request.close().timeout(timeout);
      sw.stop();
      final code = response.statusCode;
      final ok = code >= 200 && code < 400;
      await _abortBody(response);
      return ProbeResult(
        ok: ok,
        latencyMs: sw.elapsedMilliseconds,
        statusCode: code,
        url: url,
      );
    } catch (_) {
      sw.stop();
      return ProbeResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        url: url,
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _abortBody(HttpClientResponse response) async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } catch (_) {
      try {
        await response.drain<void>().timeout(
          const Duration(milliseconds: 300),
          onTimeout: () {},
        );
      } catch (_) {}
    }
  }
}
