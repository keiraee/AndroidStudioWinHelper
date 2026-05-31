import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';
import 'package:androidstudiowinhelper/core/script_resolver_flutter.dart';

typedef SdkProgressCallback = void Function(int percent, String message);

class SdkSetupManager {
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
    final resultFile =
        '${Directory.systemTemp.path}\\aswh_sdk_list_${DateTime.now().millisecondsSinceEpoch}.json';

    final args = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-SdkDir', sdkDirArg,
      '-ResultFile', resultFile,
      '-Mirror', mirror,
      '-Action', 'list-installed',
      if (proxy != null && proxy.isNotEmpty) ...['-Proxy', proxy],
      '-Json',
    ];

    final result = await Process.run('powershell.exe', args,
        stdoutEncoding: utf8, stderrEncoding: utf8);

    if (!File(resultFile).existsSync()) {
      throw StateError('查询失败: ${result.stderr}');
    }

    final json = jsonDecode(File(resultFile).readAsStringSync()) as Map<String, dynamic>;
    File(resultFile).deleteSync();

    return SdkPackageInfo.fromJson(json);
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
    _log('===== SDK $action: ${packages.join(";")} =====');

    final scriptPath = await resolveSetupSdkScript();
    final sdkDirArg = sdkDir ?? _detectSdkDir();
    final resultFile =
        '${Directory.systemTemp.path}\\aswh_sdk_${action}_${DateTime.now().millisecondsSinceEpoch}.json';

    final args = [
      '-NoProfile', '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-SdkDir', sdkDirArg,
      '-ResultFile', resultFile,
      '-Mirror', mirror,
      '-Action', action,
      if (packages.isNotEmpty) ...['-Packages', packages.join(';')],
      if (proxy != null && proxy.isNotEmpty) ...['-Proxy', proxy],
      '-Json',
    ];

    final process = await Process.start('powershell.exe', args);
    final stdoutBytes = <int>[];
    final stderrBuffer = StringBuffer();

    process.stdout.listen((chunk) {
      stdoutBytes.addAll(chunk);
      _drainLines(stdoutBytes, (line) {
        if (line.startsWith('@@PROGRESS|') && line.endsWith('@@')) {
          final body = line.substring('@@PROGRESS|'.length, line.length - 2);
          final parts = body.split('|');
          if (parts.length >= 2) {
            final pct = int.tryParse(parts[0]) ?? 0;
            final msg = parts[1];
            _log('[$pct%] $msg');
            onProgress?.call(pct.clamp(0, 100), msg);
          }
        }
      });
    });

    process.stderr.listen((chunk) {
      stderrBuffer.write(_decodeBytes(chunk));
    });

    final exitCode = await process.exitCode;

    if (stdoutBytes.isNotEmpty) {
      _log('stdout 尾部: ${_decodeBytes(stdoutBytes)}');
    }

    if (!File(resultFile).existsSync()) {
      if (exitCode != 0) {
        throw StateError('$action 失败 (exitCode: $exitCode): ${stderrBuffer}');
      }
      return SdkActionResult(success: true, message: '$action 完成', log: '');
    }

    final json = jsonDecode(File(resultFile).readAsStringSync()) as Map<String, dynamic>;
    File(resultFile).deleteSync();
    return SdkActionResult.fromJson(json);
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

  void _drainLines(List<int> buffer, void Function(String line) onLine) {
    while (true) {
      var idx = buffer.indexOf(10);
      if (idx == -1) return;
      var lineBytes = buffer.sublist(0, idx);
      buffer.removeRange(0, idx + 1);
      if (lineBytes.isNotEmpty && lineBytes.last == 13) {
        lineBytes = lineBytes.sublist(0, lineBytes.length - 1);
      }
      final line = _decodeBytes(lineBytes).trim();
      if (line.isNotEmpty) onLine(line);
    }
  }

  String _decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    try { return utf8.decode(bytes); }
    on FormatException { return utf8.decode(bytes, allowMalformed: true); }
  }
}

class SdkPackageInfo {
  final bool success;
  final String sdkDir;
  final bool hasJava;
  final List<String> installed;
  final List<String> available;

  SdkPackageInfo({
    required this.success,
    required this.sdkDir,
    required this.hasJava,
    required this.installed,
    required this.available,
  });

  factory SdkPackageInfo.fromJson(Map<String, dynamic> json) {
    return SdkPackageInfo(
      success: json['success'] == true,
      sdkDir: json['sdkDir'] ?? '',
      hasJava: json['hasJava'] == true,
      installed: (json['installed'] as List?)?.map((e) => '$e').toList() ?? [],
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
