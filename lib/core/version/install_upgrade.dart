import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';
import 'package:androidstudiowinhelper/core/models/studio_version.dart';
import 'package:androidstudiowinhelper/core/version/url_guesser.dart';
import 'package:androidstudiowinhelper/core/version/version_catalog.dart';

enum UpgradeVerdict {
  notInstalled,
  waitingCatalog,
  unknown,
  updateAvailable,
  upToDate,
  newerThanCatalog,
}

class InstallUpgradeReport {
  const InstallUpgradeReport({
    required this.verdict,
    this.install,
    this.latest,
    this.installedLabel = '',
  });

  final UpgradeVerdict verdict;
  final AndroidStudioInstall? install;
  final StudioVersion? latest;
  final String installedLabel;
}

/// 本机安装 vs 官方归档：按安装自己的渠道，对比该渠道最新可下载包。
class InstallUpgrade {
  static String catalogChannel(String installChannel) {
    final c = installChannel.toLowerCase();
    if (c.contains('canary') || c.contains('preview') || c == 'eap') {
      return 'eap';
    }
    if (c.contains('beta') || c == 'rc') return 'beta';
    if (c.contains('dev') || c.contains('nightly') || c == 'milestone') {
      return 'milestone';
    }
    return 'release';
  }

  static String displayLabel(AndroidStudioInstall install) {
    final decoded = calendarVersionOf(install);
    final suffix = install.versionSuffix.trim();
    final base = decoded ??
        (install.version.trim().isNotEmpty ? install.version.trim() : install.build);
    if (suffix.isEmpty) return base;
    if (base.toLowerCase().contains(suffix.toLowerCase())) return base;
    return '$base $suffix';
  }

  /// product-info 的 version，或 AI-241.18034.62.2412.x → 2024.1.2
  static String? calendarVersionOf(AndroidStudioInstall install) {
    return _core(install.version) ?? _core(install.build);
  }

  static InstallUpgradeReport evaluate({
    required AndroidStudioInstall? install,
    required List<StudioVersion> catalog,
  }) {
    if (install == null) {
      return const InstallUpgradeReport(verdict: UpgradeVerdict.notInstalled);
    }
    final label = displayLabel(install);
    if (catalog.isEmpty) {
      return InstallUpgradeReport(
        verdict: UpgradeVerdict.waitingCatalog,
        install: install,
        installedLabel: label,
      );
    }

    final channel = catalogChannel(install.channel);
    final latest = VersionCatalog.featured(catalog, channel: channel);
    final installedMark = _mark(
      version: install.version,
      extra: '${install.versionSuffix} ${install.channel}',
      fallback: install.build,
    );
    if (latest == null || installedMark == null) {
      return InstallUpgradeReport(
        verdict: UpgradeVerdict.unknown,
        install: install,
        latest: latest,
        installedLabel: label,
      );
    }

    final latestMark = _mark(
      version: latest.downloadVersion.isNotEmpty
          ? latest.downloadVersion
          : latest.version,
      extra: '${latest.version} ${latest.channelLabel}',
    );
    if (latestMark == null) {
      return InstallUpgradeReport(
        verdict: UpgradeVerdict.unknown,
        install: install,
        latest: latest,
        installedLabel: label,
      );
    }

    final byCore = VersionCatalog.compareDownloadVersion(
      latestMark.core,
      installedMark.core,
    );
    final cmp = byCore != 0
        ? byCore
        : latestMark.series.compareTo(installedMark.series);

    final verdict = cmp > 0
        ? UpgradeVerdict.updateAvailable
        : cmp == 0
        ? UpgradeVerdict.upToDate
        : UpgradeVerdict.newerThanCatalog;
    return InstallUpgradeReport(
      verdict: verdict,
      install: install,
      latest: latest,
      installedLabel: label,
    );
  }

  static ({String core, int series})? _mark({
    required String version,
    required String extra,
    String fallback = '',
  }) {
    final core = _core(version) ?? _core(fallback);
    if (core == null) return null;
    return (core: core, series: _seriesRank('$version $extra'));
  }

  static String? _core(String version) {
    if (version.trim().isEmpty) return null;
    final calendar = RegExp(r'(20\d{2}\.\d+(?:\.\d+)?)').firstMatch(version);
    if (calendar != null) return calendar.group(1);
    final fromBuild = UrlGuesser.decodeBuildBase3(version);
    if (fromBuild != null) return fromBuild;
    final legacy = RegExp(r'\b([1-4]\.\d+(?:\.\d+)?)\b').firstMatch(version);
    return legacy?.group(1);
  }

  static int _seriesRank(String text) {
    final canary = RegExp(
      r'canary\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (canary != null) return 2000 + int.parse(canary.group(1)!);
    final preview = RegExp(
      r'preview\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (preview != null) return 2000 + int.parse(preview.group(1)!);
    final rc = RegExp(r'\brc\s*(\d+)', caseSensitive: false).firstMatch(text);
    if (rc != null) return 1500 + int.parse(rc.group(1)!);
    final beta = RegExp(r'beta\s*(\d+)', caseSensitive: false).firstMatch(text);
    if (beta != null) return 1400 + int.parse(beta.group(1)!);
    final patch = RegExp(
      r'patch\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (patch != null) return 100 + int.parse(patch.group(1)!);
    return 100;
  }
}
