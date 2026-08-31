import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int _seeMaskNocloseprocess = 0x00000040;
const int _seeMaskNoasync = 0x00000100;
const int _swHide = 0;
const int _errorCancelled = 1223;
const int _waitObject0 = 0;
const int _waitTimeout = 258;
const int _infinite = 0xFFFFFFFF;

final class _ShellExecuteInfoW extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int fMask;
  @IntPtr()
  external int hwnd;
  external Pointer<Utf16> lpVerb;
  external Pointer<Utf16> lpFile;
  external Pointer<Utf16> lpParameters;
  external Pointer<Utf16> lpDirectory;
  @Int32()
  external int nShow;
  @IntPtr()
  external int hInstApp;
  @IntPtr()
  external int lpIDList;
  external Pointer<Utf16> lpClass;
  @IntPtr()
  external int hKeyClass;
  @Uint32()
  external int dwHotKey;
  @IntPtr()
  external int hIcon;
  @IntPtr()
  external int hProcess;
}

typedef _ShellExecuteExWNative = Int32 Function(Pointer<_ShellExecuteInfoW>);
typedef _ShellExecuteExWDart = int Function(Pointer<_ShellExecuteInfoW>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
typedef _WaitForSingleObjectNative = Uint32 Function(IntPtr, Uint32);
typedef _WaitForSingleObjectDart = int Function(int, int);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _GetExitCodeProcessNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetExitCodeProcessDart = int Function(int, Pointer<Uint32>);
typedef _TerminateProcessNative = Int32 Function(IntPtr, Uint32);
typedef _TerminateProcessDart = int Function(int, int);

class WindowsElevateResult {
  const WindowsElevateResult({
    required this.cancelled,
    required this.exitCode,
    this.error = '',
  });

  final bool cancelled;
  final int exitCode;
  final String error;
}

String quoteWindowsArg(String value) {
  if (value.isEmpty) return '""';
  if (!value.contains(RegExp(r'[\s"]'))) return value;
  final escaped = value.replaceAll('"', r'\"');
  return '"$escaped"';
}

String windowsPowerShellExe() {
  final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final path = '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  if (File(path).existsSync()) return path;
  return 'powershell.exe';
}

/// 用 runas 启动隐藏窗口进程并等待退出。
/// 系统会显示标准 UAC 同意界面；用户取消时 [WindowsElevateResult.cancelled] 为 true。
WindowsElevateResult runElevatedWorker({
  required String executable,
  required String parameters,
  Duration timeout = const Duration(seconds: 15),
}) {
  if (!Platform.isWindows) {
    throw UnsupportedError('仅支持 Windows。');
  }

  final shell32 = DynamicLibrary.open('shell32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final shellExecuteEx = shell32
      .lookupFunction<_ShellExecuteExWNative, _ShellExecuteExWDart>(
        'ShellExecuteExW',
      );
  final getLastError = kernel32
      .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  final waitForSingleObject = kernel32
      .lookupFunction<_WaitForSingleObjectNative, _WaitForSingleObjectDart>(
        'WaitForSingleObject',
      );
  final closeHandle = kernel32
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
  final getExitCodeProcess = kernel32
      .lookupFunction<_GetExitCodeProcessNative, _GetExitCodeProcessDart>(
        'GetExitCodeProcess',
      );
  final terminateProcess = kernel32
      .lookupFunction<_TerminateProcessNative, _TerminateProcessDart>(
        'TerminateProcess',
      );

  final info = calloc<_ShellExecuteInfoW>();
  final verb = 'runas'.toNativeUtf16();
  final file = executable.toNativeUtf16();
  final params = parameters.toNativeUtf16();
  try {
    info.ref.cbSize = sizeOf<_ShellExecuteInfoW>();
    info.ref.fMask = _seeMaskNocloseprocess | _seeMaskNoasync;
    info.ref.hwnd = 0;
    info.ref.lpVerb = verb;
    info.ref.lpFile = file;
    info.ref.lpParameters = params;
    info.ref.lpDirectory = nullptr;
    info.ref.nShow = _swHide;

    final ok = shellExecuteEx(info) != 0;
    if (!ok) {
      final err = getLastError();
      if (err == _errorCancelled) {
        return WindowsElevateResult(cancelled: true, exitCode: err);
      }
      return WindowsElevateResult(
        cancelled: false,
        exitCode: err,
        error: '无法请求管理员权限（错误 $err）。',
      );
    }

    final process = info.ref.hProcess;
    if (process == 0) {
      return const WindowsElevateResult(
        cancelled: false,
        exitCode: 1,
        error: '提权进程已启动但无法等待完成。',
      );
    }

    try {
      final waitMs = timeout.inMilliseconds < 0
          ? _infinite
          : timeout.inMilliseconds;
      final wait = waitForSingleObject(process, waitMs);
      if (wait == _waitTimeout) {
        terminateProcess(process, 1);
        return WindowsElevateResult(
          cancelled: false,
          exitCode: 1,
          error: '操作超时（${timeout.inSeconds}s）：提权脚本未完成。',
        );
      }
      if (wait != _waitObject0) {
        return WindowsElevateResult(
          cancelled: false,
          exitCode: wait,
          error: '等待提权进程失败（$wait）。',
        );
      }

      final codePtr = calloc<Uint32>();
      try {
        if (getExitCodeProcess(process, codePtr) == 0) {
          return const WindowsElevateResult(
            cancelled: false,
            exitCode: 1,
            error: '无法读取提权进程退出码。',
          );
        }
        return WindowsElevateResult(cancelled: false, exitCode: codePtr.value);
      } finally {
        calloc.free(codePtr);
      }
    } finally {
      closeHandle(process);
    }
  } finally {
    calloc.free(verb);
    calloc.free(file);
    calloc.free(params);
    calloc.free(info);
  }
}
