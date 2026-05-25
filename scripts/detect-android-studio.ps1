param(
    [switch]$Json,
    [switch]$DeepScan,
    [string[]]$DeepScanRoots,
    [switch]$Progress
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

$ErrorActionPreference = "SilentlyContinue"
$found = @{}

function Write-DetectProgress {
    param(
        [int]$Percent,
        [string]$Message,
        [string]$Path = ""
    )

    if ($Progress) {
        [Console]::Out.WriteLine("@@PROGRESS|$Percent|$Message|$Path@@")
        [Console]::Out.Flush()
    } elseif (-not $Json) {
        if ($Path) {
            Write-Host "[$Percent%] $Message - $Path"
        } else {
            Write-Host "[$Percent%] $Message"
        }
    }
}

function Normalize-DirPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    $p = $p -replace '[\\/]+$',''
    return $p
}

function Get-ExePathFromCommand {
    param([string]$CommandText)

    if ([string]::IsNullOrWhiteSpace($CommandText)) { return $null }
    $text = $CommandText.Trim()

    if ($text -match '^\s*"([^"]+?\.exe)"') { return $Matches[1] }
    if ($text -match '^\s*([A-Za-z]:\\[^,\"]+?\.exe),\d+$') { return $Matches[1] }
    if ($text -match '^\s*([A-Za-z]:\\.*?\.exe)(\s|$)') { return $Matches[1] }

    return $null
}

function Add-InstallPath {
    param(
        [string]$InstallPath,
        [string]$Source
    )

    $path = Normalize-DirPath $InstallPath
    if (-not $path) { return }

    $exe64 = Join-Path $path "bin\studio64.exe"
    $exe32 = Join-Path $path "bin\studio.exe"
    $infoJson = Join-Path $path "product-info.json"
    $buildTxt = Join-Path $path "build.txt"

    if (-not ((Test-Path -LiteralPath $exe64) -or (Test-Path -LiteralPath $exe32) -or (Test-Path -LiteralPath $infoJson) -or (Test-Path -LiteralPath $buildTxt))) {
        return
    }

    try { $resolved = (Resolve-Path -LiteralPath $path).Path } catch { $resolved = $path }
    $key = $resolved.ToLowerInvariant()

    if (-not $found.ContainsKey($key)) {
        $found[$key] = [PSCustomObject]@{
            Path = $resolved
            Sources = New-Object System.Collections.Generic.List[string]
        }
    }

    if (-not $found[$key].Sources.Contains($Source)) {
        $found[$key].Sources.Add($Source)
    }
}

function Add-FromExePath {
    param(
        [string]$ExePath,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($ExePath)) { return }

    $exe = [Environment]::ExpandEnvironmentVariables($ExePath.Trim().Trim('"'))
    $exe = $exe -replace ',\d+$',''

    if (-not (Test-Path -LiteralPath $exe)) { return }

    $leaf = Split-Path -Path $exe -Leaf
    if ($leaf -ine "studio64.exe" -and $leaf -ine "studio.exe") { return }

    $binDir = Split-Path -Path $exe -Parent
    $installPath = Split-Path -Path $binDir -Parent
    Add-InstallPath -InstallPath $installPath -Source $Source
}

function Add-FromCommandText {
    param(
        [string]$CommandText,
        [string]$Source
    )

    $exe = Get-ExePathFromCommand $CommandText
    if ($exe) { Add-FromExePath -ExePath $exe -Source $Source }
}

function Get-Channel {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Version
    )

    $all = "$Path $Name $Version"
    if ($all -match '(?i)canary') { return "Canary" }
    if ($all -match '(?i)beta') { return "Beta" }
    if ($all -match '(?i)preview|rc') { return "Preview" }
    return "Stable/Unknown"
}

Write-DetectProgress -Percent 5 -Message "正在检测：运行中进程..."

Get-Process studio64,studio -ErrorAction SilentlyContinue | ForEach-Object {
    Add-FromExePath -ExePath $_.Path -Source "运行中进程"
}

Write-DetectProgress -Percent 15 -Message "正在检测：卸载注册表..."

$uninstallRegPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($regPath in $uninstallRegPaths) {
    Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '(?i)Android Studio' } |
    ForEach-Object {
        Add-InstallPath -InstallPath $_.InstallLocation -Source "注册表 InstallLocation"
        Add-FromCommandText -CommandText $_.DisplayIcon -Source "注册表 DisplayIcon"
        Add-FromCommandText -CommandText $_.UninstallString -Source "注册表 UninstallString"
        Add-FromCommandText -CommandText $_.QuietUninstallString -Source "注册表 QuietUninstallString"
        Add-FromCommandText -CommandText $_.ModifyPath -Source "注册表 ModifyPath"
    }
}

Write-DetectProgress -Percent 35 -Message "正在检测：App Paths 注册表..."

$appPathRegs = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\studio64.exe",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\studio.exe",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\studio64.exe",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\studio.exe"
)

foreach ($key in $appPathRegs) {
    if (Test-Path $key) {
        $item = Get-Item -Path $key
        $defaultExe = $item.GetValue("")
        $binPath = $item.GetValue("Path")

        Add-FromExePath -ExePath $defaultExe -Source "App Paths 默认值"

        if ($binPath) {
            Add-FromExePath -ExePath (Join-Path $binPath "studio64.exe") -Source "App Paths Path"
            Add-FromExePath -ExePath (Join-Path $binPath "studio.exe") -Source "App Paths Path"
        }
    }
}

