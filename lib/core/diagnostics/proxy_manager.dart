import 'dart:convert';
import 'dart:io';

class ProxyScheme {
  final String name;
  final String? httpProxy;
  final String? httpsProxy;
  final String? noProxy;
  final Map<String, String> gradleProperties;

  const ProxyScheme({
    required this.name,
    this.httpProxy,
    this.httpsProxy,
    this.noProxy,
    this.gradleProperties = const {},
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'httpProxy': httpProxy,
        'httpsProxy': httpsProxy,
        'noProxy': noProxy,
        'gradleProperties': gradleProperties,
      };

  factory ProxyScheme.fromJson(Map<String, dynamic> json) => ProxyScheme(
        name: json['name'] as String,
        httpProxy: json['httpProxy'] as String?,
        httpsProxy: json['httpsProxy'] as String?,
        noProxy: json['noProxy'] as String?,
        gradleProperties:
            Map<String, String>.from(json['gradleProperties'] as Map? ?? {}),
      );

  static const direct = ProxyScheme(name: '直连（无代理）');
}

class ProxyManager {
  final String _configPath;

  ProxyManager({String? configDir})
      : _configPath =
            '${configDir ?? _defaultConfigDir()}\\proxy_schemes.json';

  List<ProxyScheme> _schemes = [];
  String _activeSchemeName = '直连（无代理）';

  List<ProxyScheme> get schemes => List.unmodifiable(_schemes);
  String get activeSchemeName => _activeSchemeName;
  ProxyScheme get activeScheme => _schemes.firstWhere(
        (s) => s.name == _activeSchemeName,
        orElse: () => ProxyScheme.direct,
      );

  Future<void> load() async {
    try {
      final file = File(_configPath);
      if (!file.existsSync()) {
        _schemes = [ProxyScheme.direct];
        return;
      }
      final json =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      _schemes = (json['schemes'] as List)
          .map((e) => ProxyScheme.fromJson(e as Map<String, dynamic>))
          .toList();
      _activeSchemeName = json['active'] as String? ?? '直连（无代理）';
      if (!_schemes.any((s) => s.name == '直连（无代理）')) {
        _schemes.insert(0, ProxyScheme.direct);
      }
    } catch (_) {
      _schemes = [ProxyScheme.direct];
    }
  }

  Future<void> save() async {
    final dir = Directory(_configPath).parent;
    if (!dir.existsSync()) await dir.create(recursive: true);
    final json = {
      'schemes': _schemes.map((s) => s.toJson()).toList(),
      'active': _activeSchemeName,
    };
    File(_configPath)
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  }

  void addScheme(ProxyScheme scheme) {
    _schemes.removeWhere((s) => s.name == scheme.name);
    _schemes.add(scheme);
  }

  void removeScheme(String name) {
    if (name == '直连（无代理）') return;
    _schemes.removeWhere((s) => s.name == name);
    if (_activeSchemeName == name) _activeSchemeName = '直连（无代理）';
  }

  void setActive(String name) {
    if (_schemes.any((s) => s.name == name)) _activeSchemeName = name;
  }

  Future<void> applyToGradle() async {
    final scheme = activeScheme;
    final gradleHome = _getGradleHome();
    final propsFile = File('$gradleHome/gradle.properties');
    var lines = <String>[];
    if (propsFile.existsSync()) lines = propsFile.readAsLinesSync();
    lines.removeWhere((l) =>
        l.startsWith('systemProp.http.') ||
        l.startsWith('systemProp.https.'));
    final startIdx = lines.indexOf('# ASWH Proxy Start');
    final endIdx = lines.indexOf('# ASWH Proxy End');
    if (startIdx != -1 && endIdx != -1) {
      lines.removeRange(startIdx, endIdx + 1);
    }
    if (scheme.httpProxy != null || scheme.httpsProxy != null) {
      lines.add('# ASWH Proxy Start');
      if (scheme.httpProxy != null) {
        lines.add(
            'systemProp.http.proxyHost=${scheme.httpProxy!.split(':').first}');
        if (scheme.httpProxy!.contains(':')) {
          lines.add(
              'systemProp.http.proxyPort=${scheme.httpProxy!.split(':').last}');
        }
      }
      if (scheme.httpsProxy != null) {
        lines.add(
            'systemProp.https.proxyHost=${scheme.httpsProxy!.split(':').first}');
        if (scheme.httpsProxy!.contains(':')) {
          lines.add(
              'systemProp.https.proxyPort=${scheme.httpsProxy!.split(':').last}');
        }
      }
      if (scheme.noProxy != null) {
        lines.add('systemProp.http.nonProxyHosts=${scheme.noProxy}');
      }
      for (final entry in scheme.gradleProperties.entries) {
        lines.add('${entry.key}=${entry.value}');
      }
      lines.add('# ASWH Proxy End');
    }
    await Directory(gradleHome).create(recursive: true);
    await propsFile.writeAsString(lines.join('\n'));
  }

  String _getGradleHome() {
    final envHome = Platform.environment['GRADLE_USER_HOME'];
    if (envHome != null && envHome.isNotEmpty) return envHome;
    return '${Platform.environment['USERPROFILE']}/.gradle';
  }

  static String _defaultConfigDir() {
    return '${Platform.environment['LOCALAPPDATA']}\\AndroidStudioWinHelper';
  }
}
