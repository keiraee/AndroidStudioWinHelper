import 'dart:io';

/// Android Studio NSIS 安装器在 cwd 下创建的临时文件（UTF-16LE，两行路径）。
class InstallerSettingsTmp {
  const InstallerSettingsTmp({
    required this.sdkPath,
    required this.userSettingsPath,
  });

  final String sdkPath;
  final String userSettingsPath;

  static const fileName = 'inst_user_settings.tmp';

  static String filePathIn(String workingDirectory) {
    return '${workingDirectory.replaceAll('/', r'\').replaceAll(RegExp(r'[\\/]+$'), '')}\\$fileName';
  }

  /// 解码 UTF-16LE（可带 BOM）。
  static List<String> decodeLines(List<int> bytes) {
    if (bytes.isEmpty) return const [];

    var offset = 0;
    if (bytes.length >= 2 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xFE) {
      offset = 2;
    }

    final units = <int>[];
    for (var i = offset; i + 1 < bytes.length; i += 2) {
      final unit = bytes[i] | (bytes[i + 1] << 8);
      if (unit == 0) break;
      units.add(unit);
    }

    final text = String.fromCharCodes(units);
    return text
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  static List<int> encodeLines(List<String> lines) {
    final normalized = lines.map((e) => e.trim()).where((e) => e.isNotEmpty);
    final text = '${normalized.join('\r\n')}\r\n';
    final bytes = <int>[];
    for (final unit in text.codeUnits) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return bytes;
  }

  factory InstallerSettingsTmp.fromBytes(List<int> bytes) {
    final lines = decodeLines(bytes);
    return InstallerSettingsTmp(
      sdkPath: lines.isNotEmpty ? lines[0] : '',
      userSettingsPath: lines.length > 1 ? lines[1] : '',
    );
  }

  List<int> toBytes() => encodeLines([sdkPath, userSettingsPath]);

  bool matchesTarget(String sdk, String userSettings) {
    return _normalizePath(sdkPath) == _normalizePath(sdk) &&
        _normalizePath(userSettingsPath) == _normalizePath(userSettings);
  }

  static String _normalizePath(String value) {
    return value.trim().replaceAll('/', r'\').replaceAll(RegExp(r'[\\/]+$'), '');
  }

  /// 原子写入，失败时短重试。
  static Future<bool> writeAtomic({
    required String workingDirectory,
    required String sdkPath,
    required String userSettingsPath,
    int retries = 3,
  }) async {
    final target = File(filePathIn(workingDirectory));
    final payload = InstallerSettingsTmp(
      sdkPath: sdkPath,
      userSettingsPath: userSettingsPath,
    ).toBytes();

    for (var attempt = 0; attempt < retries; attempt++) {
      try {
        final temp = File('${target.path}.aswh.tmp');
        await temp.writeAsBytes(payload, flush: true);
        if (target.existsSync()) {
          await target.delete();
        }
        await temp.rename(target.path);
        return true;
      } catch (_) {
        if (attempt == retries - 1) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 80 * (attempt + 1)));
      }
    }
    return false;
  }

  static Future<InstallerSettingsTmp?> readFrom(String workingDirectory) async {
    final file = File(filePathIn(workingDirectory));
    if (!file.existsSync()) return null;
    try {
      final bytes = await file.readAsBytes();
      return InstallerSettingsTmp.fromBytes(bytes);
    } catch (_) {
      return null;
    }
  }
}
