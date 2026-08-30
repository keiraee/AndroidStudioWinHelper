import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/android_studio_detector.dart';
import 'package:androidstudiowinhelper/core/models/android_studio_install.dart';

Future<int> runDetectAndroidStudioCommand(List<String> args) async {
  final jsonOutput = args.contains('--json');
  final deepScan = args.contains('--deep');

  final detector = AndroidStudioDetector();

  try {
    final result = await detector.detectAll(deepScan: deepScan);

    if (jsonOutput) {
      final payload = {
        'count': result.installs.length,
        'residueCount': result.residues.length,
        'installs': result.installs.map((item) => item.toJson()).toList(),
        'residues': result.residues.map((item) => item.toJson()).toList(),
        if (result.selected != null) 'selected': result.selected!.toJson(),
        if (result.selectionReason != null)
          'selectionReason': result.selectionReason!.name,
      };
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
    } else {
      _printHumanReadable(result);
    }

    return (result.hasInstalls || result.hasResidues) ? 0 : 1;
  } catch (error) {
    stderr.writeln('检测失败：$error');
    return 2;
  }
}

void _printHumanReadable(AndroidStudioDetectionResult result) {
  if (!result.hasInstalls && !result.hasResidues) {
    stdout.writeln('未检测到 Android Studio 安装或卸载残留。');
    return;
  }

  if (result.hasInstalls) {
    stdout.writeln('共检测到 ${result.installs.length} 个安装：');
    stdout.writeln('');

    for (var i = 0; i < result.installs.length; i++) {
      final install = result.installs[i];
      stdout.writeln('[${i + 1}]');
      stdout.writeln('安装路径：${install.path}');
      stdout.writeln('可执行文件：${install.executable}');
      stdout.writeln('名称：${install.name}');
      stdout.writeln('版本：${install.version}');
      stdout.writeln('构建号：${install.build}');
      stdout.writeln('渠道：${install.channel}');
      stdout.writeln('检测来源：${install.source}');
      stdout.writeln('');
    }

    if (result.selected != null) {
      stdout.writeln('推荐默认安装：${result.selected!.path}');
      stdout.writeln('选择原因：${result.selectionReason?.label ?? '未知'}');
      stdout.writeln('');
    }
  } else {
    stdout.writeln('未检测到有效 Android Studio 安装。');
    stdout.writeln('');
  }

  if (result.hasResidues) {
    stdout.writeln('发现 ${result.residues.length} 处卸载残留：');
    stdout.writeln('');
    for (var i = 0; i < result.residues.length; i++) {
      final residue = result.residues[i];
      stdout.writeln('[残留 ${i + 1}]');
      stdout.writeln('名称：${residue.name}');
      stdout.writeln('路径：${residue.path}');
      stdout.writeln('注册表：${residue.registryKey}');
      stdout.writeln('版本：${residue.version}');
      stdout.writeln('原因：${residue.reason}');
      stdout.writeln('');
    }
  }
}
