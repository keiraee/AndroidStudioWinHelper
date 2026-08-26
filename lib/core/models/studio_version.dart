class StudioVersion {
  const StudioVersion({
    required this.version,
    required this.codename,
    required this.buildNumber,
    required this.channel,
    required this.channelLabel,
    required this.releaseNotes,
    required this.downloadUrl,
    required this.downloadVersion,
    this.sha256 = '',
    this.isHistorical = false,
  });

  final String version;
  final String codename;
  final String buildNumber;
  final String channel;
  final String channelLabel;
  final String releaseNotes;
  final String downloadUrl;
  final String downloadVersion;
  final String sha256;
  final bool isHistorical;

  factory StudioVersion.fromJson(Map<String, dynamic> json) {
    return StudioVersion(
      version: json['version'] as String? ?? '',
      codename: json['codename'] as String? ?? '',
      buildNumber: json['buildNumber'] as String? ?? '',
      channel: json['channel'] as String? ?? '',
      channelLabel: json['channelLabel'] as String? ?? '',
      releaseNotes: json['releaseNotes'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String? ?? '',
      downloadVersion: json['downloadVersion'] as String? ?? '',
      sha256: json['sha256'] as String? ?? '',
      isHistorical: json['isHistorical'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'codename': codename,
        'buildNumber': buildNumber,
        'channel': channel,
        'channelLabel': channelLabel,
        'releaseNotes': releaseNotes,
        'downloadUrl': downloadUrl,
        'downloadVersion': downloadVersion,
        'sha256': sha256,
        'isHistorical': isHistorical,
      };
}

class FetchVersionsResult {
  const FetchVersionsResult({required this.versions, this.warnings = const []});

  final List<StudioVersion> versions;
  final List<String> warnings;

  bool get hasWarnings => warnings.isNotEmpty;
}
