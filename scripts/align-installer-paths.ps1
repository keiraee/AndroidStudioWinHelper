param(
    [Parameter(Mandatory = $true)]
    [string]$InstallHome,

    [Parameter(Mandatory = $true)]
    [string]$AndroidHome,

    [Parameter(Mandatory = $true)]
    [string]$AndroidUserHome
)

$ErrorActionPreference = 'Stop'

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class AswhInstallerUi {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr hWnd, EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool SetWindowText(IntPtr hWnd, string lpString);

    public static string ReadText(IntPtr hWnd) {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return string.Empty;
        var sb = new StringBuilder(len + 2);
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
        var c = (className ?? string.Empty).ToLowerInvariant();
        if (t.Contains("android studio")) return true;
        if (t.Contains("setup") && t.Contains("android")) return true;
        if (c == "#32770" && (t.Contains("install") || t.Contains("android") || t.Contains("setup"))) return true;
        return false;
    }

    public static string NormalizePath(string value) {
        if (string.IsNullOrWhiteSpace(value)) return string.Empty;
        value = value.Trim().Replace('/', '\\');
        while (value.EndsWith("\\")) value = value.Substring(0, value.Length - 1);
        return value;
    }

    public static bool TryWritePath(IntPtr hWnd, string target, out string before, out string after, out bool setOk) {
        before = ReadText(hWnd);
        after = before;
        setOk = false;
        target = NormalizePath(target);
        if (string.IsNullOrEmpty(target)) return false;
        var current = NormalizePath(before);
        if (current == target) {
            after = before;
            return true;
        }
        setOk = SetWindowText(hWnd, target);
        after = ReadText(hWnd);
        return NormalizePath(after) == target;
    }
}
"@

function Test-InstallDirCandidate([string]$current) {
    if ([string]::IsNullOrWhiteSpace($current)) { return $false }
    $lower = $current.ToLowerInvariant().Replace('/', '\')
    if ($lower.Contains('\program files') -and $lower.Contains('android studio')) { return $true }
    if ($lower.EndsWith('\androidstudio')) { return $true }
    if ($lower.Contains('\android\android studio')) { return $true }
    return $false
}

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

$installAttempted = $false
$installVerified = $false
$sdkAttempted = $false
$sdkVerified = $false
$userAttempted = $false
$userVerified = $false
$installDiag = @()
$foundWindow = $windows.Count -gt 0

foreach ($hwnd in $windows) {
    $editList = New-Object 'System.Collections.Generic.List[IntPtr]'
    $childProc = [AswhInstallerUi+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [AswhInstallerUi]::IsWindowVisible($hWnd)) { return $true }
        $className = [AswhInstallerUi]::ReadClass($hWnd)
        if ($className -ne 'Edit' -and $className -ne 'ComboBoxEx32') { return $true }
        [void]$editList.Add($hWnd)
        return $true
    }
    [AswhInstallerUi]::EnumChildWindows($hwnd, $childProc, [IntPtr]::Zero) | Out-Null

    foreach ($edit in $editList) {
        $current = [AswhInstallerUi]::ReadText($edit)
        $className = [AswhInstallerUi]::ReadClass($edit)
        $before = $null
        $after = $null
        $setOk = $false
        $verified = $false

        if (Test-InstallDirCandidate $current) {
            $installAttempted = $true
            $verified = [AswhInstallerUi]::TryWritePath($edit, $InstallHome, [ref]$before, [ref]$after, [ref]$setOk)
            if ($verified) { $installVerified = $true }
            $installDiag += "installEdit class=$className before=$before after=$after setOk=$setOk verified=$verified"
        }
        elseif (($current.ToLowerInvariant().Replace('/', '\')).Contains('\android\sdk') -or ($current.ToLowerInvariant().Replace('/', '\')).Contains('appdata\local\android')) {
            $sdkAttempted = $true
            $verified = [AswhInstallerUi]::TryWritePath($edit, $AndroidHome, [ref]$before, [ref]$after, [ref]$setOk)
            if ($verified) { $sdkVerified = $true }
        }
        elseif (($current.ToLowerInvariant().Replace('/', '\')).EndsWith('\.android')) {
            $userAttempted = $true
            $verified = [AswhInstallerUi]::TryWritePath($edit, $AndroidUserHome, [ref]$before, [ref]$after, [ref]$setOk)
            if ($verified) { $userVerified = $true }
        }
    }

    $installCandidates = @($editList | Where-Object {
        Test-InstallDirCandidate ([AswhInstallerUi]::ReadText($_))
    })
    if (-not $installVerified -and $installCandidates.Count -gt 0) {
        $edit = $installCandidates[0]
        $installAttempted = $true
        $before = $null
        $after = $null
        $setOk = $false
        $verified = [AswhInstallerUi]::TryWritePath($edit, $InstallHome, [ref]$before, [ref]$after, [ref]$setOk)
        if ($verified) { $installVerified = $true }
        $installDiag += "candidateEdit before=$before after=$after setOk=$setOk verified=$verified"
    }
    elseif (-not $installVerified -and $editList.Count -eq 1) {
        $edit = $editList[0]
        $installAttempted = $true
        $before = $null
        $after = $null
        $setOk = $false
        $verified = [AswhInstallerUi]::TryWritePath($edit, $InstallHome, [ref]$before, [ref]$after, [ref]$setOk)
        if ($verified) { $installVerified = $true }
        $installDiag += "singleEdit before=$before after=$after setOk=$setOk verified=$verified"
    }
    elseif ($editList.Count -eq 2) {
        if (-not $sdkVerified) {
            $sdkAttempted = $true
            $before = $null; $after = $null; $setOk = $false
            if ([AswhInstallerUi]::TryWritePath($editList[0], $AndroidHome, [ref]$before, [ref]$after, [ref]$setOk)) {
                $sdkVerified = $true
            }
        }
        if (-not $userVerified) {
            $userAttempted = $true
            $before = $null; $after = $null; $setOk = $false
            if ([AswhInstallerUi]::TryWritePath($editList[1], $AndroidUserHome, [ref]$before, [ref]$after, [ref]$setOk)) {
                $userVerified = $true
            }
        }
    }
}

@{
    foundInstallerWindow = $foundWindow
    installDirAligned = $installVerified
    installDirVerified = $installVerified
    installDirAttempted = $installAttempted
    sdkEditAligned = $sdkVerified
    userHomeEditAligned = $userVerified
    installDiagnostics = ($installDiag -join ' | ')
} | ConvertTo-Json -Compress