Write-DetectProgress -Percent 50 -Message "正在检测：开始菜单与桌面快捷方式..."

$shortcutRoots = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
    "$env:PUBLIC\Desktop",
    "$env:USERPROFILE\Desktop"
)

$shell = New-Object -ComObject WScript.Shell

foreach ($root in $shortcutRoots) {
    if (-not (Test-Path $root)) { continue }

    Get-ChildItem -Path $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '(?i)Android Studio' } |
    ForEach-Object {
        $lnk = $shell.CreateShortcut($_.FullName)
        Add-FromExePath -ExePath $lnk.TargetPath -Source ("快捷方式 " + $_.FullName)
    }
}

Write-DetectProgress -Percent 65 -Message "正在检测：JetBrains Toolbox..."

$toolboxRoots = @(
    "$env:LOCALAPPDATA\JetBrains\Toolbox\apps\AndroidStudio",
    "$env:LOCALAPPDATA\JetBrains\Toolbox\apps"
)

foreach ($root in $toolboxRoots) {
    if (-not (Test-Path $root)) { continue }

    Get-ChildItem -Path $root -Filter studio64.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Add-FromExePath -ExePath $_.FullName -Source "JetBrains Toolbox"
    }

    Get-ChildItem -Path $root -Filter studio.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        Add-FromExePath -ExePath $_.FullName -Source "JetBrains Toolbox"
    }
}

Write-DetectProgress -Percent 75 -Message "正在检测：常见安装路径..."

$commonPaths = @(
    "C:\Program Files\Android\Android Studio",
    "C:\Program Files\Android\Android Studio Preview",
    "C:\Program Files (x86)\Android\Android Studio",
    "$env:LOCALAPPDATA\Programs\Android Studio"
)

foreach ($path in $commonPaths) {
    Add-InstallPath -InstallPath $path -Source "常见安装路径"
}

if ($DeepScan) {
    Write-DetectProgress -Percent 85 -Message "正在检测：深度扫描（耗时较长）..."

    $roots = @()
    if ($DeepScanRoots -and $DeepScanRoots.Count -gt 0) {
        $roots = $DeepScanRoots
    } else {
        $roots = (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -ExpandProperty DeviceID | ForEach-Object { "$_\" })
    }

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }

        Get-ChildItem -Path $root -Filter studio64.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Add-FromExePath -ExePath $_.FullName -Source ("深度扫描 " + $root)
        }

        Get-ChildItem -Path $root -Filter studio.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Add-FromExePath -ExePath $_.FullName -Source ("深度扫描 " + $root)
        }
    }
}

$results = @()

foreach ($entry in ($found.Values | Sort-Object Path)) {
    $path = $entry.Path
    $exe64 = Join-Path $path "bin\studio64.exe"
    $exe32 = Join-Path $path "bin\studio.exe"
    $infoPath = Join-Path $path "product-info.json"
    $buildPath = Join-Path $path "build.txt"

    $exe = if (Test-Path -LiteralPath $exe64) { $exe64 } elseif (Test-Path -LiteralPath $exe32) { $exe32 } else { "" }

    $name = ""
    $version = ""
    $build = ""

    if (Test-Path -LiteralPath $infoPath) {
        try {
            $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
            $name = "$($info.name)"
            $version = "$($info.version)"
            $build = "$($info.buildNumber)"
        } catch {}
    }

    if (-not $build -and (Test-Path -LiteralPath $buildPath)) {
        $build = (Get-Content -LiteralPath $buildPath -TotalCount 1)
    }

    $channel = Get-Channel -Path $path -Name $name -Version $version
    $sources = ($entry.Sources | Sort-Object) -join "；"

    $results += [PSCustomObject]@{
        path = $path
        executable = $exe
        name = $name
        version = $version
        build = $build
        channel = $channel
        source = $sources
        installed = $true
    }
}

Write-DetectProgress -Percent 95 -Message "正在整理检测结果..."

if ($Json) {
    Write-DetectProgress -Percent 100 -Message "检测完成"
    if ($Progress) {
        $jsonText = if ($results.Count -eq 0) { '[]' } else { @($results) | ConvertTo-Json -Depth 5 -Compress }
        [Console]::Out.WriteLine("@@RESULT|" + $jsonText + "@@")
        [Console]::Out.Flush()
    } else {
        if ($results.Count -eq 0) {
            Write-Output '[]'
        } else {
            @($results) | ConvertTo-Json -Depth 5 -Compress:$false | Write-Output
        }
    }
    if ($results.Count -eq 0) { exit 1 } else { exit 0 }
}

Write-Host ""
Write-Host "检测结果："

if ($results.Count -eq 0) {
    Write-Host "未检测到 Android Studio 安装。"
    exit 1
}

Write-Host ("共检测到 " + $results.Count + " 个安装：")
Write-Host ""

$index = 1
foreach ($r in $results) {
    Write-Host ("[" + $index + "]")
    Write-Host ("安装路径：" + $r.path)
    Write-Host ("可执行文件：" + $r.executable)
    Write-Host ("名称：" + $r.name)
    Write-Host ("版本：" + $r.version)
    Write-Host ("构建号：" + $r.build)
    Write-Host ("渠道：" + $r.channel)
    Write-Host ("检测来源：" + $r.source)
    Write-Host ""
    $index++
}

exit 0
