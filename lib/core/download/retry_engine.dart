import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:androidstudiowinhelper/core/log_manager.dart';

// ── 错误分类 ──

/// 错误分类，用于决定重试策略。
enum ErrorCategory {
  /// TimeoutException / SocketException (超时)
  timeout,

  /// HTTP 5xx (服务器错误)
  serverError,

  /// Connection reset by peer (连接被重置)
  connectionReset,

  /// HTTP 429 (请求过多)
  rateLimited,

  /// HTTP 4xx (非 429) -> 不重试
  clientError,

  /// Failed host lookup (DNS 解析失败)
  dnsFailure,

  /// 其他未知错误
  unknown,
}

// ── 重试配置 ──

/// 单类错误的重试配置。
class RetryConfig {
  final Duration delay;
  final int maxRetries;

  const RetryConfig({required this.delay, required this.maxRetries});
}

// ── 重试决策 ──

/// 重试决策结果。
class RetryDecision {
  final bool shouldRetry;
  final Duration delay;
  final int attemptNumber;
  final int maxRetries;
  final ErrorCategory category;
  final String reason;

  const RetryDecision({
    required this.shouldRetry,
    required this.delay,
    required this.attemptNumber,
    required this.maxRetries,
    required this.category,
    required this.reason,
  });
}

// ── 重试引擎 ──

/// 智能重试引擎，根据错误类型选择不同的重试策略。
///
/// 每个下载分片应持有独立的 RetryEngine 实例以追踪各自的重试状态。
class RetryEngine {
  RetryEngine();

  static final Random _random = Random();

  // ── 策略表 ──

  static const Map<ErrorCategory, RetryConfig> _configs = {
    ErrorCategory.timeout: RetryConfig(delay: Duration(seconds: 2), maxRetries: 5),
    ErrorCategory.serverError: RetryConfig(delay: Duration(seconds: 5), maxRetries: 4),
    ErrorCategory.connectionReset: RetryConfig(delay: Duration(seconds: 1), maxRetries: 5),
    ErrorCategory.rateLimited: RetryConfig(delay: Duration(seconds: 30), maxRetries: 3),
    ErrorCategory.clientError: RetryConfig(delay: Duration.zero, maxRetries: 0),
    ErrorCategory.dnsFailure: RetryConfig(delay: Duration(seconds: 10), maxRetries: 3),
    ErrorCategory.unknown: RetryConfig(delay: Duration(seconds: 5), maxRetries: 3),
  };

  // ── 错误分类 ──

  /// 根据错误对象和 HTTP 状态码分类错误。
  static ErrorCategory classify(Object error, int? httpStatusCode) {
    // 优先按 HTTP 状态码分类
    if (httpStatusCode != null) {
      if (httpStatusCode == 429) return ErrorCategory.rateLimited;
      if (httpStatusCode >= 500) return ErrorCategory.serverError;
      if (httpStatusCode >= 400) return ErrorCategory.clientError;
    }

    // 按异常类型分类
    if (error is TimeoutException) {
      return ErrorCategory.timeout;
    }

    if (error is SocketException) {
      final message = error.message.toLowerCase();
      // DNS 解析失败
      if (message.contains('failed host lookup') ||
          message.contains('nodename nor servname provided') ||
          message.contains('no address associated with hostname')) {
        return ErrorCategory.dnsFailure;
      }
      // 连接被重置
      if (message.contains('connection reset') ||
          message.contains('connection refused')) {
        return ErrorCategory.connectionReset;
      }
      // 其他 SocketException 归类为超时/网络问题
      return ErrorCategory.timeout;
    }

    // 检查是否是 HttpException（来自 dart:io）
    if (error is HttpException) {
      final message = error.message.toLowerCase();
      if (message.contains('connection reset') ||
          message.contains('connection closed')) {
        return ErrorCategory.connectionReset;
      }
      return ErrorCategory.serverError;
    }

    // 字符串匹配兜底
    final errorStr = error.toString().toLowerCase();
    if (errorStr.contains('connection reset') ||
        errorStr.contains('connection abort')) {
      return ErrorCategory.connectionReset;
    }
    if (errorStr.contains('failed host lookup') ||
        errorStr.contains('dns')) {
      return ErrorCategory.dnsFailure;
    }
    if (errorStr.contains('timeout') ||
        errorStr.contains('timed out')) {
      return ErrorCategory.timeout;
    }

    return ErrorCategory.unknown;
  }

