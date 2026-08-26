class ScanProgress {
  const ScanProgress({
    required this.percent,
    required this.message,
    this.path = '',
  });

  final int percent;
  final String message;
  final String path;
}
