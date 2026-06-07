import 'diagnostic_result.dart';

abstract class DiagnosticCheck {
  String get checkId;
  String get title;
  String? get relatedTabId => null;

  /// 快速检查：纯本地I/O，<2秒
  Future<DiagnosticResult> quickCheck();

  /// 深度扫描：可能含网络请求、文件扫描
  Future<DiagnosticResult> fullScan();
}
