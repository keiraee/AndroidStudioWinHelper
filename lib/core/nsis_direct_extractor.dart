import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/core/script_locator.dart';
import 'package:androidstudiowinhelper/core/seven_zip_locator.dart';

class NsisExtractProgress {
  const NsisExtractProgress({
    required this.phase,
    required this.message,
    this.percent = 0,
    this.totalFiles = 0,
    this.extractedFiles = 0,
    this.totalBytes = 0,
    this.extractedBytes = 0,
    this.currentFile,
  });

  final String phase;
  final String message;
  final int percent;
  final int totalFiles;
  final int extractedFiles;
  final int totalBytes;
  final int extractedBytes;
  final String? currentFile;

  factory NsisExtractProgress.fromJson(Map<String, dynamic> json) {
    return NsisExtractProgress(
      phase: json['phase']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      percent: _asInt(json['percent']),
      totalFiles: _asInt(json['totalFiles']),
      extractedFiles: _asInt(json['extractedFiles']),
      totalBytes: _asInt(json['totalBytes']),
      extractedBytes: _asInt(json['extractedBytes']),
      currentFile: json['currentFile']?.toString(),
    );
  }
}

class NsisExtractResult {
  const NsisExtractResult({
    required this.success,
    this.installHome = '',
    this.totalFiles = 0,
    this.error = '',
    this.method = '7z-direct-extract',
  });

  final bool success;
  final String installHome;
  final int totalFiles;
  final String error;
  final String method;

  factory NsisExtractResult.fromJson(Map<String, dynamic> json) {
    return NsisExtractResult(
      success: json['success'] == true,
      installHome: json['installHome']?.toString() ?? '',
      totalFiles: _asInt(json['totalFiles']),
      error: json['error']?.toString() ?? '',
      method: json['method']?.toString() ?? '7z-direct-extract',
    );
  }
}

class NsisDirectExtractor {
  static const _logTag = 'InstallerExtract';

  final StreamController<NsisExtractProgress> _progressController =
      StreamController<NsisExtractProgress>.broadcast();

  Stream<NsisExtractProgress> get progressStream => _progressController.stream;

  Future<NsisExtractResult> extractAndDeploy({
    required String installerPath,
    required String installHome,
    String androidHome = '',
    String androidUserHome = '',
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('仅支持 Windows');
    }

    final ts = DateTime.now().millisecondsSinceEpoch;
    final progressFile =
        '${Directory.systemTemp.path}\\aswh_extract_progress_$ts.json';
    final resultFile =
        '${Directory.systemTemp.path}\\aswh_extract_result_$ts.json';

    final scriptPath = await resolveExtractAndroidStudioScript();
    final sevenZipPath = await resolveSevenZip();
    final args = [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-InstallerPath',
      installerPath,
      '-InstallHome',
      installHome,
      '-AndroidHome',
      androidHome,
      '-AndroidUserHome',
      androidUserHome,
      '-SevenZipPath',
      sevenZipPath,
      '-ProgressFile',
      progressFile,
      '-ResultFile',
      resultFile,
      '-LogFile',
      LogManager.instance.currentLogFilePath,
    ];

    LogManager.instance.write(
      _logTag,
      '开始 7z 解包: $installerPath -> $installHome (7z=$sevenZipPath)',
    );

    final process = await Process.start('powershell.exe', args);
    NsisExtractProgress? lastProgress;

    final pollTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      final p = _readProgress(progressFile);
      if (p != null &&
          (lastProgress == null ||
              p.phase != lastProgress!.phase ||
              p.percent != lastProgress!.percent ||
              p.message != lastProgress!.message ||
              p.extractedFiles != lastProgress!.extractedFiles)) {
        lastProgress = p;
        LogManager.instance.write(
          _logTag,
          '进度 phase=${p.phase} ${p.percent}% files=${p.extractedFiles}/${p.totalFiles} ${p.message}',
        );
        if (!_progressController.isClosed) {
          _progressController.add(p);
        }
      }
    });

    final exitCode = await process.exitCode;
    pollTimer.cancel();

    final finalProgress = _readProgress(progressFile);
    if (finalProgress != null && !_progressController.isClosed) {
      _progressController.add(finalProgress);
    }

    try {
      final resultFileObj = File(resultFile);
      if (!resultFileObj.existsSync()) {
        return NsisExtractResult(
          success: false,
          error: '解包脚本未返回结果（exitCode=$exitCode）',
        );
      }
      final json =
          jsonDecode(await resultFileObj.readAsString()) as Map<String, dynamic>;
      final result = NsisExtractResult.fromJson(json);
      LogManager.instance.write(
        _logTag,
        '解包完成 success=${result.success} files=${result.totalFiles} '
        'home=${result.installHome} error=${result.error}',
      );
      if (!result.success && exitCode != 0) {
        return NsisExtractResult(
          success: false,
          error: result.error.isEmpty
              ? '解包失败 exitCode=$exitCode'
              : result.error,
        );
      }
      return result;
    } finally {
      for (final path in [progressFile, resultFile]) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
      if (!_progressController.isClosed) {
        await _progressController.close();
      }
    }
  }

  NsisExtractProgress? _readProgress(String path) {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync().replaceFirst('\uFEFF', '');
      if (raw.trim().isEmpty) return null;
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      return NsisExtractProgress.fromJson(json);
    } catch (_) {
      return null;
    }
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
