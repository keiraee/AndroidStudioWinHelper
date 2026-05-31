param(
    [string]$ResultFile
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

$checks = @()

function Add-Check {
    param(
        [string]$Name,
        [string]$Category,
        [string]$Label,
        [string]$Status,
        [string]$Detail,
        [string]$Suggestion = ""
    )
    $script:checks += @{
        name       = $Name
        category   = $Category
        label      = $Label
        status     = $Status
        detail     = $Detail
        suggestion = $Suggestion
    }
}

# ============================================================
# 1. System Hardware
# ============================================================

# --- CPU Virtualization ---
$cpuName = ""
try {
    $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
    $cpuName = $cpu.Name
    $hasVTx = $cpu.VMMonitorModeExtensions -eq $true
    if (-not $hasVTx) {
        $hasVTx = $cpuName -match 'Intel'
        $hasAMDV = $cpuName -match 'AMD'
    }
    if ($hasVTx -or $hasAMDV) {
        Add-Check -Name "cpu_vt" -Category "硬件环境" -Label "CPU 虚拟化支持" -Status "ok" -Detail "$cpuName"
    } else {
        Add-Check -Name "cpu_vt" -Category "硬件环境" -Label "CPU 虚拟化支持" -Status "warning" -Detail "$cpuName (未确认 VT-x/AMD-V)" -Suggestion "请进入 BIOS 检查 Intel VT-x 或 AMD-V 是否已启用"
    }
} catch {
    Add-Check -Name "cpu_vt" -Category "硬件环境" -Label "CPU 虚拟化支持" -Status "error" -Detail "检测失败: $_"
}

# --- GPU Info ---
try {
    $gpus = Get-CimInstance Win32_VideoController -ErrorAction Stop
    $gpuLines = @()
    foreach ($gpu in $gpus) {
        if ([string]::IsNullOrWhiteSpace($gpu.Name)) { continue }
        $gpuLines += "$($gpu.Name) ($($gpu.DriverVersion))"
    }
    if ($gpuLines.Count -gt 0) {
        Add-Check -Name "gpu_driver" -Category "硬件环境" -Label "GPU 驱动" -Status "ok" -Detail ($gpuLines -join " | ")
    }
} catch {
    Add-Check -Name "gpu_driver" -Category "硬件环境" -Label "GPU 驱动" -Status "unknown" -Detail "检测失败: $_"
}

# --- Disk Type ---
try {
    $disks = Get-PhysicalDisk -ErrorAction Stop
    $diskInfo = @()
    $hasSSD = $false
    foreach ($disk in $disks) {
        $mediaType = $disk.MediaType
        if ($mediaType -eq "SSD") { $hasSSD = $true }
        $sizeGB = [math]::Round($disk.Size / 1GB, 0)
        $diskInfo += "$($disk.FriendlyName): $mediaType ($sizeGB GB)"
    }
    $status = if ($hasSSD) { "ok" } else { "warning" }
    $suggestion = if (-not $hasSSD) { "检测到全部为 HDD，模拟器启动速度会非常慢，建议将 AVD 目录迁移到 SSD" } else { "" }
    Add-Check -Name "disk_type" -Category "硬件环境" -Label "磁盘类型" -Status $status -Detail ($diskInfo -join " | ") -Suggestion $suggestion
} catch {
    Add-Check -Name "disk_type" -Category "硬件环境" -Label "磁盘类型" -Status "unknown" -Detail "无法获取磁盘类型: $_"
}

# --- RAM ---
$script:totalRAM = $null
try {
    $ram = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalRAM = [math]::Round($ram.TotalVisibleMemorySize / 1MB, 1)
    $script:totalRAM = $totalRAM
    $freeRAM = [math]::Round($ram.FreePhysicalMemory / 1MB, 1)
    $status = if ($totalRAM -lt 8) { "warning" } else { "ok" }
    $suggestion = if ($totalRAM -lt 8) { "物理内存 ${totalRAM}GB 偏少，运行模拟器时建议分配不超过 2048MB，避免系统卡顿" } else { "" }
    Add-Check -Name "system_ram" -Category "硬件环境" -Label "系统内存" -Status $status -Detail "总计 ${totalRAM}GB | 可用 ${freeRAM}GB" -Suggestion $suggestion
} catch {
    Add-Check -Name "system_ram" -Category "硬件环境" -Label "系统内存" -Status "unknown" -Detail "检测失败: $_"
}

# --- Disk Free Space ---
try {
    $sysDrive = $env:SystemDrive
    $disk = Get-PSDrive -Name ($sysDrive.TrimEnd(':')) -ErrorAction Stop
    $freeGB = [math]::Round($disk.Free / 1GB, 1)
    $usedGB = [math]::Round($disk.Used / 1GB, 1)
    $totalGB = $freeGB + $usedGB
    $status = if ($freeGB -lt 10) { "error" } elseif ($freeGB -lt 30) { "warning" } else { "ok" }
    $suggestion = ""
    if ($freeGB -lt 10) { $suggestion = "系统盘剩余 ${freeGB}GB 严重不足，模拟器快照保存可能失败，建议清理至少 20GB 空间" }
    elseif ($freeGB -lt 30) { $suggestion = "系统盘剩余 ${freeGB}GB 偏少，建议保持 30GB 以上以确保模拟器稳定运行" }
    Add-Check -Name "disk_space" -Category "硬件环境" -Label "磁盘剩余空间" -Status $status -Detail "$sysDrive 总计 ${totalGB}GB | 可用 ${freeGB}GB" -Suggestion $suggestion
} catch {
    Add-Check -Name "disk_space" -Category "硬件环境" -Label "磁盘剩余空间" -Status "unknown" -Detail "检测失败: $_"
}

# ============================================================
# 2. Virtualization
# ============================================================

# --- VirtualMachinePlatform ---
try {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if ($vmp.State -eq "Enabled") {
        Add-Check -Name "virtual_machine_platform" -Category "虚拟化配置" -Label "VirtualMachinePlatform" -Status "ok" -Detail "已启用 (WHPX 依赖组件)"
    } else {
        Add-Check -Name "virtual_machine_platform" -Category "虚拟化配置" -Label "VirtualMachinePlatform" -Status "warning" -Detail "未启用" -Suggestion "VirtualMachinePlatform 是 WHPX 的依赖组件，启用 WHPX 时需同时开启此功能"
    }
} catch {
    Add-Check -Name "virtual_machine_platform" -Category "虚拟化配置" -Label "VirtualMachinePlatform" -Status "unknown" -Detail "无法检测 (需要管理员权限): $_"
}

# --- HAXM ---
try {
    $haxm = Get-Service -Name "intelhaxm" -ErrorAction Stop
    $status = if ($haxm.Status -eq "Running") { "warning" } else { "ok" }
    $detail = "状态: $($haxm.Status)"
    $suggestion = ""
    if ($haxm.Status -eq "Running") {
        $detail += " | HAXM 正在运行"
        $suggestion = "HAXM 与 Hyper-V 互斥。如果你使用 Hyper-V/WHPX，HAXM 无法工作，无需担心。如需用 HAXM，须先关闭 Hyper-V。"
    }
    Add-Check -Name "haxm" -Category "虚拟化配置" -Label "HAXM (Intel 加速器)" -Status $status -Detail $detail -Suggestion $suggestion
} catch {
    Add-Check -Name "haxm" -Category "虚拟化配置" -Label "HAXM (Intel 加速器)" -Status "ok" -Detail "未安装 HAXM（使用 Hyper-V/WHPX 时不需要）"
}

# --- Credential Guard ---
try {
    $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
    $cgEnabled = $false
    if ($dg.SecurityServicesRunning -contains 1) { $cgEnabled = $true }
    if ($cgEnabled) {
        Add-Check -Name "credential_guard" -Category "虚拟化配置" -Label "Credential Guard" -Status "warning" -Detail "已启用" -Suggestion "Credential Guard 强制独占 Hypervisor，与 HAXM 完全互斥。必须走 WHPX 路径使用模拟器。"
    } else {
        Add-Check -Name "credential_guard" -Category "虚拟化配置" -Label "Credential Guard" -Status "ok" -Detail "未启用"
    }
} catch {
    Add-Check -Name "credential_guard" -Category "虚拟化配置" -Label "Credential Guard" -Status "unknown" -Detail "未检测到 DeviceGuard 配置（通常表示未启用）"
}

# --- HVCI ---
try {
    $hvci = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' -Name Enabled -ErrorAction Stop).Enabled
    if ($hvci -eq 1) {
        Add-Check -Name "hvci" -Category "虚拟化配置" -Label "内存完整性 (HVCI)" -Status "warning" -Detail "已启用" -Suggestion "HVCI 锁定 Hypervisor，与 HAXM 互斥。若使用 WHPX 则不影响。"
    } else {
        Add-Check -Name "hvci" -Category "虚拟化配置" -Label "内存完整性 (HVCI)" -Status "ok" -Detail "未启用"
    }
} catch {
    Add-Check -Name "hvci" -Category "虚拟化配置" -Label "内存完整性 (HVCI)" -Status "ok" -Detail "未启用（注册表项不存在）"
}

# --- Windows Sandbox ---
try {
    $sandbox = Get-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -ErrorAction Stop
    if ($sandbox.State -eq "Enabled") {
        Add-Check -Name "windows_sandbox" -Category "虚拟化配置" -Label "Windows Sandbox" -Status "warning" -Detail "已启用" -Suggestion "Windows Sandbox 依赖 Hyper-V，会占用 Hypervisor 资源。不用时建议关闭以减少竞争。"
    } else {
        Add-Check -Name "windows_sandbox" -Category "虚拟化配置" -Label "Windows Sandbox" -Status "ok" -Detail "未启用"
    }
} catch {
    Add-Check -Name "windows_sandbox" -Category "虚拟化配置" -Label "Windows Sandbox" -Status "unknown" -Detail "无法检测 (需要管理员权限): $_"
}

# ============================================================
# 3. AVD Configuration
# ============================================================

$avdDir = "$env:USERPROFILE\.android\avd"
$avdCount = 0
$runningEmulators = 0

if (Test-Path $avdDir) {
    $avdIssues = @()
    Get-ChildItem $avdDir -Filter "*.avd" -ErrorAction SilentlyContinue | ForEach-Object {
        $avdCount++
        $iniPath = Join-Path $_.FullName "config.ini"
        if (Test-Path $iniPath) {
            $ini = @{}
            Get-Content $iniPath | ForEach-Object {
                $parts = $_ -split '=', 2
                if ($parts.Count -eq 2) { $ini[$parts[0].Trim()] = $parts[1].Trim() }
            }
            $abi = $ini['abi.type']
            $gpuMode = $ini['hw.gpu.mode']
            $ramMB = $ini['hw.ramSize']
            $name = $_.Name -replace '\.avd$', ''

            $issues = @()
            if ($abi -and $abi -match 'arm') {
                $issues += "ABI=$abi (ARM 镜像在 x86 主机上无法硬件加速，极慢)"
            }
            if ($ramMB -and [int]$ramMB -gt 4096 -and $script:totalRAM -and $script:totalRAM -lt 16) {
                $issues += "RAM=${ramMB}MB (在 $($script:totalRAM)GB 物理内存下分配过多)"
            }
            if ($gpuMode -and $gpuMode -eq "sw") {
                $issues += "GPU=$gpuMode (纯软件渲染，性能极差，建议改为 auto 或 host)"
            }
            if ($issues.Count -gt 0) {
                $avdIssues += "$name`: $($issues -join '; ')"
            }
        }
    }
    if ($avdCount -gt 0) {
        $detail = "共 $avdCount 个 AVD"
        $status = "ok"
        $suggestion = ""
        if ($avdIssues.Count -gt 0) {
            $status = "warning"
            $detail += " | $($avdIssues.Count) 个存在问题"
            $suggestion = $avdIssues -join "`n"
        }
        Add-Check -Name "avd_config" -Category "模拟器配置" -Label "AVD 配置检查" -Status $status -Detail $detail -Suggestion $suggestion
    }
}

# --- Running emulator instances ---
try {
    $emuProcs = Get-Process -Name "qemu-system*" -ErrorAction Stop
    $runningEmulators = ($emuProcs | Select-Object -Property Name -Unique).Count
    if ($runningEmulators -eq 0) {
        try {
            $emuExe = Get-Process -Name "emulator" -ErrorAction Stop
            $runningEmulators = ($emuExe | Select-Object -Property Name -Unique).Count
        } catch {}
    }
    if ($runningEmulators -gt 1) {
        $memWarning = ""
        if ($script:totalRAM -and $script:totalRAM -lt 16) {
            $memWarning = "，在 $($script:totalRAM)GB 内存下可能导致严重卡顿"
        }
        Add-Check -Name "avd_running" -Category "模拟器配置" -Label "运行中的模拟器实例" -Status "warning" -Detail "当前有 $runningEmulators 个模拟器在运行" -Suggestion "多个实例同时运行会竞争 CPU/内存/Hypervisor 资源$memWarning，建议同时只运行 1-2 个"
    } elseif ($runningEmulators -eq 1) {
        Add-Check -Name "avd_running" -Category "模拟器配置" -Label "运行中的模拟器实例" -Status "ok" -Detail "当前有 1 个模拟器在运行"
    } else {
        Add-Check -Name "avd_running" -Category "模拟器配置" -Label "运行中的模拟器实例" -Status "ok" -Detail "无运行中的模拟器"
    }
} catch {
    Add-Check -Name "avd_running" -Category "模拟器配置" -Label "运行中的模拟器实例" -Status "ok" -Detail "无运行中的模拟器"
}

# ============================================================
# 4. Software Environment
# ============================================================

# --- Docker / WSL ---
$dockerRunning = $false
$dockerDetail = ""
try {
    $dockerProc = Get-Process -Name "Docker Desktop" -ErrorAction Stop
    if ($dockerProc) {
        $dockerRunning = $true
        $dockerDetail = "Docker Desktop 进程运行中"
    }
} catch {}

$wslDetail = ""
try {
    $wslOut = & wsl --status 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        $wslDetail = "WSL 可用"
        if ($wslOut -match "WSL 2") { $wslDetail += " (WSL2)" }
    }
} catch {}

