#!/bin/sh
# QoSmate Autorate Daemon
# Dynamically adjusts bandwidth based on latency measurements
# Managed by procd - runs in foreground
#
# Usage: /etc/qosmate-autorate.sh run
#        /etc/qosmate-autorate.sh status

# shellcheck disable=SC3043,SC2034,SC1091,SC1090

AUTORATE_STATE_FILE="/tmp/qosmate-autorate-state"

# Source OpenWrt functions for config_get
. /lib/functions.sh

# Shutdown flag for clean termination
_shutdown=0

# Signal handler - exit immediately (EXIT trap will do cleanup)
_handle_signal() {
    exit 0
}

# Global variables for return values
_rate_result=0
_latency_result=0
_bytes_result=0

# Load configuration using config_get
load_autorate_config() {
    config_load qosmate || return 1
    
    # Settings section
    config_get WAN settings WAN
    config_get UPRATE settings UPRATE
    config_get DOWNRATE settings DOWNRATE
    config_get ROOT_QDISC settings ROOT_QDISC
    
    # HFSC section
    config_get GAMEUP hfsc GAMEUP
    config_get GAMEDOWN hfsc GAMEDOWN
    
    # Autorate section
    config_get AUTORATE_INTERVAL autorate interval
    config_get AUTORATE_MIN_UL autorate min_ul_rate
    config_get AUTORATE_BASE_UL autorate base_ul_rate
    config_get AUTORATE_MAX_UL autorate max_ul_rate
    config_get AUTORATE_MIN_DL autorate min_dl_rate
    config_get AUTORATE_BASE_DL autorate base_dl_rate
    config_get AUTORATE_MAX_DL autorate max_dl_rate
    config_get AUTORATE_LAT_INC_THR autorate latency_increase_threshold
    config_get AUTORATE_LAT_DEC_THR autorate latency_decrease_threshold
    config_get AUTORATE_REFLECTORS autorate reflectors
    config_get AUTORATE_REFRACT_INC autorate refractory_increase
    config_get AUTORATE_REFRACT_DEC autorate refractory_decrease
    config_get AUTORATE_ADJ_UP autorate adjust_up_factor
    config_get AUTORATE_ADJ_DOWN autorate adjust_down_factor
    config_get AUTORATE_LOG_CHANGES autorate log_changes
    
    # Apply defaults using parameter expansion
    : "${AUTORATE_INTERVAL:=500}"
    : "${AUTORATE_LOG_CHANGES:=0}"
    : "${AUTORATE_MIN_UL:=$((UPRATE * 25 / 100))}"
    : "${AUTORATE_BASE_UL:=$UPRATE}"
    : "${AUTORATE_MAX_UL:=$((UPRATE * 105 / 100))}"
    : "${AUTORATE_MIN_DL:=$((DOWNRATE * 25 / 100))}"
    : "${AUTORATE_BASE_DL:=$DOWNRATE}"
    : "${AUTORATE_MAX_DL:=$((DOWNRATE * 105 / 100))}"
    : "${AUTORATE_LAT_INC_THR:=5}"
    : "${AUTORATE_LAT_DEC_THR:=10}"
    : "${AUTORATE_REFLECTORS:=1.1.1.1 8.8.8.8 9.9.9.9}"
    : "${AUTORATE_REFRACT_INC:=3}"
    : "${AUTORATE_REFRACT_DEC:=1}"
    : "${AUTORATE_ADJ_UP:=102}"
    : "${AUTORATE_ADJ_DOWN:=85}"
    : "${GAMEUP:=$((UPRATE * 15 / 100 + 400))}"
    : "${GAMEDOWN:=$((DOWNRATE * 15 / 100 + 400))}"
}

log_autorate() { logger -t qosmate-autorate "$1"; }

# Read interface bytes - result in _bytes_result
read_bytes() {
    local path
    case "$2" in
        rx) path="/sys/class/net/$1/statistics/rx_bytes" ;;
        tx) path="/sys/class/net/$1/statistics/tx_bytes" ;;
        *) _bytes_result=0; return 1 ;;
    esac
    if [ -f "$path" ]; then
        read -r _bytes_result < "$path"
    else
        _bytes_result=0
    fi
}

# Measure latency - result in _latency_result
measure_latency() {
    local reflector ping_out rtt total_rtt=0 count=0
    for reflector in $AUTORATE_REFLECTORS; do
        ping_out=$(ping -c 1 -W 1 "$reflector" 2>/dev/null) || continue
        case "$ping_out" in
            *time=*)
                rtt="${ping_out##*time=}"
                rtt="${rtt%%[!0-9]*}"
                if [ -n "$rtt" ] && [ "$rtt" -gt 0 ] 2>/dev/null; then
                    total_rtt=$((total_rtt + rtt))
                    count=$((count + 1))
                fi
                ;;
        esac
    done
    [ "$count" -gt 0 ] && _latency_result=$((total_rtt / count)) || _latency_result=9999
}

