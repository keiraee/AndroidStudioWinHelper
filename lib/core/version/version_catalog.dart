import 'dart:math' as math;

import 'package:androidstudiowinhelper/core/models/studio_version.dart';

/// 版本列表的展示规则：默认 Stable、置顶最新正式包、历史包折叠。
class VersionCatalog {
  static const String defaultChannel = 'release';
  static const int defaultRecentLimit = 8;
  static const List<String> channelOrder = [
    'release',
    'beta',
    'eap',
    'milestone',
    'archive',
  ];

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

  static List<String> orderedChannels(Iterable<String> channels) {
    final set = channels.toSet();
    return [
      for (final c in channelOrder)
        if (set.contains(c)) c,
      ...set.where((c) => !channelOrder.contains(c)),
    ];
  }

  static int? yearOf(StudioVersion version) {
    final calendar = RegExp(r'\b(201[4-9]|202[0-9]|203[0-5])\b');
    for (final source in [
      version.downloadVersion,
      version.version,
      version.buildNumber,
    ]) {
      final match = calendar.firstMatch(source);
      if (match != null) return int.parse(match.group(1)!);
    }
    return yearFromLegacyVersion(version.version) ??
        yearFromLegacyVersion(version.downloadVersion);
  }

  /// 4.2 / 3.x / 2.x 没有 2020.3 这种年号，按官方发版年份归类。
  static int? yearFromLegacyVersion(String version) {
    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(version);
    if (match == null) return null;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    if (major >= 2014 && major <= 2035) return major;
    if (major > 4) return null;
    return switch ((major, minor)) {
      (4, >= 2) => 2021,
      (4, _) => 2020,
      (3, >= 6) => 2020,
      (3, >= 3) => 2019,
      (3, >= 1) => 2018,
      (3, _) => 2017,
      (2, >= 3) => 2017,
      (2, _) => 2016,
      (1, _) => 2015,
      _ => null,
    };
  }

  static List<int> years(List<StudioVersion> versions) {
    final set = <int>{};
    for (final v in versions) {
      final year = yearOf(v);
      if (year != null) set.add(year);
    }
    final list = set.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  static List<StudioVersion> filtered(
    List<StudioVersion> versions, {
    String? channel,
    int? year,
  }) {
    return versions.where((v) {
      if (channel != null && v.channel != channel) return false;
      if (year != null && yearOf(v) != year) return false;
      return true;
    }).toList();
  }

  /// 未指定渠道时置顶最新正式版；指定渠道时置顶该渠道最新可下载包。
  static StudioVersion? featured(
    List<StudioVersion> versions, {
    String? channel,
    int? year,
  }) {
    final target = channel ?? defaultChannel;
    for (final v in sorted(filtered(versions, channel: target, year: year))) {
      if (v.downloadUrl.isEmpty) continue;
      return v;
    }
    return null;
  }

  static List<StudioVersion> listForDisplay({
    required List<StudioVersion> versions,
    String? channel,
    int? year,
    required bool showHistory,
    int recentLimit = defaultRecentLimit,
  }) {
    final feat = featured(versions, channel: channel, year: year);
    var items = filtered(sorted(versions), channel: channel, year: year)
        .where((v) => feat == null || v.downloadUrl != feat.downloadUrl)
        .toList();
    final fold = year == null && !showHistory && items.length > recentLimit;
    if (fold) {
      items = items.take(recentLimit).toList();
    }
    return items;
  }

  static bool hasMoreHistory({
    required List<StudioVersion> versions,
    String? channel,
    int? year,
    int recentLimit = defaultRecentLimit,
  }) {
    if (year != null) return false;
    final feat = featured(versions, channel: channel, year: year);
    final count = filtered(versions, channel: channel, year: year)
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
