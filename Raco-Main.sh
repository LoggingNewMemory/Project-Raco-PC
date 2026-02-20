#!/bin/bash

set -e

SCRIPT_VERSION="1.7"
SCRIPT_URL="https://raw.githubusercontent.com/LoggingNewMemory/Project-Raco-PC/main/Raco-Main.sh"
SCRIPT_PATH=$(readlink -f "$0")

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Error: This script must be run as root."
    exit 1
fi

show_header() {
    echo "========================================================"
    echo "   Project Raco PC - Linux Power Optimizer"
    echo "   Version: $SCRIPT_VERSION"
    echo "========================================================"
}

check_for_updates() {
    read -p "Check for script updates? [y/n]: " -n 1 -r
    echo "" 

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi

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
        rm -f "$temp_file"
    else
        diff --color=always -u "$SCRIPT_PATH" "$temp_file" || true
        read -p "Apply these updates? [y/n]: " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if mv "$temp_file" "$SCRIPT_PATH"; then
                chmod +x "$SCRIPT_PATH"
                chown "${current_user}:${current_group}" "$SCRIPT_PATH"
                exit 0
            else
                echo "❌ Error: Update failed."
                rm -f "$temp_file"
                exit 1
            fi
        else
            rm -f "$temp_file"
        fi
    fi
}

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

sync_ppd() {
    local target_mode="$1"
    
    if command -v powerprofilesctl &>/dev/null && systemctl is-active --quiet power-profiles-daemon; then
        
        local ppd_profile=""
        case "$target_mode" in
            "performance") ppd_profile="performance" ;;
            "balanced")    ppd_profile="balanced" ;;
            "powersave")   ppd_profile="power-saver" ;;
        esac

        if [ -n "$ppd_profile" ]; then
            if ! powerprofilesctl set "$ppd_profile" 2>/dev/null; then
                 systemctl stop power-profiles-daemon
            fi
        fi
    fi
}

stop_conflicts() {
    for service in tlp auto-cpufreq thermald; do
        if systemctl is-active --quiet "$service"; then
            systemctl stop "$service" 2>/dev/null || true
        fi
    done

    if systemctl is-active --quiet power-profiles-daemon; then
        systemctl restart power-profiles-daemon
        sleep 1
    fi
}

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

set_sata_alpm() {
    local policy="$1"
    for host in /sys/class/scsi_host/host*/link_power_management_policy; do
        write_to_sysfs "$policy" "$host"
    done
}

set_audio_powersave() {
    local timeout="$1"
    write_to_sysfs "$timeout" "/sys/module/snd_hda_intel/parameters/power_save"
    if [ "$timeout" -eq 0 ]; then
        write_to_sysfs "N" "/sys/module/snd_hda_intel/parameters/power_save_controller"
    else
        write_to_sysfs "Y" "/sys/module/snd_hda_intel/parameters/power_save_controller"
    fi
}

