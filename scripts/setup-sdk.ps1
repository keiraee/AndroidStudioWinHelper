param(
    [string]$SdkDir = "",
    [string]$ResultFile = "",
    [string]$Proxy = "",
    [string]$Mirror = "flutter",
    [string]$Action = "",          # install, uninstall, list, accept-licenses
    [string]$Packages = "",        # 竖线分隔的包列表（包 ID 本身可含分号）
    [switch]$Json
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

function Write-Progress2 {
    param([int]$Percent, [string]$Message)
    if ($Json) {
        [Console]::Out.WriteLine("@@PROGRESS|$Percent|$Message@@")
        [Console]::Out.Flush()
    }
}

function Write-Result2 {
    param([hashtable]$Result)
    $jsonResult = $Result | ConvertTo-Json -Depth 10 -Compress
    if ($ResultFile) {
        Set-Content -Path $ResultFile -Value $jsonResult -Encoding UTF8
    }
    if ($Json) {
        [Console]::Out.WriteLine("@@RESULT|$jsonResult@@")
        [Console]::Out.Flush()
    }
}

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "HH:mm:ss.fff"
    Write-Host "[$ts] $Message"
}

function Get-SdkmanagerArgs {
    param([string[]]$ExtraArgs)
    $sdkArgs = @("--sdk_root=$SdkDir")
    if ($Proxy) {
        $proxyUri = [Uri]$Proxy
        $sdkArgs += "--proxy_host=$($proxyUri.Host)"
        $sdkArgs += "--proxy_port=$($proxyUri.Port)"
        $sdkArgs += "--proxy=http"
    }
    if ($ExtraArgs) { $sdkArgs += $ExtraArgs }
    return $sdkArgs
}

# ============================================================
# 1. 确定 SDK 目录
# ============================================================
Write-Progress2 -Percent 3 -Message "正在检测 SDK 目录..."

if (-not $SdkDir) {
    foreach ($envName in @("ANDROID_HOME", "ANDROID_SDK_ROOT")) {
        $envVal = [Environment]::GetEnvironmentVariable($envName, "Machine")
        if (-not $envVal) { $envVal = [Environment]::GetEnvironmentVariable($envName, "User") }
        if ($envVal -and (Test-Path $envVal)) {
            $SdkDir = $envVal.TrimEnd('\', '/')
            Write-Log "从环境变量 $envName 检测到 SDK: $SdkDir"
            break
        }
    }
    if (-not $SdkDir) {
        $commonPaths = @(
            "D:\Android\Sdk", "C:\Android\Sdk",
            (Join-Path $env:LOCALAPPDATA "Android\Sdk")
        )
        foreach ($p in $commonPaths) {
            if ($p -and (Test-Path $p)) { $SdkDir = $p; break }
        }
    }
    if (-not $SdkDir) { $SdkDir = Join-Path $env:LOCALAPPDATA "Android\Sdk" }
}

Write-Log "SDK 路径: $SdkDir"

$env:ANDROID_HOME = $SdkDir
$env:ANDROID_SDK_ROOT = $SdkDir

# ============================================================
# 2. 镜像源 & 代理
# ============================================================
$mirrorPrefix = switch ($Mirror) {
    "flutter"  { "https://storage.flutter-io.cn" }
    "tencent"  { "https://mirrors.cloud.tencent.com" }
    "bfsu"     { "https://mirrors.bfsu.edu.cn" }
    default    { "" }
}
$googleBase = if ($mirrorPrefix) { "$mirrorPrefix/dl.google.com" } else { "https://dl.google.com" }
Write-Log "镜像: $Mirror -> $googleBase"

if ($Proxy) {
    $proxyUri = [Uri]$Proxy
    $env:JAVA_TOOL_OPTIONS = "-Dhttp.proxyHost=$($proxyUri.Host) -Dhttp.proxyPort=$($proxyUri.Port) -Dhttps.proxyHost=$($proxyUri.Host) -Dhttps.proxyPort=$($proxyUri.Port)"
    Write-Log "代理: $($proxyUri.Host):$($proxyUri.Port)"
}

# ============================================================
# 3. 安装 cmdline-tools（如果缺失）
# ============================================================
$cmdlineToolsPath = "$SdkDir\cmdline-tools\latest\bin\sdkmanager.bat"

if (-not (Test-Path $cmdlineToolsPath) -and $Action -ne "list-installed") {
    Write-Progress2 -Percent 10 -Message "正在下载 Command-line Tools..."
    $dlUrl = "$googleBase/android/repository/commandlinetools-win-11076708_latest.zip"
    $zipPath = "$env:TEMP\aswh_cmdline-tools.zip"
    Write-Log "下载: $dlUrl"

    try {
        $wc = New-Object System.Net.WebClient
        if ($Proxy) { $wc.Proxy = New-Object System.Net.WebProxy($Proxy) }
        $wc.DownloadFile($dlUrl, $zipPath)
    } catch {
        Write-Result2 @{ success = $false; message = "下载 Command-line Tools 失败: $_"; sdkDir = $SdkDir }
        exit 1
    }

    Write-Progress2 -Percent 20 -Message "正在解压..."
    $tempExtract = "$env:TEMP\aswh_cmdtools_extract"
    if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
    try {
        Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force
        $targetDir = "$SdkDir\cmdline-tools\latest"
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }
        Copy-Item "$tempExtract\cmdline-tools\*" "$targetDir\" -Recurse -Force
    } catch {
        Write-Result2 @{ success = $false; message = "解压失败: $_"; sdkDir = $SdkDir }
        exit 1
    } finally {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }

    $cmdlineToolsPath = "$SdkDir\cmdline-tools\latest\bin\sdkmanager.bat"
}

