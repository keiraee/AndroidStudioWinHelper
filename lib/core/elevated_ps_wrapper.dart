String quotePowerShellSingle(String value) =>
    "'${value.replaceAll("'", "''")}'";

/// 把 Dart 侧的 `['-Write','-RootPath','D:\\x']` 转成 PowerShell 命名参数调用片段。
/// 开关名不能加引号；仅路径等取值加引号。不能用 `@($args)` 数组 splat。
String formatPowerShellInvocationArgs(List<String> extraArgs) {
  if (extraArgs.isEmpty) return '';
  final buffer = StringBuffer();
  for (var i = 0; i < extraArgs.length; i++) {
    final arg = extraArgs[i];
    if (!arg.startsWith('-')) {
      throw ArgumentError('期望开关参数，实际为: $arg');
    }
    buffer.write(' $arg');
    final next = i + 1 < extraArgs.length ? extraArgs[i + 1] : null;
    if (next != null && !next.startsWith('-')) {
      buffer.write(' ${quotePowerShellSingle(next)}');
      i++;
    }
  }
  return buffer.toString();
}

/// 提权包装脚本：语法必须能被 PowerShell 5 解析，失败时也要写出结果文件。
String buildElevatedWrapperScript({
  required String scriptPath,
  required List<String> extraArgs,
  required String resultFile,
}) {
  final quotedScript = quotePowerShellSingle(scriptPath);
  final quotedResult = quotePowerShellSingle(resultFile);
  final invocation = extraArgs.isEmpty
      ? ' -Json -ResultFile $quotedResult'
      : formatPowerShellInvocationArgs(extraArgs);

  final buffer = StringBuffer()
    ..writeln("\$ErrorActionPreference = 'Stop'")
    ..writeln('\$ResultFile = $quotedResult')
    ..writeln('function Write-AswhError([string]\$Message) {')
    ..writeln(
      '  \$payload = @{ success = \$false; error = \$Message } | ConvertTo-Json -Compress',
    )
    ..writeln(
      '  [System.IO.File]::WriteAllText(\$ResultFile, \$payload, [System.Text.UTF8Encoding]::new(\$false))',
    )
    ..writeln('}')
    ..writeln('try {')
    ..writeln('  & $quotedScript$invocation')
    ..writeln('  if (-not (Test-Path -LiteralPath \$ResultFile)) {')
    ..writeln("    Write-AswhError 'wrapper: result file missing'")
    ..writeln('  }')
    ..writeln('} catch {')
    ..writeln('  Write-AswhError \$_.Exception.Message')
    ..writeln('}');

  return buffer.toString().replaceAll('\n', '\r\n');
}
