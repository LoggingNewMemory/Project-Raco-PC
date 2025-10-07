#!/bin/bash

# ==============================================================================
# Usage:
#   sudo ./Raco-Main.sh 1  (For Performance Mode)
#   sudo ./Raco-Main.sh 2  (For Balanced Mode)
#   sudo ./Raco-Main.sh 3  (For Powersave Mode)
# ==============================================================================


###############################
# SETTINGS
###############################

# LITE_MODE:
# When set to 1, Performance mode uses schedutil/ondemand governor with
# max frequency as ceiling, allowing dynamic scaling while prioritizing performance.
# 0 = Use performance governor (always max frequency if supported).
# 1 = Use dynamic governor with performance tuning.
LITE_MODE=0

# BETTER_POWERSAVE:
# When set to 1, Powersave mode allows bursting to mid-frequency
# for better responsiveness while still prioritizing power saving.
# 0 = Strict powersave with minimal frequency.
# 1 = Allow bursting to mid-frequency.
BETTER_POWERSAVE=0

# GPU_CONTROL:
# Enable GPU frequency and power management
# 0 = Skip GPU tweaks
# 1 = Apply GPU tweaks
GPU_CONTROL=1


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

# Gets the middle frequency from available frequencies
get_mid_freq() {
    local freqs_file="$1"
    if [ ! -r "$freqs_file" ]; then echo 0; return; fi

    local freqs=( $(tr ' ' '\n' < "$freqs_file" | sort -n) )
    local count=${#freqs[@]}

    if [ "$count" -eq 0 ]; then
        echo 0
    else
        local mid_index=$((count / 2))
        echo "${freqs[$mid_index]}"
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
    if ls /sys/class/drm/card*/device/power_dpm_force_performance_level &>/dev/null; then
        AMD_GPU_FOUND=1
    fi
    
    # Check for Intel GPU
    if ls /sys/class/drm/card*/gt_* &>/dev/null 2>&1 || \
       [ -d /sys/kernel/debug/dri/0 ]; then
        INTEL_GPU_FOUND=1
    fi
}

# Set AMD GPU performance level
set_amd_gpu_performance_level() {
    local level="$1"  # auto, low, high, manual
    
    for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
        if [ -w "$card" ]; then
            write_to_sysfs "$level" "$card"
            echo "✓ AMD GPU: Performance level set to $level"
        fi
    done
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
# MODE-SPECIFIC CPU FUNCTIONS
##########################################

set_performance() {
    echo "Applying Performance settings..."

    enable_boost
    disable_hwp_dynamic_boost
    set_pstate_limits 100 100
    set_epp "performance"

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        local cpuinfo_max_freq=$(<"$policy_dir/cpuinfo_max_freq")
        local cpuinfo_min_freq=$(<"$policy_dir/cpuinfo_min_freq")
        
        # Set frequency limits FIRST
        write_to_sysfs "$cpuinfo_max_freq" "$policy_dir/scaling_max_freq"
        
        if [ "$LITE_MODE" -eq 1 ]; then
            # Lite mode: Use dynamic governor with high minimum
            local mid_freq=$(get_mid_freq "$policy_dir/scaling_available_frequencies")
            [ "$mid_freq" -gt 0 ] && write_to_sysfs "$mid_freq" "$policy_dir/scaling_min_freq"
            
            write_to_sysfs "powersave" "$policy_dir/scaling_governor"
        else
            # Full performance: Use performance governor
            write_to_sysfs "$cpuinfo_max_freq" "$policy_dir/scaling_min_freq"
            
            write_to_sysfs "performance" "$policy_dir/scaling_governor"
        fi
    done
}

set_balanced() {
    echo "Applying Balanced settings..."

    enable_boost
    enable_hwp_dynamic_boost
    set_pstate_limits 20 100
    set_epp "balance_performance"

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        local cpuinfo_max_freq=$(<"$policy_dir/cpuinfo_max_freq")
        local cpuinfo_min_freq=$(<"$policy_dir/cpuinfo_min_freq")

        # Restore default limits
        write_to_sysfs "$cpuinfo_max_freq" "$policy_dir/scaling_max_freq"
        write_to_sysfs "$cpuinfo_min_freq" "$policy_dir/scaling_min_freq"
        
        # Use powersave governor for balanced mode
        write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
}

set_powersave() {
    echo "Applying Powersave settings..."

    disable_boost
    enable_hwp_dynamic_boost
    
    if [ "$BETTER_POWERSAVE" -eq 1 ]; then
        set_pstate_limits 10 60
    else
        set_pstate_limits 10 30
    fi
    
    set_epp "power"

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        local cpuinfo_min_freq=$(<"$policy_dir/cpuinfo_min_freq")
        local cpuinfo_max_freq=$(<"$policy_dir/cpuinfo_max_freq")
        
        # Set minimum first
        write_to_sysfs "$cpuinfo_min_freq" "$policy_dir/scaling_min_freq"
        
        if [ "$BETTER_POWERSAVE" -eq 1 ]; then
            # Better powersave: Allow bursting to mid frequency
            local mid_freq=$(get_mid_freq "$policy_dir/scaling_available_frequencies")
            if [ "$mid_freq" -gt 0 ] && [ "$mid_freq" -gt "$cpuinfo_min_freq" ]; then
                write_to_sysfs "$mid_freq" "$policy_dir/scaling_max_freq"
            else
                write_to_sysfs "$cpuinfo_min_freq" "$policy_dir/scaling_max_freq"
            fi
        else
            # Strict powersave: Lock to minimum
            write_to_sysfs "$cpuinfo_min_freq" "$policy_dir/scaling_max_freq"
        fi
        
        write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
}


##########################################
# MODE-SPECIFIC GPU FUNCTIONS
##########################################

set_gpu_performance() {
    if [ "$GPU_CONTROL" -eq 0 ]; then return; fi
    
    echo ""
    echo "Applying GPU Performance settings..."
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        set_amd_gpu_performance_level "high"
        set_amd_gpu_power_profile "1"  # 3D Full Speed
    fi
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_RP0" -gt 0 ]; then
            # Set to maximum performance (RP0)
            set_intel_gpu_freq "$INTEL_GPU_RP0" "$INTEL_GPU_RP0" "$INTEL_GPU_RP0"
        fi
    fi
}

set_gpu_balanced() {
    if [ "$GPU_CONTROL" -eq 0 ]; then return; fi
    
    echo ""
    echo "Applying GPU Balanced settings..."
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        set_amd_gpu_performance_level "auto"
        set_amd_gpu_power_profile "0"  # Bootup/Auto
    fi
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_MAX" -gt 0 ]; then
            # Allow full range, let GPU decide
            set_intel_gpu_freq "$INTEL_GPU_RPn" "$INTEL_GPU_RP0" "$INTEL_GPU_RP0"
        fi
    fi
}

set_gpu_powersave() {
    if [ "$GPU_CONTROL" -eq 0 ]; then return; fi
    
    echo ""
    echo "Applying GPU Powersave settings..."
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        set_amd_gpu_performance_level "low"
        set_amd_gpu_power_profile "5"  # Video/Power Saving
    fi
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        get_intel_gpu_freq_range
        if [ "$INTEL_GPU_RPn" -gt 0 ]; then
            # Lock to minimum frequency (RPn)
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
if [ "$GPU_CONTROL" -eq 1 ]; then
    detect_gpus
fi

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
        echo "  CPU$cpu_num: ${freq_mhz} MHz"
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
if [ "$GPU_CONTROL" -eq 1 ]; then
    echo ""
    echo "GPU Status:"
    
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        echo "  AMD GPU detected:"
        for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            if [ -r "$card" ]; then
                echo "    Performance Level: $(cat "$card")"
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
fi

exit 0