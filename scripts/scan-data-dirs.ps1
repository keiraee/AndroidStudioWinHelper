param(
    [switch]$Json,
    [switch]$Progress,
    [string[]]$SdkPath,
    [string[]]$KnownDataDir
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

function Normalize-PathKey {
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return "" }
    $P = [Environment]::ExpandEnvironmentVariables($P.Trim().Trim('"'))
    $P = $P.TrimEnd('\', '/')
    return $P.ToLowerInvariant()
}

function Get-CanonicalPath {
    param([string]$Path)
    $normalized = $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }
    $normalized = [Environment]::ExpandEnvironmentVariables($normalized.Trim().Trim('"')).TrimEnd('\', '/')
    try {
        if (Test-Path -LiteralPath $normalized) {
            return (Get-Item -LiteralPath $normalized).FullName.TrimEnd('\')
        }
    } catch {}
    return $normalized
}

function Get-EnvValue {
    param([string]$Name)
    foreach ($scope in @("Machine", "User", "Process")) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim().Trim('"')
        }
    }
    return $null
}

function Test-IsDirectory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        return (Test-Path -LiteralPath $Path -PathType Container)
    } catch {
        return $false
    }
}

# 一次遍历：总大小 + 指定一级子目录大小。遇拒绝访问的目录则跳过。
function Get-FolderSizeWithSubs {
    param(
        [string]$Path,
        [string[]]$SubNames = @()
    )

    $empty = @{ Total = [long]0; Subs = @() }
    if (-not (Test-IsDirectory $Path)) { return $empty }

    $rootFull = Get-CanonicalPath $Path
    if (-not $rootFull) { return $empty }
    $rootPrefix = $rootFull.TrimEnd('\') + '\'
    $prefixLen = $rootPrefix.Length

    $subMap = @{}
    foreach ($name in $SubNames) {
        $subMap[$name.ToLowerInvariant()] = [long]0
    }
    $wantSubs = $subMap.Count -gt 0
    $total = [long]0

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($rootFull)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                try { $total += ([System.IO.FileInfo]$file).Length } catch {}
                if (-not $wantSubs) { continue }
                if ($file.Length -le $prefixLen) { continue }
                $rel = $file.Substring($prefixLen)
                $slash = $rel.IndexOf([char]'\')
                $first = if ($slash -ge 0) { $rel.Substring(0, $slash) } else { $rel }
                $key = $first.ToLowerInvariant()
                if ($subMap.ContainsKey($key)) {
                    try { $subMap[$key] += ([System.IO.FileInfo]$file).Length } catch {}
                }
            }
            foreach ($child in [System.IO.Directory]::EnumerateDirectories($dir)) {
                try {
                    $info = New-Object System.IO.DirectoryInfo $child
                    if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                        continue
                    }
                } catch { continue }
                $stack.Push($child)
            }
        } catch {}
    }

    $items = @()
    foreach ($name in $SubNames) {
        $subPath = Join-Path $rootFull $name
        if (-not (Test-IsDirectory $subPath)) { continue }
        $size = $subMap[$name.ToLowerInvariant()]
        $items += [PSCustomObject]@{
            name = $name
            path = $subPath
            exists = $true
            sizeBytes = [long]$size
            sizeHuman = (Format-SizeHuman -Bytes $size)
        }
    }

    return @{ Total = $total; Subs = @($items) }
}

function Test-IsNestedPath {
    param([string]$Child, [string]$Parent)
    $c = Normalize-PathKey $Child
    $p = Normalize-PathKey $Parent
    if (-not $c -or -not $p -or $c -eq $p) { return $false }
    return $c.StartsWith($p + '\')
}

function Get-RootTotalBytes {
    param($EntryList)
    $existing = @($EntryList | Where-Object { $_.exists })
    $sum = [long]0
    foreach ($entry in $existing) {
        $nested = $false
        foreach ($other in $existing) {
            if ($entry.path -eq $other.path) { continue }
            if (Test-IsNestedPath -Child $entry.path -Parent $other.path) {
                $nested = $true
                break
            }
        }
        if (-not $nested) { $sum += [long]$entry.sizeBytes }
    }
    return $sum
}

function Add-UniqueDir {
    param(
        $Bag,
        [string]$Path
    )
    if (-not (Test-IsDirectory $Path)) { return }
    $canonical = Get-CanonicalPath $Path
    if (-not $canonical) { return }
    $key = Normalize-PathKey $canonical
    if ([string]::IsNullOrWhiteSpace($key)) { return }
    if ($Bag.ContainsKey($key)) { return }
    $Bag[$key] = $canonical
}

$knownDataDirSet = @{}
foreach ($name in @($KnownDataDir)) {
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $knownDataDirSet[$name.Trim().ToLowerInvariant()] = $true
    }
}
$hasKnownInstalls = $knownDataDirSet.Count -gt 0

Write-ScanProgress -Percent 1 -Message "正在查找本机开发目录…"

$jobs = New-Object System.Collections.Generic.List[object]

