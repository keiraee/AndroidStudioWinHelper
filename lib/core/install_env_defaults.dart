import 'dart:io';

class InstallEnvDefaults {
  static const variables = <String>[
    'AS_INSTALL_HOME',
    'ANDROID_HOME',
    'ANDROID_USER_HOME',
    'GRADLE_USER_HOME',
  ];

  static const labels = <String, String>{
    'AS_INSTALL_HOME': 'Android Studio 安装目录',
    'ANDROID_HOME': 'Android SDK 安装目录',
    'ANDROID_USER_HOME': 'SDK 用户配置目录',
    'GRADLE_USER_HOME': 'Gradle 用户目录',
  };

  static const descriptions = <String, String>{
    'AS_INSTALL_HOME':
        '【本工具自定义】Android Studio 本体（IDE）的安装位置，便于集中管理；'
        '官方文档无此变量，Studio 本身一般不读它。',
    'ANDROID_HOME':
        '【官方】Android SDK 安装目录。很多命令行工具靠它定位 SDK；'
        '旧名 ANDROID_SDK_ROOT 已废弃。写入时会按官方建议，把其下 tools、tools\\bin、platform-tools 追加到系统 PATH。',
    'ANDROID_USER_HOME':
        '【官方】SDK 用户配置目录，本工具默认强制为 Android 根目录下的 Sdk_userhome，'
        '替代系统默认的 %USERPROFILE%\\.android，与 SDK 安装目录分开存放。',
    'GRADLE_USER_HOME':
        '【Gradle 官方】Gradle 用户目录（依赖缓存、wrapper 分发包等），默认 %USERPROFILE%\\.gradle。'
        '各 Android 项目通过 Gradle Wrapper 自带版本，无需单独安装 GRADLE_HOME。',
  };

  /// 官方建议追加到 PATH 的 ANDROID_HOME 子目录（相对路径）。
  static const pathAppendSubdirs = <String>[
    'tools',
    r'tools\bin',
    'platform-tools',
  ];

  static const pathRecommendHint = '极其推荐使用我们定制的目录，以便后续管理和集中。';

  static const pathAppendHint =
      '按官方建议，确认写入时会把 ANDROID_HOME 下的 tools、tools\\bin、platform-tools 追加到系统 PATH（不是单独环境变量）。';

  static String normalizeDriveLetter(String raw) {
    final match = RegExp(r'([A-Za-z])').firstMatch(raw.trim());
    if (match == null) {
      throw ArgumentError('无效盘符: $raw');
    }
    return match.group(1)!.toUpperCase();
  }

  static String androidRoot(String drive) {
    final letter = normalizeDriveLetter(drive);
    return '$letter:\\Android';
  }

  /// 提权写入时使用：网络映射盘走 UNC，避免 UAC 后盘符不可见。
  static String androidRootFor(InstallDriveInfo drive) {
    if (drive.driveType == 4) {
      final unc = normalizeUncRoot(drive.providerName);
      if (unc == null) {
        throw StateError(
          '网络盘 ${drive.letter}: 无法解析 UNC 路径，请改选本地磁盘。',
        );
      }
      return '$unc\\Android';
    }
    return androidRoot(drive.letter);
  }

  static Map<String, String> pathsForDrive(String drive) {
    return pathsForRoot(androidRoot(drive));
  }

  static Map<String, String> pathsFor(InstallDriveInfo drive) {
    return pathsForRoot(androidRootFor(drive));
  }

  static Map<String, String> pathsForRoot(String root) {
    return {
      'AS_INSTALL_HOME': '$root\\AndroidStudio',
      'ANDROID_HOME': '$root\\Sdk',
      'ANDROID_USER_HOME': '$root\\Sdk_userhome',
      'GRADLE_USER_HOME': '$root\\GradleRepository',
    };
  }

  /// 由 AS_INSTALL_HOME 推导 Sdk_userhome（与 pathsForRoot 一致）。
  static String? sdkUserHomeFromInstallHome(String? installHome) {
    final root = _androidRootFromInstallHome(installHome);
    if (root == null) return null;
    return '$root\\Sdk_userhome';
  }

  static String? _androidRootFromInstallHome(String? installHome) {
    if (installHome == null || installHome.trim().isEmpty) return null;
    final normalized = installHome
        .trim()
        .replaceAll('/', r'\')
        .replaceAll(RegExp(r'[\\]+$'), '');
    if (!normalized.toUpperCase().endsWith(r'\ANDROIDSTUDIO')) return null;
    return Directory(normalized).parent.path;
  }

  /// 根据 ANDROID_HOME 生成官方建议的 PATH 条目。
  static List<String> pathEntriesForAndroidHome(String androidHome) {
    final home = androidHome.trim().replaceAll(RegExp(r'[\\/]+$'), '');
    if (home.isEmpty) return const [];
    return [
      for (final sub in pathAppendSubdirs) '$home\\$sub',
    ];
  }

  static String? normalizeUncRoot(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    var path = raw.trim().replaceAll('/', r'\');
    while (path.endsWith(r'\') && path.length > 2) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.startsWith(r'\\')) return null;
    return path;
  }

  /// 解析 Win32_LogicalDisk JSON。DriveType 2=可移动，3=本地，4=网络。
  static List<InstallDriveInfo> parseLogicalDisks(Object? json) {
    final rows = <Map<String, dynamic>>[];
    if (json is List) {
      for (final e in json) {
        if (e is Map) rows.add(Map<String, dynamic>.from(e));
      }
    } else if (json is Map) {
      rows.add(Map<String, dynamic>.from(json));
    }

    final out = <InstallDriveInfo>[];
    for (final row in rows) {
      final type = _asInt(row['DriveType']);
      if (type != 2 && type != 3 && type != 4) continue;
      final id = row['DeviceID']?.toString() ?? '';
      if (id.isEmpty) continue;
      final provider = row['ProviderName']?.toString();
      out.add(
        InstallDriveInfo(
          letter: normalizeDriveLetter(id),
          freeBytes: _asInt(row['FreeSpace']),
          totalBytes: _asInt(row['Size']),
          driveType: type,
          providerName: provider == null || provider.isEmpty ? null : provider,
          kind: switch (type) {
            2 => '可移动磁盘',
            4 => '网络映射盘',
            _ => '本地磁盘',
          },
        ),
      );
    }
    out.sort((a, b) => a.letter.compareTo(b.letter));
    return out;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

class InstallDriveInfo {
  const InstallDriveInfo({
    required this.letter,
    required this.freeBytes,
    required this.totalBytes,
    required this.kind,
    this.driveType = 3,
    this.providerName,
  });

  final String letter;
  final int freeBytes;
  final int totalBytes;
  final String kind;
  final int driveType;
  final String? providerName;
}
