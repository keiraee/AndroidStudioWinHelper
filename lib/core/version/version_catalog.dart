import 'dart:math' as math;

import 'package:androidstudiowinhelper/core/models/studio_version.dart';

/// 版本列表的展示规则：默认 Stable、置顶最新正式包、历史包折叠。
class VersionCatalog {
  static const String defaultChannel = 'release';
  static const int defaultRecentLimit = 8;

  static int compareDownloadVersion(String a, String b) {
    final ap = _parts(a);
    final bp = _parts(b);
    final n = math.max(ap.length, bp.length);
    for (var i = 0; i < n; i++) {
      final av = i < ap.length ? ap[i] : 0;
      final bv = i < bp.length ? bp[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  static List<StudioVersion> sorted(List<StudioVersion> versions) {
    final copy = List<StudioVersion>.from(versions);
    copy.sort((a, b) {
      final byVer = compareDownloadVersion(_key(b), _key(a));
      if (byVer != 0) return byVer;
      return b.version.compareTo(a.version);
    });
    return copy;
  }

  static List<StudioVersion> filtered(
    List<StudioVersion> versions, {
    String? channel,
  }) {
    if (channel == null) return List<StudioVersion>.from(versions);
    return versions.where((v) => v.channel == channel).toList();
  }

  /// 未指定渠道时置顶最新正式版；指定渠道时置顶该渠道最新可下载包。
  static StudioVersion? featured(
    List<StudioVersion> versions, {
    String? channel,
  }) {
    final target = channel ?? defaultChannel;
    for (final v in sorted(versions)) {
      if (v.channel != target) continue;
      if (v.downloadUrl.isEmpty) continue;
      return v;
    }
    return null;
  }

  static List<StudioVersion> listForDisplay({
    required List<StudioVersion> versions,
    String? channel,
    required bool showHistory,
    int recentLimit = defaultRecentLimit,
  }) {
    final feat = featured(versions, channel: channel);
    var items = filtered(sorted(versions), channel: channel)
        .where((v) => feat == null || v.downloadUrl != feat.downloadUrl)
        .toList();
    if (!showHistory && items.length > recentLimit) {
      items = items.take(recentLimit).toList();
    }
    return items;
  }

  static bool hasMoreHistory({
    required List<StudioVersion> versions,
    String? channel,
    int recentLimit = defaultRecentLimit,
  }) {
    final feat = featured(versions, channel: channel);
    final count = filtered(versions, channel: channel)
        .where((v) => feat == null || v.downloadUrl != feat.downloadUrl)
        .length;
    return count > recentLimit;
  }

  static String _key(StudioVersion v) =>
      v.downloadVersion.isNotEmpty ? v.downloadVersion : v.version;

  static List<int> _parts(String version) {
    return version
        .split('.')
        .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }
}
