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
        if (lower.Contains("\\program files") && lower.Contains("android studio")) return true;
        if (lower.EndsWith("\\androidstudio")) return true;
        if (lower.Contains("\\android\\android studio")) return true;
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

        // 1) WM_SETTEXT
        SendMessage(hWnd, WM_SETTEXT, IntPtr.Zero, target);
        NotifyEditChanged(hWnd);
        if (NormalizePath(ReadText(hWnd)) == target) return true;

        // 2) 全选 + 替换（部分 NSIS/nsDialogs 只响应此项）
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

foreach ($hwnd in $windows) {
    $edits = [AswhInstallerUi]::CollectAllEdits($hwnd)

    foreach ($edit in $edits) {
        $current = [AswhInstallerUi]::ReadText($edit)
        $className = [AswhInstallerUi]::ReadClass($edit)

        if ([AswhInstallerUi]::IsInstallDirText($current)) {
            if ([string]::IsNullOrWhiteSpace($visibleInstallPath)) {
                $visibleInstallPath = $current
            }
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
}

# 二次扫描：若 Program Files 路径仍在，说明未真正改到可见框
if (-not $installVerified) {
    foreach ($hwnd in $windows) {
        foreach ($edit in [AswhInstallerUi]::CollectAllEdits($hwnd)) {
            $current = [AswhInstallerUi]::ReadText($edit)
            if ([AswhInstallerUi]::IsInstallDirText($current)) {
                $visibleInstallPath = $current
            }
        }
    }
}

@{
    foundInstallerWindow = $foundWindow
    installDirAligned = $installVerified
    installDirVerified = $installVerified
    visibleInstallPath = $visibleInstallPath
    sdkEditAligned = $sdkVerified
    userHomeEditAligned = $userVerified
    installDiagnostics = ($installDiag -join ' | ')
} | ConvertTo-Json -Compress
