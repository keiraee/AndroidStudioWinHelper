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
$residues = New-Object System.Collections.Generic.List[object]
$residueKeys = @{}

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

function Get-CanonicalPath {
    param([string]$Path)

    $normalized = Normalize-DirPath $Path
    if (-not $normalized) { return $null }

    # Get-Item.FullName 会展开 8.3 短名（PROGRA~1 → Program Files），Resolve-Path 不会
    try {
        if (Test-Path -LiteralPath $normalized) {
            return (Get-Item -LiteralPath $normalized).FullName.TrimEnd('\')
        }
    } catch {}

    try { return (Resolve-Path -LiteralPath $normalized).Path } catch { return $normalized }
}

function Test-ValidInstallDir {
    param([string]$InstallPath)

    $path = Normalize-DirPath $InstallPath
    if (-not $path) { return $false }
    if (-not (Test-Path -LiteralPath $path)) { return $false }

    $exe64 = Join-Path $path "bin\studio64.exe"
    $exe32 = Join-Path $path "bin\studio.exe"
    $infoJson = Join-Path $path "product-info.json"
    $buildTxt = Join-Path $path "build.txt"

    return (
        (Test-Path -LiteralPath $exe64) -or
        (Test-Path -LiteralPath $exe32) -or
        (Test-Path -LiteralPath $infoJson) -or
        (Test-Path -LiteralPath $buildTxt)
    )
}

function Add-Residue {
    param(
        [string]$Kind,
        [string]$Name,
        [string]$Path,
        [string]$RegistryKey,
        [string]$Version,
        [string]$Reason,
        [string]$Source
    )

    $dedupe = ("{0}|{1}|{2}" -f $Kind, $RegistryKey, $Path).ToLowerInvariant()
    if ($residueKeys.ContainsKey($dedupe)) { return }
    $residueKeys[$dedupe] = $true

    $residues.Add([PSCustomObject]@{
        kind = $Kind
        name = if ($Name) { $Name } else { "Android Studio" }
        path = if ($Path) { $Path } else { "" }
        registryKey = if ($RegistryKey) { $RegistryKey } else { "" }
        version = if ($Version) { $Version } else { "" }
        reason = $Reason
        source = $Source
    }) | Out-Null
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

    if (-not (Test-ValidInstallDir $path)) { return }

    $resolved = Get-CanonicalPath $path
    if (-not $resolved) { $resolved = $path }
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

function Get-InstallPathFromCommand {
    param([string]$CommandText)

    $exe = Get-ExePathFromCommand $CommandText
    if (-not $exe) { return $null }

    $leaf = Split-Path -Path $exe -Leaf
    if ($leaf -ieq "studio64.exe" -or $leaf -ieq "studio.exe") {
        $binDir = Split-Path -Path $exe -Parent
        return (Split-Path -Path $binDir -Parent)
    }

    # Google/JetBrains 卸载项常见：InstallLocation 为空，UninstallString 指向安装根目录\uninstall.exe
    if ($leaf -ieq "uninstall.exe") {
        return (Split-Path -Path $exe -Parent)
    }

    return $null
}

function Add-FromCommandText {
    param(
        [string]$CommandText,
        [string]$Source
    )

    $installPath = Get-InstallPathFromCommand $CommandText
    if ($installPath) {
        Add-InstallPath -InstallPath $installPath -Source $Source
        return
    }

    $exe = Get-ExePathFromCommand $CommandText
    if ($exe) { Add-FromExePath -ExePath $exe -Source $Source }
}

function Get-Channel {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Version,
        [string]$DataDirName,
        [string]$VersionSuffix
    )

    # 渠道检测策略（依据见 docs/INSTALL-DETECTION-REVIEW.md §2.1）：
    # 1. product-info.json → versionSuffix（IntelliJ Platform 官方 ProductInfo 字段）
    # 2. product-info.json → dataDirectoryName（Google 预览版用 AndroidStudioPreview* 隔离配置）
    # 3. 安装路径 / 显示名称 / 版本字符串匹配（兜底）
    #
    # 注意：buildNumber（如 AI-242.23339.11.2421.12700392）第三位是 IntelliJ 平台小版本，
    # 不是发布渠道；Stable / Canary 可共享同一 AI-242 分支号。

    if (-not [string]::IsNullOrWhiteSpace($VersionSuffix)) {
        $suffix = $VersionSuffix.Trim()
        if ($suffix -match '(?i)canary') { return "Canary" }
        if ($suffix -match '(?i)beta') { return "Beta" }
        if ($suffix -match '(?i)\brc\b|release candidate') { return "RC" }
        if ($suffix -match '(?i)preview') { return "Preview" }
        if ($suffix -match '(?i)eap') { return "Canary" }
        if ($suffix -match '(?i)dev|nightly') { return "Dev" }
        return $suffix
    }

    if ($DataDirName -match '(?i)preview') {
        $hint = "$Path $Name $Version $DataDirName"
        if ($hint -match '(?i)canary') { return "Canary" }
        if ($hint -match '(?i)beta') { return "Beta" }
        if ($hint -match '(?i)\brc\b|release candidate') { return "RC" }
        return "Preview"
    }

    $all = "$Path $Name $Version $DataDirName"
    if ($all -match '(?i)canary') { return "Canary" }
    if ($all -match '(?i)beta') { return "Beta" }
    if ($all -match '(?i)\brc\b|release candidate|preview') { return "Preview" }
    if ($all -match '(?i)dev|nightly') { return "Dev" }
    return "Stable"
}

function Get-RegistryKeyPath {
    param($Item)
    if (-not $Item) { return "" }
    $psPath = "$($Item.PSPath)"
    if ([string]::IsNullOrWhiteSpace($psPath)) { return "" }
    return ($psPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', '')
}

function Add-CandidatePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )

    $normalized = Normalize-DirPath $Path
    if (-not $normalized) { return }
    if ($List | Where-Object { $_ -ieq $normalized }) { return }
    [void]$List.Add($normalized)
}

