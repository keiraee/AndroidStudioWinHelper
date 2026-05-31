class HypervFeature {
  const HypervFeature({
    required this.name,
    required this.state,
  });

  final String name;
  final String state; // 'Enabled', 'Disabled', 'NotPresent'

  /// Chinese label for the feature name
  String get label => _labelMap[name] ?? name;

  static const _labelMap = {
    'Microsoft-Hyper-V-All': 'Hyper-V 平台',
    'Microsoft-Hyper-V-Hypervisor': 'Hyper-V 管理程序',
    'Microsoft-Hyper-V-Services': 'Hyper-V 服务',
    'VirtualMachinePlatform': '虚拟机平台',
    'HypervisorPlatform': 'Hypervisor 平台',
  };

  factory HypervFeature.fromJson(Map<String, dynamic> json) {
    return HypervFeature(
      name: json['name'] as String? ?? '',
      state: json['state'] as String? ?? 'NotPresent',
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'state': state,
      };
}

class HypervResult {
  const HypervResult({
    required this.osEdition,
    required this.isHomeEdition,
    required this.features,
    required this.overallStatus,
  });

  final String osEdition;
  final bool isHomeEdition;
  final List<HypervFeature> features;
  final String overallStatus; // 'NotPresent', 'PartiallyEnabled', 'FullyEnabled'

  factory HypervResult.fromJson(Map<String, dynamic> json) {
    final rawFeatures = json['features'];
    return HypervResult(
      osEdition: json['osEdition'] as String? ?? 'Unknown',
      isHomeEdition: json['isHomeEdition'] as bool? ?? false,
      features: rawFeatures is List
          ? rawFeatures
              .whereType<Map<String, dynamic>>()
              .map(HypervFeature.fromJson)
              .toList()
          : const [],
      overallStatus: json['overallStatus'] as String? ?? 'NotPresent',
    );
  }

  Map<String, dynamic> toJson() => {
        'osEdition': osEdition,
        'isHomeEdition': isHomeEdition,
        'features': features.map((e) => e.toJson()).toList(),
        'overallStatus': overallStatus,
      };
}

class HypervToggleResult {
  const HypervToggleResult({
    required this.success,
    required this.message,
    this.details = '',
    this.action = '',
    this.debug = '',
  });

  final bool success;
  final String message;
  final String details;
  final String action;
  final String debug;

  factory HypervToggleResult.fromJson(Map<String, dynamic> json) {
    return HypervToggleResult(
      success: json['success'] as bool? ?? false,
      message: json['message'] as String? ?? '',
      details: json['details'] as String? ?? '',
      action: json['action'] as String? ?? '',
      debug: json['debug'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'success': success,
        'message': message,
        'details': details,
        'action': action,
        'debug': debug,
      };
}
