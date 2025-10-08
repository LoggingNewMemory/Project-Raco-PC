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

# Securely writes a value to a sysfs file
write_to_sysfs() {
    local value="$1"
    local file="$2"
    
    if [ -w "$file" ]; then
        echo "$value" > "$file" 2>/dev/null || echo "⚠️  Warning: Failed to write to $file"
    else
        echo "⚠️  Warning: Cannot write to $file. Skipping."
    fi
}

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
    local profile="$1"  # 0-7 (typically: 0=bootup, 1=3D, 4=compute, 5=video)
    
    for card in /sys/class/drm/card*/device/pp_power_profile_mode; do
        if [ -w "$card" ]; then
            write_to_sysfs "$profile" "$card"
            echo "✓ AMD GPU: Power profile set to $profile"
        fi
    done
}

# Set AMD GPU frequency (manual mode)
set_amd_gpu_clocks() {
    local sclk_level="$1"  # GPU core clock level
    local mclk_level="$2"  # Memory clock level
    
    for card_path in /sys/class/drm/card*/device; do
        if [ -w "$card_path/pp_dpm_sclk" ]; then
            write_to_sysfs "$sclk_level" "$card_path/pp_dpm_sclk"
        fi
        if [ -w "$card_path/pp_dpm_mclk" ]; then
            write_to_sysfs "$mclk_level" "$card_path/pp_dpm_mclk"
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
    
    INTEL_GPU_MIN=0
    INTEL_GPU_MAX=0
    INTEL_GPU_RP0=0
    INTEL_GPU_RPn=0
}


##########################################
# KERNEL & I/O HELPER FUNCTIONS
##########################################

# Sets the I/O scheduler for block devices
set_io_scheduler() {
    local preferred_schedulers=("$@")
    local scheduler_set=0
    
    for queue in /sys/block/*/queue; do
        if [ -w "$queue/scheduler" ]; then
            local available_schedulers=$(cat "$queue/scheduler")
            for scheduler in "${preferred_schedulers[@]}"; do
                if [[ "$available_schedulers" == *"$scheduler"* ]]; then
                    write_to_sysfs "$scheduler" "$queue/scheduler"
                    scheduler_set=1
                    break 
                fi
            done
        fi
    done
    [ "$scheduler_set" -eq 1 ] && echo "✓ I/O Scheduler configured."
}

# Configure Virtual Memory settings via sysctl
set_vm_tweaks() {
    local swappiness="$1"
    local cache_pressure="$2"
    local dirty_bg_ratio="$3"
    local dirty_ratio="$4"

    sysctl -w vm.swappiness="$swappiness" >/dev/null 2>&1
    echo "✓ VM Swappiness set to $swappiness"

    sysctl -w vm.vfs_cache_pressure="$cache_pressure" >/dev/null 2>&1
    echo "✓ VM VFS Cache Pressure set to $cache_pressure"

    sysctl -w vm.dirty_background_ratio="$dirty_bg_ratio" >/dev/null 2>&1
    sysctl -w vm.dirty_ratio="$dirty_ratio" >/dev/null 2>&1
    echo "✓ VM Dirty page ratios set to $dirty_bg_ratio% / $dirty_ratio%"
}

# Configure Kernel Samepage Merging (KSM)
set_ksm() {
    local state="$1" # 1 for on, 0 for off
    if [ ! -w /sys/kernel/mm/ksm/run ]; then return; fi

    if [ "$state" -eq 1 ]; then
        write_to_sysfs "1" /sys/kernel/mm/ksm/run
        write_to_sysfs "1500" /sys/kernel/mm/ksm/sleep_millisecs
        write_to_sysfs "100" /sys/kernel/mm/ksm/pages_to_scan
        echo "✓ KSM enabled (for memory saving)"
    else
        write_to_sysfs "0" /sys/kernel/mm/ksm/run
        echo "✓ KSM disabled (for performance)"
    fi
}

# Configure SATA ALPM (Aggressive Link Power Management)
set_sata_alpm() {
    local policy="$1"
    for host in /sys/class/scsi_host/host*/link_power_management_policy; do
        if [ -w "$host" ]; then
            write_to_sysfs "$policy" "$host"
        fi
    done
    echo "✓ SATA Link Power Management set to '$policy'"
}

