import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';

/// 文件工具 — SHA256 校验、PE 文件验证
class FileUtils {
  FileUtils._();

  /// 计算文件 SHA256（调用 Windows certutil）
  static Future<String> sha256(String filePath) async {
    final result = await Process.run(
      'certutil',
      ['-hashfile', filePath, 'SHA256'],
    );
    // Process.run 默认使用 systemEncoding（Windows 上是 GBK），正确解码中文
    final output = result.stdout as String;
    LogManager.instance.write('FileUtils', 'certutil 原始输出:\n$output');
    final lines = output.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty &&
          trimmed.length == 64 &&
          !trimmed.contains(' ')) {
        return trimmed.toLowerCase();
      }
    }
    // fallback: 用正则匹配 64 位十六进制字符串
    final match = RegExp(r'[0-9a-fA-F]{64}').firstMatch(output);
    if (match != null) return match.group(0)!.toLowerCase();
    LogManager.instance.write('FileUtils', 'certutil 输出中未找到 SHA256');
    return '';
  }

  /// 验证下载的文件是否为有效的 Windows PE 可执行文件
  static Future<bool> validatePeFile(String filePath) async {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return false;

      // 1. 文件大小检查：有效的 AS 安装包至少 100MB
      final size = file.lengthSync();
      if (size < 100 * 1024 * 1024) {
        LogManager.instance.write('FileUtils',
            '文件校验失败: 大小仅 ${(size / 1024 / 1024).toStringAsFixed(1)}MB，不是有效安装包');
        return false;
      }

      // 2. 检查 MZ 头（PE 可执行文件魔数）
      final bytes = await file.openRead(0, 2).first;
      if (bytes.length < 2 || bytes[0] != 0x4D || bytes[1] != 0x5A) {
        LogManager.instance.write('FileUtils',
            '文件校验失败: 非 MZ 头 (${bytes.map((b) => b.toRadixString(16)).join(" ")})，可能是 HTML 错误页');
        return false;
      }

      LogManager.instance.write('FileUtils',
          '文件校验通过: MZ 头正确, ${(size / 1024 / 1024).toStringAsFixed(1)}MB');
      return true;
    } catch (e) {
      LogManager.instance.write('FileUtils', '文件校验异常: $e');
      return false;
    }
  }
}