# Calculate rate in kbps - result in _rate_result
calculate_rate_kbps() {
    local delta_bytes=$(($1 - $2))
    [ "$delta_bytes" -lt 0 ] && delta_bytes=0
    _rate_result=$((delta_bytes * 8 / $3))
}

# Calculate new rate - result in _rate_result
calculate_new_rate() {
    local current_rate="$1" achieved_rate="$2" latency="$3" baseline="$4"
    local min_rate="$5" base_rate="$6" max_rate="$7"
    local last_change="$8" current_time="$9"
    local latency_delta load_percent time_since_change
    
    _rate_result=$current_rate
    
    latency_delta=$((latency - baseline))
    [ "$latency_delta" -lt 0 ] && latency_delta=0
    
    [ "$current_rate" -gt 0 ] && load_percent=$((achieved_rate * 100 / current_rate)) || load_percent=0
    time_since_change=$((current_time - last_change))
    
    if [ "$latency_delta" -gt "$AUTORATE_LAT_DEC_THR" ]; then
        [ "$time_since_change" -ge "$AUTORATE_REFRACT_DEC" ] && _rate_result=$((current_rate * AUTORATE_ADJ_DOWN / 100))
    elif [ "$load_percent" -ge 75 ] && [ "$latency_delta" -lt "$AUTORATE_LAT_INC_THR" ]; then
        [ "$time_since_change" -ge "$AUTORATE_REFRACT_INC" ] && _rate_result=$((current_rate * AUTORATE_ADJ_UP / 100))
    elif [ "$load_percent" -lt 50 ]; then
        [ "$current_rate" -gt "$base_rate" ] && _rate_result=$((current_rate * 98 / 100))
        [ "$current_rate" -lt "$base_rate" ] && _rate_result=$((current_rate * 101 / 100))
    fi
    
    # Inline clamp
    [ "$_rate_result" -lt "$min_rate" ] && _rate_result=$min_rate
    [ "$_rate_result" -gt "$max_rate" ] && _rate_result=$max_rate
}

# Get current time in seconds from /proc/uptime
get_uptime_seconds() {
    local uptime_str
    read -r uptime_str _ < /proc/uptime
    # Remove decimal part using parameter expansion
    _time_result="${uptime_str%%.*}"
}

