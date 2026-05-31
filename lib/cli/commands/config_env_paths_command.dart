import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/env_path_manager.dart';

Future<int> runConfigEnvPathsCommand(List<String> args) async {
  final jsonOutput = args.contains('--json');
  final writeMode = args.contains('--write');

  if (writeMode) {
    return _handleWrite(args, jsonOutput);
  }

  return _handleRead(jsonOutput);
}

Future<int> _handleRead(bool jsonOutput) async {
  try {
    final result = await EnvPathManager().readConfig();

    if (jsonOutput) {
      stdout.writeln(
        const JsonEncoder.withIndent('  ').convert(result.toJson()),
      );
    } else {
      stdout.writeln('环境变量检测结果：');
      stdout.writeln('');

      for (final item in result.items) {
        stdout.writeln('${item.label} (${item.variable}):');
        stdout.writeln(
          '  值: ${item.currentValue.isEmpty ? "(未设置)" : item.currentValue}',
        );
        stdout.writeln('  来源: ${item.source}');
        stdout.writeln('  存在: ${item.exists ? "是" : "否"}');
        if (item.exists && item.sizeHuman.isNotEmpty) {
          stdout.writeln('  大小: ${item.sizeHuman}');
        }
        if (item.suggestedDefault.isNotEmpty) {
          stdout.writeln('  默认: ${item.suggestedDefault}');
        }
        stdout.writeln('');
      }

      if (result.pathEntries.isNotEmpty) {
        stdout.writeln('PATH 中的 SDK 子目录：');
        for (final entry in result.pathEntries) {
          final status = entry.inPath
              ? '✓ 已在 PATH'
              : entry.exists
                  ? '✗ 未在 PATH'
                  : '— 目录不存在';
          stdout.writeln('  ${entry.subDir}  $status');
          if (entry.fullPath.isNotEmpty) {
            stdout.writeln('    ${entry.fullPath}');
          }
        }
      }
    }

    return 0;
  } catch (error) {
    stderr.writeln('检测失败：$error');
    return 2;
  }
}

Future<int> _handleWrite(List<String> args, bool jsonOutput) async {
  final varNameIdx = args.indexOf('--name');
  final varValueIdx = args.indexOf('--value');
  final appendPathIdx = args.indexOf('--append-path');
  final createDir = args.contains('--create-dir');

  try {
    if (appendPathIdx != -1 && appendPathIdx + 1 < args.length) {
      final path = args[appendPathIdx + 1];
      final result = await EnvPathManager().appendToPath(
        path: path,
        createDir: createDir,
      );

      if (jsonOutput) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(result.toJson()),
        );
      } else {
        if (result.success) {
          stdout.writeln(result.error.isNotEmpty
              ? result.error
              : '已将 $path 追加到系统 PATH');
        } else {
          stderr.writeln('追加 PATH 失败：${result.error}');
          return 2;
        }
      }
    } else if (varNameIdx != -1 && varNameIdx + 1 < args.length) {
      final name = args[varNameIdx + 1];
      final value = varValueIdx != -1 && varValueIdx + 1 < args.length
          ? args[varValueIdx + 1]
          : '';

      final result = await EnvPathManager().writeVariable(
        variable: name,
        value: value,
        createDir: createDir,
      );

      if (jsonOutput) {
        stdout.writeln(
          const JsonEncoder.withIndent('  ').convert(result.toJson()),
        );
      } else {
        if (result.success) {
          stdout.writeln('已将 $name 设置为 $value');
        } else {
          stderr.writeln('写入失败：${result.error}');
          return 2;
        }
      }
    } else {
      stderr.writeln('用法：');
      stderr.writeln('  --name <变量名> --value <值> [--create-dir]');
      stderr.writeln('  --append-path <路径> [--create-dir]');
      return 64;
    }

    return 0;
  } catch (error) {
    stderr.writeln('操作失败：$error');
    return 2;
  }
}