$combinedParts = @()
if ($dockerDetail) { $combinedParts += $dockerDetail }
if ($wslDetail) { $combinedParts += $wslDetail }
$combinedDetail = $combinedParts -join " | "
if ($combinedDetail) {
    Add-Check -Name "docker_wsl" -Category "软件环境" -Label "Docker / WSL" -Status "info" -Detail $combinedDetail
}

# --- Security Software ---
$secProcs = @()
foreach ($name in @("MsMpEng", "avp", "bdagent", "mcshield", "NortonSecurity", "360Tray", "QQPCRTP", "HipsTray", "KSafeTray", "avpui")) {
    try {
        $p = Get-Process -Name $name -ErrorAction Stop
        if ($p) { $secProcs += $p[0].ProcessName }
    } catch {}
}
if ($secProcs.Count -gt 0) {
    $status = "info"
    $suggestion = ""
    $thirdParty = $secProcs | Where-Object { $_ -ne "MsMpEng" }
    if ($thirdParty.Count -gt 0) {
        $status = "warning"
        $suggestion = "检测到第三方安全软件 ($($thirdParty -join ', '))，可能干扰 Hypervisor 注入或模拟器进程。建议将 AVD 目录和 emulator.exe 加入白名单。"
    }
    Add-Check -Name "security_software" -Category "软件环境" -Label "安全软件" -Status $status -Detail ($secProcs -join ", ") -Suggestion $suggestion
}