# ============================================================
# 4. 检查 Java
# ============================================================
$javaFound = $false
$javaExe = ""
try {
    $javaResult = & java -version 2>&1 | Out-String
    if ($javaResult -match "version") { $javaFound = $true }
} catch {}
if (-not $javaFound) {
    foreach ($c in @(
        "${env:ProgramFiles}\Android\Android Studio\jbr\bin\java.exe",
        "${env:LOCALAPPDATA}\Android\Android Studio\jbr\bin\java.exe"
    )) {
        if (Test-Path $c) { $javaExe = $c; $javaFound = $true; break }
    }
}
if ($javaExe) {
    $env:JAVA_HOME = Split-Path (Split-Path $javaExe -Parent) -Parent
}

# ============================================================
# 5. 根据 Action 执行操作
# ============================================================

if ($Action -eq "list-installed" -or $Action -eq "") {
    # ---- 列出已安装和可用包 ----
    Write-Progress2 -Percent 40 -Message "正在查询包列表..."

    $result = @{
        success = $true
        sdkDir = $SdkDir
        hasJava = $javaFound
        installed = @()
        available = @()
    }

    # 已安装
    if (Test-Path $cmdlineToolsPath) {
        try {
            $out = & $cmdlineToolsPath --sdk_root=$SdkDir --list_installed 2>&1 | Out-String
            $inSection = $false
            foreach ($line in ($out -split "`n")) {
                $trimmed = $line.Trim()
                if ($trimmed -match "Installed packages") { $inSection = $true; continue }
                if ($trimmed -match "Available Packages" -or $trimmed -match "Available Updates") { $inSection = $false; continue }
                if ($inSection -and $trimmed -and $trimmed -notmatch "^-+$" -and $trimmed -notmatch "^\s*$" -and $trimmed -notmatch "^Path\s") {
                    # 解析 sdkmanager 表格行: "pkg  |  version  |  description  |  location"
                    $parts = $trimmed -split '\s*\|\s*' | ForEach-Object { $_.Trim() }
                    if ($parts.Count -ge 3) {
                        $result.installed += @{
                            path = $parts[0]
                            version = $parts[1]
                            description = $parts[2]
                            location = if ($parts.Count -ge 4) { $parts[3] } else { "" }
                        }
                    } elseif ($parts.Count -ge 1 -and $parts[0]) {
                        $result.installed += @{ path = $parts[0]; version = ""; description = ""; location = "" }
                    }
                }
            }
        } catch {
            Write-Log "查询已安装包失败: $_"
        }

        # 可用包（带超时，防止网络问题导致卡死）
        try {
            $job = Start-Job -ScriptBlock {
                param($sdkRoot, $toolsPath)
                & $toolsPath --sdk_root=$sdkRoot --list 2>&1 | Out-String
            } -ArgumentList $SdkDir, $cmdlineToolsPath

            $finished = Wait-Job $job -Timeout 15
            if ($finished) {
                $availOut = Receive-Job $job
                $inAvail = $false
                $availCount = 0
                foreach ($line in ($availOut -split "`n")) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match "Available Packages") { $inAvail = $true; continue }
                    if ($trimmed -match "Available Updates") { $inAvail = $false; continue }
                    if ($inAvail -and $trimmed -and $trimmed -notmatch "^-+$" -and $trimmed -notmatch "^\s*$" -and $availCount -lt 200) {
                        $pkgName = ($trimmed -split '\s+')[0]
                        if ($pkgName -and $pkgName -notmatch "^Available" -and $pkgName -notmatch "^Path$") {
                            $result.available += $pkgName
                            $availCount++
                        }
                    }
                }
            } else {
                Write-Log "查询可用包超时(15s)，跳过"
                Stop-Job $job
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log "查询可用包失败: $_"
        }
    }

    Write-Result2 $result
    exit 0
}

