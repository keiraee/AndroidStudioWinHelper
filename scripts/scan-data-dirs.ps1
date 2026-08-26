param(
    [switch]$Json,
    [switch]$Progress
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

function Format-SizeHuman {
    param([long]$Bytes)

    if ($Bytes -lt 0) { return "未知" }
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    return "{0:N2} GB" -f ($Bytes / 1GB)
}

function Write-ScanProgress {
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
            Write-Host ("[$Percent%] $Message - $Path")
        } else {
            Write-Host ("[$Percent%] $Message")
        }
    }
}

function Get-FolderSizeBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $size = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum

    if ($null -eq $size) { return 0 }
    return [long]$size
}

function Get-SubEntries {
    param(
        [string]$RootPath,
        [string[]]$Names,
        [string]$ProgressLabel
    )

    $items = @()

    foreach ($name in $Names) {
        $subPath = Join-Path $RootPath $name
        if (-not (Test-Path -LiteralPath $subPath)) { continue }

        Write-ScanProgress -Percent $script:CurrentPercent -Message "正在统计子目录：$name" -Path $subPath
        $size = Get-FolderSizeBytes -Path $subPath
        $items += [PSCustomObject]@{
            name = $name
            path = $subPath
            exists = $true
            sizeBytes = $size
            sizeHuman = (Format-SizeHuman -Bytes $size)
        }
    }

    return $items
}

function Step-Progress {
    param(
        [string]$Message,
        [string]$Path = ""
    )

    $script:StepIndex++
    $percent = [int](($script:StepIndex / [Math]::Max($script:TotalSteps, 1)) * 95)
    if ($percent -lt 1) { $percent = 1 }
    if ($percent -gt 95) { $percent = 95 }
    $script:CurrentPercent = $percent
    Write-ScanProgress -Percent $percent -Message $Message -Path $Path
}

function New-Entry {
    param(
        [string]$Category,
        [string]$Label,
        [string]$Path,
        [string]$Version = "",
        [string]$Notes = "",
        [object[]]$SubEntries = @(),
        [string[]]$SubNames = @(),
        [bool]$IsActive = $false,
        [string]$ActiveSource = ""
    )

    Step-Progress -Message "正在分析：$Label" -Path $Path

    $exists = Test-Path -LiteralPath $Path
    $size = 0
  $subs = @($SubEntries)

    if ($exists) {
        $size = Get-FolderSizeBytes -Path $Path
        Step-Progress -Message "已统计：$Label（$(Format-SizeHuman -Bytes $size)）" -Path $Path

        if ($SubNames.Count -gt 0) {
            $subs = Get-SubEntries -RootPath $Path -Names $SubNames -ProgressLabel $Label
        }
    } else {
        Step-Progress -Message "目录不存在，跳过：$Label" -Path $Path
    }

    return [PSCustomObject]@{
        category = $Category
        label = $Label
        path = $Path
        version = $Version
        exists = $exists
        sizeBytes = $size
        sizeHuman = (Format-SizeHuman -Bytes $size)
        notes = $Notes
        subEntries = @($subs)
        isActive = $IsActive
        activeSource = $ActiveSource
    }
}

$script:StepIndex = 0
$script:CurrentPercent = 0
$entries = @()

Write-ScanProgress -Percent 1 -Message "准备扫描环境目录"

# 收集环境变量，用于标记正在使用的目录
$envAndroidHome = [Environment]::GetEnvironmentVariable("ANDROID_HOME")
$envAndroidSdkRoot = [Environment]::GetEnvironmentVariable("ANDROID_SDK_ROOT")

# 规范化路径用于比较
function Normalize-Path {
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return "" }
    $P = $P.Trim('"').TrimEnd('\', '/')
    return $P.ToLowerInvariant()
}

$activeSDKPaths = @{}
foreach ($envName in @("ANDROID_HOME", "ANDROID_SDK_ROOT")) {
    $value = [Environment]::GetEnvironmentVariable($envName)
    if ($value) {
        $normalized = Normalize-Path $value
        if (-not $activeSDKPaths.ContainsKey($normalized)) {
            $activeSDKPaths[$normalized] = $envName
        }
    }
}

$roamingRoot = Join-Path $env:APPDATA "Google"
$localRoot = Join-Path $env:LOCALAPPDATA "Google"

$studioNames = @()
if (Test-Path -LiteralPath $roamingRoot) {
    $studioNames += Get-ChildItem -LiteralPath $roamingRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "AndroidStudio*" } |
        Select-Object -ExpandProperty Name
}
if (Test-Path -LiteralPath $localRoot) {
    $studioNames += Get-ChildItem -LiteralPath $localRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "AndroidStudio*" } |
        Select-Object -ExpandProperty Name
}

$studioNames = $studioNames | Sort-Object -Unique

