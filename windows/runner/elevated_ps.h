#ifndef RUNNER_ELEVATED_PS_H_
#define RUNNER_ELEVATED_PS_H_

// If this process was launched as --aswh-elevated-ps1 <file>, run that
// PowerShell file with no console window and return true with an exit code.
bool TryHandleElevatedPs1Worker(int* exit_code);

#endif  // RUNNER_ELEVATED_PS_H_
