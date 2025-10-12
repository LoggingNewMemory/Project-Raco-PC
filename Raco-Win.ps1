<#
.SYNOPSIS
    Adjusts the active Windows power plan for Performance, Balanced, Powersave, or Reset modes.

.DESCRIPTION
    This script modifies key settings of the currently active power plan to optimize for
    performance, balanced use, or battery saving. It must be run with Administrator privileges.

.PARAMETER Mode
    Specifies the power mode to apply. If omitted, the script will check for updates.
    1: Performance Mode
    2: Balanced Mode
    3: Powersave Mode

.EXAMPLE
    PS> ./Raco-Win.ps1
    Checks for a new version of the script online.

.EXAMPLE
    PS> ./Raco-Win.ps1 -Mode 2
    for balanced mode
#>

[CmdletBinding()]
param (
    # --- [MODIFIED] Added Mode 4 for Reset ---
    [Parameter(Mandatory = $false, HelpMessage = "Enter the mode: 1 for Performance, 2 for Balanced, 3 for Powersave.")]
    [ValidateSet(1, 2, 3, 4)]
    [int]$Mode
)

#==============================================================================
# SCRIPT INITIALIZATION
#==============================================================================

$scriptUrl = "https://raw.githubusercontent.com/LoggingNewMemory/Project-Raco-PC/main/Raco-Win.ps1"
$scriptPath = $MyInvocation.MyCommand.Path

# Check for Administrator privileges
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "❌ Error: This script must be run as Administrator." -ErrorAction Stop
}

function Check-ForUpdates {
    $choice = Read-Host "Check for script updates? [y/n]"
    if ($choice -ne 'y') {
        return
    }

    Write-Host "Checking for updates..."
    try {
        # Download the latest script content
        $latestScriptContent = Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing | Select-Object -ExpandProperty Content
        
        # Get current script content
        $currentScriptContent = Get-Content -Path $scriptPath -Raw

        # Compare them
        if ($latestScriptContent -eq $currentScriptContent) {
            Write-Host "✅ You are already using the latest version."
        }
        else {
            Write-Host "🔄 New version found! Updating..."
            # Overwrite the current script with the new content
            Set-Content -Path $scriptPath -Value $latestScriptContent -Force
            Write-Host "✅ Script updated successfully. Please re-run the script."
            Exit
        }
    }
    catch {
        Write-Warning "❌ Error: Failed to check for updates. Please check your internet connection."
        $_
    }
}

#==============================================================================
# HELPER FUNCTION AND GUIDs
#==============================================================================

# Get the GUID of the currently active power plan
$activePlanGuid = (powercfg -getactivescheme).Split(' ')[3]

# Helper function to set a specific power setting value for both AC and DC
function Set-PowerSetting {
    param (
        [string]$Subgroup,
        [string]$Setting,
        [string]$FriendlyName,
        [int]$Value
    )
    
    try {
        # Set value for when plugged in (AC)
        powercfg -setacvalueindex $activePlanGuid $Subgroup $Setting $Value | Out-Null
        # Set value for when on battery (DC)
        powercfg -setdcvalueindex $activePlanGuid $Subgroup $Setting $Value | Out-Null
        Write-Host "✓ $FriendlyName set to: $Value"
    }
    catch {
        Write-Warning "⚠️  Warning: Failed to set '$FriendlyName'. The setting or value may not be supported on your hardware."
    }
}

# GUIDs for common power settings
$subgroupCpu = "54533251-82be-4824-96c1-47b60b740d00" # Processor power management
$settingMinState = "893dee8e-2bef-41e0-89c6-b55d0929964c" # Minimum processor state
$settingMaxState = "bc5038f7-23e0-4960-96da-33abaf5935ec" # Maximum processor state
$settingBoostMode = "be337238-0d82-4146-a960-4f3749d470c7" # Processor performance boost mode
# Boost Modes: 0=Disabled, 1=Enabled, 2=Aggressive, 3=Efficient Enabled, 4=Efficient Aggressive, 5=Aggressive At Guaranteed

# --- Advanced CPU Settings ---
$settingEPP = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"        # Energy performance preference policy (0 = Max Perf)
$settingTimeCheckInterval = "4d2b0152-7d5c-498b-88e2-34345392a2c5" # Performance time check interval (1 = 1ms check)
$settingPerfDecreaseTime = "d8edeb9b-95cf-4f95-a73c-b061973693c8"  # Performance decrease time (100 = Slowest downclock)
$settingIdleDisable = "5d76a2ca-e8c0-402f-a133-2158492d58ad"        # Disable idle states (C-states) (1 = Disable on your system)
# -----------------------------

$subgroupHdd = "0012ee47-9041-4b5d-9b77-535fba8b1442" # Hard disk
$settingSataAlpm = "dab60367-53fe-4fbc-825e-521d069d2456" # AHCI Link Power Management - HIPM/DIPM
# ALPM Modes: 0=Active, 1=HIPM, 2=DIPM (min_power)

$subgroupUsb = "2a737441-1930-4402-8d77-b2bebba308a3" # USB settings
$settingUsbSuspend = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" # USB selective suspend setting
# USB Suspend Modes: 0=Disabled, 1=Enabled