# --- VMware / VirtualBox conflict ---
$vmProcs = @()
foreach ($name in @("vmnat", "vmware-authd", "vmware-vmx", "VBoxSVC", "VirtualBoxVM")) {
    try {
        $p = Get-Process -Name $name -ErrorAction Stop
        if ($p) { $vmProcs += $name }
    } catch {}
}
if ($vmProcs.Count -gt 0) {
    Add-Check -Name "vm_conflict" -Category "软件环境" -Label "虚拟机软件冲突" -Status "warning" -Detail ($vmProcs -join ", ") -Suggestion "检测到虚拟机软件正在运行，可能与 HAXM 或 Hyper-V 竞争虚拟化资源。VMware 15.5+ 支持 Hyper-V 共存。"
}

# --- ADB Version ---
try {
    $adbOut = & adb version 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $adbOut -match "Android Debug Bridge version\s+([\d.]+)") {
        $adbVer = $Matches[1]
        Add-Check -Name "adb_version" -Category "软件环境" -Label "ADB 版本" -Status "info" -Detail "版本 $adbVer"
    }
} catch {
    # ADB not in PATH, skip silently
}

# --- Emulator Version ---
try {
    $emuVerOut = & emulator -version 2>&1 | Out-String
    if ($emuVerOut -match "Android Emulator version\s+([\d.]+)") {
        $emuVer = $Matches[1]
        Add-Check -Name "emulator_version" -Category "软件环境" -Label "Emulator 版本" -Status "info" -Detail "版本 $emuVer"
    }
} catch {
    # emulator not in PATH, skip silently
}

# ============================================================
# Build and output
# ============================================================

$result = @{
    checks = $checks
}

$jsonResult = $result | ConvertTo-Json -Depth 10 -Compress

if ($ResultFile) {
    Set-Content -Path $ResultFile -Value $jsonResult -Encoding UTF8
}

if (-not $ResultFile) {
    Write-Host $jsonResult
}