set_usb_autosuspend() {
    local state="$1"
    for dev in /sys/bus/usb/devices/*/power/control; do
        write_to_sysfs "$state" "$dev"
    done
}

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
    local state="$1" 
    if [ "$CPU_VENDOR" == "INTEL" ]; then
        local val=$((1-state))
        write_to_sysfs "$val" "/sys/devices/system/cpu/intel_pstate/no_turbo"
    fi
    if [ -w /sys/devices/system/cpu/cpufreq/boost ]; then
        write_to_sysfs "$state" "/sys/devices/system/cpu/cpufreq/boost"
    fi
}

lock_cpu_frequencies() {
    local target="$1"
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        if [ -d "$path" ]; then
            chmod 644 "$path/scaling_max_freq" "$path/scaling_min_freq" 2>/dev/null
            local max_freq=$(cat "$path/cpuinfo_max_freq")
            local min_freq=$(cat "$path/cpuinfo_min_freq")
            if [ "$target" == "max" ]; then
                write_to_sysfs "$max_freq" "$path/scaling_max_freq"
                write_to_sysfs "$max_freq" "$path/scaling_min_freq"
            elif [ "$target" == "min" ]; then
                write_to_sysfs "$min_freq" "$path/scaling_min_freq"
                write_to_sysfs "$min_freq" "$path/scaling_max_freq"
            fi
            chmod 444 "$path/scaling_max_freq" "$path/scaling_min_freq" 2>/dev/null
        fi
    done
}

unlock_cpu_frequencies() {
    for path in /sys/devices/system/cpu/cpufreq/policy*; do
        if [ -d "$path" ]; then
            chmod 644 "$path/scaling_max_freq" "$path/scaling_min_freq" 2>/dev/null
            local max_freq=$(cat "$path/cpuinfo_max_freq")
            local min_freq=$(cat "$path/cpuinfo_min_freq")
            write_to_sysfs "$max_freq" "$path/scaling_max_freq"
            write_to_sysfs "$min_freq" "$path/scaling_min_freq"
        fi
    done
}

apply_raco_common_tweaks() {
    for dir in /sys/block/*; do
        write_to_sysfs "0" "$dir/queue/iostats"
        write_to_sysfs "0" "$dir/queue/add_random"
        write_to_sysfs "32" "$dir/queue/read_ahead_kb"
        write_to_sysfs "32" "$dir/queue/nr_requests"
    done

    apply_sysctl "kernel.perf_cpu_time_max_percent" "3"
    apply_sysctl "kernel.sched_schedstats" "0"
    apply_sysctl "kernel.sched_autogroup_enabled" "0"
    apply_sysctl "kernel.sched_child_runs_first" "1"
    apply_sysctl "kernel.sched_nr_migrate" "32"
    apply_sysctl "kernel.sched_migration_cost_ns" "50000"
    apply_sysctl "kernel.split_lock_mitigate" "0"
    apply_sysctl "kernel.watchdog" "0"
    apply_sysctl "vm.page-cluster" "0"
    apply_sysctl "vm.stat_interval" "15"
    apply_sysctl "vm.compaction_proactiveness" "0"
    
    if [ -d "/sys/kernel/debug/sched" ]; then
        echo "NEXT_BUDDY" > /sys/kernel/debug/sched_features 2>/dev/null || true
        echo "NO_TTWU_QUEUE" > /sys/kernel/debug/sched_features 2>/dev/null || true
    fi
}

set_laptop_mode_tweaks() {
    local mode="$1"

    if [ "$mode" == "performance" ]; then
        apply_sysctl "vm.laptop_mode" "0" 
        write_to_sysfs "performance" "/sys/module/pcie_aspm/parameters/policy"
        
        for iface in $(ls /sys/class/net | grep -E 'wlan|wlp|wlx'); do
            if command -v iw &>/dev/null; then
                iw dev "$iface" set power_save off 2>/dev/null || true
            fi
        done

        apply_sysctl "vm.swappiness" "10"
        apply_sysctl "vm.vfs_cache_pressure" "50"
        apply_sysctl "vm.dirty_ratio" "40"
        apply_sysctl "vm.dirty_background_ratio" "10"
        apply_sysctl "vm.max_map_count" "2147483642"
        apply_sysctl "kernel.nmi_watchdog" "0"
        
        apply_raco_common_tweaks

    elif [ "$mode" == "balanced" ]; then
        apply_sysctl "vm.laptop_mode" "2" 
        write_to_sysfs "default" "/sys/module/pcie_aspm/parameters/policy"
        
        apply_sysctl "vm.swappiness" "60"
        apply_sysctl "vm.vfs_cache_pressure" "100"
        apply_sysctl "kernel.nmi_watchdog" "1"
        apply_sysctl "kernel.split_lock_mitigate" "1"
        apply_sysctl "kernel.watchdog" "1"

    else
        apply_sysctl "vm.laptop_mode" "5"
        write_to_sysfs "powersave" "/sys/module/pcie_aspm/parameters/policy"
        
        for iface in $(ls /sys/class/net | grep -E 'wlan|wlp|wlx'); do
            if command -v iw &>/dev/null; then
                iw dev "$iface" set power_save on 2>/dev/null || true
            fi
        done
        
        apply_sysctl "vm.swappiness" "60"
        apply_sysctl "vm.dirty_writeback_centisecs" "1500"
        apply_sysctl "vm.vfs_cache_pressure" "100"
        apply_sysctl "kernel.nmi_watchdog" "0"
        apply_sysctl "kernel.watchdog" "0"
    fi
}

set_network_tweaks() {
    local mode="$1"
    modprobe sch_cake 2>/dev/null || true

    if [ "$mode" == "performance" ]; then
        apply_sysctl "net.core.default_qdisc" "cake"
        apply_sysctl "net.ipv4.tcp_congestion_control" "bbr"
        apply_sysctl "net.ipv4.tcp_fastopen" "3"
        apply_sysctl "net.ipv4.tcp_window_scaling" "1"
        apply_sysctl "net.ipv4.tcp_low_latency" "1"
        apply_sysctl "net.ipv4.tcp_sack" "1"
        apply_sysctl "net.ipv4.tcp_rmem" "4096 87380 16777216"
        apply_sysctl "net.ipv4.tcp_wmem" "4096 65536 16777216"
        apply_sysctl "net.core.rmem_max" "16777216"
        apply_sysctl "net.core.wmem_max" "16777216"

    elif [ "$mode" == "balanced" ]; then
        apply_sysctl "net.core.default_qdisc" "cake"
        apply_sysctl "net.ipv4.tcp_congestion_control" "bbr"
        apply_sysctl "net.ipv4.tcp_fastopen" "3"
        apply_sysctl "net.ipv4.tcp_window_scaling" "1"
        apply_sysctl "net.ipv4.tcp_low_latency" "1"
        apply_sysctl "net.ipv4.tcp_sack" "1"
    else
        apply_sysctl "net.ipv4.tcp_congestion_control" "cubic"
        apply_sysctl "net.ipv4.tcp_low_latency" "0"
    fi
}

optimize_gpu() {
    local mode="$1"
    
    if [ "$INTEL_GPU_FOUND" -eq 1 ]; then
        for gt_dir in /sys/class/drm/card*/gt/gt* /sys/class/drm/card*; do
             if [ -r "$gt_dir/gt_max_freq_mhz" ]; then
                local max=$(cat "$gt_dir/gt_max_freq_mhz")
                local min=$(cat "$gt_dir/gt_min_freq_mhz" 2>/dev/null || echo 100)
                local profile_path="/sys/class/drm/card*/device/power_profile"
                
                if [ "$mode" == "performance" ]; then
                    write_to_sysfs "$max" "$gt_dir/gt_min_freq_mhz"
                    write_to_sysfs "$max" "$gt_dir/gt_boost_freq_mhz"
                    write_to_sysfs "high" "$profile_path"
                elif [ "$mode" == "balanced" ]; then
                    write_to_sysfs "$min" "$gt_dir/gt_min_freq_mhz"
                    write_to_sysfs "$max" "$gt_dir/gt_boost_freq_mhz"
                    write_to_sysfs "balanced" "$profile_path"
                elif [ "$mode" == "powersave" ]; then
                    write_to_sysfs "$min" "$gt_dir/gt_min_freq_mhz"
                    write_to_sysfs "$min" "$gt_dir/gt_max_freq_mhz"
                    write_to_sysfs "low" "$profile_path"
                fi
             fi
        done
    fi

    if [ "$AMD_GPU_FOUND" -eq 1 ]; then
        local dpm_level="auto"
        local dpm_state="balanced"
        local pp_mode="0"

        if [ "$mode" == "performance" ]; then 
            dpm_level="high"
            dpm_state="performance"
            pp_mode="1"
        elif [ "$mode" == "powersave" ]; then 
            dpm_level="low"
            dpm_state="battery"
            pp_mode="2"
        fi

        for card in /sys/class/drm/card*/device/power_dpm_force_performance_level; do
            write_to_sysfs "$dpm_level" "$card"
        done
        for card in /sys/class/drm/card*/device/power_dpm_state; do
            write_to_sysfs "$dpm_state" "$card"
        done
        for card in /sys/class/drm/card*/device/pp_power_profile_mode; do
            write_to_sysfs "$pp_mode" "$card"
        done
    fi

    if [ "$NVIDIA_GPU_FOUND" -eq 1 ]; then
        nvidia-smi -pm 1 >/dev/null 2>&1
        if [ "$mode" == "performance" ]; then
            nvidia-smi -rgc >/dev/null 2>&1
            nvidia-smi -rmc >/dev/null 2>&1
        elif [ "$mode" == "balanced" ]; then
            nvidia-smi -rgc >/dev/null 2>&1
            nvidia-smi -rmc >/dev/null 2>&1
        elif [ "$mode" == "powersave" ]; then
            nvidia-smi -lgc 300,900 >/dev/null 2>&1
        fi
    fi
}

