import 'dart:io';

/// 检测与启动 Android Studio 进程（与 NSIS 安装器进程区分）。
class StudioLauncher {
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

  static Future<bool> launch(String installHome) async {
    final exe = await resolveStudioExe(installHome);
    if (exe == null) return false;
    await Process.start(exe, [], mode: ProcessStartMode.detached);
    return true;
  }
}
