import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 检测与启动 Android Studio 进程（与 NSIS 安装器进程区分）。
class StudioLauncher {
  static const _logTag = 'StudioLaunch';

  static void _log(String message) {
    LogManager.instance.write(_logTag, message);
  }

  static Future<bool> isRunning() async {
    if (!Platform.isWindows) return false;
    final result = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-Command',
        r"[bool](Get-Process -Name studio64,studio -ErrorAction SilentlyContinue)",
      ],
    );
    final out = (result.stdout as String? ?? '').trim().toLowerCase();
    return out == 'true';
  }

  /// 在 [timeout] 内轮询 Studio 是否已启动。
  static Future<bool> waitUntilRunning({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 500),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await isRunning()) return true;
      await Future<void>.delayed(interval);
    }
    return false;
  }

  static Future<String?> resolveStudioExe(String installHome) async {
    final home = installHome.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    if (home.isEmpty) return null;
    for (final name in ['studio64.exe', 'studio.exe']) {
      final exe = File('$home\\bin\\$name');
      if (exe.existsSync()) return exe.path;
    }
    return null;
  }

  static Future<bool> launch(
    String installHome, {
    String androidHome = '',
    String androidUserHome = '',
  }) async {
    final exe = await resolveStudioExe(installHome);
    if (exe == null) {
      _log('未找到 Studio 可执行文件: installHome=$installHome');
      return false;
    }

    final env = Map<String, String>.from(Platform.environment);
    final sdk = androidHome.trim();
    final userHome = androidUserHome.trim();
    if (sdk.isNotEmpty) {
      env['ANDROID_HOME'] = sdk;
    }
    if (userHome.isNotEmpty) {
      env['ANDROID_USER_HOME'] = userHome;
    }
    // 仅使用 ANDROID_USER_HOME / ANDROID_HOME；移除已废弃且会冲突的变量
    env.remove('ANDROID_SDK_HOME');
    env.remove('ANDROID_SDK_ROOT');

    _log(
      '启动 Studio: exe=$exe ANDROID_HOME=${env['ANDROID_HOME'] ?? '(未注入)'} '
      'ANDROID_USER_HOME=${env['ANDROID_USER_HOME'] ?? '(未注入)'}',
    );

    await Process.start(
      exe,
      [],
      mode: ProcessStartMode.detached,
      environment: env,
    );
    _log('Studio 进程已 detached 启动');
    return true;
  }
}
