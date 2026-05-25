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
        'entries': result.entries.map((entry) => {
              'category': entry.category,
              'label': entry.label,
              'path': entry.path,
              'version': entry.version,
              'exists': entry.exists,
              'sizeBytes': entry.sizeBytes,
              'sizeHuman': entry.sizeHuman,
              'notes': entry.notes,
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
      stdout.writeln('');

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