# --- NEW: PCI Express Link State Power Management (LSPM) ---
$subgroupPcie = "501a4d13-42af-4429-9fd1-a8218c268e20" # PCI Express
$settingPcieLspm = "ee12f906-d277-404b-b6da-e5fa1a576df5" # Link State Power Management

# --- Standard Windows Power Scheme GUIDs (for Reset) ---
$guidBalanced = "381b4222-f694-41f0-9685-ff5bb260df2e"


#==============================================================================
# MODE-SPECIFIC FUNCTIONS
#==============================================================================

function Set-Performance {
    Write-Host "Applying Performance settings..."
    
    # --- CPU Core Performance Settings ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 100 # 100%
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100 # 100%
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 2 # Aggressive
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 0 # 0 = Max Performance

    # --- Advanced Aggressive CPU Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 1 # 1 = Disable C-States 
    
    # --- Low Latency/Responsiveness Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 1 # 1ms check
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 100 # Sustained Max Clock

    # --- System Tweaks (GPU/Storage/USB) ---
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 0 # Off (Max Performance)
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 0 # Active (max_performance)
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 0 # Disabled (equivalent to 'on')
}

function Set-Balanced {
    Write-Host "Applying Balanced settings..."
    
    # --- CPU Core Performance Settings ---
    # Min State: Allow CPU frequency to drop to 5% when idle (dynamic scaling)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5 # 5%
    # Max State: Allow full boost when needed
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100 # 100%
    # Boost Mode: Use 'Enabled' to allow dynamic scaling and boosting only under load (safest for downclocking)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 1 # Enabled 
    # EPP: Use a moderate value (50) instead of Max Performance (0)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 50 # 50 = Balanced

    # --- Advanced CPU Tweaks ---
    # Idle States: Re-enable C-States to allow the CPU to enter low-power states when idle (CRUCIAL for downclocking)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 0 # 0 = Enable C-States
    
    # --- Low Latency/Responsiveness Tweaks ---
    # Time Check Interval: Use a more conservative interval (15ms)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 15 # 15ms check
    # Perf Decrease Time: Use a faster response time (30) to drop clock speed when load decreases
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 30 # Moderate Clock Response

    # --- System Tweaks (GPU/Storage/USB) ---
    # PCIe LSPM: Set to Moderate Power Savings (1) to save power when GPU/PCIe devices are idle
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 1 # Moderate Power Savings
    # SATA ALPM: Set to HIPM/Medium Power Savings (1)
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 1 # HIPM (medium_power)
    # USB Suspend: Re-enable selective suspend to power down inactive USB ports
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1 # Enabled
}

function Set-Powersave {
    Write-Host "Applying Powersave settings..."

    # --- CPU Core Performance Settings ---
    # Min State: Allow CPU frequency to drop to 5% when idle (dynamic scaling)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5 # 5%
    # Max State: Cap the CPU speed to 60% of max frequency
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 60 # 60%
    # Boost Mode: Disable boosting entirely
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 0 # Disabled
    # EPP: Use the most aggressive power saving value (100)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 100 # 100 = Max Power Save

    # --- Advanced CPU Tweaks ---
    # Idle States: Ensure C-States are enabled to allow deep sleep (CRUCIAL for power saving)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 0 # 0 = Enable C-States
    
    # --- Low Latency/Responsiveness Tweaks ---
    # Time Check Interval: Changed from 30 to 15 to resolve "malformed" value error
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 15 # 15ms check
    # Perf Decrease Time: Changed from 0 to 1 to resolve "malformed" value error
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 1 # Fastest Clock Response (1ms)

    # --- System Tweaks (GPU/Storage/USB) ---
    # PCIe LSPM: Set to Maximum Power Savings (2)
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 2 # Maximum Power Savings
    # SATA ALPM: Set to DIPM/Minimum Power Savings (2)
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 2 # DIPM (min_power)
    # USB Suspend: Re-enable selective suspend to power down inactive USB ports
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1 # Enabled
}

#==============================================================================
# MAIN EXECUTION LOGIC
#==============================================================================

# --- [MODIFIED] Check if a mode was provided. If not, check for updates. ---
if (-not $PSBoundParameters.ContainsKey('Mode')) {
    Check-ForUpdates
    # Show usage if user did not update
    Write-Host "`nUsage: $PSCommandPath -Mode <1|2|3|4>"
    Write-Host "  1: Performance Mode"
    Write-Host "  2: Balanced Mode"
    Write-Host "  3: Powersave Mode"
    exit
}
# --- [END MODIFIED] ---

switch ($Mode) {
    1 {
        Set-Performance
        Write-Host "`n✅ Performance mode activated. 🔥"
    }
    2 {
        Set-Balanced
        Write-Host "`n✅ Balanced mode activated. ⚖️"
    }
    3 {
        Set-Powersave
        Write-Host "`n✅ Powersave mode activated. 🔋"
    }
    default {
        Write-Host "❌ Invalid mode specified. Use -Mode 1, 2, 3, or 4."
    }
}

# Apply the changes
powercfg -setactive $activePlanGuid | Out-Null
Write-Host "Settings have been applied to the active power plan."
