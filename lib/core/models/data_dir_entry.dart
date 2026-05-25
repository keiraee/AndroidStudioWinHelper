class DataDirSubEntry {
  const DataDirSubEntry({
    required this.name,
    required this.path,
    required this.exists,
    required this.sizeBytes,
    required this.sizeHuman,
  });

  final String name;
  final String path;
  final bool exists;
  final int sizeBytes;
  final String sizeHuman;

  factory DataDirSubEntry.fromJson(Map<String, dynamic> json) {
    return DataDirSubEntry(
      name: json['name'] as String? ?? '',
      path: json['path'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      sizeBytes: _readInt(json['sizeBytes']),
      sizeHuman: json['sizeHuman'] as String? ?? '',
    );
  }
}

class DataDirEntry {
  const DataDirEntry({
    required this.category,
    required this.label,
    required this.path,
    required this.version,
    required this.exists,
    required this.sizeBytes,
    required this.sizeHuman,
    required this.notes,
    required this.subEntries,
    this.isActive = false,
    this.activeSource = '',
  });

  final String category;
  final String label;
  final String path;
  final String version;
  final bool exists;
  final int sizeBytes;
  final String sizeHuman;
  final String notes;
  final List<DataDirSubEntry> subEntries;
  final bool isActive;
  final String activeSource;

  factory DataDirEntry.fromJson(Map<String, dynamic> json) {
    final subs = json['subEntries'];
    return DataDirEntry(
      category: json['category'] as String? ?? '',
      label: json['label'] as String? ?? '',
      path: json['path'] as String? ?? '',
      version: json['version'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      sizeBytes: _readInt(json['sizeBytes']),
      sizeHuman: json['sizeHuman'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      subEntries: subs is List
          ? subs
              .whereType<Map<String, dynamic>>()
              .map(DataDirSubEntry.fromJson)
              .toList()
          : const [],
      isActive: json['isActive'] as bool? ?? false,
      activeSource: json['activeSource'] as String? ?? '',
    );
  }
}

class DataDirScanResult {
  const DataDirScanResult({
    required this.entries,
    required this.totalSizeBytes,
    required this.totalSizeHuman,
    required this.foundCount,
  });

  final List<DataDirEntry> entries;
  final int totalSizeBytes;
  final String totalSizeHuman;
  final int foundCount;

  List<DataDirEntry> get existingEntries =>
      entries.where((entry) => entry.exists).toList();

  List<DataDirEntry> get sortedEntries {
    final sorted = List<DataDirEntry>.from(entries);
    sorted.sort((a, b) {
      if (a.isActive && !b.isActive) return -1;
      if (!a.isActive && b.isActive) return 1;
      return 0;
    });
    return sorted;
  }

  factory DataDirScanResult.fromJson(Map<String, dynamic> json) {
    final rawEntries = json['entries'];
    return DataDirScanResult(
      entries: rawEntries is List
          ? rawEntries
              .whereType<Map<String, dynamic>>()
              .map(DataDirEntry.fromJson)
              .toList()
          : const [],
      totalSizeBytes: _readInt(json['totalSizeBytes']),
      totalSizeHuman: json['totalSizeHuman'] as String? ?? '',
      foundCount: _readInt(json['foundCount']),
    );
  }
}

int _readInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return 0;
}
