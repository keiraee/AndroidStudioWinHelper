import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/powershell_runner.dart';
import 'package:androidstudiowinhelper/core/script_resolver_flutter.dart';

typedef SdkProgressCallback = void Function(int percent, String message);

class SdkSetupManager {
  SdkSetupManager({PowerShellRunner? runner})
      : _runner = runner ?? PowerShellRunner(logTag: 'SdkSetup');

  final PowerShellRunner _runner;

  static void _log(String msg) {
    LogManager.instance.write('SdkSetup', msg);
  }

  /// 查询已安装和可用的包
  Future<SdkPackageInfo> listPackages({
    String? sdkDir,
    String? proxy,
    String mirror = 'flutter',
  }) async {
    _log('===== 查询 SDK 包列表 =====');

    final scriptPath = await resolveSetupSdkScript();
    final sdkDirArg = sdkDir ?? _detectSdkDir();

    final args = [
      '-SdkDir', sdkDirArg,
      '-Mirror', mirror,
      '-Action', 'list-installed',
      if (proxy != null && proxy.isNotEmpty) ...['-Proxy', proxy],
      '-Json',
    ];

    final result = await _runner.run(
      scriptPath: scriptPath,
      extraArgs: args,
    );

    if (result.jsonResult != null) {
      return SdkPackageInfo.fromJson(result.jsonResult!);
    }

    // 回退：检查结果文件
    final resultFile = _findResultFile(result.stdout);
    if (resultFile != null && File(resultFile).existsSync()) {
      final json = jsonDecode(File(resultFile).readAsStringSync()) as Map<String, dynamic>;
      try { File(resultFile).deleteSync(); } catch (_) {}
      return SdkPackageInfo.fromJson(json);
    }

    throw StateError('查询失败: ${result.stderr}');
  }

  /// 安装指定包
  Future<SdkActionResult> install({
    String? sdkDir,
    String? proxy,
    String mirror = 'flutter',
    required List<String> packages,
    SdkProgressCallback? onProgress,
  }) async {
    return _runAction(
      action: 'install',
      packages: packages,
      sdkDir: sdkDir,
      proxy: proxy,
      mirror: mirror,
      onProgress: onProgress,
    );
  }

  /// 卸载指定包
  Future<SdkActionResult> uninstall({
    String? sdkDir,
    String? proxy,
    String mirror = 'flutter',
    required List<String> packages,
    SdkProgressCallback? onProgress,
  }) async {
    return _runAction(
      action: 'uninstall',
      packages: packages,
      sdkDir: sdkDir,
      proxy: proxy,
      mirror: mirror,
      onProgress: onProgress,
    );
  }

  /// 接受所有协议
  Future<SdkActionResult> acceptLicenses({
    String? sdkDir,
    String? proxy,
    String mirror = 'flutter',
  }) async {
    return _runAction(
      action: 'accept-licenses',
      packages: [],
      sdkDir: sdkDir,
      proxy: proxy,
      mirror: mirror,
    );
  }

  Future<SdkActionResult> _runAction({
    required String action,
    required List<String> packages,
    String? sdkDir,
    String? proxy,
    String mirror = 'flutter',
    SdkProgressCallback? onProgress,
  }) async {
    // 包 ID 本身含 ';'（如 platforms;android-36），列表分隔用 '|' 避免拆坏
    _log('===== SDK $action: ${packages.join("|")} =====');

    final scriptPath = await resolveSetupSdkScript();
    final sdkDirArg = sdkDir ?? _detectSdkDir();
    final resultFile =
        '${Directory.systemTemp.path}\\aswh_sdk_${action}_${DateTime.now().millisecondsSinceEpoch}.json';

    final args = [
      '-SdkDir', sdkDirArg,
      '-ResultFile', resultFile,
      '-Mirror', mirror,
      '-Action', action,
      if (packages.isNotEmpty) ...['-Packages', packages.join('|')],
      if (proxy != null && proxy.isNotEmpty) ...['-Proxy', proxy],
      '-Json',
    ];

    final result = await _runner.run(
      scriptPath: scriptPath,
      extraArgs: args,
      onProgress: onProgress != null
          ? (progress) => onProgress(progress.percent, progress.message)
          : null,
    );

    if (result.stdout.isNotEmpty) {
      _log('stdout 尾部: ${result.stdout.length > 500 ? result.stdout.substring(result.stdout.length - 500) : result.stdout}');
    }

    // 检查结果文件
    if (File(resultFile).existsSync()) {
      final json = jsonDecode(File(resultFile).readAsStringSync()) as Map<String, dynamic>;
      try { File(resultFile).deleteSync(); } catch (_) {}
      return SdkActionResult.fromJson(json);
    }

    if (result.jsonResult != null) {
      return SdkActionResult.fromJson(result.jsonResult!);
    }

    if (!result.success) {
      throw StateError('$action 失败 (exitCode: ${result.exitCode}): ${result.stderr}');
    }

    return SdkActionResult(success: true, message: '$action 完成', log: '');
  }

