class AndroidStudioInstall {
  const AndroidStudioInstall({
    required this.path,
    required this.executable,
    required this.name,
    required this.version,
    required this.build,
    required this.channel,
    required this.source,
    this.dataDirectoryName = '',
    this.productVendor = '',
    this.productCode = '',
    this.launcherPath = '',
    this.sdkPath = '',
    this.installSdk = '',
    this.installHaxm = '',
    this.userSettingsPath = '',
  });

  final String path;
  final String executable;
  final String name;
  final String version;
  final String build;
  final String channel;
  final String source;

  /// product-info.json → dataDirectoryName (运行时配置目录名)
  final String dataDirectoryName;

  /// product-info.json → productVendor (如 "Google")
  final String productVendor;

  /// product-info.json → productCode (如 "AI")
  final String productCode;

  /// product-info.json → launch[0].launcherPath (如 "bin/studio64.exe")
  final String launcherPath;

  /// HKLM\SOFTWARE\Android Studio → SdkPath (NSIS 安装器写入)
  final String sdkPath;

  /// HKLM\SOFTWARE\Android Studio → InstallSdk ("0" 或 "1")
  final String installSdk;

  /// HKLM\SOFTWARE\Android Studio → InstallHaxm ("0" 或 "1")
  final String installHaxm;

  /// HKLM\SOFTWARE\Android Studio → UserSettingsPath (如 %USERPROFILE%\.android)
  final String userSettingsPath;

  factory AndroidStudioInstall.fromJson(Map<String, dynamic> json) {
    return AndroidStudioInstall(
      path: json['path'] as String? ?? '',
      executable: json['executable'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as String? ?? '',
      build: json['build'] as String? ?? '',
      channel: json['channel'] as String? ?? '',
      source: json['source'] as String? ?? '',
      dataDirectoryName: json['dataDirectoryName'] as String? ?? '',
      productVendor: json['productVendor'] as String? ?? '',
      productCode: json['productCode'] as String? ?? '',
      launcherPath: json['launcherPath'] as String? ?? '',
      sdkPath: json['sdkPath'] as String? ?? '',
      installSdk: json['installSdk'] as String? ?? '',
      installHaxm: json['installHaxm'] as String? ?? '',
      userSettingsPath: json['userSettingsPath'] as String? ?? '',
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
      'dataDirectoryName': dataDirectoryName,
      'productVendor': productVendor,
      'productCode': productCode,
      'launcherPath': launcherPath,
      'sdkPath': sdkPath,
      'installSdk': installSdk,
      'installHaxm': installHaxm,
      'userSettingsPath': userSettingsPath,
    };
  }

  bool get isValid =>
      path.isNotEmpty &&
      (executable.isNotEmpty || name.isNotEmpty || version.isNotEmpty);
}

/// 强卸/卸不干净后的残留（首期：卸载注册表幽灵项）
class AndroidStudioResidue {
  const AndroidStudioResidue({
    required this.kind,
    required this.name,
    required this.path,
    required this.registryKey,
    required this.version,
    required this.reason,
    required this.source,
  });

  final String kind;
  final String name;
  final String path;
  final String registryKey;
  final String version;
  final String reason;
  final String source;

  String get kindLabel => switch (kind) {
        'orphanConfig' => '配置残留',
        'registry' => '注册表残留',
        _ => '卸载残留',
      };

  factory AndroidStudioResidue.fromJson(Map<String, dynamic> json) {
    return AndroidStudioResidue(
      kind: json['kind'] as String? ?? 'registry',
      name: json['name'] as String? ?? 'Android Studio',
      path: json['path'] as String? ?? '',
      registryKey: json['registryKey'] as String? ?? '',
      version: json['version'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      source: json['source'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'name': name,
        'path': path,
        'registryKey': registryKey,
        'version': version,
        'reason': reason,
        'source': source,
      };
}

enum AndroidStudioSelectionReason {
  runningProcess,
  highestVersion,
  onlyCandidate;

  String get label => switch (this) {
        runningProcess => '当前正在运行',
        highestVersion => '版本最高',
        onlyCandidate => '唯一候选',
      };
}

class AndroidStudioDetectionResult {
  const AndroidStudioDetectionResult({
    required this.installs,
    this.residues = const [],
    this.selected,
    this.selectionReason,
  });

  final List<AndroidStudioInstall> installs;
  final List<AndroidStudioResidue> residues;
  final AndroidStudioInstall? selected;
  final AndroidStudioSelectionReason? selectionReason;

  bool get hasInstalls => installs.isNotEmpty;
  bool get hasResidues => residues.isNotEmpty;

  factory AndroidStudioDetectionResult.fromJson(Map<String, dynamic> json) {
    final rawInstalls = json['installs'];
    final rawResidues = json['residues'];
    final rawSelected = json['selected'];
    final installs = rawInstalls is List
        ? rawInstalls
            .whereType<Map<String, dynamic>>()
            .map(AndroidStudioInstall.fromJson)
            .where((item) => item.isValid)
            .toList()
        : const <AndroidStudioInstall>[];

    AndroidStudioInstall? selected;
    if (rawSelected is Map<String, dynamic>) {
      final parsed = AndroidStudioInstall.fromJson(rawSelected);
      if (parsed.isValid) {
        selected = installs.where((item) => item.path == parsed.path).firstOrNull ??
            parsed;
      }
    }

    final selectionReason = selected == null
        ? null
        : json['selectionReason'] is String
            ? AndroidStudioSelectionReason.values
                .where((e) => e.name == json['selectionReason'])
                .firstOrNull
            : null;

    return AndroidStudioDetectionResult(
      installs: installs,
      residues: rawResidues is List
          ? rawResidues
              .whereType<Map<String, dynamic>>()
              .map(AndroidStudioResidue.fromJson)
              .toList()
          : const [],
      selected: selected,
      selectionReason: selectionReason,
    );
  }

  Map<String, dynamic> toJson() => {
        'installs': installs.map((e) => e.toJson()).toList(),
        'residues': residues.map((e) => e.toJson()).toList(),
        if (selected != null) 'selected': selected!.toJson(),
        if (selectionReason != null) 'selectionReason': selectionReason!.name,
      };
}