function Get-OfficialProductRegPaths {
    return @(
        "HKLM:\SOFTWARE\Android Studio",
        "HKLM:\SOFTWARE\WOW6432Node\Android Studio",
        "HKCU:\SOFTWARE\Android Studio"
    )
}

Write-DetectProgress -Percent 5 -Message "正在检测：运行中进程..."

Get-Process studio64,studio -ErrorAction SilentlyContinue | ForEach-Object {
    Add-FromExePath -ExePath $_.Path -Source "运行中进程"
}

# 官方 NSIS 安装器主写入点（优先于 Uninstall.InstallLocation）
Write-DetectProgress -Percent 12 -Message "正在检测：官方产品注册表..."

$shellEarly = $null
$nsisRegValues = @{}  # 存储 NSIS 安装器写入的附加注册表值 (per-path)

foreach ($productKey in (Get-OfficialProductRegPaths)) {
    if (-not (Test-Path -LiteralPath $productKey)) { continue }

    $product = Get-ItemProperty -LiteralPath $productKey -ErrorAction SilentlyContinue
    $productPath = Normalize-DirPath $product.Path
    $regKeyPath = Get-RegistryKeyPath $product
    $startMenuGroup = "$($product.StartMenuGroup)"
    if ([string]::IsNullOrWhiteSpace($startMenuGroup)) { $startMenuGroup = "Android Studio" }

    # 收集 NSIS 安装器写入的附加注册表值
    if ($productPath) {
        $nsisKey = Get-CanonicalPath $productPath
        if (-not $nsisKey) { $nsisKey = $productPath }
        $nsisRegValues[$nsisKey.ToLowerInvariant()] = [PSCustomObject]@{
            SdkPath          = "$(Normalize-DirPath $product.SdkPath)"
            InstallSdk       = "$($product.InstallSdk)"
            InstallHaxm      = "$($product.InstallHaxm)"
            UserSettingsPath = "$(Normalize-DirPath $product.UserSettingsPath)"
            StartMenuGroup   = $startMenuGroup
        }
    }

    if ($productPath -and (Test-ValidInstallDir $productPath)) {
        Add-InstallPath -InstallPath $productPath -Source "注册表 SOFTWARE\Android Studio"
    } else {
        $reason = if ([string]::IsNullOrWhiteSpace($productPath)) {
            "官方产品键仍在，但 Path 为空（疑似强卸残留）"
        } elseif (-not (Test-Path -LiteralPath $productPath)) {
            "官方产品键仍在，但 Path 指向的安装目录不存在"
        } else {
            "官方产品键仍在，但 Path 目录缺少 studio 可执行文件 / product-info"
        }

        Add-Residue `
            -Kind "registry" `
            -Name "Android Studio" `
            -Path $(if ($productPath) { $productPath } else { "" }) `
            -RegistryKey $regKeyPath `
            -Version "" `
            -Reason $reason `
            -Source "官方产品注册表"
    }

    # StartMenuGroup 指向的开始菜单目录（安装器 CreateShortCut 目标）
    $smRoots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\$startMenuGroup",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\$startMenuGroup"
    )
    foreach ($smRoot in $smRoots) {
        if (-not (Test-Path -LiteralPath $smRoot)) { continue }
        if (-not $shellEarly) { $shellEarly = New-Object -ComObject WScript.Shell }
        Get-ChildItem -LiteralPath $smRoot -Filter *.lnk -ErrorAction SilentlyContinue | ForEach-Object {
            $lnk = $shellEarly.CreateShortcut($_.FullName)
            Add-FromExePath -ExePath $lnk.TargetPath -Source ("注册表 StartMenuGroup " + $_.FullName)
        }
    }
}

Write-DetectProgress -Percent 18 -Message "正在检测：卸载注册表..."

$uninstallRegPaths = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
)

foreach ($regPath in $uninstallRegPaths) {
    $uninstallItems = @(
        Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match '(?i)Android Studio' }
    )

    foreach ($item in $uninstallItems) {
        $displayName = "$($item.DisplayName)"
        $displayVersion = "$($item.DisplayVersion)"
        $regKey = Get-RegistryKeyPath $item
        $installLoc = Normalize-DirPath $item.InstallLocation

        # 有效安装仍按原逻辑收录
        Add-InstallPath -InstallPath $item.InstallLocation -Source "注册表 InstallLocation"
        Add-FromCommandText -CommandText $item.DisplayIcon -Source "注册表 DisplayIcon"
        Add-FromCommandText -CommandText $item.UninstallString -Source "注册表 UninstallString"
        Add-FromCommandText -CommandText $item.QuietUninstallString -Source "注册表 QuietUninstallString"
        Add-FromCommandText -CommandText $item.ModifyPath -Source "注册表 ModifyPath"

        # 候选只来自本卸载项自身字段，避免把其他安装的官方 Path 填进来漏报残留
        $candidates = New-Object System.Collections.Generic.List[string]
        Add-CandidatePath -List $candidates -Path $installLoc
        foreach ($cmd in @(
            $item.UninstallString,
            $item.QuietUninstallString,
            $item.DisplayIcon,
            $item.ModifyPath
        )) {
            Add-CandidatePath -List $candidates -Path (Get-InstallPathFromCommand $cmd)
        }

        $validPath = $null
        foreach ($candidate in $candidates) {
            if (Test-ValidInstallDir $candidate) {
                $validPath = $candidate
                break
            }
        }

        # 仍能解析到有效安装 → 不是残留（仅缺 InstallLocation 字段很常见）
        if ($validPath) { continue }

        $reportPath = if ($installLoc) { $installLoc } elseif ($candidates.Count -gt 0) { $candidates[0] } else { "" }

        if ($candidates.Count -eq 0) {
            $reason = "卸载项仍在，且无法从 InstallLocation / UninstallString / DisplayIcon 解析安装路径"
        } elseif ($reportPath -and -not (Test-Path -LiteralPath $reportPath)) {
            $reason = "卸载项仍在，但安装目录不存在"
        } else {
            $reason = "卸载项仍在，但安装目录缺少 studio 可执行文件 / product-info（疑似未卸干净）"
        }

        Add-Residue `
            -Kind "registry" `
            -Name $displayName `
            -Path $reportPath `
            -RegistryKey $regKey `
            -Version $displayVersion `
            -Reason $reason `
            -Source "卸载注册表"
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

# 首次运行后 Local 配置目录里的 .home 回指安装根（IDE 运行期写入，可反查安装）
Write-DetectProgress -Percent 42 -Message "正在检测：IDE 配置回指 (.home)..."

$googleLocal = Join-Path $env:LOCALAPPDATA "Google"
if (Test-Path -LiteralPath $googleLocal) {
    Get-ChildItem -LiteralPath $googleLocal -Directory -Filter "AndroidStudio*" -ErrorAction SilentlyContinue | ForEach-Object {
        $homeFile = Join-Path $_.FullName ".home"
        if (-not (Test-Path -LiteralPath $homeFile)) { return }
        try {
            $homePath = (Get-Content -LiteralPath $homeFile -TotalCount 1 -ErrorAction Stop)
        } catch { return }
        Add-InstallPath -InstallPath $homePath -Source ("IDE .home " + $_.Name)
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
    $roots = @()
    if ($DeepScanRoots -and $DeepScanRoots.Count -gt 0) {
        $roots = $DeepScanRoots
    } else {
        $roots = (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -ExpandProperty DeviceID | ForEach-Object { "$_\" })
    }

    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }

        Write-DetectProgress -Percent 85 -Message "正在深度扫描：$root（耗时较长）..." -Path $root

        # -Include 在无通配路径时可能只扫顶层；拼 \* 才能真正递归。
        $searchRoot = $root.TrimEnd('\') + '\*'
        Get-ChildItem -Path $searchRoot -Include studio64.exe, studio.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            Add-FromExePath -ExePath $_.FullName -Source ("深度扫描 " + $root)
        }
    }
}

# 孤儿配置检测：所有检测源完成后再拍快照，避免漏掉快捷方式 / Toolbox / 常见路径 / 深度扫描才发现的安装
Write-DetectProgress -Percent 90 -Message "正在检测：运行时配置残留..."

$knownInstallPaths = @($found.Keys)
$googleRoaming = Join-Path $env:APPDATA "Google"
$googleLocal = Join-Path $env:LOCALAPPDATA "Google"

# 收集所有已知安装的 dataDirectoryName 用于关联
$knownDataDirNames = @{}
foreach ($entry in $found.Values) {
    $infoPath = Join-Path $entry.Path "product-info.json"
    if (Test-Path -LiteralPath $infoPath) {
        try {
            $pi = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
            if ($pi.dataDirectoryName) {
                $knownDataDirNames["$($pi.dataDirectoryName)".ToLowerInvariant()] = $true
            }
        } catch {}
    }
}

# 收集所有 selector (Local + Roaming)
$allSelectors = @{}

if (Test-Path -LiteralPath $googleLocal) {
    Get-ChildItem -LiteralPath $googleLocal -Directory -Filter "AndroidStudio*" -ErrorAction SilentlyContinue | ForEach-Object {
        $allSelectors[$_.Name] = [PSCustomObject]@{
            LocalDir   = $_.FullName
            RoamingDir = ""
            HomePath   = ""
            Matched    = $false
        }
    }
}

if (Test-Path -LiteralPath $googleRoaming) {
    Get-ChildItem -LiteralPath $googleRoaming -Directory -Filter "AndroidStudio*" -ErrorAction SilentlyContinue | ForEach-Object {
        if ($allSelectors.ContainsKey($_.Name)) {
            $allSelectors[$_.Name].RoamingDir = $_.FullName
        } else {
            $allSelectors[$_.Name] = [PSCustomObject]@{
                LocalDir   = ""
                RoamingDir = $_.FullName
                HomePath   = ""
                Matched    = $false
            }
        }
    }
}

# 关联检查：对每个 selector 判断是否属于已知安装
foreach ($selector in $allSelectors.Keys) {
    $info = $allSelectors[$selector]

    # 检查 1: dataDirectoryName 直接匹配已知安装
    if ($knownDataDirNames.ContainsKey($selector.ToLowerInvariant())) {
        $info.Matched = $true
        continue
    }

    # 检查 2: .home 文件回指已知安装
    if ($info.LocalDir) {
        $homeFile = Join-Path $info.LocalDir ".home"
        if (Test-Path -LiteralPath $homeFile) {
            try {
                $homePath = (Get-Content -LiteralPath $homeFile -TotalCount 1 -ErrorAction Stop).Trim()
                $info.HomePath = $homePath
                if ($homePath) {
                    $resolvedHome = try { (Resolve-Path -LiteralPath $homePath -ErrorAction Stop).Path } catch { $homePath }
                    if ($knownInstallPaths -contains $resolvedHome.ToLowerInvariant()) {
                        $info.Matched = $true
                        continue
                    }
                }
            } catch {}
        }
    }
}

# 未关联的标记为孤儿残留
foreach ($selector in ($allSelectors.Keys | Sort-Object)) {
    $info = $allSelectors[$selector]
    if ($info.Matched) { continue }

    $orphanPaths = @()
    if ($info.LocalDir) { $orphanPaths += $info.LocalDir }
    if ($info.RoamingDir) { $orphanPaths += $info.RoamingDir }
    $pathStr = $orphanPaths -join "; "

    $reason = if ($info.HomePath) {
        "运行时配置目录存在，但 .home 指向的安装 [$($info.HomePath)] 已不存在（卸载后残留）"
    } else {
        "运行时配置目录存在，但无法关联到已知安装（疑似残留）"
    }

    Add-Residue `
        -Kind "orphanConfig" `
        -Name $selector `
        -Path $pathStr `
        -RegistryKey "" `
        -Version "" `
        -Reason $reason `
        -Source "运行时配置目录"
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
    $dataDirectoryName = ""
    $versionSuffix = ""
    $productVendor = ""
    $productCode = ""
    $launcherPath = ""

    if (Test-Path -LiteralPath $infoPath) {
        try {
            $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
            $name = "$($info.name)"
            $version = "$($info.version)"
            $build = "$($info.buildNumber)"
            $dataDirectoryName = "$($info.dataDirectoryName)"
            $versionSuffix = "$($info.versionSuffix)"
            $productVendor = "$($info.productVendor)"
            $productCode = "$($info.productCode)"
            # 提取 Windows amd64 launcherPath
            if ($info.launch) {
                $winLaunch = @($info.launch | Where-Object { $_.os -eq "Windows" -and $_.arch -eq "amd64" })
                if ($winLaunch.Count -gt 0) { $launcherPath = "$($winLaunch[0].launcherPath)" }
            }
        } catch {}
    }

    if (-not $build -and (Test-Path -LiteralPath $buildPath)) {
        $build = (Get-Content -LiteralPath $buildPath -TotalCount 1)
    }

    # 渠道检测：versionSuffix → dataDirectoryName → 路径字符串
    $channel = Get-Channel -Path $path -Name $name -Version $version -DataDirName $dataDirectoryName -VersionSuffix $versionSuffix
    $sources = ($entry.Sources | Sort-Object) -join "；"

    $nsisReg = $nsisRegValues[$path.ToLowerInvariant()]

    $results += [PSCustomObject]@{
        path = $path
        executable = $exe
        name = $name
        version = $version
        build = $build
        dataDirectoryName = $dataDirectoryName
        productVendor = $productVendor
        productCode = $productCode
        launcherPath = $launcherPath
        channel = $channel
        source = $sources
        sdkPath = if ($nsisReg) { $nsisReg.SdkPath } else { "" }
        installSdk = if ($nsisReg) { $nsisReg.InstallSdk } else { "" }
        installHaxm = if ($nsisReg) { $nsisReg.InstallHaxm } else { "" }
        userSettingsPath = if ($nsisReg) { $nsisReg.UserSettingsPath } else { "" }
    }
}

Write-DetectProgress -Percent 95 -Message "正在整理检测结果..."

$payload = [ordered]@{
    installs = @($results)
    residues = @($residues.ToArray())
}
$jsonText = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
if ([string]::IsNullOrWhiteSpace($jsonText)) {
    $jsonText = '{"installs":[],"residues":[]}'
}

if ($Json) {
    Write-DetectProgress -Percent 100 -Message "检测完成"
    if ($Progress) {
        [Console]::Out.WriteLine("@@RESULT|" + $jsonText + "@@")
        [Console]::Out.Flush()
    } else {
        Write-Output $jsonText
    }
    exit 0
}

Write-Host ""
Write-Host "检测结果："

if ($results.Count -eq 0) {
    Write-Host "未检测到 Android Studio 安装。"
} else {
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
        if ($r.dataDirectoryName) { Write-Host ("数据目录名：" + $r.dataDirectoryName) }
        if ($r.productVendor) { Write-Host ("厂商：" + $r.productVendor) }
        if ($r.channel) { Write-Host ("渠道：" + $r.channel) }
        if ($r.sdkPath) { Write-Host ("SDK 路径：" + $r.sdkPath) }
        if ($r.userSettingsPath) { Write-Host ("用户设置路径：" + $r.userSettingsPath) }
        Write-Host ("检测来源：" + $r.source)
        Write-Host ""
        $index++
    }
}

if ($residues.Count -gt 0) {
    Write-Host ("发现 " + $residues.Count + " 处卸载残留：")
    Write-Host ""
    $index = 1
    foreach ($r in $residues) {
        Write-Host ("[残留 " + $index + "]")
        Write-Host ("名称：" + $r.name)
        Write-Host ("路径：" + $r.path)
        Write-Host ("注册表：" + $r.registryKey)
        Write-Host ("原因：" + $r.reason)
        Write-Host ""
        $index++
    }
}

exit 0
