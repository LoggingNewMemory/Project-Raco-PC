#!/bin/bash

# ==============================================================================
# Usage:
#   sudo ./Raco-Main.sh        (Shows Version & Checks for updates)
#   sudo ./Raco-Main.sh 1      (For Performance Mode)
#   sudo ./Raco-Main.sh 2      (For Balanced Mode)
#   sudo ./Raco-Main.sh 3      (For Powersave Mode)
# ==============================================================================


##############################
# SCRIPT INITIALIZATION
##############################

set -e

SCRIPT_VERSION="1.3"
SCRIPT_URL="https://raw.githubusercontent.com/LoggingNewMemory/Project-Raco-PC/main/Raco-Main.sh"
SCRIPT_PATH=$(readlink -f "$0")

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Error: This script must be run as root."
    echo "Please try again using 'sudo'."
    exit 1
fi

show_header() {
    echo "========================================================"
    echo "   Project Raco PC - Linux Power Optimizer"
    echo "   Version: $SCRIPT_VERSION"
    echo "========================================================"
    echo ""
}

check_for_updates() {
    read -p "Check for script updates? [y/n]: " -n 1 -r
    echo "" 

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi

    echo "Checking for updates..."
    
    # Capture the current owner and group of the script BEFORE updating
    local current_user
    local current_group
    current_user=$(stat -c '%U' "$SCRIPT_PATH")
    current_group=$(stat -c '%G' "$SCRIPT_PATH")

    local temp_file
    temp_file=$(mktemp)
    if ! curl -sL "$SCRIPT_URL" -o "$temp_file"; then
        echo "❌ Error: Failed to download updates."
        rm -f "$temp_file"
        exit 1
    fi
    
    if cmp -s "$SCRIPT_PATH" "$temp_file"; then
        echo "✅ You are using the latest version ($SCRIPT_VERSION)."
        rm -f "$temp_file"
    else
        echo "🔄 New version found! Updating..."
        if mv "$temp_file" "$SCRIPT_PATH"; then
            chmod +x "$SCRIPT_PATH"
            
            # Restore the original ownership
            chown "${current_user}:${current_group}" "$SCRIPT_PATH"

            echo "✅ Script updated. Please re-run the script to load new changes."
            exit 0
        else
            echo "❌ Error: Update failed."
            rm -f "$temp_file"
            exit 1
        fi
    fi
}

##############################
# HELPER FUNCTIONS
##############################

write_to_sysfs() {
    local value="$1"
    local file="$2"
    if [ -w "$file" ]; then
        echo "$value" > "$file" 2>/dev/null || true
    fi
}

apply_sysctl() {
    local key="$1"
    local value="$2"
    if sysctl -n "$key" &>/dev/null; then
        sysctl -w "$key=$value" &>/dev/null
    fi
}

send_notification() {
    local title="$1"
    local body="$2"
    if [ -n "$SUDO_USER" ]; then
        local user_id=$(id -u "$SUDO_USER")
        local bus="unix:path=/run/user/$user_id/bus"
        sudo -u "$SUDO_USER" DBUS_SESSION_BUS_ADDRESS="$bus" notify-send "$title" "$body" 2>/dev/null || true
    fi
}

# --- CRITICAL: STOP CONFLICTING SERVICES ---
stop_conflicts() {
    echo "Checking for conflicting power managers..."
    # power-profiles-daemon has been removed from this list as per update 1.3
    for service in tlp auto-cpufreq thermald; do
        if systemctl is-active --quiet "$service"; then
            echo "⚠️  Stopping $service to prevent interference..."
            systemctl stop "$service" 2>/dev/null || true
        fi
    done
}

restart_services() {
    echo "🔄 Restoring power management services..."
    # Attempt to start standard power managers if they exist
    # power-profiles-daemon removed from restart logic as it is no longer stopped
    for service in tlp auto-cpufreq thermald; do
        # Check if service exists before trying to start
        if systemctl list-unit-files "$service.service" &>/dev/null; then
            if ! systemctl is-active --quiet "$service"; then
                echo "   -> Starting $service..."
                systemctl start "$service" 2>/dev/null || true
            fi
        fi
    done
}


##########################################
# HARDWARE DETECTION
##########################################

