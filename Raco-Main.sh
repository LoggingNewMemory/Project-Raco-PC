#!/bin/bash

# ==============================================================================
# Raco CPU Performance Script - Improved Version
#
# This script adjusts CPU performance profiles on Linux systems using
# a more reliable approach that works with modern CPU governors.
# It MUST be run with root privileges (e.g., using 'sudo').
#
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

# Disable CPU boost (Intel Turbo / AMD Precision Boost)
disable_boost() {
    # Intel
    if [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        write_to_sysfs "1" /sys/devices/system/cpu/intel_pstate/no_turbo
    fi
    
    # AMD
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        write_to_sysfs "0" /sys/devices/system/cpu/cpufreq/boost
    fi
}

# Enable CPU boost
enable_boost() {
    # Intel
    if [ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]; then
        write_to_sysfs "0" /sys/devices/system/cpu/intel_pstate/no_turbo
    fi
    
    # AMD
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        write_to_sysfs "1" /sys/devices/system/cpu/cpufreq/boost
    fi
}

# Set energy performance preference (for intel_pstate)
set_epp() {
    local preference="$1"
    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        local epp_file="$policy_dir/energy_performance_preference"
        if [ -w "$epp_file" ]; then
            write_to_sysfs "$preference" "$epp_file"
        fi
    done
}




##########################################
# MODE-SPECIFIC FUNCTIONS
##########################################

set_performance() {
    echo "Applying Performance settings..."

    enable_boost
    set_epp "performance"

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        if [ "$LITE_MODE" -eq 1 ]; then
            # Lite mode: Use dynamic governor with performance tuning
            write_to_sysfs "powersave" "$policy_dir/scaling_governor"
        else
            # Full performance: Use performance governor
            write_to_sysfs "performance" "$policy_dir/scaling_governor"
        fi
    done
}

set_balanced() {
    echo "Applying Balanced settings..."

    enable_boost
    set_epp "balance_performance"

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        # Use powersave governor for balanced mode
        write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
}

set_powersave() {
    echo "Applying Powersave settings..."

    disable_boost
    set_epp "power"

    for policy_dir in /sys/devices/system/cpu/cpufreq/policy*; do
        write_to_sysfs "powersave" "$policy_dir/scaling_governor"
    done
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

case $MODE in
    1)
        set_performance
        echo "✅ Performance mode activated. 🔥"
        ;;
    2)
        set_balanced
        echo "✅ Balanced mode activated. ⚖️"
        ;;
    3)
        set_powersave
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

exit 0