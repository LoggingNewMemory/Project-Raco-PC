#!/bin/bash

# ==============================================================================
# Usage:
#   sudo ./Raco-Main.sh 1  (For Performance Mode)
#   sudo ./Raco-Main.sh 2  (For Balanced Mode)
#   sudo ./Raco-Main.sh 3  (For Powersave Mode)
# ==============================================================================


##############################
# SCRIPT INITIALIZATION
##############################

set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Error: This script must be run as root."
    echo "Please try again using 'sudo'."
    exit 1
fi


##############################
# HELPER FUNCTIONS
##############################

# Securely writes a value to a sysfs or procfs file
write_to_sysfs() {
    local value="$1"
    local file="$2"
    
    if [ -w "$file" ]; then
        echo "$value" > "$file" 2>/dev/null || echo "⚠️  Warning: Failed to write '$value' to $file"
    else
        echo "⚠️  Warning: Cannot write to $file. Skipping."
    fi
}


##########################################
# CPU HELPER FUNCTIONS
##########################################

# Disable Intel Turbo Boost
disable_boost() {
    if [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        write_to_sysfs "1" /sys/devices/system/cpu/intel_pstate/no_turbo
    fi
}

# Enable Intel Turbo Boost
enable_boost() {
    if [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        write_to_sysfs "0" /sys/devices/system/cpu/intel_pstate/no_turbo
    fi
}

# Enable HWP Dynamic Boost (if available)
enable_hwp_dynamic_boost() {
    if [ -w /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ]; then
        write_to_sysfs "1" /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost
        echo "✓ HWP Dynamic Boost enabled"
    fi
}

# Disable HWP Dynamic Boost
disable_hwp_dynamic_boost() {
    if [ -w /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost ]; then
        write_to_sysfs "0" /sys/devices/system/cpu/intel_pstate/hwp_dynamic_boost
        echo "✓ HWP Dynamic Boost disabled"
    fi
}

# Set Intel P-State performance percentage limits
set_pstate_limits() {
    local min_perf="$1"
    local max_perf="$2"
    
    if [ -w /sys/devices/system/cpu/intel_pstate/min_perf_pct ]; then
        write_to_sysfs "$min_perf" /sys/devices/system/cpu/intel_pstate/min_perf_pct
        echo "✓ Min performance: ${min_perf}%"
    fi
    
    if [ -w /sys/devices/system/cpu/intel_pstate/max_perf_pct ]; then
        write_to_sysfs "$max_perf" /sys/devices/system/cpu/intel_pstate/max_perf_pct
        echo "✓ Max performance: ${max_perf}%"
    fi
}

# Set energy performance preference (for intel_pstate)
# EPP can only be set when using powersave governor
set_epp() {
    local preference="$1"
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        local epp_file="$policy_dir/energy_performance_preference"
        local gov_file="$policy_dir/scaling_governor"
        
        if [ -w "$epp_file" ] && [ -r "$gov_file" ]; then
            local current_gov=$(<"$gov_file")
            
            # EPP only works with powersave governor
            if [ "$current_gov" != "powersave" ]; then
                write_to_sysfs "powersave" "$gov_file"
            fi
            
            write_to_sysfs "$preference" "$epp_file"
        fi
    done
}


##########################################
# GPU HELPER FUNCTIONS
##########################################

# Detect available GPUs
detect_gpus() {
    AMD_GPU_FOUND=0
    INTEL_GPU_FOUND=0
    
    # Check for AMD GPU
    if ls /sys/class/drm/card*/device/pp_power_profile_mode &>/dev/null; then
        AMD_GPU_FOUND=1
    fi
    
    # Check for Intel GPU
    if ls /sys/class/drm/card*/gt_* &>/dev/null 2>&1 || \
       [ -d /sys/kernel/debug/dri/0 ]; then
        INTEL_GPU_FOUND=1
    fi
}

# Set AMD GPU power profile
set_amd_gpu_power_profile() {
    local profile="$1"
    for card in /sys/class/drm/card*/device/pp_power_profile_mode; do
        if [ -w "$card" ]; then
            write_to_sysfs "$profile" "$card"
            echo "✓ AMD GPU: Power profile set to $profile"
        fi
    done
}

# Set Intel GPU frequency
set_intel_gpu_freq() {
    local min_freq="$1"
    local max_freq="$2"
    local boost_freq="$3"
    
    # Try GT (Graphics Technology) interface first (newer)
    for gt_dir in /sys/class/drm/card*/gt/gt*; do
        if [ -d "$gt_dir" ]; then
            [ -w "$gt_dir/rps_min_freq_mhz" ] && write_to_sysfs "$min_freq" "$gt_dir/rps_min_freq_mhz"
            [ -w "$gt_dir/rps_max_freq_mhz" ] && write_to_sysfs "$max_freq" "$gt_dir/rps_max_freq_mhz"
            [ -w "$gt_dir/rps_boost_freq_mhz" ] && write_to_sysfs "$boost_freq" "$gt_dir/rps_boost_freq_mhz"
            echo "✓ Intel GPU: Frequencies set (min: ${min_freq}MHz, max: ${max_freq}MHz, boost: ${boost_freq}MHz)"
            return
        fi
    done
    
    # Fallback to older interface
    for card in /sys/class/drm/card*/gt_min_freq_mhz; do
        local card_dir=$(dirname "$card")
        [ -w "$card" ] && write_to_sysfs "$min_freq" "$card"
        [ -w "$card_dir/gt_max_freq_mhz" ] && write_to_sysfs "$max_freq" "$card_dir/gt_max_freq_mhz"
        [ -w "$card_dir/gt_boost_freq_mhz" ] && write_to_sysfs "$boost_freq" "$card_dir/gt_boost_freq_mhz"
        echo "✓ Intel GPU: Frequencies set (min: ${min_freq}MHz, max: ${max_freq}MHz, boost: ${boost_freq}MHz)"
    done
}

# Get Intel GPU min/max frequencies
get_intel_gpu_freq_range() {
    # Try GT interface first
    for gt_dir in /sys/class/drm/card*/gt/gt*; do
        if [ -r "$gt_dir/rps_min_freq_mhz" ] && [ -r "$gt_dir/rps_max_freq_mhz" ]; then
            INTEL_GPU_MIN=$(cat "$gt_dir/rps_min_freq_mhz" 2>/dev/null || echo 0)
            INTEL_GPU_MAX=$(cat "$gt_dir/rps_max_freq_mhz" 2>/dev/null || echo 0)
            INTEL_GPU_RP0=$(cat "$gt_dir/rps_RP0_freq_mhz" 2>/dev/null || echo "$INTEL_GPU_MAX")
            INTEL_GPU_RPn=$(cat "$gt_dir/rps_RPn_freq_mhz" 2>/dev/null || echo "$INTEL_GPU_MIN")
            return
        fi
    done
    
    # Fallback to older interface
    for card in /sys/class/drm/card*/gt_min_freq_mhz; do
        local card_dir=$(dirname "$card")
        INTEL_GPU_MIN=$(cat "$card" 2>/dev/null || echo 0)
        INTEL_GPU_MAX=$(cat "$card_dir/gt_max_freq_mhz" 2>/dev/null || echo 0)
        INTEL_GPU_RP0=$(cat "$card_dir/gt_RP0_freq_mhz" 2>/dev/null || echo "$INTEL_GPU_MAX")
        INTEL_GPU_RPn=$(cat "$card_dir/gt_RPn_freq_mhz" 2>/dev/null || echo "$INTEL_GPU_MIN")
        return
    done
    
    INTEL_GPU_MIN=0 INTEL_GPU_MAX=0 INTEL_GPU_RP0=0 INTEL_GPU_RPn=0
}


##########################################
# SYSTEM TWEAKS HELPER FUNCTIONS
##########################################

# Set I/O scheduler for block devices
set_io_scheduler() {
    local scheduler="$1"
    for dev_path in /sys/block/[sv]d* /sys/block/nvme*; do
        if [ -d "$dev_path" ]; then
            write_to_sysfs "$scheduler" "$dev_path/queue/scheduler"
        fi
    done
    echo "✓ I/O Scheduler set to: $scheduler"
}

# Set SATA Aggressive Link Power Management (ALPM)
set_sata_alpm() {
    local mode="$1" # min_power, medium_power, max_performance
    for host in /sys/class/scsi_host/host*/link_power_management_policy; do
        write_to_sysfs "$mode" "$host"
    done
    echo "✓ SATA ALPM set to: $mode"
}

# Set USB autosuspend
set_usb_autosuspend() {
    local mode="$1" # "on" or "auto"
    for dev in /sys/bus/usb/devices/*/power/control; do
        write_to_sysfs "$mode" "$dev"
    done
    echo "✓ USB Autosuspend control set to: $mode"
}

# Set Audio codec power saving
set_audio_powersave() {
    local value="$1" # 0=off, 1=on
    write_to_sysfs "$value" "/sys/module/snd_hda_intel/parameters/power_save"
    echo "✓ Audio codec power saving set to: $value"
}

# Set Kernel Samepage Merging (KSM)
set_ksm() {
    local value="$1" # 0=off, 1=on
    write_to_sysfs "$value" "/sys/kernel/mm/ksm/run"
    echo "✓ Kernel Samepage Merging (KSM) set to: $value"
}

# Set Transparent Huge Pages (THP)
set_thp() {
    local mode="$1" # always, madvise, never
    write_to_sysfs "$mode" "/sys/kernel/mm/transparent_hugepage/enabled"
    echo "✓ Transparent Huge Pages (THP) set to: $mode"
}


##########################################
# MODE-SPECIFIC FUNCTIONS
##########################################

set_performance() {
    echo "Applying Performance settings..."
    # --- CPU ---
    enable_boost
    disable_hwp_dynamic_boost
    set_pstate_limits 100 100
    set_epp "performance"
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        write_to_sysfs "$(<"$policy_dir/cpuinfo_max_freq")" "$policy_dir/scaling_max_freq"
        write_to_sysfs "$(<"$policy_dir/cpuinfo_max_freq")" "$policy_dir/scaling_min_freq"
        write_to_sysfs "performance" "$policy_dir/scaling_governor"
    done
    
    # --- System Tweaks ---
    set_io_scheduler "none"
    set_sata_alpm "max_performance"
    set_usb_autosuspend "on"
    set_audio_powersave "0"
    set_ksm "0"
    set_thp "always"
}

set_balanced() {
    echo "Applying Balanced settings..."
    # --- CPU ---
    enable_boost
    enable_hwp_dynamic_boost
    set_pstate_limits 20 100
    set_epp "balance_performance"
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        write_to_sysfs "$(<"$policy_dir/cpuinfo_max_freq")" "$policy_dir/scaling_max_freq"
        write_to_sysfs "$(<"$policy_dir/cpuinfo_min_freq")" "$policy_dir/scaling_min_freq"
        write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done

    # --- System Tweaks ---
    set_io_scheduler "bfq"
    set_sata_alpm "medium_power"
    set_usb_autosuspend "auto"
    set_audio_powersave "1"
    set_ksm "0"
    set_thp "madvise"
}

set_powersave() {
    echo "Applying Powersave settings..."
    # --- CPU ---
    disable_boost
    disable_hwp_dynamic_boost
    set_pstate_limits 10 30
    set_epp "power"
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        local min_freq=$(<"$policy_dir/cpuinfo_min_freq")
        write_to_sysfs "$min_freq" "$policy_dir/scaling_min_freq"
        write_to_sysfs "$min_freq" "$policy_dir/scaling_max_freq"
        write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
    
    # --- System Tweaks ---
    set_io_scheduler "bfq"
    set_sata_alpm "min_power"
    set_usb_autosuspend "auto"
    set_audio_powersave "1"
    set_ksm "1"
    set_thp "never"
}

set_gpu_performance() {
    echo ""
    echo "Applying GPU Performance settings..."
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then set_amd_gpu_power_profile "1"; fi
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_RP0" -gt 0 ]; then set_intel_gpu_freq "$INTEL_GPU_RP0" "$INTEL_GPU_RP0" "$INTEL_GPU_RP0"; fi
    fi
}

set_gpu_balanced() {
    echo ""
    echo "Applying GPU Balanced settings..."
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then set_amd_gpu_power_profile "0"; fi
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_MAX" -gt 0 ]; then set_intel_gpu_freq "$INTEL_GPU_RPn" "$INTEL_GPU_RP0" "$INTEL_GPU_RP0"; fi
    fi
}

set_gpu_powersave() {
    echo ""
    echo "Applying GPU Powersave settings..."
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then set_amd_gpu_power_profile "5"; fi
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_RPn" -gt 0 ]; then set_intel_gpu_freq "$INTEL_GPU_RPn" "$INTEL_GPU_RPn" "$INTEL_GPU_RPn"; fi
    fi
}


##########################################
# MAIN EXECUTION LOGIC
##########################################

if [ -z "$1" ]; then
    echo "Usage: sudo $0 <mode>"
    echo "  1: Performance Mode"
    echo "  2: Balanced (Default) Mode"
    echo "  3: Powersave Mode"
    exit 1
fi

MODE=$1
detect_gpus

case $MODE in
    1)
        set_performance
        set_gpu_performance
        echo "✅ Performance mode activated. 🔥"
        ;;
    2)
        set_balanced
        set_gpu_balanced
        echo "✅ Balanced mode activated. ⚖️"
        ;;
    3)
        set_powersave
        set_gpu_powersave
        echo "✅ Powersave mode activated. 🔋"
        ;;
    *)
        echo "❌ Error: Invalid mode '$MODE'. Please use 1, 2, or 3."
        exit 1
        ;;
esac

echo ""
echo "--------------------------------"
echo "        CURRENT STATUS"
echo "--------------------------------"

# Display CPU status
echo ""
echo "CPU Frequency & Governor:"
for cpu in /sys/devices/system/cpu/cpu0/cpufreq/*; do
    name=$(basename "$cpu")
    if [ "$name" = "scaling_setspeed" ] || [ "$name" = "energy_performance_available_preferences" ]; then
        continue
    fi
    if [ -r "$cpu" ]; then
        value=$(cat "$cpu" 2>/dev/null)
        if [[ $name == *"freq" ]]; then value=$((value/1000))" MHz"; fi
        printf "  %-22s: %s\n" "$name" "$value"
    fi
done

# Display Intel P-State status
echo ""
echo "Intel P-State status:"
if [ -d /sys/devices/system/cpu/intel_pstate ]; then
    [ -r /sys/devices/system/cpu/intel_pstate/status ] && echo "  Status: $(cat /sys/devices/system/cpu/intel_pstate/status)"
    if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        [ "$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" -eq 0 ] && echo "  Turbo: Enabled" || echo "  Turbo: Disabled"
    fi
    [ -r /sys/devices/system/cpu/intel_pstate/min_perf_pct ] && echo "  Min Perf: $(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct)%"
    [ -r /sys/devices/system/cpu/intel_pstate/max_perf_pct ] && echo "  Max Perf: $(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)%"
else
    echo "  Intel P-State driver not active."
fi


# Display GPU status
echo ""
echo "GPU Status:"
if [ "$AMD_GPU_FOUND" -eq 1 ]; then
    echo "  AMD GPU detected:"
    for card in /sys/class/drm/card*/device/pp_power_profile_mode; do [ -r "$card" ] && echo "    Current Power Profile: $(grep '\*' "$card")" && break; done
fi
if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
    echo "  Intel GPU detected:"
    for gt_dir in /sys/class/drm/card*/gt/gt*; do
        if [ -r "$gt_dir/rps_cur_freq_mhz" ]; then
            printf "    Current: %s MHz,  Min: %s MHz,  Max: %s MHz\n" \
                "$(cat "$gt_dir/rps_cur_freq_mhz" 2>/dev/null || echo N/A)" \
                "$(cat "$gt_dir/rps_min_freq_mhz" 2>/dev/null || echo N/A)" \
                "$(cat "$gt_dir/rps_max_freq_mhz" 2>/dev/null || echo N/A)"
            break
        fi
    done
fi
if [ "$AMD_GPU_FOUND" -eq 0 ] && [ "$INTEL_GPU_FOUND" -eq 0 ]; then echo "  No supported GPU detected"; fi


# Display System Tweaks Status
echo ""
echo "System Tweaks Status:"
# I/O Scheduler (checking sda as a representative device)
if [ -r /sys/block/sda/queue/scheduler ]; then echo "  I/O Scheduler (sda): $(cat /sys/block/sda/queue/scheduler)"; fi
# SATA ALPM (checking host0)
if [ -r /sys/class/scsi_host/host0/link_power_management_policy ]; then echo "  SATA ALPM (host0): $(cat /sys/class/scsi_host/host0/link_power_management_policy)"; fi
# Audio Power Save
if [ -r /sys/module/snd_hda_intel/parameters/power_save ]; then echo "  Audio Power Save: $(cat /sys/module/snd_hda_intel/parameters/power_save)"; fi
# KSM & THP
if [ -r /sys/kernel/mm/ksm/run ]; then echo "  KSM Enabled: $(cat /sys/kernel/mm/ksm/run)"; fi
if [ -r /sys/kernel/mm/transparent_hugepage/enabled ]; then echo "  THP Mode: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"; fi


exit 0