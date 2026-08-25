import 'dart:convert';
import 'dart:io';

import 'package:androidstudiowinhelper/core/download/chunk_state.dart';
import 'package:androidstudiowinhelper/core/log_manager.dart';

/// `.part.meta` JSON 文件的读写工具。
///
/// 每个 `.part` 文件对应一个同名的 `.part.meta` 文件，
/// 例如 `file.exe.part` → `file.exe.part.meta`。
class MetaStore {
  MetaStore._();

  /// 获取 `.part.meta` 文件路径。
  static String _metaPath(String partPath) => '$partPath.meta';

  /// 保存元数据到 `.part.meta` 文件。
  static Future<void> save(String partPath, DownloadMeta meta) async {
    final path = _metaPath(partPath);
    try {
      final json = const JsonEncoder.withIndent('  ').convert(meta.toJson());
      await File(path).writeAsString(json, flush: true);
      LogManager.instance.write('MetaStore', '保存元数据: $path');
    } catch (e) {
      LogManager.instance.write('MetaStore', '保存元数据失败: $path, 错误: $e');
      rethrow;
    }
  }

  /// 从 `.part.meta` 文件加载元数据。
  /// 文件不存在则返回 `null`。
  static Future<DownloadMeta?> load(String partPath) async {
    final path = _metaPath(partPath);
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;

      final json = jsonDecode(content) as Map<String, dynamic>;
      LogManager.instance.write('MetaStore', '加载元数据: $path');
      return DownloadMeta.fromJson(json);
    } catch (e) {
      LogManager.instance.write('MetaStore', '加载元数据失败: $path, 错误: $e');
      return null;
    }
  }

  /// 删除 `.part.meta` 文件。
  static Future<void> delete(String partPath) async {
    final path = _metaPath(partPath);
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        LogManager.instance.write('MetaStore', '删除元数据: $path');
      }
    } catch (e) {
      LogManager.instance.write('MetaStore', '删除元数据失败: $path, 错误: $e');
    }
  }

  /// 从旧格式 `.part` 文件迁移到新格式。
  ///
  /// 旧格式使用单个 `.part` 文件（无 `.part.meta`），
  /// 此方法根据 `.part` 文件大小创建等价的元数据（单分片模式）。
  static Future<DownloadMeta> migrateFromLegacy(
    String partPath,
    String url,
  ) async {
    final partFile = File(partPath);
    final downloadedBytes =
        await partFile.exists() ? await partFile.length() : 0;

    LogManager.instance.write('MetaStore',
        '从旧格式迁移: $partPath (已下载 ${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)}MB)');

    // 旧格式不知道 totalBytes，用单分片模拟：
    // totalBytes 设为 0 表示"未知"，ChunkedDownloader 会探测服务器获取真实大小。
    // 已有的数据算作 chunk 0 的已下载部分。
    final chunk = ChunkState(
      index: 0,
      startByte: 0,
      endByte: 0, // 未知，待探测后更新
      downloadedBytes: downloadedBytes,
      status: downloadedBytes > 0 ? ChunkStatus.downloading : ChunkStatus.pending,
    );

    final meta = DownloadMeta(
      url: url,
      totalBytes: 0, // 未知，ChunkedDownloader 会探测
      chunks: [chunk],
      createdAt: DateTime.now(),
    );

    await save(partPath, meta);
    LogManager.instance.write('MetaStore', '迁移完成: $partPath');
    return meta;
  }
}
