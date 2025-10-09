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

$subgroupHdd = "0012ee47-9041-4b5d-9b77-535fba8b1442" # Hard disk
$settingSataAlpm = "dab60367-53fe-4fbc-825e-521d069d2456" # AHCI Link Power Management - HIPM/DIPM
# ALPM Modes: 0=Active, 1=HIPM, 2=DIPM (min_power)

$subgroupUsb = "2a737441-1930-4402-8d77-b2bebba308a3" # USB settings
$settingUsbSuspend = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" # USB selective suspend setting
# USB Suspend Modes: 0=Disabled, 1=Enabled

#==============================================================================
# MODE-SPECIFIC FUNCTIONS
#==============================================================================

function Set-Performance {
    Write-Host "Applying Performance settings..."
    # --- CPU ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 2 # Aggressive
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMinState -FriendlyName "CPU Min State" -Value 100 # 100%
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingMaxState -FriendlyName "CPU Max State" -Value 100 # 100%
    
    # --- System Tweaks ---
    Set-PowerSetting -Subgroup $subgroupHdd -Setting $settingSataAlpm -FriendlyName "SATA ALPM" -Value 0 # Active (max_performance)
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 0 # Disabled (equivalent to 'on')
}

function Set-Balanced {
    Write-Host "Applying Balanced settings..."
    # --- CPU ---
    Set-PowerSetting -Subgroup $subgroupCpu -Setting $settingBoostMode -FriendlyName "CPU Boost Mode" -Value 4 # Efficient Aggressive (Windows Default)
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
    Set-PowerSetting -Subgroup $subgroupUsb -Setting $settingUsbSuspend -FriendlyName "USB Suspend" -Value 1 # Enabled (equivalent to 'auto')
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