# 设计：多线程分片下载 + 智能重试

## 背景

当前 `DownloadManager` 使用单线程流式下载，速度约 3-4 MB/s。用户网络环境（中国）连接 `edgedl.me.gvt1.com`（Google CDN）经常超时或中断。需要：

1. 多线程分片下载提升速度
2. 智能重试减少手动操作
3. 分片级续传提升恢复效率

## 架构

```
DownloadManager (编排层)
├── ChunkedDownloader (分片下载器)
│   ├── SpeedProber → 探测带宽，决定分片数
│   ├── ChunkScheduler → 分配 byte ranges，管理并发
│   └── ChunkWriter → 分片写入文件对应 offset
├── RetryEngine (智能重试)
│   ├── ErrorClassifier → 错误类型分类
│   └── StrategySelector → 选择重试策略
└── DownloadTask (数据模型，扩展)
    ├── chunks: List<ChunkState>
    └── retryState: RetryState
```

### 组件职责

- **DownloadManager**：编排层，协调下载流程，管理任务生命周期。不直接操作 HTTP。
- **ChunkedDownloader**：分片下载核心。探测带宽、切分文件、并发下载、合并校验。
- **RetryEngine**：智能重试。根据错误类型选择重试策略，管理重试计数和间隔。
- **DownloadTask**：数据模型。扩展分片状态和重试状态。

## 分片下载机制

### 自适应分片流程

1. `HEAD` 请求获取文件大小（`Content-Length`）
2. 探测阶段：用 2 个连接下载前 2MB，测量带宽
3. 根据带宽决定分片数：
   - < 2 MB/s → 2 个分片
   - 2-5 MB/s → 4 个分片
   - 5-10 MB/s → 8 个分片
   - > 10 MB/s → 16 个分片
4. 按分片数切分 byte range，启动并发下载
5. 每个分片用 `RandomAccessFile` 写入文件对应 offset（`setPosition` + `writeFrom`），无需合并步骤
6. 全部分片完成后，做 MZ 头校验 + SHA256

### 分片状态模型

```dart
class ChunkState {
  final int index;           // 分片序号
  final int startByte;       // 起始字节
  final int endByte;         // 结束字节（含）
  final int downloadedBytes; // 已下载字节
  final ChunkStatus status;  // pending/downloading/completed/failed
  final int retryCount;      // 重试次数
  final String? lastError;   // 最近错误信息
}

enum ChunkStatus { pending, downloading, completed, failed }
```

### 存储格式

旧格式（单文件流式追加）：
```
android-studio-xxx.exe.part      ← 二进制数据
```

新格式（分片 + 元数据）：
```
android-studio-xxx.exe.part      ← 预分配数据文件（稀疏文件）
android-studio-xxx.exe.part.meta ← JSON 元数据
```

`.part.meta` 内容：
```json
{
  "version": 2,
  "url": "https://edgedl.me.gvt1.com/...",
  "totalBytes": 1486269688,
  "chunkCount": 4,
  "chunks": [
    {"index": 0, "start": 0, "end": 371567421, "downloaded": 371567422, "status": "completed"},
    {"index": 1, "start": 371567422, "end": 743134843, "downloaded": 500000000, "status": "downloading"},
    {"index": 2, "start": 743134844, "end": 1114702265, "downloaded": 0, "status": "pending"},
    {"index": 3, "start": 1114702266, "end": 1486269687, "downloaded": 0, "status": "pending"}
  ],
  "createdAt": "2026-06-04T20:09:54Z"
}
```

### 向后兼容

检测到旧格式 `.part` 文件（无 `.part.meta`）时，自动转换：整个文件作为单个分片（`index: 0, start: 0, end: fileSize-1, downloaded: fileSize, status: completed`），后续下载使用新格式。

## 智能重试引擎

### 错误分类与策略

| 错误类型 | 判断条件 | 重试间隔 | 最大次数 |
|---------|---------|---------|---------|
| 超时 | `TimeoutException` / `SocketException` | 2s → 4s → 8s → 16s → 32s | 5 |
| 服务端错误 | HTTP 5xx | 5s → 15s → 30s → 60s | 4 |
| 连接重置 | `Connection reset by peer` | 1s → 2s → 4s → 8s → 16s | 5 |
| 限流 | HTTP 429 | 读 `Retry-After` 头，或 30s → 60s | 3 |
| 客户端错误 | HTTP 4xx (非 429) | **不重试** | 0 |
| DNS 失败 | `Failed host lookup` | 10s → 30s → 60s | 3 |

### 重试范围

以**分片**为单位重试。分片 A 超时只重试分片 A，分片 B/C 继续下载。

### 重试行为

1. 分片失败 → 标记为 `failed`，记录已下载字节和错误信息
2. 等待重试间隔（根据错误类型）
3. 用 `Range: bytes=<已下载>-<结束>` 重新请求该分片
4. 从断点继续写入对应 offset

## DownloadTask 模型扩展

```dart
class DownloadTask {
  // 现有字段保留
  final String versionKey;
  final String url;
  final String fileName;
  final String filePath;
  final DownloadState state;
  final int totalBytes;
  final int downloadedBytes;
  final int speedBytesPerSec;
  final String errorMessage;
  final DateTime? startTime;

  // 新增字段
  final List<ChunkState> chunks;      // 分片状态列表
  final int chunkCount;               // 总分片数
  final int completedChunks;          // 已完成分片数
  final RetryState? retryState;       // 当前重试状态
}

class RetryState {
  final int currentRetry;      // 当前第几次重试
  final int maxRetries;        // 最大重试次数
  final String lastError;      // 最近一次错误
  final DateTime? nextRetryAt; // 下次重试时间
  final String errorType;      // 错误类型标识
}
```

## UI 变化

### DownloadProgressCard

下载中状态新增分片信息：
```
████████████████░░░░░░░░  67%
945.2 MB / 1415.4 MB    3.6 MB/s
分片: 3/4 完成 · 重试: 0 次        ← 新增

[暂停]  [取消]
```

重试状态显示：
```
████████████░░░░░░░░░░░░  48%
分片 2 失败: 连接超时
自动重试中... (2/5)  4秒后重试      ← 新增

[暂停]  [取消]
```

其他状态（idle、connecting、completed、paused、error）UI 不变。

## 实施计划

### 阶段 1：RetryEngine
- 新增 `lib/core/retry_engine.dart`
- 实现错误分类器和策略选择器
- 单元测试：各错误类型的重试策略

### 阶段 2：ChunkedDownloader
- 新增 `lib/core/chunked_downloader.dart`
- 实现带宽探测、分片调度、并发下载、分片写入
- 扩展 `DownloadTask` 和 `ChunkState` 模型
- 实现 `.part.meta` 读写

### 阶段 3：集成到 DownloadManager
- 重构 `DownloadManager.start()` 使用 `ChunkedDownloader`
- 实现向后兼容（旧 `.part` 文件转换）
- 暂停/取消操作适配分片模式

### 阶段 4：UI 更新
- 更新 `DownloadProgressCard` 显示分片进度和重试状态
- 更新 `DownloadTab` 的进度日志

## 范围外

- 下载队列（后续功能）
- 下载速度限制
- 分片级 hash 校验（只做文件级 SHA256）
- 跨平台支持（仅 Windows）
