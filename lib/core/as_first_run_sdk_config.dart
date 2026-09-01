import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 安装完成后预写 Android Studio 首次启动 SDK 配置。
class AsFirstRunSdkConfig {
  const AsFirstRunSdkConfig({
    required this.installHome,
    required this.androidHome,
    this.logTag = 'InstallerIntercept',
  });

  final String installHome;
  final String androidHome;
  final String logTag;

  static Future<String?> readMachineEnv(String name) async {
    if (!Platform.isWindows) return null;
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        '[Environment]::GetEnvironmentVariable("$name","Machine")',
      ],
    );
    final value = (result.stdout as String? ?? '').trim();
    return value.isEmpty ? null : value;
  }

  static Future<Map<String, String>> resolvePaths({
    Map<String, String>? preferred,
  }) async {
    final out = <String, String>{};
    for (final key in const [
      'AS_INSTALL_HOME',
      'ANDROID_HOME',
      'ANDROID_USER_HOME',
    ]) {
      final fromPreferred = preferred?[key]?.trim();
      if (fromPreferred != null && fromPreferred.isNotEmpty) {
        out[key] = fromPreferred;
        LogManager.instance.write(
          'FirstRunSdk',
          '路径 $key 来自安装向导: $fromPreferred',
        );
        continue;
      }
      final fromMachine = await readMachineEnv(key);
      if (fromMachine != null && fromMachine.isNotEmpty) {
        out[key] = fromMachine;
        LogManager.instance.write(
          'FirstRunSdk',
          '路径 $key 来自 Machine 环境变量: $fromMachine',
        );
      }
    }
    return out;
  }

  Future<bool> isInstallSuccessful() async {
    return (await resolveInstallHome()) != null;
  }

  /// 优先 AS_INSTALL_HOME，其次注册表 Path。
  Future<String?> resolveInstallHome() async {
    final home = installHome.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    if (home.isNotEmpty && _isValidInstallTree(home)) {
      return home;
    }
    final fromReg = await _readRegistryInstallPath();
    if (fromReg != null && _isValidInstallTree(fromReg)) {
      return fromReg;
    }
    return null;
  }

  /// 安装器退出后文件/注册表可能延迟就绪，轮询等待。
  Future<String?> resolveInstallHomeWithRetry({
    Duration timeout = const Duration(seconds: 20),
    Duration interval = const Duration(seconds: 1),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final home = await resolveInstallHome();
      if (home != null) return home;
      await Future<void>.delayed(interval);
    }
    return null;
  }

  static bool _isValidInstallTree(String home) {
    final root = home.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    if (root.isEmpty) return false;
    if (File('$root\\product-info.json').existsSync()) return true;
    if (File('$root\\bin\\studio64.exe').existsSync()) return true;
    return File('$root\\bin\\studio.exe').existsSync();
  }

  Future<String?> readDataDirectoryName() async {
    final candidates = <String>[];
    final home = installHome.trim();
    if (home.isNotEmpty) candidates.add(home);

    final fromReg = await _readRegistryInstallPath();
    if (fromReg != null && fromReg.isNotEmpty) {
      candidates.add(fromReg);
    }

    for (final dir in candidates) {
      final name = await _readDataDirectoryNameFrom('$dir\\product-info.json');
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  Future<AsFirstRunWriteResult> apply() async {
    if (!Platform.isWindows) {
      return const AsFirstRunWriteResult(
        success: false,
        message: '仅支持 Windows',
      );
    }

    final sdk = androidHome.trim();
    if (sdk.isEmpty) {
      return const AsFirstRunWriteResult(
        success: false,
        message: 'ANDROID_HOME 为空',
      );
    }

    if (!await isInstallSuccessful()) {
      return const AsFirstRunWriteResult(
        success: false,
        message: '未检测到有效安装，跳过 other.xml',
      );
    }

    final selector = await readDataDirectoryName();
    if (selector == null || selector.isEmpty) {
      return const AsFirstRunWriteResult(
        success: false,
        message: '无法读取 dataDirectoryName',
      );
    }

    await _ensureSdkSkeleton(sdk);

    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return const AsFirstRunWriteResult(
        success: false,
        message: 'APPDATA 未设置',
      );
    }

    final optionsDir = Directory('$appData\\Google\\$selector\\options');
    if (!optionsDir.existsSync()) {
      optionsDir.createSync(recursive: true);
    }
    final otherFile = File('${optionsDir.path}\\other.xml');
    final writtenPath = await _mergeOtherXml(otherFile, sdk);

    LogManager.instance.write(
      logTag,
      '已写入首次启动 SDK 路径: $writtenPath -> $sdk',
    );

    return AsFirstRunWriteResult(
      success: true,
      message: '已写入 $writtenPath',
      otherXmlPath: writtenPath,
      dataDirectoryName: selector,
    );
  }

  Future<void> _ensureSdkSkeleton(String sdkPath) async {
    final sdkDir = Directory(sdkPath);
    if (!sdkDir.existsSync()) {
      sdkDir.createSync(recursive: true);
    }
    final platforms = Directory('${sdkDir.path}\\platforms');
    if (!platforms.existsSync()) {
      platforms.createSync(recursive: true);
    }
  }

  Future<String> _mergeOtherXml(File file, String sdkPath) async {
    Map<String, dynamic> data;
    if (file.existsSync()) {
      try {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        data = decoded is Map<String, dynamic>
            ? Map<String, dynamic>.from(decoded)
            : <String, dynamic>{};
      } catch (_) {
        data = <String, dynamic>{};
      }
    } else {
      data = <String, dynamic>{};
    }

    data['android.sdk.path'] = sdkPath.replaceAll('/', r'\');
    final encoder = const JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(data)}\n', flush: true);
    return file.path;
  }

  Future<String?> _readRegistryInstallPath() async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        r'(Get-ItemProperty -Path "HKLM:\SOFTWARE\Android Studio" -ErrorAction SilentlyContinue).Path',
      ],
    );
    final value = (result.stdout as String? ?? '').trim();
    return value.isEmpty ? null : value.replaceAll(RegExp(r'[\\/]+$'), '');
  }

  Future<String?> _readDataDirectoryNameFrom(String path) async {
    final file = File(path);
    if (!file.existsSync()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return json['dataDirectoryName']?.toString();
    } catch (_) {
      return null;
    }
  }
}

class AsFirstRunWriteResult {
  const AsFirstRunWriteResult({
    required this.success,
    required this.message,
    this.otherXmlPath,
    this.dataDirectoryName,
  });

  final bool success;
  final String message;
  final String? otherXmlPath;
  final String? dataDirectoryName;
}