detect_hardware() {
    if grep -q "GenuineIntel" /proc/cpuinfo; then CPU_VENDOR="INTEL"; fi
    if grep -q "AuthenticAMD" /proc/cpuinfo; then CPU_VENDOR="AMD"; fi
    
    INTEL_GPU_FOUND=0
    AMD_GPU_FOUND=0
    NVIDIA_GPU_FOUND=0
    
    if ls /sys/class/drm/card*/gt_* &>/dev/null 2>&1 || [ -d /sys/kernel/debug/dri/0 ]; then INTEL_GPU_FOUND=1; fi
    if ls /sys/class/drm/card*/device/power_dpm_state &>/dev/null 2>&1; then AMD_GPU_FOUND=1; fi
    if command -v nvidia-smi &>/dev/null; then NVIDIA_GPU_FOUND=1; fi
}


##########################################
# CPU OPTIMIZATION
##########################################

set_cpu_governor() {
    local gov="$1"
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        write_to_sysfs "$gov" "$cpu"
    done
}

set_cpu_epp() {
    local pref="$1" 
    for path in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        write_to_sysfs "$pref" "$path"
    done
}

set_cpu_boost() {
    local state="$1" # 1=Enable, 0=Disable
    if [ "$CPU_VENDOR" == "INTEL" ]; then
        # 0 = Turbo Enabled, 1 = Turbo Disabled
        local val=$((1-state))
        write_to_sysfs "$val" "/sys/devices/system/cpu/intel_pstate/no_turbo"
    fi
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        write_to_sysfs "$state" "/sys/devices/system/cpu/cpufreq/boost"
    fi
}


##########################################
# "FAKE AC" & SYSTEM TWEAKS
##########################################

set_laptop_mode_tweaks() {
    local mode="$1" # performance, balanced, powersave

    if [ "$mode" == "performance" ]; then
        # --- THE "FAKE AC" LOGIC ---
        # 1. Disable "Laptop Mode" - Kernel behaves as if plugged in (spins up disks, aggressive flushes)
        apply_sysctl "vm.laptop_mode" "0" 
        
        # 2. Force PCIe Links to stay fully powered (Fixes battery micro-stutters)
        write_to_sysfs "performance" "/sys/module/pcie_aspm/parameters/policy"
        
        # 3. Disable WiFi Power Save (Fixes ping spikes on battery)
        for iface in $(ls /sys/class/net | grep -E 'wlan|wlp|wlx'); do
            if command -v iw &>/dev/null; then
                iw dev "$iface" set power_save off 2>/dev/null || true
            fi
        done

        # 4. Standard VM Perf Tweaks
        apply_sysctl "vm.swappiness" "10"
        apply_sysctl "vm.vfs_cache_pressure" "50"
        apply_sysctl "vm.dirty_ratio" "40"
        apply_sysctl "vm.dirty_background_ratio" "10"
        apply_sysctl "vm.max_map_count" "2147483642"
        apply_sysctl "kernel.nmi_watchdog" "0"

    elif [ "$mode" == "balanced" ]; then
        apply_sysctl "vm.laptop_mode" "2" # Moderate power saving
        write_to_sysfs "default" "/sys/module/pcie_aspm/parameters/policy"
        
        apply_sysctl "vm.swappiness" "60"
        apply_sysctl "vm.vfs_cache_pressure" "100"
        apply_sysctl "kernel.nmi_watchdog" "1"

    else # powersave
        apply_sysctl "vm.laptop_mode" "5" # Aggressive power saving
        write_to_sysfs "powersave" "/sys/module/pcie_aspm/parameters/policy"
        
        # Re-enable WiFi Power Save
        for iface in $(ls /sys/class/net | grep -E 'wlan|wlp|wlx'); do
            if command -v iw &>/dev/null; then
                iw dev "$iface" set power_save on 2>/dev/null || true
            fi
        done
        
        apply_sysctl "vm.swappiness" "60"
        apply_sysctl "vm.dirty_writeback_centisecs" "1500"
    fi
}

