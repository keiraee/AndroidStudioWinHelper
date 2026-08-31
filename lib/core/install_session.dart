import 'dart:convert';
import 'dart:io';

/// 安装监视会话：区分「NSIS 安装器结束」与「Android Studio 首次启动」。
class InstallSession {
  InstallSession({
    required this.versionKey,
    required this.workingDirectory,
    required this.paths,
    required this.phase,
    this.installerExitCode,
    this.installVerified = false,
    this.studioLaunchedByUs = false,
    this.otherXmlWritten = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String versionKey;
  final String workingDirectory;
  final Map<String, String> paths;
  final InstallSessionPhase phase;
  final int? installerExitCode;
  final bool installVerified;
  final bool studioLaunchedByUs;
  final bool otherXmlWritten;
  final DateTime updatedAt;

  String? get installHome => paths['AS_INSTALL_HOME']?.trim();
  String? get androidHome => paths['ANDROID_HOME']?.trim();

  bool get needsResume =>
      phase == InstallSessionPhase.watchingInstaller ||
      phase == InstallSessionPhase.awaitingStudioLaunch ||
      phase == InstallSessionPhase.studioFirstRunPending ||
      phase == InstallSessionPhase.interrupted;

  static File get _sessionFile {
    final base = Platform.environment['LOCALAPPDATA'] ?? '';
    return File('$base\\AndroidStudioWinHelper\\install_session.json');
  }

  static InstallSession? loadPending() {
    try {
      final file = _sessionFile;
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final session = InstallSession.fromJson(json);
      if (!session.needsResume) return null;
      return session;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(InstallSession session) async {
    final file = _sessionFile;
    file.parent.createSync(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
      flush: true,
    );
  }

  static Future<void> clear() async {
    try {
      final file = _sessionFile;
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {}
  }

  InstallSession copyWith({
    InstallSessionPhase? phase,
    int? installerExitCode,
    bool? installVerified,
    bool? studioLaunchedByUs,
    bool? otherXmlWritten,
    DateTime? updatedAt,
  }) {
    return InstallSession(
      versionKey: versionKey,
      workingDirectory: workingDirectory,
      paths: paths,
      phase: phase ?? this.phase,
      installerExitCode: installerExitCode ?? this.installerExitCode,
      installVerified: installVerified ?? this.installVerified,
      studioLaunchedByUs: studioLaunchedByUs ?? this.studioLaunchedByUs,
      otherXmlWritten: otherXmlWritten ?? this.otherXmlWritten,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'versionKey': versionKey,
    'workingDirectory': workingDirectory,
    'paths': paths,
    'phase': phase.name,
    'installerExitCode': installerExitCode,
    'installVerified': installVerified,
    'studioLaunchedByUs': studioLaunchedByUs,
    'otherXmlWritten': otherXmlWritten,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory InstallSession.fromJson(Map<String, dynamic> json) {
    final pathsRaw = json['paths'];
    final paths = <String, String>{};
    if (pathsRaw is Map) {
      for (final entry in pathsRaw.entries) {
        paths['${entry.key}'] = '${entry.value}';
      }
    }
    return InstallSession(
      versionKey: json['versionKey']?.toString() ?? '',
      workingDirectory: json['workingDirectory']?.toString() ?? '',
      paths: paths,
      phase: InstallSessionPhase.values.firstWhere(
        (p) => p.name == json['phase'],
        orElse: () => InstallSessionPhase.interrupted,
      ),
      installerExitCode: json['installerExitCode'] as int?,
      installVerified: json['installVerified'] == true,
      studioLaunchedByUs: json['studioLaunchedByUs'] == true,
      otherXmlWritten: json['otherXmlWritten'] == true,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }
}

enum InstallSessionPhase {
  /// 正在监视 NSIS 安装向导
  watchingInstaller,

  /// 安装器已退出且文件已就位，等待 Studio 进程（最多 10s）
  awaitingStudioLaunch,

  /// Studio 已启动，等待用户在 IDE 内完成首次配置
  studioFirstRunPending,

  /// 全流程结束
  completed,

  /// 用户手动停止或安装未验证成功
  interrupted,
}
