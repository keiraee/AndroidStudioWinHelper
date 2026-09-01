param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$InstallHome,

    [string]$AndroidHome = '',
    [string]$AndroidUserHome = '',
    [string]$SevenZipPath = '',

    [Parameter(Mandatory = $true)]
    [string]$ProgressFile,

    [Parameter(Mandatory = $true)]
    [string]$ResultFile,

    [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

function Find-SevenZip {
    param([string]$PreferredPath = '')

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath)) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    if ($env:ASWH_7ZIP -and (Test-Path -LiteralPath $env:ASWH_7ZIP)) {
        return (Resolve-Path -LiteralPath $env:ASWH_7ZIP).Path
    }

    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $bundledCandidates = @(
        (Join-Path $scriptDir '..\..\tools\7zip\7z.exe'),
        (Join-Path $scriptDir '..\..\..\tools\7zip\7z.exe')
    )
    foreach ($p in $bundledCandidates) {
        if (Test-Path -LiteralPath $p) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }

    $systemCandidates = @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($p in $systemCandidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Write-ProgressState {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Compress
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ProgressFile, $json, $utf8)
}

function Write-ResultState {
    param([hashtable]$State)
    $json = $State | ConvertTo-Json -Compress
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ResultFile, $json, $utf8)
}

function Write-ExtractLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($LogFile)) { return }
    try {
        $ts = Get-Date -Format 'HH:mm:ss.fff'
        $line = "[ExtractScript $ts] $Message"
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Normalize-Dir([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim().Replace('/', '\')
    while ($p.EndsWith('\') -and $p.Length -gt 3) {
        $p = $p.Substring(0, $p.Length - 1)
    }
    return $p
}

try {
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    $installDir = Normalize-Dir $InstallHome
    if (-not (Test-Path -LiteralPath $installer)) {
        throw "安装包不存在: $installer"
    }
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        throw 'InstallHome 为空'
    }

    $sevenZip = Find-SevenZip -PreferredPath $SevenZipPath
    if (-not $sevenZip) {
        throw '未找到 7-Zip。请重新安装 AndroidStudioWinHelper（内置 7-Zip）或手动安装 7-Zip。'
    }

    Write-ExtractLog "开始解包 installer=$installer installDir=$installDir sevenZip=$sevenZip"

    Write-ProgressState @{
        phase = 'listing'
        message = '正在扫描 NSIS 安装包（$_31_ 载荷）…'
        percent = 0
    }

    $listOut = & $sevenZip l $installer '$_31_\*' 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "7z 列表失败: $listOut"
    }

    $payloadLines = @($listOut -split "`r?`n" | Where-Object { $_ -match '\$_31_\\' })
    $totalFiles = $payloadLines.Count
    if ($totalFiles -le 0) {
        throw '安装包中未找到 $_31_\ 载荷（可能不是官方 Android Studio NSIS 包）'
    }

    Write-ProgressState @{
        phase = 'extracting'
        message = "正在解压 $totalFiles 个文件…"
        percent = 0
        totalFiles = $totalFiles
        extractedFiles = 0
    }

    $tempRoot = Join-Path $env:TEMP ("aswh_nsis_extract_" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $extractArgs = @(
        'x', $installer,
        "-o$tempRoot",
        '$_31_\*',
        '-y', '-bsp1', '-bb1'
    )

    $lastPercent = 0
    & $sevenZip @extractArgs 2>&1 | ForEach-Object {
        $line = $_.ToString()
        if ($line -match '(\d+)\s*%') {
            $pct = [int]$matches[1]
            if ($pct -ge $lastPercent) {
                $lastPercent = $pct
                Write-ProgressState @{
                    phase = 'extracting'
                    message = "正在解压… $pct%"
                    percent = $pct
                    totalFiles = $totalFiles
                    extractedFiles = [int]([math]::Round($totalFiles * $pct / 100.0))
                }
            }
        }
        elseif ($line -match '\$_31_\\(.+)$') {
            Write-ProgressState @{
                phase = 'extracting'
                message = "正在解压: $($matches[1])"
                percent = $lastPercent
                totalFiles = $totalFiles
                extractedFiles = [int]([math]::Round($totalFiles * $lastPercent / 100.0))
                currentFile = $matches[1]
            }
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "7z 解压失败，exitCode=$LASTEXITCODE"
    }

    $payloadDir = Join-Path $tempRoot '$_31_'
    if (-not (Test-Path -LiteralPath $payloadDir)) {
        throw "解压后未找到目录: $payloadDir"
    }

    Write-ProgressState @{
        phase = 'deploying'
        message = "正在部署到 $installDir …"
        percent = 100
        totalFiles = $totalFiles
        extractedFiles = $totalFiles
    }

    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    $robocopy = Get-Command robocopy -ErrorAction SilentlyContinue
    if ($robocopy) {
        & robocopy $payloadDir $installDir /E /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
        if ($LASTEXITCODE -ge 8) {
            throw "robocopy 部署失败，exitCode=$LASTEXITCODE"
        }
    } else {
        Copy-Item -Path (Join-Path $payloadDir '*') -Destination $installDir -Recurse -Force
    }

    $studioExe = Join-Path $installDir 'bin\studio64.exe'
    if (-not (Test-Path -LiteralPath $studioExe)) {
        throw "部署后未找到 $studioExe"
    }

    Write-ProgressState @{
        phase = 'registry'
        message = '正在写入安装注册表…'
        percent = 100
        totalFiles = $totalFiles
        extractedFiles = $totalFiles
    }

    $homeReg = $installDir
    if (-not $homeReg.EndsWith('\')) { $homeReg += '\' }

    $sdkPath = if ($AndroidHome) { Normalize-Dir $AndroidHome } else { '' }

    if ($AndroidUserHome) {
        $userSettings = Normalize-Dir $AndroidUserHome
    } elseif ($env:ANDROID_USER_HOME) {
        $userSettings = Normalize-Dir $env:ANDROID_USER_HOME
    } else {
        $androidRoot = Split-Path -Parent $installDir
        $userSettings = Join-Path $androidRoot 'Sdk_userhome'
    }
    if ([string]::IsNullOrWhiteSpace($userSettings)) {
        throw 'ANDROID_USER_HOME / Sdk_userhome 路径为空'
    }
    if (-not (Test-Path -LiteralPath $userSettings)) {
        New-Item -ItemType Directory -Path $userSettings -Force | Out-Null
    }
    $userSettingsReg = $userSettings
    if (-not $userSettingsReg.EndsWith('\')) { $userSettingsReg += '\' }

    # 同步 Machine 级 ANDROID_USER_HOME（解包阶段兜底，与安装向导一致）
    try {
        [Environment]::SetEnvironmentVariable('ANDROID_USER_HOME', $userSettings, 'Machine')
        Write-ExtractLog "写入 Machine ANDROID_USER_HOME=$userSettings"
        # ANDROID_SDK_HOME 已废弃；与 ANDROID_USER_HOME 同时存在会导致 Studio 启动失败
        [Environment]::SetEnvironmentVariable('ANDROID_SDK_HOME', $null, 'Machine')
        Write-ExtractLog '清除 Machine ANDROID_SDK_HOME（已废弃）'
    } catch {
        Write-ExtractLog "写入 ANDROID_USER_HOME 失败: $($_.Exception.Message)"
        # 无管理员权限时不阻断解包
    }

    $productKey = 'HKLM:\SOFTWARE\Android Studio'
    if (-not (Test-Path -LiteralPath $productKey)) {
        New-Item -Path $productKey -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $productKey -Name 'Path' -Value $homeReg -Type ExpandString -Force
    Set-ItemProperty -LiteralPath $productKey -Name 'StartMenuGroup' -Value 'Android Studio' -Type String -Force
    Set-ItemProperty -LiteralPath $productKey -Name 'JdkPath' -Value '' -Type String -Force
    Set-ItemProperty -LiteralPath $productKey -Name 'SdkPath' -Value $sdkPath -Type ExpandString -Force
    Set-ItemProperty -LiteralPath $productKey -Name 'InstallSdk' -Value '0' -Type String -Force
    Set-ItemProperty -LiteralPath $productKey -Name 'InstallHaxm' -Value '0' -Type String -Force
    Set-ItemProperty -LiteralPath $productKey -Name 'UserSettingsPath' -Value $userSettingsReg -Type ExpandString -Force
    Write-ExtractLog "注册表 UserSettingsPath=$userSettingsReg SdkPath=$sdkPath Path=$homeReg"

    $uninstallKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Android Studio'
    if (-not (Test-Path -LiteralPath $uninstallKey)) {
        New-Item -Path $uninstallKey -Force | Out-Null
    }
    $uninstallExe = Join-Path $installDir 'uninstall.exe'
    Set-ItemProperty -LiteralPath $uninstallKey -Name 'DisplayName' -Value 'Android Studio' -Type String -Force
    Set-ItemProperty -LiteralPath $uninstallKey -Name 'Publisher' -Value 'Google LLC' -Type String -Force
    Set-ItemProperty -LiteralPath $uninstallKey -Name 'UninstallString' -Value "`"$uninstallExe`"" -Type ExpandString -Force
    Set-ItemProperty -LiteralPath $uninstallKey -Name 'InstallLocation' -Value $installDir -Type ExpandString -Force

    Write-ProgressState @{
        phase = 'shortcut'
        message = '正在创建开始菜单快捷方式…'
        percent = 100
    }

    try {
        $startMenu = [Environment]::GetFolderPath('CommonPrograms')
        $groupDir = Join-Path $startMenu 'Android Studio'
        if (-not (Test-Path -LiteralPath $groupDir)) {
            New-Item -ItemType Directory -Path $groupDir -Force | Out-Null
        }
        $shell = New-Object -ComObject WScript.Shell
        $lnk = $shell.CreateShortcut((Join-Path $groupDir 'Android Studio.lnk'))
        $lnk.TargetPath = $studioExe
        $lnk.WorkingDirectory = $installDir
        $lnk.Save()
    } catch {
        # 快捷方式失败不阻断
    }

    try {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }

    Write-ProgressState @{
        phase = 'done'
        message = '解包部署完成'
        percent = 100
        totalFiles = $totalFiles
        extractedFiles = $totalFiles
    }

    Write-ResultState @{
        success = $true
        installHome = $installDir
        totalFiles = $totalFiles
        method = '7z-direct-extract'
    }
    exit 0
} catch {
    Write-ProgressState @{
        phase = 'error'
        message = $_.Exception.Message
        percent = 0
    }
    Write-ResultState @{
        success = $false
        error = $_.Exception.Message
        method = '7z-direct-extract'
    }
    exit 1
}