if ($Action -eq "install") {
    # ---- 安装指定包 ----
    if (-not $Packages) {
        Write-Result2 @{ success = $false; message = "未指定要安装的包" }
        exit 1
    }
    if (-not (Test-Path $cmdlineToolsPath)) {
        Write-Result2 @{ success = $false; message = "sdkmanager 不存在" }
        exit 1
    }

    $pkgList = $Packages -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $installLog = @()

    # 先接受所有 license
    Write-Progress2 -Percent 30 -Message "正在接受 SDK 协议..."
    Write-Log "接受所有 SDK 协议..."
    try {
        $acceptArgs = Get-SdkmanagerArgs @("--licenses")
        $cmd = "echo y | `"$cmdlineToolsPath`" $($acceptArgs -join ' ')"
        $null = cmd.exe /c $cmd 2>&1 | Out-String
        Write-Log "协议接受完成"
    } catch {
        Write-Log "协议接受过程: $_"
    }

    # 逐个安装
    $failedCount = 0
    for ($i = 0; $i -lt $pkgList.Count; $i++) {
        $pkg = $pkgList[$i]
        $pct = 50 + [math]::Floor(40 * ($i + 1) / ($pkgList.Count + 1))
        Write-Progress2 -Percent $pct -Message "正在安装: $pkg"
        Write-Log "安装: $pkg"

        try {
            $sdkArgs = Get-SdkmanagerArgs @($pkg)
            $cmd = "echo y | `"$cmdlineToolsPath`" $($sdkArgs -join ' ')"
            $output = cmd.exe /c $cmd 2>&1 | Out-String

            if ($output -match "done" -or $output -match "Packages installed" -or $LASTEXITCODE -eq 0) {
                Write-Log "安装成功: $pkg"
                $installLog += "$pkg : OK"
            } else {
                Write-Log "安装失败: $pkg (exit=$LASTEXITCODE)"
                $installLog += "$pkg : FAILED"
                $failedCount++
            }
        } catch {
            Write-Log "安装失败: $pkg - $_"
            $installLog += "$pkg : FAILED - $_"
            $failedCount++
        }
    }

    # AEHD 驱动
    $aehdInstaller = "$SdkDir\extras\google\Android_Emulator_Hypervisor_Driver\silent_install.bat"
    $aehdOk = $true
    if ($pkgList -contains "extras;google;Android_Emulator_Hypervisor_Driver") {
        if (Test-Path $aehdInstaller) {
            Write-Log "安装 AEHD 驱动..."
            try {
                & $aehdInstaller 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
                    $installLog += "AEHD Driver : FAILED (exit=$LASTEXITCODE)"
                    $aehdOk = $false
                    $failedCount++
                } else {
                    $installLog += "AEHD Driver : OK"
                }
            } catch {
                $installLog += "AEHD Driver : FAILED - $_"
                $aehdOk = $false
                $failedCount++
            }
        } else {
            Write-Log "AEHD 安装器不存在: $aehdInstaller"
            $installLog += "AEHD Driver : FAILED - installer missing"
            $aehdOk = $false
            $failedCount++
        }
    }

    $allOk = ($failedCount -eq 0)
    Write-Progress2 -Percent 100 -Message $(if ($allOk) { "安装完成" } else { "安装部分失败" })
    Write-Result2 @{
        success = $allOk
        message = if ($allOk) {
            "安装完成: $($installLog.Count) 个包"
        } else {
            "安装失败 $failedCount 个包（共 $($pkgList.Count) 个）"
        }
        installLog = ($installLog -join "`n")
    }
    exit $(if ($allOk) { 0 } else { 1 })
}

