param(
    [switch]$Json,
    [switch]$Progress,
    [switch]$Write,
    [string]$VarName,
    [string]$VarValue,
    [switch]$CreateDir,
    [string]$AppendPath,
    [string]$ResultFile,
    [string]$Scope = "Machine",
    [switch]$Unset
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

function Write-EnvProgress {
    param(
        [int]$Percent,
        [string]$Message,
        [string]$Path = ""
    )

    if ($Progress -and -not $ResultFile) {
        [Console]::Out.WriteLine("@@PROGRESS|$Percent|$Message|$Path@@")
        [Console]::Out.Flush()
    } elseif (-not $Json -and -not $ResultFile) {
        if ($Path) {
            Write-Host ("[$Percent%] $Message - $Path")
        } else {
            Write-Host ("[$Percent%] $Message")
        }
    }
}

function Format-SizeHuman {
    param([long]$Bytes)

    if ($Bytes -lt 0) { return "未知" }
    if ($Bytes -lt 1KB) { return "$Bytes B" }
    if ($Bytes -lt 1MB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    return "{0:N2} GB" -f ($Bytes / 1GB)
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

function Normalize-Path {
    param([string]$P)
    if ([string]::IsNullOrWhiteSpace($P)) { return "" }
    $P = $P.Trim('"').TrimEnd('\', '/')
    return $P.ToLowerInvariant()
}

function Broadcast-SettingChange {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class EnvBroadcaster {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@ -ErrorAction SilentlyContinue

    $HWND_BROADCAST = [IntPtr]0xffff
    $WM_SETTINGCHANGE = 0x1A
    $SMTO_ABORTIFHUNG = 0x0002
    [IntPtr]$result = [IntPtr]::Zero
    try {
        [EnvBroadcaster]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]0, "Environment", $SMTO_ABORTIFHUNG, 5000, [ref]$result) | Out-Null
    } catch {
        # 静默失败，不影响主流程
    }
}

function Write-ResultJson {
    param([string]$JsonText)

    if ($ResultFile) {
        $dir = [System.IO.Path]::GetDirectoryName($ResultFile)
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        [System.IO.File]::WriteAllText($ResultFile, $JsonText, $utf8)
    } elseif ($Progress) {
        [Console]::Out.WriteLine("@@RESULT|$JsonText@@")
        [Console]::Out.Flush()
    } else {
        $JsonText
    }
}

# ==================== Write 模式 ====================
if ($Write) {
    $result = @{ success = $false; variable = ""; value = ""; error = "" }

    try {
        if ($AppendPath) {
            # 追加 PATH 模式
            $systemPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
            $currentParts = $systemPath -split ";" | Where-Object { $_ -ne "" }
            $normalizedParts = $currentParts | ForEach-Object { Normalize-Path $_ }
            $toAdd = Normalize-Path $AppendPath

            if ($normalizedParts -contains $toAdd) {
                $result.success = $true
                $result.variable = "PATH"
                $result.value = $AppendPath
                $result.error = "路径已存在于 PATH 中"
            } else {
                if ($CreateDir -and -not (Test-Path -LiteralPath $AppendPath)) {
                    New-Item -ItemType Directory -Force -Path $AppendPath | Out-Null
                }
                $newPath = ($currentParts + $AppendPath) -join ";"
                [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
                Broadcast-SettingChange
                $result.success = $true
                $result.variable = "PATH"
                $result.value = $AppendPath
            }
        } else {
            # 写入/删除单个变量模式
            if ([string]::IsNullOrWhiteSpace($VarName)) {
                throw "未指定变量名"
            }

            $targetScope = if ($Scope -eq "User") { "User" } else { "Machine" }

            if ($Unset -or [string]::IsNullOrWhiteSpace($VarValue)) {
                [Environment]::SetEnvironmentVariable($VarName, $null, $targetScope)
                Broadcast-SettingChange
                $result.success = $true
                $result.variable = $VarName
                $result.value = ""
            } else {
                if ($CreateDir -and -not (Test-Path -LiteralPath $VarValue)) {
                    New-Item -ItemType Directory -Force -Path $VarValue | Out-Null
                }

                [Environment]::SetEnvironmentVariable($VarName, $VarValue, $targetScope)
                Broadcast-SettingChange
                $result.success = $true
                $result.variable = $VarName
                $result.value = $VarValue
            }
        }
    } catch {
        $result.error = $_.Exception.Message
    }

    $resultObj = [PSCustomObject]$result
    Write-ResultJson ($resultObj | ConvertTo-Json -Compress)
    exit 0
}

# ==================== Read 模式 ====================

Write-EnvProgress -Percent 1 -Message "正在扫描注册表中的环境变量"

$items = @()
$pathEntries = @()

# 核心变量定义（带建议默认值和中文标签）
$coreVarDefs = @{
    "ANDROID_HOME"      = @{ label = "Android SDK 路径"; default = (Join-Path $env:LOCALAPPDATA "Android\Sdk") }
    "ANDROID_SDK_ROOT"  = @{ label = "Android SDK 根目录"; default = (Join-Path $env:LOCALAPPDATA "Android\Sdk") }
    "GRADLE_HOME"       = @{ label = "Gradle 主目录"; default = "" }
    "GRADLE_USER_HOME"  = @{ label = "Gradle 用户缓存目录"; default = (Join-Path $env:USERPROFILE ".gradle") }
    "JAVA_HOME"         = @{ label = "Java/JDK 安装路径"; default = "" }
    "CLASSPATH"         = @{ label = "Java 类路径"; default = "" }
    "ANDROID_NDK_ROOT"  = @{ label = "Android NDK 路径"; default = "" }
    "ANDROID_NDK_HOME"  = @{ label = "Android NDK 路径 (备用)"; default = "" }
}

# 关键词过滤列表（不区分大小写，匹配变量名，仅安卓开发相关）
$filterKeywords = @(
    "ANDROID", "GRADLE", "JAVA", "JDK", "JRE", "NDK", "KOTLIN"
)

# PATH 中要排除的系统变量名
$skipVars = @(
    "PATH", "Path", "PATHEXT", "PSModulePath", "ComSpec",
    "SystemRoot", "SystemDrive", "windir", "TEMP", "TMP",
    "USERPROFILE", "HOMEDRIVE", "HOMEPATH", "APPDATA",
    "LOCALAPPDATA", "ProgramData", "ProgramFiles", "ProgramFiles(x86)",
    "CommonProgramFiles", "CommonProgramFiles(x86)",
    "ALLUSERSPROFILE", "PUBLIC", "NUMBER_OF_PROCESSORS",
    "PROCESSOR_ARCHITECTURE", "PROCESSOR_IDENTIFIER",
    "PROCESSOR_LEVEL", "PROCESSOR_REVISION", "OS",
    "DriverData", "OneDrive", "OneDriveConsumer",
    # 非安卓开发相关，按关键词过滤可能误匹配的
    "ChocolateyInstall", "ChocolateyLastPathUpdate",
    "MAVEN_HOME", "M2_HOME",
    "FLUTTER_STORAGE_BASE_URL", "FLUTTER_ROOT",
    "DART_SDK", "PUB_CACHE",
    "NODE_PATH", "NODE_HOME", "NPM_CONFIG_PREFIX",
    "GOLAND_VM_OPTIONS", "RUBYMINE_VM_OPTIONS", "RUSTROVER_VM_OPTIONS",
    "WEBSTORM_VM_OPTIONS", "PYCHARM_VM_OPTIONS", "CLION_VM_OPTIONS",
    "IDEA_VM_OPTIONS", "INTELLIJ_VM_OPTIONS"
)

# 从注册表读取所有环境变量
$machineRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
$userRegPath = "HKCU:\Environment"

Write-EnvProgress -Percent 5 -Message "正在读取系统级环境变量"

$machineVars = @{}
if (Test-Path $machineRegPath) {
    Get-ItemProperty -Path $machineRegPath -ErrorAction SilentlyContinue |
        Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
        Where-Object { $skipVars -notcontains $_.Name } |
        ForEach-Object {
            $name = $_.Name
            $val = (Get-ItemProperty -Path $machineRegPath -Name $name -ErrorAction SilentlyContinue).$name
            if ($val -and $val -is [string]) {
                $machineVars[$name] = $val
            }
        }
}

Write-EnvProgress -Percent 15 -Message "正在读取用户级环境变量"

$userVars = @{}
if (Test-Path $userRegPath) {
    Get-ItemProperty -Path $userRegPath -ErrorAction SilentlyContinue |
        Get-Member -MemberType NoteProperty -ErrorAction SilentlyContinue |
        Where-Object { $skipVars -notcontains $_.Name } |
        ForEach-Object {
            $name = $_.Name
            $val = (Get-ItemProperty -Path $userRegPath -Name $name -ErrorAction SilentlyContinue).$name
            if ($val -and $val -is [string]) {
                $userVars[$name] = $val
            }
        }
}

Write-EnvProgress -Percent 30 -Message "正在过滤开发相关变量"

# 合并所有变量名
$allVarNames = @($machineVars.Keys) + @($userVars.Keys) | Sort-Object -Unique

# 过滤：核心变量 + 关键词匹配
$matchedVars = [System.Collections.Generic.List[object]]::new()

foreach ($name in $allVarNames) {
    $isCore = $coreVarDefs.ContainsKey($name)
    $isMatch = $false

    if (-not $isCore) {
        foreach ($kw in $filterKeywords) {
            if ($name.ToUpperInvariant().Contains($kw)) {
                $isMatch = $true
                break
            }
        }
    }

    if (-not $isCore -and -not $isMatch) { continue }

    $machineVal = $machineVars[$name]
    $userVal = $userVars[$name]

    $source = "NotSet"
    $currentVal = ""

    if ($machineVal -and $userVal) {
        $source = "Machine"
        $currentVal = $machineVal
    } elseif ($machineVal) {
        $source = "Machine"
        $currentVal = $machineVal
    } elseif ($userVal) {
        $source = "User"
        $currentVal = $userVal
    }

    $exists = $false
    $sizeBytes = 0
    $sizeHuman = ""

    if ($currentVal -and (Test-Path -LiteralPath $currentVal)) {
        $exists = $true
        # 环境配置不需要计算目录大小，跳过以提升性能
    }

    $coreDef = $coreVarDefs[$name]
    $label = if ($coreDef) { $coreDef.label } else { $name }
    $default = if ($coreDef) { $coreDef.default } else { "" }

    $matchedVars += [PSCustomObject]@{
        variable = $name
        label = $label
        currentValue = $currentVal
        source = $source
        exists = $exists
        sizeBytes = $sizeBytes
        sizeHuman = $sizeHuman
        suggestedDefault = $default
        isCore = $isCore
    }
}

# 补全：核心变量即使未设置也要展示（方便用户主动配置）
foreach ($coreName in $coreVarDefs.Keys) {
    $alreadyAdded = $false
    foreach ($mv in $matchedVars) {
        if ($mv.variable -eq $coreName) { $alreadyAdded = $true; break }
    }
    if (-not $alreadyAdded) {
        $coreDef = $coreVarDefs[$coreName]
        $matchedVars += [PSCustomObject]@{
            variable = $coreName
            label = $coreDef.label
            currentValue = ""
            source = "NotSet"
            exists = $false
            sizeBytes = 0
            sizeHuman = ""
            suggestedDefault = $coreDef.default
            isCore = $true
        }
    }
}

# 核心变量排前面，再按变量名排序
$items = @($matchedVars | Sort-Object -Property @{Expression = { -not $_.isCore }}, @{Expression = { $_.variable }})

Write-EnvProgress -Percent 50 -Message "正在分析 PATH 中的 SDK 条目"

# 检测 PATH 中的 Android 相关条目
$sdkPath = ""
foreach ($v in @("ANDROID_HOME", "ANDROID_SDK_ROOT")) {
    $val = [Environment]::GetEnvironmentVariable($v, "Machine")
    if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, "User") }
    if ($val -and (Test-Path -LiteralPath $val)) {
        $sdkPath = $val.TrimEnd('\', '/')
        break
    }
}
if (-not $sdkPath) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA "Android\Sdk"
    if (Test-Path -LiteralPath $defaultSdk) {
        $sdkPath = $defaultSdk
    }
}

$pathSubDirs = @("platform-tools", "build-tools", "cmdline-tools\latest\bin", "emulator", "ndk-bundle", "tools\bin")
$systemPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
$normalizedSystemPath = ($systemPath -split ";" | Where-Object { $_ -ne "" } | ForEach-Object { Normalize-Path $_ })

foreach ($sub in $pathSubDirs) {
    $fullPath = if ($sdkPath) { Join-Path $sdkPath $sub } else { "" }
    $normFull = Normalize-Path $fullPath
    $inPath = $normalizedSystemPath -contains $normFull
    $subExists = $fullPath -and (Test-Path -LiteralPath $fullPath)

    $pathEntries += [PSCustomObject]@{
        subDir = $sub
        fullPath = $fullPath
        inPath = $inPath
        exists = $subExists
    }
}

Write-EnvProgress -Percent 95 -Message "正在汇总结果"

# 移除排序用的 isCore 字段
$cleanItems = @($items | ForEach-Object {
    [PSCustomObject]@{
        variable = $_.variable
        label = $_.label
        currentValue = $_.currentValue
        source = $_.source
        exists = $_.exists
        sizeBytes = $_.sizeBytes
        sizeHuman = $_.sizeHuman
        suggestedDefault = $_.suggestedDefault
    }
})

$result = [PSCustomObject]@{
    items = @($cleanItems)
    pathEntries = @($pathEntries)
}

Write-EnvProgress -Percent 100 -Message "检测完成，共找到 $($cleanItems.Count) 个相关变量"

$resultJson = $result | ConvertTo-Json -Depth 6 -Compress
Write-ResultJson $resultJson

exit 0
