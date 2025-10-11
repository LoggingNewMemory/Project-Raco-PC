<#
.SYNOPSIS
    Adjusts the active Windows power plan for Performance, Balanced, or Powersave modes.

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
    PS> ./Raco-Win.ps1 -Mode 1
    Applies the Performance settings to the current power plan.
#>

[CmdletBinding()]
param (
    # --- [MODIFIED] Made this parameter optional to allow for update checking ---
    [Parameter(Mandatory = $false, HelpMessage = "Enter the mode: 1 for Performance, 2 for Balanced, 3 for Powersave.")]
    [ValidateSet(1, 2, 3)]
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
        Write-Warning "⚠️  Warning: Failed to set '$FriendlyName'."
    }
}

# GUIDs for common power settings
$subgroupCpu = "54533251-82be-4824-96c1-47b60b740d00" # Processor power management
$settingMinState = "893dee8e-2bef-41e0-89c6-b55d0929964c" # Minimum processor state
$settingMaxState = "bc5038f7-23e0-4960-96da-33abaf5935ec" # Maximum processor state
$settingBoostMode = "be337238-0d82-4146-a960-4f3749d470c7" # Processor performance boost mode
# Boost Modes: 0=Disabled, 1=Enabled, 2=Aggressive, 3=Efficient Enabled, 4=Efficient Aggressive, 5=Aggressive At Guaranteed

# --- NEW ADVANCED CPU SETTINGS (Often hidden) ---
$settingEPP = "36687f9e-e3a5-4dbf-b1dc-15eb381c6863"        # Energy performance preference policy (0 = Max Perf)
$settingTimeCheckInterval = "4d2b0152-7d5c-498b-88e2-34345392a2c5" # Performance time check interval (1 = 1ms check)
$settingPerfDecreaseTime = "d8edeb9b-95cf-4f95-a73c-b061973693c8"  # Performance decrease time (100 = Slowest downclock)
$settingIdleDisable = "5d76a2ca-e8c0-402f-a133-2158492d58ad"        # Disable idle states (C-states) (0 = Disable)
$settingPerfIncrease = "465e1f50-b610-473a-ab58-a740a309a815"       # Processor performance increase policy (2 = Rocket)
$settingPerfDecrease = "465e1f50-b610-473a-ab58-a740a309a815"       # Processor performance decrease policy (1 = Single)
# --- END NEW ADVANCED CPU SETTINGS ---

$subgroupHdd = "0012ee47-9041-4b5d-9b77-535fba8b1442" # Hard disk
$settingSataAlpm = "dab60367-53fe-4fbc-825e-521d069d2456" # AHCI Link Power Management - HIPM/DIPM
# ALPM Modes: 0=Active, 1=HIPM, 2=DIPM (min_power)

$subgroupUsb = "2a737441-1930-4402-8d77-b2bebba308a3" # USB settings
$settingUsbSuspend = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" # USB selective suspend setting
# USB Suspend Modes: 0=Disabled, 1=Enabled

# --- NEW: PCI Express Link State Power Management (LSPM) ---
$subgroupPcie = "501a4d13-42af-4429-9fd1-a8218c268e20" # PCI Express
$settingPcieLspm = "ee12f906-d277-404b-b6da-e5fa1a576df5" # Link State Power Management

# --- NEW FUNCTION TO UNHIDE SETTINGS ---
function Set-HiddenAttributes {
    Write-Host "`n👀 Unhiding advanced CPU power settings for modification..."

    # The -ATTRIB_HIDE flag removes the 'hide' attribute, making the setting visible and editable.
    
    # Performance Policies (Increase/Decrease)
    Write-Host "   - Unhiding Performance Policies..."
    powercfg -attributes $subgroupCpu $settingPerfIncrease -ATTRIB_HIDE | Out-Null
    
    # Performance Time Check Interval (Responsiveness)
    Write-Host "   - Unhiding Time Check Interval..."
    powercfg -attributes $subgroupCpu $settingTimeCheckInterval -ATTRIB_HIDE | Out-Null

    # Performance Decrease Time (Sustained Clock)
    Write-Host "   - Unhiding Performance Decrease Time..."
    powercfg -attributes $subgroupCpu $settingPerfDecreaseTime -ATTRIB_HIDE | Out-Null
    
    # Disable CPU Idle States (C-states)
    Write-Host "   - Unhiding CPU Idle States (C-states)..."
    powercfg -attributes $subgroupCpu $settingIdleDisable -ATTRIB_HIDE | Out-Null

    # Energy performance preference policy (EPP)
    Write-Host "   - Unhiding Energy Performance Preference..."
    powercfg -attributes $subgroupCpu $settingEPP -ATTRIB_HIDE | Out-Null

    Write-Host "✅ Hidden settings now unmasked."
}
# ----------------------------------------


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
    # UPDATED VALUE: 1 = Disable Idle (Max Performance)
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingIdleDisable -FriendlyName "Disable CPU Idle States" -Value 1 # 1 = Disable C-States 

    # --- REMOVED: These settings are not supported on your hardware and cause errors ---
    # Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfIncrease -FriendlyName "Perf Increase Policy" -Value 2 
    # Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecrease -FriendlyName "Perf Decrease Policy" -Value 1 
    
    # --- Low Latency/Responsiveness Tweaks ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingTimeCheckInterval -FriendlyName "Perf Time Check Interval" -Value 1 # 1ms check
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingPerfDecreaseTime -FriendlyName "Perf Decrease Time" -Value 100 # Sustained Max Clock

    # --- System Tweaks (GPU/Storage/USB) ---
    # NEW: Forces PCIe link to remain fully active for max GPU/SSD speed.
    Set-PowerSetting -Subgroup $subgroupPcie -Setting $settingPcieLspm -FriendlyName "PCIe LSPM" -Value 0 # Off (Max Performance)

    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 0 # Active (max_performance)
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 0 # Disabled (equivalent to 'on')
}

function Set-Balanced {
    Write-Host "Applying Balanced settings..."
    # --- CPU ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 1 # Enabled (New safe default) 
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5   # 5%
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100 # 100%
    
    # --- System Tweaks ---
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 1 # HIPM (medium_power)
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1 # Enabled (equivalent to 'auto')
}

function Set-Powersave {
    Write-Host "Applying Powersave settings..."
    # --- CPU ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 0 # Disabled
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 5   # 5%
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 60  # 60% to limit frequency
    
    # --- System Tweaks ---
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 2 # DIPM (min_power)
    Set-PowerSetting -subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1 # Enabled (equivalent to 'auto')
}

#==============================================================================
# MAIN EXECUTION LOGIC
#==============================================================================

# --- [MODIFIED] Check if a mode was provided. If not, check for updates. ---
if (-not $PSBoundParameters.ContainsKey('Mode')) {
    Check-ForUpdates
    # Show usage if user did not update
    Write-Host "`nUsage: $PSCommandPath -Mode <1|2|3>"
    Write-Host "  1: Performance Mode"
    Write-Host "  2: Balanced Mode"
    Write-Host "  3: Powersave Mode"
    exit
}
# --- [END MODIFIED] ---

switch ($Mode) {
    1 {
        Set-HiddenAttributes # NEW: Unhide settings first
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
}

# Apply the changes
powercfg -setactive $activePlanGuid | Out-Null
Write-Host "Settings have been applied to the active power plan."
