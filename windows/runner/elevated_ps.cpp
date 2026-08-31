#include "elevated_ps.h"

#include <windows.h>

#include <string>
#include <vector>

namespace {

int RunHiddenPowershellFile(const std::wstring& ps1_path) {
  wchar_t powershell[MAX_PATH] = {0};
  const DWORD found = SearchPathW(nullptr, L"powershell.exe", nullptr, MAX_PATH,
                                  powershell, nullptr);
  if (found == 0 || found >= MAX_PATH) {
    return 2;
  }

  std::wstring cmd = L"powershell.exe -NoProfile -ExecutionPolicy Bypass "
                     L"-NonInteractive -WindowStyle Hidden -File \"";
  cmd += ps1_path;
  cmd += L"\"";

  std::vector<wchar_t> cmd_buf(cmd.begin(), cmd.end());
  cmd_buf.push_back(L'\0');

  STARTUPINFOW si;
  ZeroMemory(&si, sizeof(si));
  si.cb = sizeof(si);
  si.dwFlags = STARTF_USESHOWWINDOW;
  si.wShowWindow = SW_HIDE;

  PROCESS_INFORMATION pi;
  ZeroMemory(&pi, sizeof(pi));

  const BOOL ok = CreateProcessW(powershell, cmd_buf.data(), nullptr, nullptr,
                                 FALSE, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                                 nullptr, nullptr, &si, &pi);
  if (!ok) {
    const DWORD err = GetLastError();
    return err == 0 ? 3 : static_cast<int>(err);
  }

  WaitForSingleObject(pi.hProcess, INFINITE);
  DWORD exit_code = 1;
  GetExitCodeProcess(pi.hProcess, &exit_code);
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  return static_cast<int>(exit_code);
}

}  // namespace

bool TryHandleElevatedPs1Worker(int* exit_code) {
  int argc = 0;
  wchar_t** argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return false;
  }

  bool handled = false;
  int code = 1;
  for (int i = 1; i + 1 < argc; ++i) {
    if (wcscmp(argv[i], L"--aswh-elevated-ps1") == 0) {
      handled = true;
      code = RunHiddenPowershellFile(argv[i + 1]);
      break;
    }
  }
  LocalFree(argv);

  if (handled && exit_code != nullptr) {
    *exit_code = code;
  }
  return handled;
}
