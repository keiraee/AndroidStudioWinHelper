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

    public static bool WriteIfDifferent(IntPtr hWnd, string target) {
        target = NormalizePath(target);
        if (string.IsNullOrEmpty(target)) return false;
        var current = NormalizePath(ReadText(hWnd));
        if (current == target) return true;
        return SetWindowText(hWnd, target);
    }
}
"@

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

$installAligned = $false
$sdkAligned = $false
$userAligned = $false
$foundWindow = $windows.Count -gt 0

foreach ($hwnd in $windows) {
    $editList = New-Object 'System.Collections.Generic.List[IntPtr]'
    $childProc = [AswhInstallerUi+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        if (-not [AswhInstallerUi]::IsWindowVisible($hWnd)) { return $true }
        if ([AswhInstallerUi]::ReadClass($hWnd) -ne 'Edit') { return $true }
        [void]$editList.Add($hWnd)
        return $true
    }
    [AswhInstallerUi]::EnumChildWindows($hwnd, $childProc, [IntPtr]::Zero) | Out-Null

    foreach ($edit in $editList) {
        $current = [AswhInstallerUi]::ReadText($edit).ToLowerInvariant().Replace('/', '\')
        if ($current.Contains('\program files') -and $current.Contains('android studio')) {
            if ([AswhInstallerUi]::WriteIfDifferent($edit, $InstallHome)) { $installAligned = $true }
        }
        elseif ($current.EndsWith('\androidstudio') -or $current.Contains('\android\android studio')) {
            if ([AswhInstallerUi]::WriteIfDifferent($edit, $InstallHome)) { $installAligned = $true }
        }
        elseif ($current.Contains('\android\sdk') -or $current.Contains('appdata\local\android')) {
            if ([AswhInstallerUi]::WriteIfDifferent($edit, $AndroidHome)) { $sdkAligned = $true }
        }
        elseif ($current.EndsWith('\.android') -or $current.Contains('\.android\\')) {
            if ([AswhInstallerUi]::WriteIfDifferent($edit, $AndroidUserHome)) { $userAligned = $true }
        }
    }

    if ($editList.Count -eq 1) {
        if ([AswhInstallerUi]::WriteIfDifferent($editList[0], $InstallHome)) { $installAligned = $true }
    }
    elseif ($editList.Count -eq 2) {
        if ([AswhInstallerUi]::WriteIfDifferent($editList[0], $AndroidHome)) { $sdkAligned = $true }
        if ([AswhInstallerUi]::WriteIfDifferent($editList[1], $AndroidUserHome)) { $userAligned = $true }
    }
}

@{
    foundInstallerWindow = $foundWindow
    installDirAligned = $installAligned
    sdkEditAligned = $sdkAligned
    userHomeEditAligned = $userAligned
} | ConvertTo-Json -Compress
