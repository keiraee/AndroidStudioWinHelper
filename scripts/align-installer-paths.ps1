param(
    [string]$InstallHome = '',
    [string]$AndroidHome = '',
    [string]$AndroidUserHome = '',
    [string]$WorkerConfigFile = '',
    [string]$WorkerResultFile = '',
    [string]$WorkerStopFile = '',
    [int]$WorkerIntervalMs = 350
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

public static class AswhInstallerUi {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    const int WM_SETTEXT = 0x000C;
    const int WM_COMMAND = 0x0111;
    const int EN_CHANGE = 0x0300;
    const int EM_SETSEL = 0x00B1;
    const int EM_REPLACESEL = 0x00C2;

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetDlgCtrlID(IntPtr hWnd);

    static readonly Regex DrivePath = new Regex(@"^[A-Za-z]:\\", RegexOptions.CultureInvariant);

    public static string ReadText(IntPtr hWnd) {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return string.Empty;
        var sb = new StringBuilder(len + 4);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ReadClass(IntPtr hWnd) {
        var sb = new StringBuilder(256);
        GetClassName(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static bool LooksLikeInstaller(string title, string className) {
        var t = (title ?? string.Empty).ToLowerInvariant();
        if (t.Contains("android studio")) return true;
        if (t.Contains("setup") && t.Contains("android")) return true;
        return false;
    }

    public static string NormalizePath(string value) {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        value = value.Trim().Replace('/', '\\');
        while (value.EndsWith("\\")) value = value.Substring(0, value.Length - 1);
        return value;
    }

    public static bool IsEditLike(string className) {
        if (string.IsNullOrEmpty(className)) return false;
        return className == "Edit" || className == "ComboBoxEx32" || className == "ComboBox";
    }

    public static bool IsInstallDirText(string text) {
        var lower = (text ?? string.Empty).ToLowerInvariant().Replace('/', '\\');
        if (lower.Contains("\\program files") && lower.Contains("android")) return true;
        if (lower.EndsWith("\\androidstudio")) return true;
        if (lower.Contains("\\android\\android studio")) return true;
        if (DrivePath.IsMatch(lower) && lower.Contains("android") && lower.Contains("studio")) return true;
        return false;
    }

    public static bool IsAbsoluteInstallPathCandidate(string text) {
        var norm = NormalizePath(text);
        if (string.IsNullOrEmpty(norm)) return false;
        if (!DrivePath.IsMatch(norm)) return false;
        var lower = norm.ToLowerInvariant();
        if (lower.Contains("program files")) return true;
        if (lower.Contains("androidstudio")) return true;
        if (lower.Contains("android studio")) return true;
        if (lower.Contains("\\android\\")) return true;
        return false;
    }

    static void NotifyEditChanged(IntPtr hWnd) {
        IntPtr parent = GetParent(hWnd);
        if (parent == IntPtr.Zero) return;
        int id = GetDlgCtrlID(hWnd);
        if (id == 0) return;
        SendMessage(parent, WM_COMMAND, (IntPtr)((EN_CHANGE << 16) | (id & 0xFFFF)), hWnd);
    }

    public static bool ForceWriteEdit(IntPtr hWnd, string target) {
        target = NormalizePath(target);
        if (string.IsNullOrEmpty(target)) return false;

        SendMessage(hWnd, WM_SETTEXT, IntPtr.Zero, target);
        NotifyEditChanged(hWnd);
        if (NormalizePath(ReadText(hWnd)) == target) return true;

        SendMessage(hWnd, EM_SETSEL, IntPtr.Zero, (IntPtr)(-1));
        SendMessage(hWnd, EM_REPLACESEL, (IntPtr)1, target);
        NotifyEditChanged(hWnd);
        return NormalizePath(ReadText(hWnd)) == target;
    }

    static readonly List<IntPtr> EditBuffer = new List<IntPtr>();

    static int CollectEditsCallback(IntPtr hWnd, IntPtr lParam) {
        if (!IsWindowVisible(hWnd)) return 1;
        string cls = ReadClass(hWnd);
        if (IsEditLike(cls)) EditBuffer.Add(hWnd);
        EnumChildWindows(hWnd, CollectEditsCallback, IntPtr.Zero);
        return 1;
    }

    public static List<IntPtr> CollectAllEdits(IntPtr root) {
        EditBuffer.Clear();
        EnumChildWindows(root, CollectEditsCallback, IntPtr.Zero);
        return new List<IntPtr>(EditBuffer);
    }
}
"@

function Test-SdkCandidate([string]$current) {
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    $lower = $current.ToLowerInvariant().Replace('/', '\')
    return $lower.Contains('\android\sdk') -or $lower.Contains('appdata\local\android')
}

function Test-UserHomeCandidate([string]$current) {
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    $lower = $current.ToLowerInvariant().Replace('/', '\')
    return $lower.EndsWith('\.android')
}

function Invoke-AswhAlignInstallerEdits {
    param(
        [Parameter(Mandatory = $true)][string]$InstallHome,
        [Parameter(Mandatory = $true)][string]$AndroidHome,
        [Parameter(Mandatory = $true)][string]$AndroidUserHome
    )

    $windows = New-Object System.Collections.Generic.List[IntPtr]
    $collectTop = [AswhInstallerUi+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [AswhInstallerUi]::IsWindowVisible($hWnd)) { return $true }
        $title = [AswhInstallerUi]::ReadText($hWnd)
        $className = [AswhInstallerUi]::ReadClass($hWnd)
        if ([AswhInstallerUi]::LooksLikeInstaller($title, $className)) {
            [void]$script:windows.Add($hWnd)
        }
        return $true
    }
    [AswhInstallerUi]::EnumWindows($collectTop, [IntPtr]::Zero) | Out-Null

    $installVerified = $false
    $sdkVerified = $false
    $userVerified = $false
    $installDiag = @()
    $foundWindow = $windows.Count -gt 0
    $visibleInstallPath = ''
    $installEditHandled = $false

    foreach ($hwnd in $windows) {
        $edits = [AswhInstallerUi]::CollectAllEdits($hwnd)

        foreach ($edit in $edits) {
            $current = [AswhInstallerUi]::ReadText($edit)
            $className = [AswhInstallerUi]::ReadClass($edit)

            if (-not $installEditHandled -and [AswhInstallerUi]::IsInstallDirText($current)) {
                $installEditHandled = $true
                if ([string]::IsNullOrWhiteSpace($visibleInstallPath)) { $visibleInstallPath = $current }
                $before = $current
                $verified = [AswhInstallerUi]::ForceWriteEdit($edit, $InstallHome)
                $after = [AswhInstallerUi]::ReadText($edit)
                $installDiag += "install class=$className before=$before after=$after verified=$verified"
                if ($verified) { $installVerified = $true }
            }
            elseif (Test-SdkCandidate $current) {
                $verified = [AswhInstallerUi]::ForceWriteEdit($edit, $AndroidHome)
                if ($verified) { $sdkVerified = $true }
                $installDiag += "sdk class=$className verified=$verified text=$current"
            }
            elseif (Test-UserHomeCandidate $current) {
                $verified = [AswhInstallerUi]::ForceWriteEdit($edit, $AndroidUserHome)
                if ($verified) { $userVerified = $true }
                $installDiag += "user class=$className verified=$verified text=$current"
            }
        }

        if (-not $installEditHandled) {
            foreach ($edit in $edits) {
                $current = [AswhInstallerUi]::ReadText($edit)
                $className = [AswhInstallerUi]::ReadClass($edit)
                if ([AswhInstallerUi]::IsAbsoluteInstallPathCandidate($current)) {
                    $installEditHandled = $true
                    if ([string]::IsNullOrWhiteSpace($visibleInstallPath)) { $visibleInstallPath = $current }
                    $before = $current
                    $verified = [AswhInstallerUi]::ForceWriteEdit($edit, $InstallHome)
                    $after = [AswhInstallerUi]::ReadText($edit)
                    $installDiag += "install-fallback class=$className before=$before after=$after verified=$verified"
                    if ($verified) { $installVerified = $true }
                    break
                }
            }
        }
    }

    if (-not $installVerified) {
        foreach ($hwnd in $windows) {
            foreach ($edit in [AswhInstallerUi]::CollectAllEdits($hwnd)) {
                $current = [AswhInstallerUi]::ReadText($edit)
                if ([AswhInstallerUi]::IsInstallDirText($current) -or [AswhInstallerUi]::IsAbsoluteInstallPathCandidate($current)) {
                    $visibleInstallPath = $current
                }
            }
        }
    }

    return @{
        foundInstallerWindow = $foundWindow
        installDirAligned = $installVerified
        installDirVerified = $installVerified
        visibleInstallPath = $visibleInstallPath
        sdkEditAligned = $sdkVerified
        userHomeEditAligned = $userVerified
        installDiagnostics = ($installDiag -join ' | ')
        elevatedWorker = $true
    }
}

function Write-AswhRegistryPriming {
    param([Parameter(Mandatory = $true)][string]$InstallHome)

    $result = @{
        uninstallInstallLocation = $false
        productRegistryPath = $false
        error = ''
    }
    try {
        $uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Android Studio'
        if (-not (Test-Path -LiteralPath $uninstallKey)) {
            New-Item -Path $uninstallKey -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $uninstallKey -Name 'InstallLocation' -Value $InstallHome -Type ExpandString -Force
        $result.uninstallInstallLocation = $true
    } catch {
        $result.error = $_.Exception.Message
    }
    try {
        $productKey = 'HKLM:\SOFTWARE\Android Studio'
        if (-not (Test-Path -LiteralPath $productKey)) {
            New-Item -Path $productKey -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $productKey -Name 'Path' -Value $InstallHome -Type ExpandString -Force
        $result.productRegistryPath = $true
    } catch {
        if ($result.error) { $result.error += ' | ' }
        $result.error += $_.Exception.Message
    }
    return $result
}

function Write-AswhJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )
    $json = $Object | ConvertTo-Json -Compress
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $json, $utf8)
}

if ($WorkerConfigFile -and $WorkerResultFile -and $WorkerStopFile) {
    $registryPrimed = $false
    $registryError = ''
    while (-not (Test-Path -LiteralPath $WorkerStopFile)) {
        try {
            if (-not (Test-Path -LiteralPath $WorkerConfigFile)) {
                Start-Sleep -Milliseconds $WorkerIntervalMs
                continue
            }
            $cfgRaw = Get-Content -LiteralPath $WorkerConfigFile -Raw -ErrorAction Stop
            $cfg = $cfgRaw | ConvertFrom-Json
            $installDir = [string]$cfg.installHome
            $sdk = [string]$cfg.androidHome
            $user = [string]$cfg.androidUserHome

            if ($installDir -and -not $registryPrimed) {
                $prime = Write-AswhRegistryPriming -InstallHome $installDir
                $registryPrimed = [bool]$prime.uninstallInstallLocation -or [bool]$prime.productRegistryPath
                $registryError = [string]$prime.error
            }

            if ($installDir -and $sdk -and $user) {
                $align = Invoke-AswhAlignInstallerEdits -InstallHome $installDir -AndroidHome $sdk -AndroidUserHome $user
                $align.registryPrimed = $registryPrimed
                $align.registryError = $registryError
                Write-AswhJsonFile -Path $WorkerResultFile -Object $align
            }
        } catch {
            Write-AswhJsonFile -Path $WorkerResultFile -Object @{
                foundInstallerWindow = $false
                installDirVerified = $false
                visibleInstallPath = ''
                installDiagnostics = $_.Exception.Message
                elevatedWorker = $true
                workerError = $_.Exception.Message
            }
        }
        Start-Sleep -Milliseconds $WorkerIntervalMs
    }
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InstallHome) -or [string]::IsNullOrWhiteSpace($AndroidHome) -or [string]::IsNullOrWhiteSpace($AndroidUserHome)) {
    throw 'InstallHome, AndroidHome, AndroidUserHome are required in single-shot mode.'
}

$result = Invoke-AswhAlignInstallerEdits -InstallHome $InstallHome -AndroidHome $AndroidHome -AndroidUserHome $AndroidUserHome
$result.elevatedWorker = $false
$result | ConvertTo-Json -Compress
