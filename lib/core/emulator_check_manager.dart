import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/models/emulator_check_result.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';

class EmulatorCheckManager {
  static void _log(String message) {
    LogManager.instance.write('EmuCheck', message);
  }

  Future<EmulatorCheckResult> runChecks() async {
    _log('===== 开始模拟器兼容性检测 =====');

    if (!Platform.isWindows) {
      throw UnsupportedError('模拟器兼容性检测仅支持 Windows。');
    }

    final scriptPath = await resolveCheckEmulatorScript();
    _log('检测脚本路径: $scriptPath');

    final resultFile =
        '${Directory.systemTemp.path}\\aswh_emucheck_${DateTime.now().millisecondsSinceEpoch}.json';

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
}
