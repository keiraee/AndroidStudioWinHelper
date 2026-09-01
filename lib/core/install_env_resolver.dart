import 'dart:io';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/env_path_manager.dart';
import 'package:androidstudiowinhelper/core/install_env_defaults.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 安装向导路径来源。
enum InstallEnvPathSource {
  machine,
  user,
  registry,
  detector,
  inferred,
}

class InstallEnvResolved {
  const InstallEnvResolved({
    required this.paths,
    required this.sources,
    required this.machinePaths,
  });

  final Map<String, String> paths;
  final Map<String, InstallEnvPathSource> sources;
  final Map<String, String> machinePaths;

  /// 安装目录 + SDK 路径均已解析，可视为已有配置。
  bool get hasExistingInstallSetup {
    return (paths['AS_INSTALL_HOME'] ?? '').isNotEmpty &&
        (paths['ANDROID_HOME'] ?? '').isNotEmpty;
  }

  bool get hasAnyMachineVariable => machinePaths.isNotEmpty;
}

/// 合并环境变量、注册表与本机检测结果，供安装向导预填路径。
class InstallEnvResolver {
  const InstallEnvResolver._();

  static const _logTag = 'InstallEnv';

  static void _log(String message) {
    LogManager.instance.write(_logTag, message);
  }

  static Future<InstallEnvResolved> resolve({
    required EnvPathManager envManager,
  }) async {
    const keys = InstallEnvDefaults.variables;
    final machine = await envManager.readMachineVariables(keys);
    final user = await envManager.readUserVariables(keys);

    final paths = <String, String>{};
    final sources = <String, InstallEnvPathSource>{};

    for (final key in keys) {
      final machineVal = machine[key];
      if (machineVal != null && machineVal.isNotEmpty) {
        paths[key] = machineVal;
        sources[key] = InstallEnvPathSource.machine;
        continue;
      }
      final userVal = user[key];
      if (userVal != null && userVal.isNotEmpty) {
        paths[key] = userVal;
        sources[key] = InstallEnvPathSource.user;
      }
    }

    await _fillInstallHome(paths, sources);
    await _fillAndroidHome(paths, sources);
    _inferSiblingPaths(paths, sources);

    _log('路径解析完成 hasExisting=${paths['AS_INSTALL_HOME'] != null && paths['ANDROID_HOME'] != null}');
    for (final key in keys) {
      final value = paths[key];
      if (value == null || value.isEmpty) continue;
      _log('  $key=${sources[key]?.name ?? '?'} -> $value');
    }

    return InstallEnvResolved(
      paths: paths,
      sources: sources,
      machinePaths: machine,
    );
  }

  static Future<void> _fillInstallHome(
    Map<String, String> paths,
    Map<String, InstallEnvPathSource> sources,
  ) async {
    if ((paths['AS_INSTALL_HOME'] ?? '').isNotEmpty) return;

    final fromReg = await _readRegistryInstallPath();
    if (fromReg != null && fromReg.isNotEmpty) {
      paths['AS_INSTALL_HOME'] = fromReg;
      sources['AS_INSTALL_HOME'] = InstallEnvPathSource.registry;
      return;
    }

    final detected = await _detectStudioInstallPath();
    if (detected != null && detected.isNotEmpty) {
      paths['AS_INSTALL_HOME'] = detected;
      sources['AS_INSTALL_HOME'] = InstallEnvPathSource.detector;
    }
  }

  static Future<void> _fillAndroidHome(
    Map<String, String> paths,
    Map<String, InstallEnvPathSource> sources,
  ) async {
    if ((paths['ANDROID_HOME'] ?? '').isNotEmpty) return;

    final sdkFromReg = await _readRegistrySdkPath();
    if (sdkFromReg != null && sdkFromReg.isNotEmpty) {
      paths['ANDROID_HOME'] = sdkFromReg;
      sources['ANDROID_HOME'] = InstallEnvPathSource.registry;
    }
  }

  static void _inferSiblingPaths(
    Map<String, String> paths,
    Map<String, InstallEnvPathSource> sources,
  ) {
    final root = _androidRootFromInstallHome(paths['AS_INSTALL_HOME']);
    if (root == null) return;

    final defaults = InstallEnvDefaults.pathsForRoot(root);
    for (final key in InstallEnvDefaults.variables) {
      if ((paths[key] ?? '').isNotEmpty) continue;
      final inferred = defaults[key];
      if (inferred == null || inferred.isEmpty) continue;
      paths[key] = inferred;
      sources[key] = InstallEnvPathSource.inferred;
    }
  }

  static String? _androidRootFromInstallHome(String? installHome) {
    if (installHome == null || installHome.trim().isEmpty) return null;
    final normalized = installHome
        .trim()
        .replaceAll('/', r'\')
        .replaceAll(RegExp(r'[\\]+$'), '');
    if (!normalized.toUpperCase().endsWith(r'\ANDROIDSTUDIO')) {
      return null;
    }
    return Directory(normalized).parent.path;
  }

  static Future<String?> _readRegistryInstallPath() async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        r'(Get-ItemProperty -Path "HKLM:\SOFTWARE\Android Studio" -ErrorAction SilentlyContinue).Path',
      ],
    );
    final value = (result.stdout as String? ?? '').trim();
    if (value.isEmpty) return null;
    return value.replaceAll(RegExp(r'[\\/]+$'), '');
  }

  static Future<String?> _readRegistrySdkPath() async {
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        r'(Get-ItemProperty -Path "HKLM:\SOFTWARE\Android Studio" -ErrorAction SilentlyContinue).SdkPath',
      ],
    );
    final value = (result.stdout as String? ?? '').trim();
    if (value.isEmpty) return null;
    return value.replaceAll(RegExp(r'[\\/]+$'), '');
  }

  static Future<String?> _detectStudioInstallPath() async {
    try {
      final detection = await AndroidStudioDetector().detectAll();
      final selected = detection.selected;
      if (selected == null || !selected.isValid) return null;
      return selected.path.replaceAll(RegExp(r'[\\/]+$'), '');
    } catch (_) {
      return null;
    }
  }
}