  /// 从 stdout 中提取结果文件路径
  String? _findResultFile(String stdout) {
    final match = RegExp(r'ResultFile:\s*(.+)').firstMatch(stdout);
    return match?.group(1)?.trim();
  }

  /// 自动检测 SDK 路径
  static String detectSdkDir() => _detectSdkDir();

  static String _detectSdkDir() {
    for (final envName in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final val = Platform.environment[envName];
      LogManager.instance.write('SdkSetup', '$envName = $val');
      if (val != null && val.isNotEmpty && Directory(val).existsSync()) {
        return val;
      }
    }
    for (final p in ['D:\\Android\\Sdk', 'C:\\Android\\Sdk']) {
      if (Directory(p).existsSync()) return p;
    }
    // 兜底 PowerShell 读注册表
    try {
      final r = Process.runSync('powershell.exe', [
        '-NoProfile', '-Command',
        '[Environment]::GetEnvironmentVariable("ANDROID_HOME","Machine")'
      ]);
      final v = (r.stdout as String).trim();
      if (v.isNotEmpty && Directory(v).existsSync()) return v;
    } catch (_) {}
    return '${Platform.environment['LOCALAPPDATA']}\\Android\\Sdk';
  }

  /// 快速检测状态（不跑 PowerShell）
  static SdkStatus quickStatus() {
    final sdkDir = detectSdkDir();
    return SdkStatus(
      sdkDir: sdkDir,
      components: {
        'platform-tools': File('$sdkDir\\platform-tools\\adb.exe').existsSync(),
        'emulator': File('$sdkDir\\emulator\\emulator.exe').existsSync(),
        'build-tools': Directory('$sdkDir\\build-tools').existsSync(),
        'cmdline-tools': File('$sdkDir\\cmdline-tools\\latest\\bin\\sdkmanager.bat').existsSync(),
        'platforms': Directory('$sdkDir\\platforms').existsSync(),
        'aehd-driver': _checkAehdDriver(),
      },
      hasJava: _detectJava(),
    );
  }

  static bool _checkAehdDriver() {
    try {
      final r = Process.runSync('sc', ['query', 'aehd']);
      return (r.stdout as String).contains('RUNNING') || (r.stdout as String).contains('STOPPED');
    } catch (_) {}
    return false;
  }

  static bool _detectJava() {
    try {
      final r = Process.runSync('java', ['-version']);
      if (r.exitCode == 0) return true;
    } catch (_) {}
    for (final c in [
      '${Platform.environment['ProgramFiles']}\\Android\\Android Studio\\jbr\\bin\\java.exe',
      '${Platform.environment['LOCALAPPDATA']}\\Android\\Android Studio\\jbr\\bin\\java.exe',
    ]) {
      if (File(c).existsSync()) return true;
    }
    return false;
  }
}

class InstalledPackage {
  final String path;
  final String version;
  final String description;
  final String location;

  const InstalledPackage({
    required this.path,
    required this.version,
    required this.description,
    this.location = '',
  });

  factory InstalledPackage.fromJson(Map<String, dynamic> json) {
    return InstalledPackage(
      path: json['path'] ?? '',
      version: json['version'] ?? '',
      description: json['description'] ?? '',
      location: json['location'] ?? '',
    );
  }

  /// 兼容旧格式（纯字符串）
  factory InstalledPackage.fromString(String s) {
    return InstalledPackage(path: s, version: '', description: '', location: '');
  }

  /// 显示名称：优先用 description，其次用 path
  String get displayTitle {
    if (description.isNotEmpty) return description;
    return path;
  }
}

class SdkPackageInfo {
  final bool success;
  final String sdkDir;
  final bool hasJava;
  final List<InstalledPackage> installed;
  final List<String> available;

  SdkPackageInfo({
    required this.success,
    required this.sdkDir,
    required this.hasJava,
    required this.installed,
    required this.available,
  });

  factory SdkPackageInfo.fromJson(Map<String, dynamic> json) {
    final installedRaw = json['installed'] as List? ?? [];
    final installed = installedRaw.map((e) {
      if (e is Map<String, dynamic>) {
        return InstalledPackage.fromJson(e);
      }
      return InstalledPackage.fromString('$e');
    }).toList();

    return SdkPackageInfo(
      success: json['success'] == true,
      sdkDir: json['sdkDir'] ?? '',
      hasJava: json['hasJava'] == true,
      installed: installed,
      available: (json['available'] as List?)?.map((e) => '$e').toList() ?? [],
    );
  }
}

class SdkActionResult {
  final bool success;
  final String message;
  final String log;

  SdkActionResult({required this.success, required this.message, required this.log});

  factory SdkActionResult.fromJson(Map<String, dynamic> json) {
    return SdkActionResult(
      success: json['success'] == true,
      message: json['message'] ?? '',
      log: json['installLog'] ?? json['uninstallLog'] ?? json['output'] ?? '',
    );
  }
}

class SdkStatus {
  final String sdkDir;
  final Map<String, bool> components;
  final bool hasJava;

  SdkStatus({required this.sdkDir, required this.components, required this.hasJava});

  bool get allReady => components.values.every((v) => v) && hasJava;
}
