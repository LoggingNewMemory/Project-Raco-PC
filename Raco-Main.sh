# INI ADALAH PORT DARI PROJECT RACO
# BUAT PC / LAPTOP YANG OSNYA LINUX YA

# Jadi ini hal no.1 gw bakal coba ubah freq CPUnya

#!/bin/bash

###############################
# SETTINGS
###############################
# This script is self-contained. Modify the values below directly if needed.

# LITE_MODE:
# 0 = Use max frequencies in performance modes.
# 1 = Use mid-range frequencies in performance modes (less aggressive).
LITE_MODE=0

# BETTER_POWERAVE:
# 0 = Use the lowest frequencies in powersave mode.
# 1 = Use mid-range frequencies in powersave mode (better responsiveness).
BETTER_POWERAVE=0


##############################
# HELPER FUNCTIONS
##############################

# Securely writes a value to a system file.
tweak() {
    if [ -e "$2" ]; then
        chmod 644 "$2" >/dev/null 2>&1
        echo "$1" > "$2" 2>/dev/null
        chmod 444 "$2" >/dev/null 2>&1
    fi
}

# Unsecurely writes a value to a system file (used for unlocking).
kakangkuh() {
	[ ! -f "$2" ] && return 1
	chmod 644 "$2" >/dev/null 2>&1
	echo "$1" >"$2" 2>/dev/null
}

# Finds the highest frequency from a list.
which_maxfreq() {
	tr ' ' '\n' <"$1" | sort -nr | head -n 1
}

# Finds the lowest frequency from a list.
which_minfreq() {
	tr ' ' '\n' <"$1" | grep -v '^[[:space:]]*$' | sort -n | head -n 1
}

# Finds the middle frequency from a list.
which_midfreq() {
	total_opp=$(wc -w <"$1")
	mid_opp=$(((total_opp + 1) / 2))
	tr ' ' '\n' <"$1" | grep -v '^[[:space:]]*$' | sort -nr | head -n $mid_opp | tail -n 1
}


###################################
# CPU FREQUENCY FUNCTIONS
###################################

# Locks CPU frequency to max for performance (PPM Driver).
cpufreq_ppm_max_perf() {
	cluster=-1
	for path in /sys/devices/system/cpu/cpufreq/policy*; do
		((cluster++))
		cpu_maxfreq=$(<"$path/cpuinfo_max_freq")
		tweak "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq

		if [ "$LITE_MODE" -eq 1 ]; then
			cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies")
			tweak "$cluster $cpu_midfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
		else
			tweak "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
		fi
	done
}

# Locks CPU frequency to max for performance (Standard Driver).
cpufreq_max_perf() {
	for path in /sys/devices/system/cpu/*/cpufreq; do
		cpu_maxfreq=$(<"$path/cpuinfo_max_freq")
		tweak "$cpu_maxfreq" "$path/scaling_max_freq"

		if [ "$LITE_MODE" -eq 1 ]; then
			cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies")
			tweak "$cpu_midfreq" "$path/scaling_min_freq"
		else
			tweak "$cpu_maxfreq" "$path/scaling_min_freq"
		fi
	done
	chmod -f 444 /sys/devices/system/cpu/cpufreq/policy*/scaling_*_freq
}

# Unlocks CPU frequency limits to default (PPM Driver).
cpufreq_ppm_unlock() {
	cluster=0
	for path in /sys/devices/system/cpu/cpufreq/policy*; do
		cpu_maxfreq=$(<"$path/cpuinfo_max_freq")
		cpu_minfreq=$(<"$path/cpuinfo_min_freq")
		kakangkuh "$cluster $cpu_maxfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq
		kakangkuh "$cluster $cpu_minfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
		((cluster++))
	done
}

# Unlocks CPU frequency limits to default (Standard Driver).
cpufreq_unlock() {
	for path in /sys/devices/system/cpu/*/cpufreq; do
		cpu_maxfreq=$(<"$path/cpuinfo_max_freq")
		cpu_minfreq=$(<"$path/cpuinfo_min_freq")
		kakangkuh "$cpu_maxfreq" "$path/scaling_max_freq"
		kakangkuh "$cpu_minfreq" "$path/scaling_min_freq"
	done
	chmod -f 644 /sys/devices/system/cpu/cpufreq/policy*/scaling_*_freq
}

# Locks CPU frequency to min for powersaving (PPM Driver).
cpufreq_ppm_min_perf() {
    cluster=-1
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        ((cluster++))
        cpu_minfreq=$(<"$path/cpuinfo_min_freq")
        if [ "$BETTER_POWERAVE" -eq 1 ]; then
            cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies")
            tweak "$cluster $cpu_midfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq
            tweak "$cluster $cpu_minfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
        else
            tweak "$cluster $cpu_minfreq" /proc/ppm/policy/hard_userlimit_max_cpu_freq
            tweak "$cluster $cpu_minfreq" /proc/ppm/policy/hard_userlimit_min_cpu_freq
        fi
    done
}

# Locks CPU frequency to min for powersaving (Standard Driver).
cpufreq_min_perf() {
    for path in /sys/devices/system/cpu/*/cpufreq; do
        cpu_minfreq=$(<"$path/cpuinfo_min_freq")
        if [ "$BETTER_POWERAVE" -eq 1 ]; then
            cpu_midfreq=$(which_midfreq "$path/scaling_available_frequencies")
            tweak "$cpu_midfreq" "$path/scaling_max_freq"
            tweak "$cpu_minfreq" "$path/scaling_min_freq"
        else
            tweak "$cpu_minfreq" "$path/scaling_max_freq"
            tweak "$cpu_minfreq" "$path/scaling_min_freq"
        fi
    done
    chmod -f 444 /sys/devices/system/cpu/cpufreq/policy*/scaling_*_freq
}


##########################################
# MODE-SPECIFIC FUNCTIONS
##########################################

performance_basic() {
    if [ -d /proc/ppm ]; then
        cpufreq_ppm_max_perf
    else
        cpufreq_max_perf
    fi
}

balanced_basic() {
    if [ -d /proc/ppm ]; then
        cpufreq_ppm_unlock
    else
        cpufreq_unlock
    fi
}

powersave_basic() {
    if [ -d /proc/ppm ]; then
        cpufreq_ppm_min_perf
    else
        cpufreq_min_perf
    fi
}


##########################################
# MAIN EXECUTION LOGIC
##########################################

if [ -z "$1" ]; then
    echo "Usage: $0 <mode>"
    echo "  1: Performance Mode"
    echo "  2: Normal (Balanced) Mode"
    echo "  3: Powersave Mode"
    exit 1
fi

MODE=$1

case $MODE in
    1)
        performance_basic
        echo "Performance mode activated. 🔥"
        ;;
    2)
        balanced_basic
        echo "Normal (Balanced) mode activated. ⚖️"
        ;;
    3)
        powersave_basic
        echo "Powersave mode activated. 🔋"
        ;;
    *)
        echo "Error: Invalid mode '$MODE'. Please use 1, 2, or 3."
        exit 1
        ;;
esac

exit 0