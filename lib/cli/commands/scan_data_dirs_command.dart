import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/data_dir_scanner.dart';

Future<int> runScanDataDirsCommand(List<String> args) async {
  final jsonOutput = args.contains('--json');

  try {
    final result = await DataDirScanner().scanAll();

    if (jsonOutput) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert({
        'foundCount': result.foundCount,
        'totalSizeBytes': result.totalSizeBytes,
        'totalSizeHuman': result.totalSizeHuman,
        'scannedAt': result.scannedAt,
        'entries': result.entries.map((entry) => {
              'category': entry.category,
              'label': entry.label,
              'path': entry.path,
              'version': entry.version,
              'exists': entry.exists,
              'sizeBytes': entry.sizeBytes,
              'sizeHuman': entry.sizeHuman,
              'notes': entry.notes,
              'isActive': entry.isActive,
              'activeSource': entry.activeSource,
              'isOrphan': entry.isOrphan,
              'subEntries': entry.subEntries
                  .map((sub) => {
                        'name': sub.name,
                        'path': sub.path,
                        'exists': sub.exists,
                        'sizeBytes': sub.sizeBytes,
                        'sizeHuman': sub.sizeHuman,
                      })
                  .toList(),
            }),
      }));
    } else {
      stdout.writeln('共找到 ${result.foundCount} 个存在的目录，合计约 ${result.totalSizeHuman}');
      if (result.scannedAt.isNotEmpty) {
        stdout.writeln('扫描时间：${result.scannedAt}');
      }
      stdout.writeln('');

      if (result.entries.isEmpty) {
        stdout.writeln('未找到 Android 开发相关目录。');
        return 0;
      }

      for (var i = 0; i < result.entries.length; i++) {
        final entry = result.entries[i];
        stdout.writeln('[${i + 1}] ${entry.label}');
        stdout.writeln('类型：${entry.category}');
        if (entry.version.isNotEmpty) {
          stdout.writeln('版本：${entry.version}');
        }
        stdout.writeln('路径：${entry.path}');
        stdout.writeln('存在：${entry.exists ? '是' : '否'}');
        if (entry.exists) {
          stdout.writeln('大小：${entry.sizeHuman}');
        }
        if (entry.isOrphan) {
          stdout.writeln('标记：卸载残留');
        }
        if (entry.activeSource.isNotEmpty) {
          stdout.writeln('环境变量：${entry.activeSource}');
        }
        if (entry.notes.isNotEmpty) {
          stdout.writeln('说明：${entry.notes}');
        }
        if (entry.subEntries.isNotEmpty) {
          stdout.writeln('子目录：');
          for (final sub in entry.subEntries) {
            stdout.writeln('  - ${sub.name}  ${sub.sizeHuman}  ${sub.path}');
          }
        }
        stdout.writeln('');
      }
    }

    return 0;
  } catch (error) {
    stderr.writeln('扫描失败：$error');
    return 2;
  }
}
