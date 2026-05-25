class AndroidStudioInstall {
  const AndroidStudioInstall({
    required this.path,
    required this.executable,
    required this.name,
    required this.version,
    required this.build,
    required this.channel,
    required this.source,
    this.installed = true,
  });

  final String path;
  final String executable;
  final String name;
  final String version;
  final String build;
  final String channel;
  final String source;
  final bool installed;

  factory AndroidStudioInstall.fromJson(Map<String, dynamic> json) {
    return AndroidStudioInstall(
      path: json['path'] as String? ?? '',
      executable: json['executable'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      build: json['build'] as String? ?? '',
      channel: json['channel'] as String? ?? '',
      source: json['source'] as String? ?? '',
      installed: json['installed'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'executable': executable,
      'name': name,
      'version': version,
      'build': build,
      'channel': channel,
      'source': source,
      'installed': installed,
    };
  }

  bool get isValid =>
      path.isNotEmpty &&
      (executable.isNotEmpty || name.isNotEmpty || version.isNotEmpty);
}

enum AndroidStudioSelectionReason {
  runningProcess,
  highestVersion,
  onlyCandidate,
}

class AndroidStudioDetectionResult {
  const AndroidStudioDetectionResult({
    required this.installs,
    this.selected,
    this.selectionReason,
  });

  final List<AndroidStudioInstall> installs;
  final AndroidStudioInstall? selected;
  final AndroidStudioSelectionReason? selectionReason;

  bool get hasInstalls => installs.isNotEmpty;
}
