import 'dart:async';
import 'package:androidstudiowinhelper/core/log_manager.dart';
import 'diagnostic_check.dart';
import 'diagnostic_result.dart';

class DiagnosticOrchestrator {
  final List<DiagnosticCheck> _checks;
  final LogManager _log;

  DiagnosticOrchestrator({
    required List<DiagnosticCheck> checks,
    LogManager? log,
  })  : _checks = checks,
        _log = log ?? LogManager.instance;

  List<DiagnosticCheck> get checks => List.unmodifiable(_checks);

  /// 启动快速检查：并行执行所有check的quickCheck
  Future<List<DiagnosticResult>> runQuickCheck() async {
    _log.write('Diag', 'Starting quick check (${_checks.length} checks)');
    final results = await Future.wait(
      _checks.map((c) async {
        try {
          return await c.quickCheck().timeout(
            const Duration(seconds: 5),
            onTimeout: () => DiagnosticResult(
              checkId: c.checkId,
              title: c.title,
              status: DiagnosticStatus.warning,
              issues: [
                DiagnosticIssue(
                  message: '快速检查超时',
                  severity: IssueSeverity.warning,
                ),
              ],
            ),
          );
        } catch (e) {
          _log.write('Diag', 'Quick check failed: ${c.checkId} - $e');
          return DiagnosticResult(
            checkId: c.checkId,
            title: c.title,
            status: DiagnosticStatus.warning,
            issues: [
              DiagnosticIssue(
                message: '检查失败: $e',
                severity: IssueSeverity.warning,
              ),
            ],
          );
        }
      }),
    );
    _log.write('Diag', 'Quick check done: ${results.where((r) => r.status != DiagnosticStatus.ok).length} issues');
    return results;
  }

  /// 深度扫描：串行执行，通过Stream逐个产出结果
  Stream<DiagnosticResult> runFullScan() async* {
    _log.write('Diag', 'Starting full scan (${_checks.length} checks)');
    for (final check in _checks) {
      try {
        _log.write('Diag', 'Running full scan: ${check.checkId}');
        final result = await check.fullScan().timeout(
          const Duration(seconds: 30),
          onTimeout: () => DiagnosticResult(
            checkId: check.checkId,
            title: check.title,
            status: DiagnosticStatus.warning,
            issues: [
              DiagnosticIssue(
                message: '深度扫描超时',
                severity: IssueSeverity.warning,
              ),
            ],
          ),
        );
        yield result;
      } catch (e) {
        _log.write('Diag', 'Full scan failed: ${check.checkId} - $e');
        yield DiagnosticResult(
          checkId: check.checkId,
          title: check.title,
          status: DiagnosticStatus.warning,
          issues: [
            DiagnosticIssue(
              message: '扫描失败: $e',
              severity: IssueSeverity.warning,
            ),
          ],
        );
      }
    }
    _log.write('Diag', 'Full scan complete');
  }
}