set_performance() {
    sync_ppd "performance"
    set_cpu_governor "performance"
    set_cpu_epp "performance"
    set_cpu_boost 1
    lock_cpu_frequencies "max"
    set_laptop_mode_tweaks "performance"
    set_network_tweaks "performance"
    set_sata_alpm "max_performance"
    set_audio_powersave 0
    set_usb_autosuspend "on" 
}

set_balanced() {
    sync_ppd "balanced"
    set_cpu_governor "schedutil"
    set_cpu_epp "balance_performance"
    set_cpu_boost 1
    unlock_cpu_frequencies
    set_laptop_mode_tweaks "balanced"
    set_network_tweaks "balanced"
    set_sata_alpm "med_power_with_dipm"
    set_audio_powersave 10 
    set_usb_autosuspend "auto"
}

set_powersave() {
    sync_ppd "powersave"
    set_cpu_governor "powersave"
    set_cpu_epp "power"
    set_cpu_boost 0
    lock_cpu_frequencies "min"
    set_laptop_mode_tweaks "powersave"
    set_network_tweaks "powersave"
    set_sata_alpm "min_power"
    set_audio_powersave 1 
    set_usb_autosuspend "auto"
}

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

echo "  CPU Vendor: $CPU_VENDOR"
echo "  Laptop Mode: $(sysctl -n vm.laptop_mode)"
echo "  ASPM Policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null || echo N/A)"
if systemctl is-active --quiet power-profiles-daemon; then
    echo "  PPD Status: Active ($(powerprofilesctl get))"
else
    echo "  PPD Status: Stopped"
fi

exit 0