# Windows Power Plan Manager
 
<#
.SYNOPSIS
    Adjusts the active Windows power plan for Performance, Balanced, or Powersave modes.

.DESCRIPTION
    This script modifies key settings of the currently active power plan to optimize for
    performance, balanced use, or battery saving. It must be run with Administrator privileges.

.PARAMETER Mode
    Specifies the power mode to apply.
    1: Performance Mode
    2: Balanced Mode
    3: Powersave Mode

.EXAMPLE
    PS> ./Raco-Win.ps1 -Mode 2
    Applies balanced mode settings.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $false, HelpMessage = "Enter the mode: 1 for Performance, 2 for Balanced, 3 for Powersave.")]
    [ValidateSet(1, 2, 3)]
    [int]$Mode
)

#==============================================================================
# SCRIPT INITIALIZATION
#==============================================================================

# Check for Administrator privileges
if (-Not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Error: This script must be run as Administrator." -ErrorAction Stop
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
        Write-Host "[OK] $FriendlyName set to: $Value"
    }
    catch {
        Write-Warning "Warning: Failed to set '$FriendlyName'. The setting or value may not be supported on your hardware."
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
$settingIdleDisable = "5d76a2ca-e8c0-402f-a133-2158492d58ad"        # Disable idle states (C-states) (1 = Disable)

$subgroupHdd = "0012ee47-9041-4b5d-9b77-535fba8b1442" # Hard disk
$settingSataAlpm = "dab60367-53fe-4fbc-825e-521d069d2456" # AHCI Link Power Management - HIPM/DIPM
# ALPM Modes: 0=Active, 1=HIPM, 2=DIPM (min_power)

$subgroupUsb = "2a737441-1930-4402-8d77-b2bebba308a3" # USB settings
$settingUsbSuspend = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" # USB selective suspend setting
# USB Suspend Modes: 0=Disabled, 1=Enabled

# --- PCI Express Link State Power Management (LSPM) ---
$subgroupPcie = "501a4d13-42af-4429-9fd1-a8218c268e20" # PCI Express
$settingPcieLspm = "ee12f906-d277-404b-b6da-e5fa1a576df5" # Link State Power Management


#==============================================================================
# MODE-SPECIFIC FUNCTIONS
#==============================================================================

function Set-Performance {
    Write-Host "`nApplying Performance settings..." -ForegroundColor Cyan
    
    # --- CPU Core Performance Settings ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 2
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 0

    # --- Advanced Aggressive CPU Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 1

    # --- Low Latency/Responsiveness Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 1
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 100

    # --- System Tweaks (GPU/Storage/USB) ---
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 0
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 0
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 0
}

function Set-Balanced {
    Write-Host "`nApplying Balanced settings..." -ForegroundColor Cyan
    
    # --- CPU Core Performance Settings ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 1
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 50

    # --- Advanced CPU Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 0
    
    # --- Low Latency/Responsiveness Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 15
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 30

    # --- System Tweaks (GPU/Storage/USB) ---
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 1
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 1
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1
}

function Set-Powersave {
    Write-Host "`nApplying Powersave settings..." -ForegroundColor Cyan

    # --- CPU Core Performance Settings ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 60
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 0
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 100

    # --- Advanced CPU Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 0
    
    # --- Low Latency/Responsiveness Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 15
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 1

    # --- System Tweaks (GPU/Storage/USB) ---
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 2
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 2
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1
}

#==============================================================================
# MAIN EXECUTION LOGIC
#==============================================================================

# Check if a mode was provided. If not, output usage instructions.
if (-not $PSBoundParameters.ContainsKey('Mode')) {
    Write-Host "`nUsage: $PSCommandPath -Mode <1|2|3>"
    Write-Host "  1: Performance Mode"
    Write-Host "  2: Balanced Mode"
    Write-Host "  3: Powersave Mode"
    exit
}

switch ($Mode) {
    1 {
        Set-Performance
        Write-Host "`nPerformance mode activated." -ForegroundColor Green
    }
    2 {
        Set-Balanced
        Write-Host "`nBalanced mode activated." -ForegroundColor Green
    }
    3 {
        Set-Powersave
        Write-Host "`nPowersave mode activated." -ForegroundColor Green
    }
    default {
        Write-Host "Invalid mode specified. Use -Mode 1, 2, or 3." -ForegroundColor Red
        exit 1
    }
}

# Apply the changes
powercfg -setactive $activePlanGuid | Out-Null

Write-Host "Settings have been applied to the active power plan." -ForegroundColor Yellow