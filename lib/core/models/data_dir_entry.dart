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

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'exists': exists,
        'sizeBytes': sizeBytes,
        'sizeHuman': sizeHuman,
      };
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
    this.isOrphan = false,
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
  final bool isOrphan;

  factory DataDirEntry.fromJson(Map<String, dynamic> json) {
    return DataDirEntry(
      category: json['category'] as String? ?? '',
      label: json['label'] as String? ?? '',
      path: json['path'] as String? ?? '',
      version: json['version'] as String? ?? '',
      exists: json['exists'] as bool? ?? false,
      sizeBytes: _readInt(json['sizeBytes']),
      sizeHuman: json['sizeHuman'] as String? ?? '',
      notes: json['notes'] as String? ?? '',
      subEntries: _readObjectList(json['subEntries'])
          .map(DataDirSubEntry.fromJson)
          .toList(),
      isActive: json['isActive'] as bool? ?? false,
      activeSource: json['activeSource'] as String? ?? '',
      isOrphan: json['isOrphan'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'category': category,
        'label': label,
        'path': path,
        'version': version,
        'exists': exists,
        'sizeBytes': sizeBytes,
        'sizeHuman': sizeHuman,
        'notes': notes,
        'subEntries': subEntries.map((e) => e.toJson()).toList(),
        'isActive': isActive,
        'activeSource': activeSource,
        'isOrphan': isOrphan,
      };
}

class DataDirScanResult {
  const DataDirScanResult({
    required this.entries,
    required this.totalSizeBytes,
    required this.totalSizeHuman,
    required this.foundCount,
    this.scannedAt = '',
  });

  final List<DataDirEntry> entries;
  final int totalSizeBytes;
  final String totalSizeHuman;
  final int foundCount;
  final String scannedAt;

  List<DataDirEntry> get existingEntries =>
      entries.where((entry) => entry.exists).toList();

  List<DataDirEntry> get sortedEntries {
    final sorted = List<DataDirEntry>.from(entries);
    sorted.sort((a, b) {
      if (a.isOrphan != b.isOrphan) return a.isOrphan ? 1 : -1;
      if (a.isActive && !b.isActive) return -1;
      if (!a.isActive && b.isActive) return 1;
      return b.sizeBytes.compareTo(a.sizeBytes);
    });
    return sorted;
  }

  factory DataDirScanResult.fromJson(Map<String, dynamic> json) {
    final entries = _readObjectList(json['entries'])
        .map(DataDirEntry.fromJson)
        .toList();
    return DataDirScanResult(
      entries: entries,
      totalSizeBytes: _readInt(json['totalSizeBytes']),
      totalSizeHuman: json['totalSizeHuman'] as String? ?? '',
      foundCount: json.containsKey('foundCount')
          ? _readInt(json['foundCount'])
          : entries.length,
      scannedAt: json['scannedAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'entries': entries.map((e) => e.toJson()).toList(),
        'totalSizeBytes': totalSizeBytes,
        'totalSizeHuman': totalSizeHuman,
        'foundCount': foundCount,
        if (scannedAt.isNotEmpty) 'scannedAt': scannedAt,
      };
}

List<Map<String, dynamic>> _readObjectList(Object? value) {
  if (value is List) {
    return value.whereType<Map<String, dynamic>>().toList();
  }
  if (value is Map<String, dynamic>) {
    return [value];
  }
  return const [];
}

int _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
