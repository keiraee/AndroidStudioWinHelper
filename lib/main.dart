import 'dart:io';

import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'package:androidstudiowinhelper/pages/detect_page.dart';
import 'package:flutter/material.dart';

void main() {
  LogManager.instance.init();
  LogManager.instance.write(
    'App',
    '启动 AndroidStudioWinHelper，日志目录=${LogManager.instance.logDirPath}',
  );
  LogManager.instance.cleanupOldLogs(keepDays: 30);
  Widget app = const AndroidStudioWinHelperApp();
  if (Platform.isWindows) {
    app = ExcludeSemantics(child: app);
  }
  runApp(app);
}

class AndroidStudioWinHelperApp extends StatelessWidget {
  const AndroidStudioWinHelperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'androidstudiowinhelper',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0078D4)),
        useMaterial3: true,
      ),
      home: const DetectPage(),
    );
  }
}