set_network_tweaks() {
    local mode="$1"
    modprobe sch_cake 2>/dev/null || true

    if [ "$mode" == "performance" ] || [ "$mode" == "balanced" ]; then
        apply_sysctl "net.core.default_qdisc" "cake"
        apply_sysctl "net.ipv4.tcp_congestion_control" "bbr"
        apply_sysctl "net.ipv4.tcp_fastopen" "3"
        apply_sysctl "net.ipv4.tcp_window_scaling" "1"
    else
        apply_sysctl "net.ipv4.tcp_congestion_control" "cubic"
    fi
}


##########################################
# GPU OPTIMIZATION
##########################################

optimize_gpu() {
    local mode="$1"
    
    # INTEL
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        for gt_dir in /sys/class/drm/card*/gt/gt* /sys/class/drm/card*; do
             if [ -r "$gt_dir/gt_max_freq_mhz" ]; then
                local max=$(cat "$gt_dir/gt_max_freq_mhz")
                local min=$(cat "$gt_dir/gt_min_freq_mhz" 2>/dev/null || echo 100)
                if [ "$mode" == "performance" ]; then
                    write_to_sysfs "$max" "$gt_dir/gt_min_freq_mhz"
                    write_to_sysfs "$max" "$gt_dir/gt_boost_freq_mhz"
                elif [ "$mode" == "powersave" ]; then
                    write_to_sysfs "$min" "$gt_dir/gt_min_freq_mhz"
                    write_to_sysfs "$min" "$gt_dir/gt_max_freq_mhz"
                fi
             fi
        done
    fi

    # AMD
    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        local dpm_level="auto"
        if [ "$mode" == "performance" ]; then dpm_level="high"; fi
        if [ "$mode" == "powersave" ]; then dpm_level="low"; fi
        for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            write_to_sysfs "$dpm_level" "$card"
        done
    fi

    # NVIDIA
    if [ "$NVIDIA_GPU_FOUND" -eq 1 ]; then
        if [ "$mode" == "performance" ]; then
            nvidia-smi -pm 1 >/dev/null
            # Lock clocks if possible (requires knowing your specific GPU max clocks, skipping unsafe locks)
            echo "✓ Nvidia GPU: Persistence Mode Enabled"
        fi
    fi
}


##########################################
# MODE WRAPPERS
##########################################

set_performance() {
    set_cpu_governor "performance"
    set_cpu_epp "performance"
    set_cpu_boost 1
    set_laptop_mode_tweaks "performance"
    set_network_tweaks "performance"
}

set_balanced() {
    set_cpu_governor "schedutil"
    set_cpu_epp "balance_performance"
    set_cpu_boost 1
    set_laptop_mode_tweaks "balanced"
    set_network_tweaks "balanced"
}

set_powersave() {
    set_cpu_governor "powersave"
    set_cpu_epp "power"
    set_cpu_boost 0
    set_laptop_mode_tweaks "powersave"
    set_network_tweaks "powersave"
}


##########################################
# MAIN EXECUTION
##########################################

if [ -z "$1" ]; then
    show_header
    check_for_updates
    echo "Usage: sudo $0 <mode>"
    echo "  1: Performance Mode"
    echo "  2: Balanced Mode"
    echo "  3: Powersave Mode"
    exit 1
fi

MODE=$1
detect_hardware

# Always stop conflicting services before applying our own modes
stop_conflicts

case $MODE in
    1)
        set_performance
        optimize_gpu "performance"
        echo "✅ Performance locked. Battery saving disabled. 🔥"
        send_notification "Project Raco PC" "Performance Mode Active"
        ;;
    2)
        set_balanced
        optimize_gpu "balanced"
        echo "✅ Balanced mode activated. ⚖️"
        send_notification "Project Raco PC" "Balanced Mode Active"
        ;;
    3)
        set_powersave
        optimize_gpu "powersave"
        echo "✅ Powersave mode activated. 🔋"
        send_notification "Project Raco PC" "Powersave Mode Active"
        ;;
    *)
        echo "❌ Error: Invalid mode '$MODE'."
        exit 1
        ;;
esac

echo ""
echo "--------------------------------"
echo "        SYSTEM STATUS"
echo "--------------------------------"
echo "  CPU Vendor: $CPU_VENDOR"
echo "  Laptop Mode: $(sysctl -n vm.laptop_mode) (0=Force AC, >0=Battery Mode)"
echo "  ASPM Policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo N/A)"
echo "  Queue Disc: $(sysctl -n net.core.default_qdisc)"

exit 0