# Main daemon loop - runs in foreground (procd expects this)
run_daemon() {
    load_autorate_config || { log_autorate "ERROR: Failed to load config"; exit 1; }
    
    # Load TC update functions
    local AUTORATE_TC_SCRIPT="/etc/qosmate-autorate-tc.sh"
    if [ -f "$AUTORATE_TC_SCRIPT" ]; then
        . "$AUTORATE_TC_SCRIPT"
    else
        log_autorate "ERROR: $AUTORATE_TC_SCRIPT not found"
        exit 1
    fi
    
    [ -z "$WAN" ] && { log_autorate "ERROR: WAN not configured"; exit 1; }
    
    local wan_iface="$WAN" lan_iface="ifb-$WAN"
    local ul_rate="$AUTORATE_BASE_UL" dl_rate="$AUTORATE_BASE_DL"
    local prev_ul_bytes prev_dl_bytes curr_ul_bytes curr_dl_bytes
    local achieved_ul achieved_dl baseline_latency=0 baseline_samples=0
    local last_ul_change=0 last_dl_change=0 current_time loop_count=0
    local new_ul_rate new_dl_rate ul_change_pct dl_change_pct
    local _time_result=0
    
    # Convert ms to seconds for sleep (only once at start)
    local sleep_sec
    sleep_sec=$(awk "BEGIN{printf \"%.3f\", $AUTORATE_INTERVAL/1000}")
    
    # Initialize byte counters
    read_bytes "$wan_iface" tx; prev_ul_bytes=$_bytes_result
    read_bytes "$lan_iface" tx; prev_dl_bytes=$_bytes_result
    
    log_autorate "Daemon started (WAN=$wan_iface, interval=${AUTORATE_INTERVAL}ms)"
    log_autorate "UL: min=$AUTORATE_MIN_UL base=$AUTORATE_BASE_UL max=$AUTORATE_MAX_UL"
    log_autorate "DL: min=$AUTORATE_MIN_DL base=$AUTORATE_BASE_DL max=$AUTORATE_MAX_DL"
    
    # Signal handling: TERM/INT set shutdown flag, EXIT does cleanup
    trap '_handle_signal' TERM INT
    trap 'rm -f "$AUTORATE_STATE_FILE"; log_autorate "Daemon stopped"' EXIT
    
    while [ "$_shutdown" -eq 0 ]; do
        # Interruptible sleep: run in background and wait
        sleep "$sleep_sec" &
        wait $! 2>/dev/null || true
        
        # Check if we should exit after sleep
        [ "$_shutdown" -ne 0 ] && break
        
        # Check if interfaces still exist (avoid race condition during restart)
        [ ! -d "/sys/class/net/$wan_iface" ] && break
        [ ! -d "/sys/class/net/$lan_iface" ] && break
        
        # Get current time from /proc/uptime
        get_uptime_seconds
        current_time=$_time_result
        loop_count=$((loop_count + 1))
        
        # Read current byte counters
        read_bytes "$wan_iface" tx; curr_ul_bytes=$_bytes_result
        read_bytes "$lan_iface" tx; curr_dl_bytes=$_bytes_result
        
        # Calculate achieved rates
        calculate_rate_kbps "$curr_ul_bytes" "$prev_ul_bytes" "$AUTORATE_INTERVAL"
        achieved_ul=$_rate_result
        calculate_rate_kbps "$curr_dl_bytes" "$prev_dl_bytes" "$AUTORATE_INTERVAL"
        achieved_dl=$_rate_result
        
        prev_ul_bytes=$curr_ul_bytes
        prev_dl_bytes=$curr_dl_bytes
        
        # Measure latency every 2nd loop
        if [ $((loop_count % 2)) -eq 0 ]; then
            measure_latency
            if [ "$baseline_samples" -lt 10 ]; then
                baseline_latency=$(( (baseline_latency * baseline_samples + _latency_result) / (baseline_samples + 1) ))
                baseline_samples=$((baseline_samples + 1))
            else
                baseline_latency=$(( (baseline_latency * 9 + _latency_result) / 10 ))
            fi
        fi
        
        [ "$baseline_samples" -lt 5 ] && continue
        
        # Calculate new rates
        calculate_new_rate "$ul_rate" "$achieved_ul" "$_latency_result" "$baseline_latency" \
            "$AUTORATE_MIN_UL" "$AUTORATE_BASE_UL" "$AUTORATE_MAX_UL" "$last_ul_change" "$current_time"
        new_ul_rate=$_rate_result
        
        calculate_new_rate "$dl_rate" "$achieved_dl" "$_latency_result" "$baseline_latency" \
            "$AUTORATE_MIN_DL" "$AUTORATE_BASE_DL" "$AUTORATE_MAX_DL" "$last_dl_change" "$current_time"
        new_dl_rate=$_rate_result
        
        # Apply upload rate change
        if [ "$new_ul_rate" != "$ul_rate" ]; then
            ul_change_pct=$(( (new_ul_rate - ul_rate) * 100 / ul_rate ))
            [ "$ul_change_pct" -lt 0 ] && ul_change_pct=$((-ul_change_pct))
            if [ "$AUTORATE_LOG_CHANGES" = "1" ] || [ "$ul_change_pct" -ge 5 ]; then
                log_autorate "UL: $ul_rate -> $new_ul_rate kbps (${ul_change_pct}%, latency=$_latency_result)"
            fi
            autorate_update_bandwidth "$new_ul_rate" "$wan_iface" "egress"
            ul_rate=$new_ul_rate
            last_ul_change=$current_time
        fi
        
        # Apply download rate change
        if [ "$new_dl_rate" != "$dl_rate" ]; then
            dl_change_pct=$(( (new_dl_rate - dl_rate) * 100 / dl_rate ))
            [ "$dl_change_pct" -lt 0 ] && dl_change_pct=$((-dl_change_pct))
            if [ "$AUTORATE_LOG_CHANGES" = "1" ] || [ "$dl_change_pct" -ge 5 ]; then
                log_autorate "DL: $dl_rate -> $new_dl_rate kbps (${dl_change_pct}%, latency=$_latency_result)"
            fi
            autorate_update_bandwidth "$new_dl_rate" "$lan_iface" "ingress"
            dl_rate=$new_dl_rate
            last_dl_change=$current_time
        fi
        
        # Write state file
        printf 'ul_rate=%s\ndl_rate=%s\nachieved_ul=%s\nachieved_dl=%s\nlatency=%s\nbaseline=%s\n' \
            "$ul_rate" "$dl_rate" "$achieved_ul" "$achieved_dl" "$_latency_result" "$baseline_latency" \
            > "$AUTORATE_STATE_FILE"
    done
}

# Show current status
show_status() {
    if [ -f "$AUTORATE_STATE_FILE" ]; then
        echo "Autorate state:"
        cat "$AUTORATE_STATE_FILE"
        return 0
    fi
    echo "Autorate not running or no state available"
    return 1
}

case "$1" in
    run) run_daemon ;;
    status) show_status ;;
    *) echo "Usage: $0 {run|status}"; exit 1 ;;
esac
