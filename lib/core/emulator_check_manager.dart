import 'dart:convert';
import 'dart:io';

// ignore_for_file: avoid_print

import 'package:androidstudiowinhelper/core/models/emulator_check_result.dart';

class EmulatorCheckManager {
  static void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[EmuCheck $ts] $message');
  }

  Future<EmulatorCheckResult> runChecks() async {
    _log('===== 开始模拟器兼容性检测 =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('模拟器兼容性检测仅支持 Windows。');
    }

    // Find script
    final scriptPath = await _resolveScript();
    _log('检测脚本路径: $scriptPath');

    // Ensure the script has UTF-8 BOM so PowerShell 5.1 reads Chinese correctly
    await _ensureUtf8Bom(scriptPath);

    final resultFile =
        '${Directory.systemTemp.path}\\aswh_emucheck_${DateTime.now().millisecondsSinceEpoch}.json';

    // Run without elevation (non-admin checks only)
    final args = [
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', scriptPath,
      '-ResultFile', resultFile,
    ];

    _log('执行命令: powershell.exe ${args.join(' ')}');

    final result = await Process.run(
      'powershell.exe',
      args,
      stdoutEncoding: null,
      stderrEncoding: null,
    );

    final exitCode = result.exitCode;
    _log('命令执行完毕, exitCode: $exitCode');

    if (exitCode != 0) {
      final stderrText = _decodeText(result.stderr);
      final stdoutText = _decodeText(result.stdout);
      if (stdoutText.isNotEmpty) _log('stdout: $stdoutText');
      if (stderrText.isNotEmpty) _log('stderr: $stderrText');
    }

    final resultFileObj = File(resultFile);
    if (!resultFileObj.existsSync()) {
      _log('[错误] 结果文件未生成');
      throw StateError('检测脚本未生成结果文件 (exitCode: $exitCode)。');
    }

    try {
      final rawContent = resultFileObj.readAsStringSync();
      _log('结果文件内容: ${rawContent.length > 2000 ? rawContent.substring(0, 2000) : rawContent}');
      final json = jsonDecode(rawContent);
      if (json is Map<String, dynamic>) {
        final checkResult = EmulatorCheckResult.fromJson(json);
        _log('检测完成: ${checkResult.checks.length} 项, ${checkResult.warningCount} 个警告');
        return checkResult;
      }
      throw StateError('结果文件格式无效。');
    } finally {
      try { resultFileObj.deleteSync(); } catch (_) {}
    }
  }

  Future<void> _ensureUtf8Bom(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    // UTF-8 BOM is 0xEF 0xBB 0xBF
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return; // already has BOM
    }
    final bom = [0xEF, 0xBB, 0xBF];
    await file.writeAsBytes([...bom, ...bytes]);
    _log('已为脚本添加 UTF-8 BOM: $filePath');
  }

  Future<String> _resolveScript() async {
    // Try relative to the executable first, then relative to the project
    final candidates = [
      '${Directory.current.path}\\scripts\\check-emulator.ps1',
      '${Platform.resolvedExecutable}\\..\\scripts\\check-emulator.ps1',
    ];

    // Also try to find via pubspec-relative path
    final scriptDir = _findScriptDir();
    if (scriptDir != null) {
      candidates.insert(0, '$scriptDir\\check-emulator.ps1');
    }

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return File(path).absolute.path;
      }
    }

    // Walk up from current directory to find project root
    var dir = Directory.current;
    for (var i = 0; i < 10; i++) {
      final candidate = File('${dir.path}\\scripts\\check-emulator.ps1');
      if (candidate.existsSync()) return candidate.absolute.path;
      if (!dir.parent.path.endsWith(dir.path)) {
        dir = dir.parent;
      } else {
        break;
      }
    }

    throw StateError('未找到检测脚本: check-emulator.ps1');
  }

  String _decodeText(Object? data) {
    if (data == null) return '';
    if (data is String) return data;
    if (data is List<int>) {
      if (data.isEmpty) return '';
      try {
        return utf8.decode(data);
      } on FormatException {
        return utf8.decode(data, allowMalformed: true);
      }
    }
    return data.toString();
  }

  String? _findScriptDir() {
    // Look for scripts dir next to pubspec.yaml
    var dir = Directory.current;
    for (var i = 0; i < 10; i++) {
      final scriptsDir = Directory('${dir.path}\\scripts');
      if (scriptsDir.existsSync()) return scriptsDir.path;
      if (!dir.parent.path.endsWith(dir.path)) {
        dir = dir.parent;
      } else {
        break;
      }
    }
    return null;
  }
}
