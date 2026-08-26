class EmulatorCheck {
  const EmulatorCheck({
    required this.name,
    required this.category,
    required this.label,
    required this.status,
    required this.detail,
    this.suggestion = '',
  });

  final String name;
  final String category;
  final String label;
  final String status; // 'ok', 'warning', 'error', 'info', 'unknown'
  final String detail;
  final String suggestion;

  factory EmulatorCheck.fromJson(Map<String, dynamic> json) {
    return EmulatorCheck(
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '',
      label: json['label'] as String? ?? '',
      status: json['status'] as String? ?? 'unknown',
      detail: json['detail'] as String? ?? '',
      suggestion: json['suggestion'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'label': label,
        'status': status,
        'detail': detail,
        'suggestion': suggestion,
      };
}

class EmulatorCheckResult {
  const EmulatorCheckResult({
    required this.checks,
  });

  final List<EmulatorCheck> checks;

  factory EmulatorCheckResult.fromJson(Map<String, dynamic> json) {
    final rawChecks = json['checks'];
    return EmulatorCheckResult(
      checks: rawChecks is List
          ? rawChecks
              .whereType<Map<String, dynamic>>()
              .map(EmulatorCheck.fromJson)
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'checks': checks.map((e) => e.toJson()).toList(),
      };

  int get warningCount =>
      checks.where((c) => c.status == 'warning' || c.status == 'error').length;

  /// Returns checks grouped by category, preserving insertion order.
  List<MapEntry<String, List<EmulatorCheck>>> get groupedByCategory {
    final map = <String, List<EmulatorCheck>>{};
    for (final check in checks) {
      final cat = check.category.isEmpty ? '其他' : check.category;
      map.putIfAbsent(cat, () => []).add(check);
    }
    return map.entries.toList();
  }
}
