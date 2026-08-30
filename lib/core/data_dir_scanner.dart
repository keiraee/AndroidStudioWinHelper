import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/models/data_dir_entry.dart';
import 'package:androidstudiowinhelper/core/models/scan_progress.dart';
import 'package:androidstudiowinhelper/core/powershell_runner.dart';
import 'package:androidstudiowinhelper/core/scan_cache.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

typedef ScanProgressCallback = void Function(ScanProgress progress);

class DataDirScanner {
  DataDirScanner({PowerShellRunner? runner})
      : _runner = runner ?? PowerShellRunner(logTag: 'Scan');

  static const Duration scanTimeout = Duration(seconds: 600);

  final PowerShellRunner _runner;

  Future<DataDirScanResult> scanAll({
    ScanProgressCallback? onProgress,
    Duration? timeout,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('数据目录扫描仅支持 Windows。');
    }

    final scriptPath = await resolveScanDataDirsScript();
    final scriptFile = File(scriptPath);
    if (!scriptFile.existsSync()) {
      throw StateError('未找到扫描脚本：$scriptPath');
    }

    final extraArgs = <String>['-Json', '-Progress'];
    final installCache = ScanCache.loadInstall();
    if (installCache != null) {
      for (final install in installCache.installs) {
        if (install.sdkPath.trim().isNotEmpty) {
          extraArgs.addAll(['-SdkPath', install.sdkPath.trim()]);
        }
        if (install.dataDirectoryName.trim().isNotEmpty) {
          extraArgs.addAll(['-KnownDataDir', install.dataDirectoryName.trim()]);
        }
      }
    }

    final result = await _runner.run(
      scriptPath: scriptFile.absolute.path,
      extraArgs: extraArgs,
      onProgress: onProgress,
      timeout: timeout ?? scanTimeout,
    );

    return _parseOutput(result);
  }

  DataDirScanResult _parseOutput(PowerShellResult result) {
    if (result.jsonResult != null) {
      return DataDirScanResult.fromJson(result.jsonResult!);
    }

    final stdoutText = result.stdout;
    const marker = '@@RESULT|';
    final startIdx = stdoutText.indexOf(marker);
    if (startIdx >= 0) {
      final afterMarker = startIdx + marker.length;
      final endIdx = stdoutText.indexOf('@@', afterMarker);
      final jsonText = endIdx > afterMarker
          ? stdoutText.substring(afterMarker, endIdx).trim()
          : stdoutText.substring(afterMarker).trim();
      return _parseJsonText(jsonText, result);
    }

    final jsonText = stdoutText
        .split('\n')
        .where((line) => !line.trim().startsWith('@@PROGRESS|'))
        .join('\n')
        .trim();

    if (jsonText.isEmpty) {
      throw StateError(_buildScanFailureMessage(result));
    }

    return _parseJsonText(jsonText, result);
  }

  DataDirScanResult _parseJsonText(String jsonText, PowerShellResult result) {
    if (jsonText.isEmpty) {
      throw StateError(_buildScanFailureMessage(result));
    }

    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('根节点不是对象');
      }
      return DataDirScanResult.fromJson(decoded);
    } on FormatException catch (error) {
      throw StateError('扫描脚本返回的结果无法解析：$error');
    }
  }

  String _buildScanFailureMessage(PowerShellResult result) {
    final parts = <String>['扫描脚本未返回有效结果'];

    if (result.exitCode != 0) {
      parts.add('exitCode=${result.exitCode}');
    }

    final stderr = result.stderr.trim();
    if (stderr.isNotEmpty) {
      parts.add('stderr: $stderr');
    }

    if (result.progressEvents.isNotEmpty) {
      final last = result.progressEvents.last;
      parts.add('最后进度: ${last.percent}% ${last.message}');
    }

    return parts.join('；');
  }
}