# Configure Audio codec power saving
set_audio_power() {
    local state="$1" # 1 for on, 0 for off
    if [ -w /sys/module/snd_hda_intel/parameters/power_save ]; then
        write_to_sysfs "$state" /sys/module/snd_hda_intel/parameters/power_save
        if [ "$state" -eq 1 ]; then
             write_to_sysfs "Y" /sys/module/snd_hda_intel/parameters/power_save_controller
             echo "✓ Audio codec power saving enabled"
        else
             write_to_sysfs "N" /sys/module/snd_hda_intel/parameters/power_save_controller
             echo "✓ Audio codec power saving disabled"
        fi
    fi
}


##########################################
# MODE-SPECIFIC CPU FUNCTIONS
##########################################

set_performance() {
    echo "Applying Performance settings..."

    if [ -w /sys/firmware/acpi/platform_profile ]; then
        write_to_sysfs "performance" /sys/firmware/acpi/platform_profile
        echo "✓ Platform profile set to performance"
    fi

    enable_boost
    disable_hwp_dynamic_boost
    set_pstate_limits 100 100

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -w "$policy_dir/scaling_governor" ] && write_to_sysfs "performance" "$policy_dir/scaling_governor"
    done
    echo "✓ CPU Scaling Governor set to performance"
    
    echo ""
    echo "Applying Kernel & I/O tweaks for Performance..."
    set_io_scheduler "kyber" "mq-deadline"
    set_vm_tweaks 10 50 15 30
    set_sata_alpm "max_performance"
    set_audio_power 0
    set_ksm 0
}

set_balanced() {
    echo "Applying Balanced settings..."

    if [ -w /sys/firmware/acpi/platform_profile ]; then
        write_to_sysfs "balanced" /sys/firmware/acpi/platform_profile
        echo "✓ Platform profile set to balanced"
    fi
 
    enable_boost
    enable_hwp_dynamic_boost
    set_pstate_limits 20 100

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -w "$policy_dir/scaling_governor" ] && write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
    echo "✓ CPU Scaling Governor set to powersave"
    
    echo ""
    echo "Applying Kernel & I/O tweaks for Balanced..."
    set_io_scheduler "bfq" "mq-deadline"
    set_vm_tweaks 60 100 10 20  # Default kernel values
    set_sata_alpm "medium_power"
    set_audio_power 1
    set_ksm 0 
}

set_powersave() {
    echo "Applying Powersave settings..."

    if [ -w /sys/firmware/acpi/platform_profile ]; then
        local available_profiles=$(<"/sys/firmware/acpi/platform_profile")
        if [[ "$available_profiles" == *"low-power"* ]]; then
            write_to_sysfs "low-power" /sys/firmware/acpi/platform_profile
            echo "✓ Platform profile set to low-power"
        else
            write_to_sysfs "balanced" /sys/firmware/acpi/platform_profile
            echo "✓ Platform profile set to balanced (best available for powersave)"
        fi
    fi
    
    disable_boost
    disable_hwp_dynamic_boost
    set_pstate_limits 10 30

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -w "$policy_dir/scaling_governor" ] && write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
    echo "✓ CPU Scaling Governor set to powersave"
    
    echo ""
    echo "Applying Kernel & I/O tweaks for Powersave..."
    set_io_scheduler "bfq"
    set_vm_tweaks 80 150 5 10
    set_sata_alpm "min_power"
    set_audio_power 1
    set_ksm 1
}


##########################################
# MODE-SPECIFIC GPU FUNCTIONS
##########################################

set_gpu_performance() {
    echo ""
    echo "Applying GPU Performance settings..."
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        set_amd_gpu_power_profile "1"  # 3D Full Speed
    fi
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_RP0" -gt 0 ]; then
            set_intel_gpu_freq "$INTEL_GPU_RP0" "$INTEL_GPU_RP0" "$INTEL_GPU_RP0"
        fi
    fi
}