$roamingRoot = Join-Path $env:APPDATA "Google"
$localRoot = Join-Path $env:LOCALAPPDATA "Google"

$studioNames = New-Object System.Collections.Generic.List[string]
foreach ($root in @($roamingRoot, $localRoot)) {
    if (-not (Test-IsDirectory $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "AndroidStudio*" } |
        ForEach-Object {
            if (-not $studioNames.Contains($_.Name)) { $studioNames.Add($_.Name) }
        }
}

foreach ($name in ($studioNames | Sort-Object)) {
    $version = $name -replace "^AndroidStudioPreview", "" -replace "^AndroidStudio", ""
    $isOrphan = $hasKnownInstalls -and -not $knownDataDirSet.ContainsKey($name.ToLowerInvariant())
    $orphanNote = if ($isOrphan) { "未关联到当前安装（卸载残留）" } else { "" }

    $roamingPath = Join-Path $roamingRoot $name
    if (Test-IsDirectory $roamingPath) {
        $note = "settings、plugins、vmoptions 等用户配置"
        if ($orphanNote) { $note = "$note；$orphanNote" }
        $jobs.Add([PSCustomObject]@{
            Category = "config"
            Label = if ($version) { "IDE 配置 · $version" } else { "IDE 配置（Roaming）" }
            Path = $roamingPath
            Version = $version
            Notes = $note
            SubNames = @("options", "plugins", "codestyles", "colors")
            IsActive = -not $isOrphan
            ActiveSource = ""
            IsOrphan = $isOrphan
        }) | Out-Null
    }

    $localPath = Join-Path $localRoot $name
    if (Test-IsDirectory $localPath) {
        $note = "caches、index、tmp 等本地数据，体积通常较大"
        if ($orphanNote) { $note = "$note；$orphanNote" }
        $jobs.Add([PSCustomObject]@{
            Category = "cache"
            Label = if ($version) { "IDE 缓存 · $version" } else { "IDE 缓存（Local）" }
            Path = $localPath
            Version = $version
            Notes = $note
            SubNames = @("caches", "cache", "index", "tmp", "compile-server", "plugins", "LocalHistory", "log")
            IsActive = -not $isOrphan
            ActiveSource = ""
            IsOrphan = $isOrphan
        }) | Out-Null
    }

    $logPath = Join-Path $localPath "log"
    if (Test-IsDirectory $logPath) {
        $note = "Android Studio 运行日志，已计入上方 IDE 缓存合计"
        if ($orphanNote) { $note = "$note；$orphanNote" }
        $jobs.Add([PSCustomObject]@{
            Category = "log"
            Label = if ($version) { "IDE 日志 · $version" } else { "IDE 运行日志" }
            Path = $logPath
            Version = $version
            Notes = $note
            SubNames = @()
            IsActive = -not $isOrphan
            ActiveSource = ""
            IsOrphan = $isOrphan
        }) | Out-Null
    }
}

$androidPath = Join-Path $env:USERPROFILE ".android"
if (Test-IsDirectory $androidPath) {
    $jobs.Add([PSCustomObject]@{
        Category = "android"
        Label = "Android 工具配置（.android）"
        Path = $androidPath
        Version = ""
        Notes = "ADB 密钥、AVD 模拟器、debug.keystore 等"
        SubNames = @("avd", "cache", "studio")
        IsActive = $false
        ActiveSource = ""
        IsOrphan = $false
    }) | Out-Null
}

$avdHome = Get-EnvValue "ANDROID_AVD_HOME"
$defaultAvd = Join-Path $androidPath "avd"
if ((Test-IsDirectory $avdHome) -and (Normalize-PathKey $avdHome) -ne (Normalize-PathKey $defaultAvd)) {
    $jobs.Add([PSCustomObject]@{
        Category = "android"
        Label = "AVD 模拟器镜像"
        Path = (Get-CanonicalPath $avdHome)
        Version = ""
        Notes = "ANDROID_AVD_HOME 指定的模拟器目录"
        SubNames = @()
        IsActive = $true
        ActiveSource = "ANDROID_AVD_HOME"
        IsOrphan = $false
    }) | Out-Null
}

$gradlePath = Join-Path $env:USERPROFILE ".gradle"
if (Test-IsDirectory $gradlePath) {
    $jobs.Add([PSCustomObject]@{
        Category = "gradle"
        Label = "Gradle 缓存（.gradle）"
        Path = $gradlePath
        Version = ""
        Notes = "Gradle 依赖缓存、wrapper 分发包，可占用大量磁盘"
        SubNames = @("caches", "wrapper", "daemon")
        IsActive = $false
        ActiveSource = ""
        IsOrphan = $false
    }) | Out-Null
}

$sdkBag = @{}
$defaultSdk = Join-Path $env:LOCALAPPDATA "Android\Sdk"
Add-UniqueDir -Bag $sdkBag -Path $defaultSdk
foreach ($envName in @("ANDROID_HOME", "ANDROID_SDK_ROOT")) {
    Add-UniqueDir -Bag $sdkBag -Path (Get-EnvValue $envName)
}
foreach ($extra in @($SdkPath)) {
    Add-UniqueDir -Bag $sdkBag -Path $extra
}

$activeSdkMap = @{}
foreach ($envName in @("ANDROID_HOME", "ANDROID_SDK_ROOT")) {
    $value = Get-EnvValue $envName
    if (-not $value) { continue }
    $canonical = Get-CanonicalPath $value
    $key = Normalize-PathKey $canonical
    if ($key -and -not $activeSdkMap.ContainsKey($key)) {
        $activeSdkMap[$key] = $envName
    }
}

foreach ($sdkCanonical in ($sdkBag.Values | Sort-Object)) {
    $key = Normalize-PathKey $sdkCanonical
    $sdkIsActive = $activeSdkMap.ContainsKey($key)
    $sdkActiveSource = if ($sdkIsActive) { $activeSdkMap[$key] } else { "" }
    $jobs.Add([PSCustomObject]@{
        Category = "sdk"
        Label = "Android SDK"
        Path = $sdkCanonical
        Version = ""
        Notes = "SDK Platform、Build Tools、Platform Tools 等"
        SubNames = @("platforms", "build-tools", "platform-tools", "emulator", "system-images")
        IsActive = $sdkIsActive
        ActiveSource = $sdkActiveSource
        IsOrphan = $false
    }) | Out-Null
}

$script:TotalJobs = [Math]::Max($jobs.Count, 1)
$entries = @()

if ($jobs.Count -eq 0) {
    Write-ScanProgress -Percent 100 -Message "未找到可扫描的开发目录"
} else {
    Write-ScanProgress -Percent 3 -Message "发现 $($jobs.Count) 个实际存在的目录，开始统计占用…"
}

$index = 0
foreach ($job in $jobs) {
    $index++
    $percent = [int]((($index - 1) / $script:TotalJobs) * 95)
    if ($percent -lt 3) { $percent = 3 }
    if ($percent -gt 95) { $percent = 95 }
    Write-ScanProgress -Percent $percent -Message "正在统计：$($job.Label)" -Path $job.Path

    $sized = Get-FolderSizeWithSubs -Path $job.Path -SubNames $job.SubNames
    $entries += [PSCustomObject]@{
        category = $job.Category
        label = $job.Label
        path = $job.Path
        version = $job.Version
        exists = $true
        sizeBytes = [long]$sized.Total
        sizeHuman = (Format-SizeHuman -Bytes $sized.Total)
        notes = $job.Notes
        subEntries = @($sized.Subs)
        isActive = [bool]$job.IsActive
        activeSource = $job.ActiveSource
        isOrphan = [bool]$job.IsOrphan
    }
}

Write-ScanProgress -Percent 98 -Message "正在汇总扫描结果"

$totalSize = Get-RootTotalBytes -EntryList $entries
$scannedAt = [DateTime]::UtcNow.ToString("o")

$result = [PSCustomObject]@{
    entries = @($entries)
    totalSizeBytes = [long]$totalSize
    totalSizeHuman = (Format-SizeHuman -Bytes $totalSize)
    foundCount = @($entries).Count
    scannedAt = $scannedAt
}

Write-ScanProgress -Percent 100 -Message "扫描完成"

$jsonText = $result | ConvertTo-Json -Depth 8 -Compress
if ([string]::IsNullOrWhiteSpace($jsonText)) {
    $jsonText = '{"entries":[],"totalSizeBytes":0,"totalSizeHuman":"0 B","foundCount":0,"scannedAt":""}'
}

if ($Json) {
    if ($Progress) {
        [Console]::Out.WriteLine("@@RESULT|" + $jsonText + "@@")
        [Console]::Out.Flush()
    } else {
        Write-Output $jsonText
    }
    exit 0
}

Write-Host ""
Write-Host "扫描结果："
if ($entries.Count -eq 0) {
    Write-Host "未找到 Android 开发相关目录。"
    exit 0
}

Write-Host ("共找到 " + $result.foundCount + " 个目录，合计约 " + $result.totalSizeHuman + "（已扣除嵌套重复）")
Write-Host ""

$displayIndex = 1
foreach ($entry in $entries) {
    Write-Host ("[" + $displayIndex + "] " + $entry.label)
    Write-Host ("类型：" + $entry.category)
    if ($entry.version) { Write-Host ("版本：" + $entry.version) }
    Write-Host ("路径：" + $entry.path)
    Write-Host ("大小：" + $entry.sizeHuman)
    if ($entry.isOrphan) { Write-Host "标记：卸载残留" }
    if ($entry.activeSource) { Write-Host ("环境变量：" + $entry.activeSource) }
    if ($entry.notes) { Write-Host ("说明：" + $entry.notes) }
    if ($entry.subEntries -and @($entry.subEntries).Count -gt 0) {
        Write-Host "子目录："
        foreach ($sub in @($entry.subEntries)) {
            Write-Host ("  - " + $sub.name + "  " + $sub.sizeHuman + "  " + $sub.path)
        }
    }
    Write-Host ""
    $displayIndex++
}

exit 0
