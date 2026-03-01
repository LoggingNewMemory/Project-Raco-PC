# Windows Power Plan Manager v2.0
 
<#
.SYNOPSIS
    Adjusts the active Windows power plan for Performance, Balanced, or Powersave modes.

.DESCRIPTION
    This script modifies key settings of the currently active power plan to optimize for
    raw performance, balanced use, or battery saving. Must run as Administrator.

.PARAMETER Mode
    Specifies the power mode to apply.
    1: Performance Mode
    2: Balanced Mode
    3: Powersave Mode
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

$activePlanGuid = (powercfg -getactivescheme).Split(' ')[3]

function Set-PowerSetting {
    param (
        [string]$Subgroup,
        [string]$Setting,
        [string]$FriendlyName,
        [int]$Value
    )
    
    try {
        powercfg -setacvalueindex $activePlanGuid $Subgroup $Setting $Value | Out-Null
        powercfg -setdcvalueindex $activePlanGuid $Subgroup $Setting $Value | Out-Null
        Write-Host "[OK] $FriendlyName set to: $Value"
    }
    catch {
        Write-Warning "Warning: Failed to set '$FriendlyName'."
    }
}

# --- CPU GUIDs ---
$subgroupCpu = "54533251-82be-4824-96c1-47b60b740d00" 
$settingMinState = "893dee8e-2bef-41e0-89c6-b55d0929964c" 
$settingMaxState = "bc5038f7-23e0-4960-96da-33abaf5935ec" 
$settingBoostMode = "be337238-0d82-4146-a960-4f3749d470c7" 
$settingEPP = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"        
$settingTimeCheckInterval = "4d2b0152-7d5c-498b-88e2-34345392a2c5" 
$settingPerfDecreaseTime = "d8edeb9b-95cf-4f95-a73c-b061973693c8"  
$settingIdleDisable = "5d76a2ca-e8c0-402f-a133-2158492d58ad"        
$settingCoreParkingMin = "0cc5b647-c1df-4637-891a-dec35c318583" # Processor performance core parking min cores
$settingCoolingPolicy = "94d3a615-a899-4ac5-ae2b-e4d8f634360f"  # System cooling policy (0=Passive, 1=Active)

# --- Storage & System GUIDs ---
$subgroupHdd = "0012ee47-9041-4b5d-9b77-535fba8b1442" 
$settingSataAlpm = "dab60367-53fe-4fbc-825e-521d069d2456" 
$settingDiskTurnOff = "6738e2c4-e8a5-4a42-b16a-e040e769756e" # Hard disk turn off time (Seconds)

$subgroupUsb = "2a737441-1930-4402-8d77-b2bebba308a3" 
$settingUsbSuspend = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" 

$subgroupPcie = "501a4d13-42af-4429-9fd1-a8218c268e20" 
$settingPcieLspm = "ee12f906-d277-404b-b6da-e5fa1a576df5" 

$subgroupWifi = "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1"
$settingWifiPower = "12bbebe6-58d6-4636-95bb-3217ef867c1a" # 0=Max Perf, 1=Low Save, 2=Med Save, 3=Max Save

#==============================================================================
# MODE-SPECIFIC FUNCTIONS
#==============================================================================

function Set-Performance {
    Write-Host "`nApplying Extreme Performance settings..." -ForegroundColor Cyan
    
    # Unpark all cores & lock states
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingCoreParkingMin -FriendlyName "Core Parking Min Cores" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 2
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 0
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingCoolingPolicy -FriendlyName "System Cooling Policy" -Value 1

    # Disable latency states
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 1
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 1
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 100

    # Device max performance overrides
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 0
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 0
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingDiskTurnOff -FriendlyName "Disk Turn Off Time" -Value 0
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 0
    Set-PowerSetting -Subgroup $subgroupWifi -Setting $settingWifiPower -FriendlyName "Wireless Adapter Power" -Value 0
}

function Set-Balanced {
    Write-Host "`nReverting to Balanced / OS Defaults..." -ForegroundColor Cyan
    
    # Re-enable standard core parking & dynamic states
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingCoreParkingMin -FriendlyName "Core Parking Min Cores" -Value 10
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 1
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 50
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingCoolingPolicy -FriendlyName "System Cooling Policy" -Value 1

    # Restore dynamic idle & intervals
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 0
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 15
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 30

    # Restore device sleep limits
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 1
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 1
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingDiskTurnOff -FriendlyName "Disk Turn Off Time (sec)" -Value 1200
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1
    Set-PowerSetting -Subgroup $subgroupWifi -Setting $settingWifiPower -FriendlyName "Wireless Adapter Power" -Value 1
}

function Set-Powersave {
    Write-Host "`nApplying Powersave settings..." -ForegroundColor Cyan

    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 60
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingCoreParkingMin -FriendlyName "Core Parking Min Cores" -Value 5
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 0
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingEPP -FriendlyName "Energy Perf Preference" -Value 100
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingCoolingPolicy -FriendlyName "System Cooling Policy" -Value 0

    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 0
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 15
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 1

    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 2
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 2
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingDiskTurnOff -FriendlyName "Disk Turn Off Time (sec)" -Value 300
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1
    Set-PowerSetting -Subgroup $subgroupWifi -Setting $settingWifiPower -FriendlyName "Wireless Adapter Power" -Value 3
}

#==============================================================================
# MAIN EXECUTION LOGIC
#==============================================================================

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
        Write-Host "`nPerformance mode activated. Hardware unbound." -ForegroundColor Green
    }
    2 {
        Set-Balanced
        Write-Host "`nBalanced mode activated. Defaults restored." -ForegroundColor Green
    }
    3 {
        Set-Powersave
        Write-Host "`nPowersave mode activated. Maximum battery savings." -ForegroundColor Green
    }
    default {
        Write-Host "Invalid mode specified. Use -Mode 1, 2, or 3." -ForegroundColor Red
        exit 1
    }
}

powercfg -setactive $activePlanGuid | Out-Null
Write-Host "Settings have been firmly applied to the active power plan." -ForegroundColor Yellow