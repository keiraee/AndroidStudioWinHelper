param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("Enable", "Disable")]
    [string]$Action,

    [string]$ResultFile,
    [string]$FeatureName,
    [switch]$Json
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
[Console]::InputEncoding = $utf8
$OutputEncoding = $utf8

$ErrorActionPreference = "SilentlyContinue"

function Write-Result {
    param([hashtable]$Result)

    $jsonResult = $Result | ConvertTo-Json -Depth 10 -Compress

    if ($ResultFile) {
        Set-Content -Path $ResultFile -Value $jsonResult -Encoding UTF8
    }

    if ($Json) {
        [Console]::Out.WriteLine("@@RESULT|$jsonResult@@")
        [Console]::Out.Flush()
    } else {
        Write-Host ""
        Write-Host "=== Hyper-V Toggle Result ===" -ForegroundColor Cyan
        Write-Host "Success: $($Result.success)"
        Write-Host "Message: $($Result.message)"
        if ($Result.details) {
            Write-Host "Details: $($Result.details)"
        }
    }
}

function Enable-Feature {
    param([string]$FeatureName)
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
        if ($f -and ($f.State -eq "Enabled" -or $f.State -eq "EnablePending")) {
            if ($f.State -eq "EnablePending") {
                return "$FeatureName : EnablePending (restart to take effect)"
            }
            return "$FeatureName : Already enabled"
        }
        # Try to enable regardless of current state (handles DisabledWithPayloadRemoved)
        $enableResult = Enable-WindowsOptionalFeature -Online -FeatureName $FeatureName -All -NoRestart -ErrorAction Stop
        # Verify the feature was actually enabled
        $f2 = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
        if ($f2 -and ($f2.State -eq "Enabled" -or $f2.State -eq "EnablePending")) {
            if ($f2.State -eq "EnablePending" -or $enableResult.RestartNeeded) {
                return "$FeatureName : Enabled (restart needed)"
            }
            return "$FeatureName : Enabled"
        } else {
            $stateAfter = if ($f2) { $f2.State } else { "NotPresent" }
            return "$FeatureName : FAILED - command succeeded but state is '$stateAfter'"
        }
    } catch {
        return "$FeatureName : FAILED - $_"
    }
}

function Disable-Feature {
    param([string]$FeatureName)
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction SilentlyContinue
        if (-not $f -or ($f.State -ne "Enabled" -and $f.State -ne "EnablePending")) {
            return "$FeatureName : Not enabled, skipped"
        }
        $disableResult = Disable-WindowsOptionalFeature -Online -FeatureName $FeatureName -NoRestart -ErrorAction Stop
        if ($disableResult.RestartNeeded) {
            return "$FeatureName : Disabled (restart needed)"
        }
        return "$FeatureName : Disabled"
    } catch {
        return "$FeatureName : FAILED - $_"
    }
}

# --- Detect Home edition ---
$productName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName -ErrorAction SilentlyContinue).ProductName
$isHome = $productName -match 'Home'

# --- Debug: log received parameters ---
$debugLog = "DEBUG: Action=$Action, FeatureName='$FeatureName', ResultFile=$ResultFile, Json=$Json`n"

# --- Features to operate on ---
$allFeatures = if ($FeatureName) {
    ,$FeatureName
} else {
    # Default: only Hyper-V core components (NOT WHPX)
    # WHPX is toggled separately via -FeatureName HypervisorPlatform
    @(
        "Microsoft-Hyper-V-All",
        "Microsoft-Hyper-V-Hypervisor",
        "Microsoft-Hyper-V-Services"
    )
}

$debugLog += "DEBUG: allFeatures count=$($allFeatures.Count), values=$($allFeatures -join ', ')`n"

$success = $true
$message = ""
$details = ""
$failedCount = 0

try {
    if ($Action -eq "Enable") {
        # Home edition needs to install Hyper-V packages first (only for full toggle, not single feature)
        if ($isHome -and -not $FeatureName) {
            if ($Json) {
                [Console]::Out.WriteLine("@@PROGRESS|10|Home edition detected, installing Hyper-V packages...@@")
                [Console]::Out.Flush()
            }

            $mumFiles = Get-ChildItem "$env:SystemRoot\servicing\Packages\*Hyper-V*.mum" -ErrorAction SilentlyContinue
            if ($mumFiles) {
                foreach ($mum in $mumFiles) {
                    $dismResult = & dism.exe /online /norestart /add-package:"$($mum.FullName)" 2>&1
                    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
                        $details += "Failed to install $($mum.Name): $dismResult`n"
                    }
                }
            } else {
                $details += "No Hyper-V .mum packages found, skipping install step.`n"
            }
        }

        if ($Json) {
            [Console]::Out.WriteLine("@@PROGRESS|30|Enabling Hyper-V features...@@")
            [Console]::Out.Flush()
        }

        $idx = 0
        foreach ($feature in $allFeatures) {
            $idx++
            $debugLog += "DEBUG: Enable loop idx=$idx, feature='$feature', type=$($feature.GetType().Name), len=$($feature.Length)`n"
            $pct = 30 + [math]::Floor(60 * $idx / $allFeatures.Count)

            if ($Json) {
                [Console]::Out.WriteLine("@@PROGRESS|$pct|Enabling $feature...@@")
                [Console]::Out.Flush()
            }

            $result = Enable-Feature -FeatureName $feature
            $details += "$result`n"
            $debugLog += "DEBUG: Enable result='$result'`n"
            if ($result -match "FAILED") {
                $failedCount++
            }
        }

        if ($failedCount -eq $allFeatures.Count) {
            $success = $false
            $message = "All features failed to enable. Check details for errors."
        } elseif ($failedCount -gt 0) {
            $message = "Some features enabled with errors. Restart required to take effect."
        } else {
            $message = "Hyper-V enabled. Restart required to take effect."
        }

    } else {
        # --- Disable ---
        if ($Json) {
            [Console]::Out.WriteLine("@@PROGRESS|30|Disabling Hyper-V features...@@")
            [Console]::Out.Flush()
        }

        $idx = 0
        foreach ($feature in $allFeatures) {
            $idx++
            $debugLog += "DEBUG: Disable loop idx=$idx, feature='$feature', type=$($feature.GetType().Name), len=$($feature.Length)`n"
            $pct = 30 + [math]::Floor(60 * $idx / $allFeatures.Count)

            if ($Json) {
                [Console]::Out.WriteLine("@@PROGRESS|$pct|Disabling $feature...@@")
                [Console]::Out.Flush()
            }

            $result = Disable-Feature -FeatureName $feature
            $details += "$result`n"
            $debugLog += "DEBUG: Disable result='$result'`n"
            if ($result -match "FAILED") {
                $failedCount++
            }
        }

        if ($failedCount -eq $allFeatures.Count) {
            $success = $false
            $message = "All features failed to disable. Check details for errors."
        } elseif ($failedCount -gt 0) {
            $message = "Some features disabled with errors. Restart required to take effect."
        } else {
            $message = "Hyper-V disabled. Restart required to take effect."
        }
    }
} catch {
    $success = $false
    $message = "Operation failed: $_"
}

if ($Json) {
    [Console]::Out.WriteLine("@@PROGRESS|100|Operation complete@@")
    [Console]::Out.Flush()
}

Write-Result -Result @{
    success = $success
    message = $message
    details = $details.Trim()
    action  = $Action
    debug   = $debugLog.Trim()
}
