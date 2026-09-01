import 'dart:io';

/// 解析 7-Zip 可执行文件路径：优先使用随应用打包在 flutter_assets 内的副本。
Future<String> resolveSevenZip() async {
  final envPath = Platform.environment['ASWH_7ZIP']?.trim();
  if (envPath != null && envPath.isNotEmpty && File(envPath).existsSync()) {
    return File(envPath).absolute.path;
  }

  for (final candidate in _bundledCandidates()) {
    if (_isValidSevenZip(candidate)) {
      return File(candidate).absolute.path;
    }
  }

  for (final candidate in _systemCandidates()) {
    if (_isValidSevenZip(candidate)) {
      return File(candidate).absolute.path;
    }
  }

  throw StateError(
    '未找到 7-Zip。请重新安装 AndroidStudioWinHelper，或安装 7-Zip 后重试。',
  );
}

bool _isValidSevenZip(String exePath) {
  if (!File(exePath).existsSync()) return false;
  final dllPath = '${File(exePath).parent.path}${Platform.pathSeparator}7z.dll';
  return File(dllPath).existsSync();
}

Iterable<String> _bundledCandidates() sync* {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  yield _join(exeDir, 'data/flutter_assets/tools/7zip/7z.exe');

  final cwd = Directory.current.path;
  yield _join(cwd, 'tools/7zip/7z.exe');
  yield _join(cwd, '../tools/7zip/7z.exe');
}

Iterable<String> _systemCandidates() sync* {
  final programFiles = Platform.environment['ProgramFiles'];
  if (programFiles != null && programFiles.isNotEmpty) {
    yield _join(programFiles, '7-Zip/7z.exe');
  }
  final programFilesX86 = Platform.environment['ProgramFiles(x86)'];
  if (programFilesX86 != null && programFilesX86.isNotEmpty) {
    yield _join(programFilesX86, '7-Zip/7z.exe');
  }
}

String _join(String base, String relative) {
  final normalizedBase = base.replaceAll('/', Platform.pathSeparator);
  final normalizedRelative = relative.replaceAll('/', Platform.pathSeparator);
  return '$normalizedBase${Platform.pathSeparator}$normalizedRelative';
}
