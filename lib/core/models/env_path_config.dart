class EnvPathItem {
  const EnvPathItem({
    required this.variable,
    required this.label,
    required this.currentValue,
    required this.source,
    required this.exists,
    this.sizeBytes = 0,
    this.sizeHuman = '',
    this.suggestedDefault = '',
    this.isCore = false,
    this.deprecated = false,
    this.deprecationHint = '',
  });

  final String variable;
  final String label;
  final String currentValue;
  final String source; // 'Machine', 'User', 'Process', 'Default', 'NotSet'
  final bool exists;
  final int sizeBytes;
  final String sizeHuman;
  final String suggestedDefault;

  /// 与安装向导口径一致的推荐变量（AS_INSTALL_HOME / ANDROID_HOME /
  /// ANDROID_USER_HOME / GRADLE_USER_HOME 等）。
  final bool isCore;

  /// 已废弃变量：只在系统里实际存在时才会返回，界面上只提供「清除」。
  final bool deprecated;
  final String deprecationHint;

  factory EnvPathItem.fromJson(Map<String, dynamic> json) {
    return EnvPathItem(
      variable: json['variable'] as String? ?? '',
      label: json['label'] as String? ?? '',
      currentValue: json['currentValue'] as String? ?? '',
      source: json['source'] as String? ?? 'NotSet',
      exists: json['exists'] as bool? ?? false,
      sizeBytes: _readInt(json['sizeBytes']),
      sizeHuman: json['sizeHuman'] as String? ?? '',
      suggestedDefault: json['suggestedDefault'] as String? ?? '',
      isCore: json['isCore'] as bool? ?? false,
      deprecated: json['deprecated'] as bool? ?? false,
      deprecationHint: json['deprecationHint'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'variable': variable,
    'label': label,
    'currentValue': currentValue,
    'source': source,
    'exists': exists,
    'sizeBytes': sizeBytes,
    'sizeHuman': sizeHuman,
    'suggestedDefault': suggestedDefault,
    'isCore': isCore,
    'deprecated': deprecated,
    'deprecationHint': deprecationHint,
  };
}

class EnvPathEntry {
  const EnvPathEntry({
    required this.subDir,
    required this.fullPath,
    required this.inPath,
    required this.exists,
  });

  final String subDir;
  final String fullPath;
  final bool inPath;
  final bool exists;

  factory EnvPathEntry.fromJson(Map<String, dynamic> json) {
    return EnvPathEntry(
      subDir: json['subDir'] as String? ?? '',
      fullPath: json['fullPath'] as String? ?? '',
      inPath: json['inPath'] as bool? ?? false,
      exists: json['exists'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'subDir': subDir,
    'fullPath': fullPath,
    'inPath': inPath,
    'exists': exists,
  };
}

class EnvPathConfigResult {
  const EnvPathConfigResult({required this.items, required this.pathEntries});

  final List<EnvPathItem> items;
  final List<EnvPathEntry> pathEntries;

  factory EnvPathConfigResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawPathEntries = json['pathEntries'];
    return EnvPathConfigResult(
      items: rawItems is List
          ? rawItems
                .whereType<Map<String, dynamic>>()
                .map(EnvPathItem.fromJson)
                .toList()
          : const [],
      pathEntries: rawPathEntries is List
          ? rawPathEntries
                .whereType<Map<String, dynamic>>()
                .map(EnvPathEntry.fromJson)
                .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
    'items': items.map((e) => e.toJson()).toList(),
    'pathEntries': pathEntries.map((e) => e.toJson()).toList(),
  };
}

class EnvPathWriteResult {
  const EnvPathWriteResult({
    required this.success,
    required this.variable,
    required this.value,
    this.error = '',
  });

  final bool success;
  final String variable;
  final String value;
  final String error;

  factory EnvPathWriteResult.fromJson(Map<String, dynamic> json) {
    return EnvPathWriteResult(
      success: json['success'] as bool? ?? false,
      variable: json['variable'] as String? ?? '',
      value: json['value'] as String? ?? '',
      error: json['error'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'success': success,
    'variable': variable,
    'value': value,
    'error': error,
  };
}

class EnvPathBatchWriteResult {
  const EnvPathBatchWriteResult({
    required this.success,
    this.error = '',
    this.items = const [],
  });

  final bool success;
  final String error;
  final List<EnvPathWriteResult> items;

  factory EnvPathBatchWriteResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final parsed = <EnvPathWriteResult>[];
    if (rawItems is List) {
      for (final e in rawItems) {
        if (e is Map) {
          parsed.add(EnvPathWriteResult.fromJson(Map<String, dynamic>.from(e)));
        }
      }
    } else if (rawItems is Map) {
      parsed.add(
        EnvPathWriteResult.fromJson(Map<String, dynamic>.from(rawItems)),
      );
    }
    return EnvPathBatchWriteResult(
      success: json['success'] as bool? ?? false,
      error: json['error'] as String? ?? '',
      items: parsed,
    );
  }
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}
