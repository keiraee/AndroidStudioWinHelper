param(
    [switch]$Json,
    [switch]$Progress,
    [string]$ResultFile
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

$ErrorActionPreference = "SilentlyContinue"

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

# --- Main ---

Write-DetectProgress -Percent 10 -Message "Detecting Windows edition..."

# Get Windows edition
$productName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName -ErrorAction SilentlyContinue).ProductName
if (-not $productName) {
    $productName = "Unknown"
}

$isHome = $productName -match 'Home'

Write-DetectProgress -Percent 30 -Message "Detecting Hyper-V features..."

# Feature definitions (label is English only - Chinese labels handled in Dart)
$featureDefs = @(
    @{ Name = "Microsoft-Hyper-V-All" },
    @{ Name = "Microsoft-Hyper-V-Hypervisor" },
    @{ Name = "Microsoft-Hyper-V-Services" },
    @{ Name = "VirtualMachinePlatform" },
    @{ Name = "HypervisorPlatform" }
)

$features = @()
$enabledCount = 0
$disabledCount = 0
$notPresentCount = 0
$progressBase = 30
$progressStep = [math]::Floor(60 / $featureDefs.Count)

foreach ($i in 0..($featureDefs.Count - 1)) {
    $def = $featureDefs[$i]
    $pct = $progressBase + ($i + 1) * $progressStep

    Write-DetectProgress -Percent $pct -Message "Checking $($def.Name)..."

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $def.Name -ErrorAction Stop
        $state = $feature.State.ToString()
    } catch {
        $state = "NotPresent"
    }

    if ($state -eq "Enabled" -or $state -eq "EnablePending") {
        $enabledCount++
    } elseif ($state -eq "Disabled") {
        $disabledCount++
    } else {
        $notPresentCount++
        $state = "NotPresent"
    }

    $features += @{
        name  = $def.Name
        state = $state
    }
}

# Determine overall status
if ($enabledCount -eq $featureDefs.Count) {
    $overallStatus = "FullyEnabled"
} elseif ($enabledCount -eq 0) {
    $overallStatus = "NotPresent"
} else {
    $overallStatus = "PartiallyEnabled"
}

Write-DetectProgress -Percent 95 -Message "Generating report..."

$result = @{
    osEdition      = $productName
    isHomeEdition  = [bool]$isHome
    features       = $features
    overallStatus  = $overallStatus
}

$jsonResult = $result | ConvertTo-Json -Depth 10 -Compress

Write-DetectProgress -Percent 100 -Message "Detection complete."

# Write to result file if specified (used by elevated detect)
if ($ResultFile) {
    Set-Content -Path $ResultFile -Value $jsonResult -Encoding UTF8
}

if ($Json) {
    [Console]::Out.WriteLine("@@RESULT|$jsonResult@@")
    [Console]::Out.Flush()
} else {
    Write-Host ""
    Write-Host "=== Hyper-V Status Report ===" -ForegroundColor Cyan
    Write-Host "OS Edition: $productName"
    Write-Host "Home Edition: $(if ($isHome) { 'Yes' } else { 'No' })"
    Write-Host ""
    foreach ($f in $features) {
        $color = switch ($f.state) {
            "Enabled"    { "Green" }
            "Disabled"   { "Yellow" }
            "NotPresent" { "Red" }
            default      { "Gray" }
        }
        Write-Host "  $($f.name): $($f.state)" -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "Overall Status: $overallStatus"
}