set_gpu_balanced() {
    echo ""
    echo "Applying GPU Balanced settings..."
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        set_amd_gpu_power_profile "0"  # Bootup/Auto
    fi
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_MAX" -gt 0 ]; then
            set_intel_gpu_freq "$INTEL_GPU_RPn" "$INTEL_GPU_RP0" "$INTEL_GPU_RP0"
        fi
    fi
}

set_gpu_powersave() {
    echo ""
    echo "Applying GPU Powersave settings..."
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        set_amd_gpu_power_profile "5"  # Video/Power Saving
    fi
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_RPn" -gt 0 ]; then
            set_intel_gpu_freq "$INTEL_GPU_RPn" "$INTEL_GPU_RPn" "$INTEL_GPU_RPn"
        fi
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

# Detect available GPUs
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
echo "Current CPU frequency info:"
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    if [ -r "$cpu" ]; then
        cpu_num=$(echo "$cpu" | grep -oP 'cpu\K[0-9]+')
        freq=$(cat "$cpu")
        freq_mhz=$((freq / 1000))
        gov_file="/sys/devices/system/cpu/cpu${cpu_num}/cpufreq/scaling_governor"
        governor=$(cat "$gov_file" 2>/dev/null || echo "N/A")
        echo "  CPU$cpu_num: ${freq_mhz} MHz (Governor: $governor)"
        break  # Just show one as example
    fi
done

# Display Intel P-State status
echo ""
echo "Intel P-State status:"
if [ -r /sys/devices/system/cpu/intel_pstate/status ]; then
    echo "  Status: $(cat /sys/devices/system/cpu/intel_pstate/status)"
fi
if [ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
    turbo_status=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)
    [ "$turbo_status" -eq 0 ] && echo "  Turbo: Enabled" || echo "  Turbo: Disabled"
fi
if [ -r /sys/devices/system/cpu/intel_pstate/min_perf_pct ]; then
    echo "  Min Perf: $(cat /sys/devices/system/cpu/intel_pstate/min_perf_pct)%"
fi
if [ -r /sys/devices/system/cpu/intel_pstate/max_perf_pct ]; then
    echo "  Max Perf: $(cat /sys/devices/system/cpu/intel_pstate/max_perf_pct)%"
fi

# Display GPU status
echo ""
echo "GPU Status:"

if [ "$AMD_GPU_FOUND" -eq 1 ]; then
    echo "  AMD GPU detected:"
    for card in /sys/class/drm/card*/device/pp_power_profile_mode; do
        if [ -r "$card" ]; then
            echo "    Current Power Profile: $(grep '\*' "$card")"
            break
        fi
    done
fi

if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
    echo "  Intel GPU detected:"
    # Try GT interface
    for gt_dir in /sys/class/drm/card*/gt/gt*; do
        if [ -r "$gt_dir/rps_cur_freq_mhz" ]; then
            cur_freq=$(cat "$gt_dir/rps_cur_freq_mhz" 2>/dev/null || echo "N/A")
            min_freq=$(cat "$gt_dir/rps_min_freq_mhz" 2>/dev/null || echo "N/A")
            max_freq=$(cat "$gt_dir/rps_max_freq_mhz" 2>/dev/null || echo "N/A")
            echo "    Current: ${cur_freq} MHz"
            echo "    Range: ${min_freq} - ${max_freq} MHz"
            break
        fi
    done
    
    # Fallback to older interface
    for card in /sys/class/drm/card*/gt_cur_freq_mhz; do
        if [ -r "$card" ]; then
            cur_freq=$(cat "$card" 2>/dev/null || echo "N/A")
            echo "    Current: ${cur_freq} MHz"
            break
        fi
    done
fi

if [ "$AMD_GPU_FOUND" -eq 0 ] && [ "$INTEL_GPU_FOUND" -eq 0 ]; then
    echo "  No supported GPU detected"
fi

exit 0