$sdkCandidates = New-Object System.Collections.Generic.HashSet[string]
$defaultSdk = Join-Path $env:LOCALAPPDATA "Android\Sdk"
[void]$sdkCandidates.Add($defaultSdk)
foreach ($envName in @("ANDROID_HOME", "ANDROID_SDK_ROOT")) {
    $value = [Environment]::GetEnvironmentVariable($envName)
    if ($value) { [void]$sdkCandidates.Add($value.Trim('"')) }
}

$script:TotalSteps = 1 + ($studioNames.Count * 3 * 2) + (2 * 2) + (@($sdkCandidates).Count * 2) + 1

Write-ScanProgress -Percent 3 -Message "已发现 $($studioNames.Count) 个 Android Studio 配置版本"

foreach ($name in $studioNames) {
    $version = $name -replace "^AndroidStudio", ""
    $roamingPath = Join-Path $roamingRoot $name
    $localPath = Join-Path $localRoot $name
    $logPath = Join-Path $localPath "log"

    $entries += New-Entry -Category "config" -Label "IDE 配置（Roaming）" -Path $roamingPath -Version $version `
        -Notes "settings、plugins、vmoptions 等用户配置" `
        -SubNames @("options", "plugins", "codestyles", "colors")

    $entries += New-Entry -Category "cache" -Label "IDE 缓存与索引（Local）" -Path $localPath -Version $version `
        -Notes "caches、index、tmp 等本地数据，体积通常较大" `
        -SubNames @("caches", "cache", "index", "tmp", "compile-server", "plugins", "LocalHistory")

    $entries += New-Entry -Category "log" -Label "IDE 运行日志" -Path $logPath -Version $version `
        -Notes "Android Studio 运行日志，排查问题时可查看"
}

$androidPath = Join-Path $env:USERPROFILE ".android"
$entries += New-Entry -Category "android" -Label "Android 工具配置（.android）" -Path $androidPath `
    -Notes "ADB 密钥、AVD 模拟器、debug.keystore 等" `
    -SubNames @("avd", "cache", "studio")

$gradlePath = Join-Path $env:USERPROFILE ".gradle"
$entries += New-Entry -Category "gradle" -Label "Gradle 缓存（.gradle）" -Path $gradlePath `
    -Notes "Gradle 依赖缓存、wrapper 分发包，可占用大量磁盘" `
    -SubNames @("caches", "wrapper", "daemon")

foreach ($sdkPath in ($sdkCandidates | Sort-Object)) {
    if ([string]::IsNullOrWhiteSpace($sdkPath)) { continue }

    $normalizedSdk = Normalize-Path $sdkPath
    $sdkIsActive = $activeSDKPaths.ContainsKey($normalizedSdk)
    $sdkActiveSource = if ($sdkIsActive) { $activeSDKPaths[$normalizedSdk] } else { "" }

    $entries += New-Entry -Category "sdk" -Label "Android SDK" -Path $sdkPath `
        -Notes "SDK Platform、Build Tools、Platform Tools 等" `
        -SubNames @("platforms", "build-tools", "platform-tools", "emulator", "system-images") `
        -IsActive $sdkIsActive -ActiveSource $sdkActiveSource
}

Write-ScanProgress -Percent 98 -Message "正在汇总扫描结果"

$existingEntries = @($entries | Where-Object { $_.exists })
$totalSize = ($existingEntries | Measure-Object -Property sizeBytes -Sum).Sum
if ($null -eq $totalSize) { $totalSize = 0 }

$result = [PSCustomObject]@{
    entries = @($entries)
    totalSizeBytes = [long]$totalSize
    totalSizeHuman = (Format-SizeHuman -Bytes $totalSize)
    foundCount = $existingEntries.Count
}

Write-ScanProgress -Percent 100 -Message "扫描完成"

if ($Json) {
    if ($Progress) {
        [Console]::Out.WriteLine("@@RESULT|" + ($result | ConvertTo-Json -Depth 6 -Compress) + "@@")
        [Console]::Out.Flush()
    } else {
        $result | ConvertTo-Json -Depth 6 -Compress:$false
    }
    exit 0
}

Write-Host ""
Write-Host "扫描结果："
Write-Host ("共找到 " + $result.foundCount + " 个存在的目录，合计约 " + $result.totalSizeHuman)
Write-Host ""

$index = 1
foreach ($entry in $entries) {
    Write-Host ("[" + $index + "] " + $entry.label)
    Write-Host ("类型：" + $entry.category)
    if ($entry.version) { Write-Host ("版本：" + $entry.version) }
    Write-Host ("路径：" + $entry.path)
    Write-Host ("存在：" + $(if ($entry.exists) { "是" } else { "否" }))
    if ($entry.exists) {
        Write-Host ("大小：" + $entry.sizeHuman)
    }
    if ($entry.notes) {
        Write-Host ("说明：" + $entry.notes)
    }
    if ($entry.subEntries -and $entry.subEntries.Count -gt 0) {
        Write-Host "子目录："
        foreach ($sub in $entry.subEntries) {
            Write-Host ("  - " + $sub.name + "  " + $sub.sizeHuman + "  " + $sub.path)
        }
    }
    Write-Host ""
    $index++
}

exit 0
