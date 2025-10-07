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