if ($Action -eq "uninstall") {
    # ---- 卸载指定包 ----
    if (-not $Packages) {
        Write-Result2 @{ success = $false; message = "未指定要卸载的包" }
        exit 1
    }

    $pkgList = $Packages -split "\|" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $uninstallLog = @()

    $failedCount = 0
    for ($i = 0; $i -lt $pkgList.Count; $i++) {
        $pkg = $pkgList[$i]
        Write-Progress2 -Percent (30 + [math]::Floor(60 * ($i + 1) / $pkgList.Count)) -Message "正在卸载: $pkg"
        Write-Log "卸载: $pkg"

        try {
            $sdkArgs = Get-SdkmanagerArgs @("--uninstall", $pkg)
            $cmd = "`"$cmdlineToolsPath`" $($sdkArgs -join ' ')"
            $output = cmd.exe /c $cmd 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
                $uninstallLog += "$pkg : FAILED (exit=$LASTEXITCODE)"
                $failedCount++
            } else {
                $uninstallLog += "$pkg : OK"
            }
        } catch {
            $uninstallLog += "$pkg : FAILED - $_"
            $failedCount++
        }
    }

    $allOk = ($failedCount -eq 0)
    Write-Progress2 -Percent 100 -Message $(if ($allOk) { "卸载完成" } else { "卸载部分失败" })
    Write-Result2 @{
        success = $allOk
        message = if ($allOk) { "卸载完成" } else { "卸载失败 $failedCount 个包" }
        uninstallLog = ($uninstallLog -join "`n")
    }
    exit $(if ($allOk) { 0 } else { 1 })
}

if ($Action -eq "accept-licenses") {
    # ---- 接受所有 license ----
    Write-Progress2 -Percent 50 -Message "正在接受 SDK 协议..."
    try {
        $sdkArgs = Get-SdkmanagerArgs @("--licenses")
        $cmd = "echo y | `"$cmdlineToolsPath`" $($sdkArgs -join ' ')"
        $output = cmd.exe /c $cmd 2>&1 | Out-String
        Write-Result2 @{ success = $true; message = "所有协议已接受"; output = $output.Substring(0, [Math]::Min(500, $output.Length)) }
    } catch {
        Write-Result2 @{ success = $false; message = "接受协议失败: $_" }
    }
    exit 0
}

Write-Result2 @{ success = $false; message = "未知操作: $Action" }