  // ── 获取重试配置 ──

  /// 获取某类错误的重试配置。
  static RetryConfig configFor(ErrorCategory category) {
    return _configs[category] ?? _configs[ErrorCategory.unknown]!;
  }

  // ── 退避延迟 ──

  /// 计算退避延迟（指数退避 + 随机抖动）。
  ///
  /// 公式: `delay = baseDelay * 2^attempt + random(0, 1000)ms`
  static Duration backoffDelay(int attempt, Duration baseDelay) {
    final multiplier = 1 << attempt; // 2^attempt
    final baseMs = baseDelay.inMilliseconds * multiplier;
    final jitterMs = _random.nextInt(1001); // 0~1000ms
    return Duration(milliseconds: baseMs + jitterMs);
  }

  // ── 重试决策 ──

  /// 综合判断是否应该重试，返回决策结果。
  ///
  /// [error] 原始异常对象。
  /// [httpStatusCode] HTTP 响应状态码（可选）。
  /// [currentRetry] 当前已重试次数（从 0 开始）。
  /// [retryAfterHeader] HTTP 429 响应的 Retry-After 头值（秒数，可选）。
  static RetryDecision shouldRetry(
    Object error,
    int? httpStatusCode,
    int currentRetry, {
    int? retryAfterHeader,
  }) {
    final category = classify(error, httpStatusCode);
    final config = configFor(category);

    // 不重试的类别
    if (config.maxRetries == 0) {
      final decision = RetryDecision(
        shouldRetry: false,
        delay: Duration.zero,
        attemptNumber: currentRetry,
        maxRetries: 0,
        category: category,
        reason: '错误类型 ${category.name} 不支持重试',
      );
      LogManager.instance.write(
        'RetryEngine',
        '决策: 不重试 | 类型=${category.name} | 原因=${decision.reason}',
      );
      return decision;
    }

    // 已达最大重试次数
    if (currentRetry >= config.maxRetries) {
      final decision = RetryDecision(
        shouldRetry: false,
        delay: Duration.zero,
        attemptNumber: currentRetry,
        maxRetries: config.maxRetries,
        category: category,
        reason: '已达最大重试次数 ${config.maxRetries}',
      );
      LogManager.instance.write(
        'RetryEngine',
        '决策: 不重试 | 类型=${category.name} | '
            '次数=$currentRetry/${config.maxRetries} | 原因=${decision.reason}',
      );
      return decision;
    }

    // 计算延迟
    Duration delay;

    // 429 特殊处理：优先使用 Retry-After 头
    if (category == ErrorCategory.rateLimited && retryAfterHeader != null && retryAfterHeader > 0) {
      delay = Duration(seconds: retryAfterHeader);
      LogManager.instance.write(
        'RetryEngine',
        '使用 Retry-After 头值: ${retryAfterHeader}s',
      );
    } else {
      delay = backoffDelay(currentRetry, config.delay);
    }

    final decision = RetryDecision(
      shouldRetry: true,
      delay: delay,
      attemptNumber: currentRetry + 1,
      maxRetries: config.maxRetries,
      category: category,
      reason: '${category.name} 错误，第 ${currentRetry + 1}/${config.maxRetries} 次重试，'
          '等待 ${delay.inMilliseconds}ms',
    );

    LogManager.instance.write(
      'RetryEngine',
      '决策: 重试 | 类型=${category.name} | '
          '次数=${currentRetry + 1}/${config.maxRetries} | '
          '延迟=${delay.inMilliseconds}ms | 原因=$error',
    );

    return decision;
  }

  // ── 等待重试 ──

  /// 等待指定的重试延迟时间，期间输出日志。
  static Future<void> waitBeforeRetry(RetryDecision decision) async {
    if (!decision.shouldRetry || decision.delay == Duration.zero) return;

    LogManager.instance.write(
      'RetryEngine',
      '等待重试: ${decision.delay.inMilliseconds}ms '
          '(类型=${decision.category.name}, '
          '第 ${decision.attemptNumber}/${decision.maxRetries} 次)',
    );

    await Future<void>.delayed(decision.delay);

    LogManager.instance.write(
      'RetryEngine',
      '等待结束，开始第 ${decision.attemptNumber} 次重试',
    );
  }
}
