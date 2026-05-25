import 'dart:io';

import 'package:androidstudiowinhelper/cli/commands/detect_android_studio_command.dart';
import 'package:androidstudiowinhelper/cli/commands/scan_data_dirs_command.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _printHelp();
    exit(0);
  }

  final command = args.first;
  final commandArgs = args.skip(1).toList();

  final exitCode = switch (command) {
    'detect-android-studio' => await runDetectAndroidStudioCommand(commandArgs),
    'scan-data-dirs' => await runScanDataDirsCommand(commandArgs),
    _ => _unknownCommand(command),
  };

  exit(exitCode);
}

int _unknownCommand(String command) {
  stderr.writeln('未知命令：$command');
  stderr.writeln('');
  _printHelp();
  return 64;
}

void _printHelp() {
  stdout.writeln('androidstudiowinhelper CLI (aswh)');
  stdout.writeln('');
  stdout.writeln('用法：');
  stdout.writeln('  dart run bin/aswh.dart detect-android-studio [--json] [--deep]');
  stdout.writeln('  dart run bin/aswh.dart scan-data-dirs [--json]');
  stdout.writeln('');
  stdout.writeln('命令：');
  stdout.writeln('  detect-android-studio   检测所有 Android Studio 安装');
  stdout.writeln('  scan-data-dirs          磁盘占用体检（配置、缓存、日志、SDK）');
  stdout.writeln('');
  stdout.writeln('选项：');
  stdout.writeln('  --json                  以 JSON 格式输出');
  stdout.writeln('  --deep                  启用深度扫描（较慢）');
}
