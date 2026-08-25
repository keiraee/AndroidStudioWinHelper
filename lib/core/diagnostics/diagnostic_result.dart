enum DiagnosticStatus { ok, warning, error }

enum IssueSeverity { info, warning, error }

enum FixRisk { safe, risky }

class DiagnosticIssue {
  final String message;
  final IssueSeverity severity;
  final FixAction? fix;

  const DiagnosticIssue({
    required this.message,
    required this.severity,
    this.fix,
  });
}

class FixAction {
  final String label;
  final FixRisk risk;
  final Future<void> Function()? execute;
  /// 若设置，点击修复时跳转到对应 Tab，而不是执行副作用
  final String? navigateTabId;

  const FixAction({
    required this.label,
    required this.risk,
    this.execute,
    this.navigateTabId,
  }) : assert(execute != null || navigateTabId != null,
            'FixAction 需要 execute 或 navigateTabId');
}

class DiagnosticResult {
  final String checkId;
  final String title;
  final DiagnosticStatus status;
  final List<DiagnosticIssue> issues;
  final String? relatedTabId;

  const DiagnosticResult({
    required this.checkId,
    required this.title,
    required this.status,
    this.issues = const [],
    this.relatedTabId,
  });

  factory DiagnosticResult.ok({
    required String checkId,
    required String title,
    String? relatedTabId,
  }) {
    return DiagnosticResult(
      checkId: checkId,
      title: title,
      status: DiagnosticStatus.ok,
      relatedTabId: relatedTabId,
    );
  }

  factory DiagnosticResult.withIssues({
    required String checkId,
    required String title,
    required List<DiagnosticIssue> issues,
    String? relatedTabId,
  }) {
    final hasError = issues.any((i) => i.severity == IssueSeverity.error);
    final hasWarning =
        issues.any((i) => i.severity == IssueSeverity.warning);
    return DiagnosticResult(
      checkId: checkId,
      title: title,
      status: hasError
          ? DiagnosticStatus.error
          : hasWarning
              ? DiagnosticStatus.warning
              : DiagnosticStatus.ok,
      issues: issues,
      relatedTabId: relatedTabId,
    );
  }
}
