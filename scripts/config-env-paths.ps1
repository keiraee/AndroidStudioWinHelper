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
    [switch]$Unset,
    [string]$BatchFile,
    [switch]$PrepareRoot,
    [string]$RootPath,
    [switch]$MoveDir,
    [string]$MoveFrom,
    [string]$MoveTo
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

function Get-AndroidRootDefault {
    foreach ($v in @("AS_INSTALL_HOME", "ANDROID_HOME", "ANDROID_USER_HOME", "GRADLE_USER_HOME")) {
        $val = [Environment]::GetEnvironmentVariable($v, "Machine")
        if (-not $val) { $val = [Environment]::GetEnvironmentVariable($v, "User") }
        if ([string]::IsNullOrWhiteSpace($val)) { continue }
        $parent = Split-Path -Parent ($val.Trim().TrimEnd('\', '/'))
        if ($parent) { return $parent }
    }
    $drive = if ($env:SystemDrive) { $env:SystemDrive } else { "C:" }
    return (Join-Path $drive "Android")
}

# ==================== Write 模式 ====================
if ($Write) {
    if ($MoveDir) {
        $result = @{ success = $false; variable = "MOVE"; value = $MoveTo; error = "" }
        try {
            if ([string]::IsNullOrWhiteSpace($MoveFrom)) { throw "未指定源目录" }
            if ([string]::IsNullOrWhiteSpace($MoveTo)) { throw "未指定目标目录" }

            $from = $MoveFrom.Trim().TrimEnd('\', '/')
            $to = $MoveTo.Trim().TrimEnd('\', '/')
            if ((Normalize-Path $from) -eq (Normalize-Path $to)) {
                throw "源目录与目标目录相同"
            }
            if (-not (Test-Path -LiteralPath $from -PathType Container)) {
                throw "源目录不存在: $from"
            }
            # 目标不能位于源目录内部，否则 robocopy 会无限递归
            if ((Normalize-Path $to).StartsWith((Normalize-Path $from) + '\')) {
                throw "目标目录不能位于源目录内部"
            }
            if (-not (Test-Path -LiteralPath $to)) {
                New-Item -ItemType Directory -Force -Path $to | Out-Null
            }

            # /MOVE = 复制后删除源；/E 含空目录；/R:1 /W:1 避免长时间重试
            & robocopy $from $to /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
            $rc = $LASTEXITCODE
            # robocopy: 0-7 视为成功，8+ 为失败
            if ($rc -ge 8) { throw "robocopy 迁移失败，exitCode=$rc" }

            $result.success = $true
        } catch {
            $result.error = $_.Exception.Message
        }
        Write-ResultJson (([PSCustomObject]$result) | ConvertTo-Json -Compress)
        exit 0
    }

    if ($PrepareRoot) {
        $result = @{ success = $false; variable = "ROOT"; value = $RootPath; error = "" }
        try {
            if ([string]::IsNullOrWhiteSpace($RootPath)) { throw "未指定根目录" }

            if (Test-Path -LiteralPath $RootPath) {
                $existing = Get-Item -LiteralPath $RootPath -Force
                if (-not $existing.PSIsContainer) {
                    throw "目标路径已存在但不是文件夹: $RootPath"
                }
            } else {
                if ($RootPath -match '^([A-Za-z]):\\') {
                    $driveRoot = ($matches[1] + ':\')
                    if (-not (Test-Path -LiteralPath $driveRoot)) {
                        throw "盘符 $($matches[1]): 在管理员进程中不可用。网络映射盘请使用 UNC 路径，或改选本地磁盘。"
                    }
                }
                $created = [System.IO.Directory]::CreateDirectory($RootPath)
                if (-not $created.Exists) { throw "目录创建失败: $RootPath" }
            }

            if (-not [System.IO.Directory]::Exists($RootPath)) {
                throw "目录不可用: $RootPath"
            }

            $probe = Join-Path $RootPath ".aswh_write_probe"
            [System.IO.File]::WriteAllText($probe, "ok")
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $result.success = $true
        } catch {
            $result.error = $_.Exception.Message
        }
        Write-ResultJson (([PSCustomObject]$result) | ConvertTo-Json -Compress)
        exit 0
    }

    if ($BatchFile) {
        $result = @{ success = $false; variable = "BATCH"; value = ""; error = ""; items = @() }
        try {
            if (-not (Test-Path -LiteralPath $BatchFile)) { throw "批处理文件不存在: $BatchFile" }
            $rawBatch = [System.IO.File]::ReadAllText($BatchFile, [System.Text.UTF8Encoding]::new($false))
            $batch = $rawBatch | ConvertFrom-Json
            $createDir = [bool]$batch.createDir
            $allOk = $true
            $items = @()

            foreach ($v in @($batch.variables)) {
                $name = [string]$v.name
                $val = [string]$v.value
                $item = @{ variable = $name; value = $val; success = $false; error = "" }
                try {
                    if ([string]::IsNullOrWhiteSpace($name)) { throw "变量名为空" }
                    if ($createDir -and -not [string]::IsNullOrWhiteSpace($val) -and -not (Test-Path -LiteralPath $val)) {
                        New-Item -ItemType Directory -Force -Path $val | Out-Null
                    }
                    [Environment]::SetEnvironmentVariable($name, $val, "Machine")
                    $readBack = [Environment]::GetEnvironmentVariable($name, "Machine")
                    if ($readBack -ne $val) { throw "回读不一致: 期望 $val , 实际 $readBack" }
                    $item.success = $true
                    if ($name -eq 'ANDROID_USER_HOME') {
                        [Environment]::SetEnvironmentVariable('ANDROID_SDK_HOME', $null, 'Machine')
                    }
                    if ($name -eq 'ANDROID_HOME') {
                        [Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $null, 'Machine')
                    }
                } catch {
                    $allOk = $false
                    $item.error = $_.Exception.Message
                }
                $items += $item
            }

            foreach ($p in @($batch.removePath)) {
                $pathVal = [string]$p
                if ([string]::IsNullOrWhiteSpace($pathVal)) { continue }
                $item = @{ variable = "PATH-"; value = $pathVal; success = $false; error = "" }
                try {
                    $systemPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
                    $currentParts = @()
                    if ($systemPath) { $currentParts = $systemPath -split ";" | Where-Object { $_ -ne "" } }
                    $toRemove = Normalize-Path $pathVal
                    $kept = @($currentParts | Where-Object { (Normalize-Path $_) -ne $toRemove })
                    if ($kept.Count -ne $currentParts.Count) {
                        [Environment]::SetEnvironmentVariable("PATH", ($kept -join ";"), "Machine")
                    }
                    $readPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
                    $readParts = @()
                    if ($readPath) { $readParts = $readPath -split ";" | ForEach-Object { Normalize-Path $_ } }
                    if ($readParts -contains $toRemove) { throw "PATH 回读仍包含 $pathVal" }
                    $item.success = $true
                } catch {
                    $allOk = $false
                    $item.error = $_.Exception.Message
                }
                $items += $item
            }

            foreach ($p in @($batch.appendPath)) {
                $pathVal = [string]$p
                if ([string]::IsNullOrWhiteSpace($pathVal)) { continue }
                $item = @{ variable = "PATH"; value = $pathVal; success = $false; error = "" }
                try {
                    if ($createDir -and -not (Test-Path -LiteralPath $pathVal)) {
                        New-Item -ItemType Directory -Force -Path $pathVal | Out-Null
                    }
                    $systemPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
                    $currentParts = @()
                    if ($systemPath) { $currentParts = $systemPath -split ";" | Where-Object { $_ -ne "" } }
                    $normalizedParts = $currentParts | ForEach-Object { Normalize-Path $_ }
                    $toAdd = Normalize-Path $pathVal
                    if ($normalizedParts -notcontains $toAdd) {
                        $newPath = ($currentParts + $pathVal) -join ";"
                        [Environment]::SetEnvironmentVariable("PATH", $newPath, "Machine")
                    }
                    $readPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
                    $readParts = @()
                    if ($readPath) { $readParts = $readPath -split ";" | ForEach-Object { Normalize-Path $_ } }
                    if ($readParts -notcontains $toAdd) { throw "PATH 回读未包含 $pathVal" }
                    $item.success = $true
                } catch {
                    $allOk = $false
                    $item.error = $_.Exception.Message
                }
                $items += $item
            }

            Broadcast-SettingChange
            $itemObjs = @($items | ForEach-Object {
                [PSCustomObject]@{
                    variable = $_.variable
                    value    = $_.value
                    success  = $_.success
                    error    = $_.error
                }
            })
            $resultObj = [PSCustomObject]@{
                success  = $allOk
                variable = "BATCH"
                value    = ""
                error    = $(if (-not $allOk) { "部分环境变量写入或校验失败" } else { "" })
                items    = $itemObjs
            }
            Write-ResultJson ($resultObj | ConvertTo-Json -Depth 6 -Compress)
            exit 0
        } catch {
            $result.error = $_.Exception.Message
        }
        Write-ResultJson (([PSCustomObject]$result) | ConvertTo-Json -Depth 6 -Compress)
        exit 0
    }

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

# 建议默认值以「安装向导」使用的 Android 根目录为基准，保证两个模块口径一致
$androidRoot = Get-AndroidRootDefault

# 核心变量定义（带建议默认值和中文标签）
# deprecated = 已废弃变量，只在实际存在时展示，并提示清除
$coreVarDefs = @{
    "AS_INSTALL_HOME"   = @{ label = "Android Studio 安装目录"; default = (Join-Path $androidRoot "AndroidStudio"); primary = $true }
    "ANDROID_HOME"      = @{ label = "Android SDK 路径"; default = (Join-Path $androidRoot "Sdk"); primary = $true }
    "ANDROID_USER_HOME" = @{ label = "Android 用户配置目录（AVD / 首选项）"; default = (Join-Path $androidRoot "Sdk_userhome"); primary = $true }
    "GRADLE_USER_HOME"  = @{ label = "Gradle 用户缓存目录"; default = (Join-Path $androidRoot "GradleRepository"); primary = $true }
    "JAVA_HOME"         = @{ label = "Java/JDK 安装路径"; default = "" }
    "ANDROID_NDK_ROOT"  = @{ label = "Android NDK 路径"; default = "" }
    "ANDROID_NDK_HOME"  = @{ label = "Android NDK 路径 (备用)"; default = "" }
    "CLASSPATH"         = @{ label = "Java 类路径"; default = ""; deprecated = $true; hint = "现代 Android/Gradle 工程不依赖 CLASSPATH，保留可能干扰构建" }
    "ANDROID_SDK_ROOT"  = @{ label = "Android SDK 根目录（已废弃）"; default = ""; deprecated = $true; hint = "已被 ANDROID_HOME 取代，与 ANDROID_HOME 不一致时会导致 SDK 解析错误" }
    "ANDROID_SDK_HOME"  = @{ label = "Android 首选项目录（已废弃）"; default = ""; deprecated = $true; hint = "已被 ANDROID_USER_HOME 取代，同时存在会让 Studio 启动报 AndroidLocationsException" }
    "GRADLE_HOME"       = @{ label = "Gradle 主目录（已废弃）"; default = ""; deprecated = $true; hint = "Android Studio 使用内置/Wrapper 的 Gradle，不需要该变量" }
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
    $isDeprecated = [bool]($coreDef -and $coreDef.deprecated)
    $hint = if ($coreDef -and $coreDef.hint) { $coreDef.hint } else { "" }

    $matchedVars += [PSCustomObject]@{
        variable = $name
        label = $label
        currentValue = $currentVal
        source = $source
        exists = $exists
        sizeBytes = $sizeBytes
        sizeHuman = $sizeHuman
        suggestedDefault = $default
        isCore = [bool]($coreDef -and $coreDef.primary)
        deprecated = $isDeprecated
        deprecationHint = $hint
    }
}

# 补全：核心变量即使未设置也要展示（方便用户主动配置）
# 已废弃变量不补全——没设置就不该出现在界面上诱导用户去设
foreach ($coreName in $coreVarDefs.Keys) {
    $coreDef = $coreVarDefs[$coreName]
    if ($coreDef.deprecated) { continue }

    $alreadyAdded = $false
    foreach ($mv in $matchedVars) {
        if ($mv.variable -eq $coreName) { $alreadyAdded = $true; break }
    }
    if (-not $alreadyAdded) {
        $matchedVars += [PSCustomObject]@{
            variable = $coreName
            label = $coreDef.label
            currentValue = ""
            source = "NotSet"
            exists = $false
            sizeBytes = 0
            sizeHuman = ""
            suggestedDefault = $coreDef.default
            isCore = [bool]$coreDef.primary
            deprecated = $false
            deprecationHint = ""
        }
    }
}

# 推荐变量排前面，废弃变量排最后，同组按变量名排序
$items = @($matchedVars | Sort-Object -Property `
    @{Expression = { -not $_.isCore }}, `
    @{Expression = { [bool]$_.deprecated }}, `
    @{Expression = { $_.variable }})

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
        isCore = [bool]$_.isCore
        deprecated = [bool]$_.deprecated
        deprecationHint = [string]$_.deprecationHint
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
