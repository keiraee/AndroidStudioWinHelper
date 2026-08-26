import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/powershell_runner.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef ScanProgressCallback = void Function(ScanProgress progress);

class DataDirScanner {
  DataDirScanner({PowerShellRunner? runner})
      : _runner = runner ?? PowerShellRunner(logTag: 'Scan');

  final PowerShellRunner _runner;

  Future<DataDirScanResult> scanAll({
    ScanProgressCallback? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('数据目录扫描仅支持 Windows。');
    }

    final scriptPath = await resolveScanDataDirsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到扫描脚本：$scriptPath');
    }

    final result = await _runner.run(
      scriptPath: scriptFile.absolute.path,
      extraArgs: ['-Json'],
      onProgress: onProgress,
    );

    if (!result.success && result.stdout.isEmpty) {
      throw StateError('PowerShell 执行失败：${result.stderr}');
    }

    return _parseOutput(result);
  }

  DataDirScanResult _parseOutput(PowerShellResult result) {
    // 优先用 @@RESULT|@@ 标记提取的 JSON
    if (result.jsonResult != null) {
      return DataDirScanResult.fromJson(result.jsonResult!);
    }

    // 回退：从 stdout 中提取 JSON
    final stdoutText = result.stdout;
    const marker = '@@RESULT|';
    final startIdx = stdoutText.indexOf(marker);
    final String jsonText;
    if (startIdx >= 0) {
      final afterMarker = startIdx + marker.length;
      final endIdx = stdoutText.indexOf('@@', afterMarker);
      if (endIdx > afterMarker) {
        jsonText = stdoutText.substring(afterMarker, endIdx).trim();
      } else {
        jsonText = stdoutText.substring(afterMarker).trim();
      }
    } else {
      jsonText = stdoutText
          .split('\n')
          .where((line) => !line.trim().startsWith('@@PROGRESS|'))
          .join('\n')
          .trim();
    }

    if (jsonText.isEmpty) {
      return const DataDirScanResult(
        entries: [],
        totalSizeBytes: 0,
        totalSizeHuman: '0 B',
        foundCount: 0,
      );
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw StateError('扫描结果格式无效。');
      }
      return DataDirScanResult.fromJson(decoded);
    } on FormatException catch (error) {
      throw StateError('扫描结果 JSON 解析失败：$error');
    }
  }
}
