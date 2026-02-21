#!/bin/sh
# QoSmate Autorate Daemon
# Dynamically adjusts bandwidth based on latency measurements
# Managed by procd - runs in foreground
#
# Usage: /etc/qosmate-autorate.sh run
#        /etc/qosmate-autorate.sh status

# shellcheck disable=SC3043,SC2034,SC1091,SC1090

AUTORATE_STATE_FILE="/tmp/qosmate-autorate-state"
AUTORATE_HISTORY_FILE="/tmp/qosmate-autorate-history"
AUTORATE_FLASH_HISTORY="/etc/qosmate.d/autorate_hourly.csv"
AUTORATE_MAX_FLASH=4320     # Flash: 30 days at ~6 entries/h (10 min buckets)

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
    local _interval_raw
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

    # Validate interval to prevent divide-by-zero in rate calculations
    _interval_raw="$AUTORATE_INTERVAL"
    case "$AUTORATE_INTERVAL" in
        ''|*[!0-9]*)
            AUTORATE_INTERVAL=500
            logger -t qosmate-autorate "WARNING: Invalid autorate interval '$_interval_raw', using 500ms"
            ;;
        *)
            if [ "$AUTORATE_INTERVAL" -le 0 ]; then
                AUTORATE_INTERVAL=500
                logger -t qosmate-autorate "WARNING: Non-positive autorate interval '$_interval_raw', using 500ms"
            fi
            ;;
    esac

    # Convert thresholds from ms (user config) to tenths of ms (internal)
    AUTORATE_LAT_INC_THR=$((AUTORATE_LAT_INC_THR * 10))
    AUTORATE_LAT_DEC_THR=$((AUTORATE_LAT_DEC_THR * 10))
}

log_autorate() { logger -t qosmate-autorate "$1"; }

# Consolidate RAM history into 10-min bucket summaries and append to flash
# Buckets are based on timestamp (int(ts/600)) so gaps don't corrupt data
# Flash format: ts,avg_ul,avg_dl,avg_a_ul,avg_a_dl,avg_lat,max_lat,avg_bl,avg_ulp,avg_dlp
consolidate_to_flash() {
    [ ! -f "$AUTORATE_HISTORY_FILE" ] || [ ! -s "$AUTORATE_HISTORY_FILE" ] && return
    awk -F',' '{
        b = int($1 / 600)
        if(!(b in n)) keys[++kc] = b
        n[b]++; ul[b]+=$2; dl[b]+=$3; aul[b]+=$4; adl[b]+=$5
        lat[b]+=$6; bl[b]+=$7; ulp[b]+=$8; dlp[b]+=$9
        if($6+0 > mlat[b]+0) mlat[b]=$6; ts[b]=$1
    } END {
        for(i=1; i<=kc; i++) { b=keys[i]
            printf "%s,%d,%d,%d,%d,%d,%d,%d,%d,%d\n",
                ts[b], ul[b]/n[b], dl[b]/n[b], aul[b]/n[b], adl[b]/n[b],
                lat[b]/n[b], mlat[b], bl[b]/n[b], ulp[b]/n[b], dlp[b]/n[b]
        }
    }' "$AUTORATE_HISTORY_FILE" >> "$AUTORATE_FLASH_HISTORY"
    # Truncate flash to max entries
    local lc
    lc=$(wc -l < "$AUTORATE_FLASH_HISTORY" 2>/dev/null) || lc=0
    if [ "$lc" -gt "$AUTORATE_MAX_FLASH" ]; then
        tail -n "$AUTORATE_MAX_FLASH" "$AUTORATE_FLASH_HISTORY" > "${AUTORATE_FLASH_HISTORY}.tmp" && \
            mv "${AUTORATE_FLASH_HISTORY}.tmp" "$AUTORATE_FLASH_HISTORY"
    fi
}

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

# Measure latency in tenths of ms - result in _latency_result
# e.g. "time=4.7 ms" -> 47 (tenths of ms)
measure_latency() {
    local reflector ping_out rtt rtt_int rtt_frac total_rtt=0 count=0
    for reflector in $AUTORATE_REFLECTORS; do
        ping_out=$(ping -c 1 -W 1 "$reflector" 2>/dev/null) || continue
        case "$ping_out" in
            *time=*)
                rtt="${ping_out##*time=}"
                # Parse with tenths of ms precision
                case "$rtt" in
                    *.*)
                        rtt_int="${rtt%%.*}"
                        rtt_frac="${rtt#*.}"
                        rtt_frac="${rtt_frac%%[!0-9]*}"
                        rtt_frac="${rtt_frac%${rtt_frac#?}}"  # first decimal digit only
                        [ -z "$rtt_frac" ] && rtt_frac=0
                        rtt=$((rtt_int * 10 + rtt_frac))
                        ;;
                    *)
                        rtt="${rtt%%[!0-9]*}"
                        rtt=$((rtt * 10))
                        ;;
                esac
                if [ -n "$rtt" ] && [ "$rtt" -gt 0 ] 2>/dev/null; then
                    total_rtt=$((total_rtt + rtt))
                    count=$((count + 1))
                fi
                ;;
        esac
    done
    [ "$count" -gt 0 ] && _latency_result=$((total_rtt / count)) || _latency_result=99990
}

# Calculate rate in kbps - result in _rate_result
# Formula: (bytes * 8) / interval_ms = bits/ms = kbit/s
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

# Get current time from /proc/uptime (single read, two results)
# _time_result: seconds (integer), _time_cs_result: centiseconds (integer)
get_uptime() {
    local uptime_str _frac
    read -r uptime_str _ < /proc/uptime
    _time_result="${uptime_str%%.*}"
    _frac="${uptime_str#*.}"
    _frac="${_frac%"${_frac#??}"}"
    [ ${#_frac} -eq 1 ] && _frac="${_frac}0"
    _time_cs_result=$((_time_result * 100 + ${_frac#0}))
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

    # Read active cake qdisc type (written by qosmate.sh at setup time)
    CAKE_TYPE=$(cat /tmp/qosmate/cake_type 2>/dev/null)
    : "${CAKE_TYPE:=cake}"
    
    local wan_iface="$WAN" lan_iface="ifb-$WAN"
    local ul_rate="$AUTORATE_BASE_UL" dl_rate="$AUTORATE_BASE_DL"
    local prev_ul_bytes prev_dl_bytes curr_ul_bytes curr_dl_bytes
    local achieved_ul=0 achieved_dl=0 baseline_latency=0 baseline_samples=0
    local last_ul_change=0 last_dl_change=0 current_time loop_count=0
    local _time_cs_result=0 prev_time_cs=0 delta_ms
    local new_ul_rate new_dl_rate ul_change_pct dl_change_pct
    local _time_result=0
    local state_restore_ttl=300 state_age=-1 startup_uptime=0
    local restored_ul_rate="" restored_dl_rate=""
    # Reflector failure tracking
    local reflector_failures=0 last_good_latency=0
    # Direction heuristic
    local ul_load_pct=0 dl_load_pct=0
    # Time-based history tracking (wall-clock, independent of loop speed)
    local last_history_write=0
    local last_truncate=0
    local last_consolidate=0
    
    # Convert ms to seconds for sleep (only once at start)
    local sleep_sec
    sleep_sec=$(awk "BEGIN{printf \"%.3f\", $AUTORATE_INTERVAL/1000}")
    
    # Capture startup uptime once for state age calculation
    get_uptime
    startup_uptime=$_time_result

    # Try to restore rates from recent state snapshot (survives short restarts)
    if [ -f "$AUTORATE_STATE_FILE" ]; then
        local _prev_ul _prev_dl _prev_state_uptime _key _val
        while IFS='=' read -r _key _val; do
            case "$_key" in
                ul_rate) _prev_ul="$_val" ;;
                dl_rate) _prev_dl="$_val" ;;
                state_uptime) _prev_state_uptime="$_val" ;;
            esac
        done < "$AUTORATE_STATE_FILE"

        case "$_prev_state_uptime" in
            ''|*[!0-9]*) state_age=-1 ;;
            *) state_age=$((startup_uptime - _prev_state_uptime)) ;;
        esac

        if [ "$state_age" -ge 0 ] && [ "$state_age" -le "$state_restore_ttl" ]; then
            if [ -n "$_prev_ul" ] && [ "$_prev_ul" -gt 0 ] 2>/dev/null && \
               [ "$_prev_ul" -ge "$AUTORATE_MIN_UL" ] && [ "$_prev_ul" -le "$AUTORATE_MAX_UL" ]; then
                restored_ul_rate=$_prev_ul
            fi
            if [ -n "$_prev_dl" ] && [ "$_prev_dl" -gt 0 ] 2>/dev/null && \
               [ "$_prev_dl" -ge "$AUTORATE_MIN_DL" ] && [ "$_prev_dl" -le "$AUTORATE_MAX_DL" ]; then
                restored_dl_rate=$_prev_dl
            fi
        elif [ "$state_age" -gt "$state_restore_ttl" ] 2>/dev/null; then
            log_autorate "State snapshot too old (${state_age}s), starting from base rates"
        else
            log_autorate "State snapshot has no valid timestamp, starting from base rates"
        fi
    fi

    # Keep live qdisc rates aligned with restored daemon state after restart.
    if [ -n "$restored_ul_rate" ] && [ "$restored_ul_rate" != "$ul_rate" ]; then
        if autorate_update_bandwidth "$restored_ul_rate" "$wan_iface" "egress"; then
            ul_rate=$restored_ul_rate
        else
            log_autorate "WARNING: Failed to restore UL rate $restored_ul_rate kbps on $wan_iface, using base $ul_rate kbps"
        fi
    fi
    if [ -n "$restored_dl_rate" ] && [ "$restored_dl_rate" != "$dl_rate" ]; then
        if autorate_update_bandwidth "$restored_dl_rate" "$lan_iface" "ingress"; then
            dl_rate=$restored_dl_rate
        else
            log_autorate "WARNING: Failed to restore DL rate $restored_dl_rate kbps on $lan_iface, using base $dl_rate kbps"
        fi
    fi
    
    # Initialize byte counters and timestamp for first rate calculation
    read_bytes "$wan_iface" tx; prev_ul_bytes=$_bytes_result
    read_bytes "$lan_iface" tx; prev_dl_bytes=$_bytes_result
    get_uptime; prev_time_cs=$_time_cs_result
    
    log_autorate "Daemon started (WAN=$wan_iface, interval=${AUTORATE_INTERVAL}ms)"
    log_autorate "UL: min=$AUTORATE_MIN_UL base=$AUTORATE_BASE_UL max=$AUTORATE_MAX_UL (start=${ul_rate})"
    log_autorate "DL: min=$AUTORATE_MIN_DL base=$AUTORATE_BASE_DL max=$AUTORATE_MAX_DL (start=${dl_rate})"
    
    # Signal handling: TERM/INT exit cleanly, state file kept for recovery
    trap '_handle_signal' TERM INT
    trap '[ "$(uci -q get qosmate.autorate.flash_history)" = "1" ] && consolidate_to_flash; log_autorate "Daemon stopped"' EXIT
    
    while [ "$_shutdown" -eq 0 ]; do
        # Interruptible sleep: run in background and wait
        sleep "$sleep_sec" &
        wait $! 2>/dev/null || true
        
        # Check if we should exit after sleep
        [ "$_shutdown" -ne 0 ] && break
        
        # Check if interfaces still exist (avoid race condition during restart)
        [ ! -d "/sys/class/net/$wan_iface" ] && break
        [ ! -d "/sys/class/net/$lan_iface" ] && break
        
        # Get current time from /proc/uptime (seconds + centiseconds in one read)
        get_uptime
        current_time=$_time_result
        loop_count=$((loop_count + 1))
        
        # Read current byte counters
        read_bytes "$wan_iface" tx; curr_ul_bytes=$_bytes_result
        read_bytes "$lan_iface" tx; curr_dl_bytes=$_bytes_result
        
        # Calculate achieved rates using real elapsed time
        delta_ms=$(( (_time_cs_result - prev_time_cs) * 10 ))
        [ "$delta_ms" -le 0 ] && delta_ms=$AUTORATE_INTERVAL
        calculate_rate_kbps "$curr_ul_bytes" "$prev_ul_bytes" "$delta_ms"
        achieved_ul=$_rate_result
        calculate_rate_kbps "$curr_dl_bytes" "$prev_dl_bytes" "$delta_ms"
        achieved_dl=$_rate_result
        
        prev_ul_bytes=$curr_ul_bytes
        prev_dl_bytes=$curr_dl_bytes
        prev_time_cs=$_time_cs_result
        
        # Measure latency every 2nd loop
        if [ $((loop_count % 2)) -eq 0 ]; then
            measure_latency
            
            # Reflector unreachability guard: keep last good value on failure
            if [ "$_latency_result" -ge 99990 ]; then
                reflector_failures=$((reflector_failures + 1))
                [ "$((reflector_failures % 5))" -eq 0 ] && \
                    log_autorate "WARNING: All reflectors unreachable ($reflector_failures cycles)"
                [ "$last_good_latency" -gt 0 ] && _latency_result=$last_good_latency
            else
                reflector_failures=0
                last_good_latency=$_latency_result
            fi
            
            # Baseline update with drift protection
            if [ "$_latency_result" -lt 99990 ]; then
                if [ "$baseline_samples" -lt 10 ]; then
                    # Initial sampling - always accept
                    baseline_latency=$(( (baseline_latency * baseline_samples + _latency_result) / (baseline_samples + 1) ))
                    baseline_samples=$((baseline_samples + 1))
                elif [ "$achieved_ul" -lt "$((ul_rate * 50 / 100))" ] && \
                     [ "$achieved_dl" -lt "$((dl_rate * 50 / 100))" ]; then
                    # Only update baseline when load is low (idle)
                    # Baseline can only decrease, never increase
                    local new_baseline=$(( (baseline_latency * 9 + _latency_result) / 10 ))
                    [ "$new_baseline" -lt "$baseline_latency" ] && baseline_latency=$new_baseline
                fi
            fi
        fi
        
        [ "$baseline_samples" -lt 5 ] && continue
        
        # Direction load percentages for heuristic
        [ "$ul_rate" -gt 0 ] && ul_load_pct=$((achieved_ul * 100 / ul_rate)) || ul_load_pct=0
        [ "$dl_rate" -gt 0 ] && dl_load_pct=$((achieved_dl * 100 / dl_rate)) || dl_load_pct=0
        
        # Calculate new rates
        calculate_new_rate "$ul_rate" "$achieved_ul" "$_latency_result" "$baseline_latency" \
            "$AUTORATE_MIN_UL" "$AUTORATE_BASE_UL" "$AUTORATE_MAX_UL" "$last_ul_change" "$current_time"
        new_ul_rate=$_rate_result
        
        calculate_new_rate "$dl_rate" "$achieved_dl" "$_latency_result" "$baseline_latency" \
            "$AUTORATE_MIN_DL" "$AUTORATE_BASE_DL" "$AUTORATE_MAX_DL" "$last_dl_change" "$current_time"
        new_dl_rate=$_rate_result
        
        # Direction heuristic: don't reduce idle direction when only the other is loaded
        if [ "$new_ul_rate" -lt "$ul_rate" ] && [ "$ul_load_pct" -lt 50 ] && [ "$dl_load_pct" -ge 75 ]; then
            new_ul_rate=$ul_rate
        fi
        if [ "$new_dl_rate" -lt "$dl_rate" ] && [ "$dl_load_pct" -lt 50 ] && [ "$ul_load_pct" -ge 75 ]; then
            new_dl_rate=$dl_rate
        fi
        
        # Apply upload rate change
        if [ "$new_ul_rate" != "$ul_rate" ]; then
            ul_change_pct=$(( (new_ul_rate - ul_rate) * 100 / ul_rate ))
            [ "$ul_change_pct" -lt 0 ] && ul_change_pct=$((-ul_change_pct))
            if [ "$AUTORATE_LOG_CHANGES" = "1" ] || [ "$ul_change_pct" -ge 5 ]; then
                log_autorate "UL: $ul_rate -> $new_ul_rate kbps (${ul_change_pct}%, latency=$((_latency_result/10)).$((_latency_result%10))ms)"
            fi
            if autorate_update_bandwidth "$new_ul_rate" "$wan_iface" "egress"; then
                ul_rate=$new_ul_rate
                last_ul_change=$current_time
            else
                log_autorate "WARNING: Failed to apply UL rate $new_ul_rate kbps, keeping $ul_rate kbps"
            fi
        fi
        
        # Apply download rate change
        if [ "$new_dl_rate" != "$dl_rate" ]; then
            dl_change_pct=$(( (new_dl_rate - dl_rate) * 100 / dl_rate ))
            [ "$dl_change_pct" -lt 0 ] && dl_change_pct=$((-dl_change_pct))
            if [ "$AUTORATE_LOG_CHANGES" = "1" ] || [ "$dl_change_pct" -ge 5 ]; then
                log_autorate "DL: $dl_rate -> $new_dl_rate kbps (${dl_change_pct}%, latency=$((_latency_result/10)).$((_latency_result%10))ms)"
            fi
            if autorate_update_bandwidth "$new_dl_rate" "$lan_iface" "ingress"; then
                dl_rate=$new_dl_rate
                last_dl_change=$current_time
            else
                log_autorate "WARNING: Failed to apply DL rate $new_dl_rate kbps, keeping $dl_rate kbps"
            fi
        fi
        
        # Write state file (latency in tenths of ms internally)
        printf 'ul_rate=%s\ndl_rate=%s\nachieved_ul=%s\nachieved_dl=%s\nlatency=%s\nbaseline=%s\nul_load_pct=%s\ndl_load_pct=%s\nstate_uptime=%s\n' \
            "$ul_rate" "$dl_rate" "$achieved_ul" "$achieved_dl" "$_latency_result" "$baseline_latency" \
            "$ul_load_pct" "$dl_load_pct" "$current_time" \
            > "$AUTORATE_STATE_FILE"
        
        # Time-based history write (every 2s real time, independent of loop speed)
        if [ $((current_time - last_history_write)) -ge 2 ]; then
            last_history_write=$current_time
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
                "$current_time" "$ul_rate" "$dl_rate" "$achieved_ul" "$achieved_dl" \
                "$_latency_result" "$baseline_latency" "$ul_load_pct" "$dl_load_pct" \
                >> "$AUTORATE_HISTORY_FILE"
            
            # Truncate RAM history every 3 minutes (keep last 3600s by timestamp)
            if [ $((current_time - last_truncate)) -ge 180 ]; then
                last_truncate=$current_time
                local cutoff=$((current_time - 3600))
                awk -F, -v c="$cutoff" '$1 >= c' "$AUTORATE_HISTORY_FILE" > "${AUTORATE_HISTORY_FILE}.tmp" && \
                    mv "${AUTORATE_HISTORY_FILE}.tmp" "$AUTORATE_HISTORY_FILE"
            fi
            
            # Consolidate to flash every hour (if enabled via UCI)
            if [ $((current_time - last_consolidate)) -ge 3600 ]; then
                last_consolidate=$current_time
                [ "$(uci -q get qosmate.autorate.flash_history)" = "1" ] && consolidate_to_flash
            fi
        fi
    done
}

# Show current status
show_status() {
    local running=0 state_age=-1 state_ttl=300
    local _state_uptime _key _val

    /etc/init.d/qosmate-autorate running >/dev/null 2>&1 && running=1

    if [ "$running" -eq 1 ]; then
        echo "Autorate daemon is running"
    else
        echo "Autorate daemon is not running"
    fi

    if [ -f "$AUTORATE_STATE_FILE" ]; then
        while IFS='=' read -r _key _val; do
            case "$_key" in
                state_uptime) _state_uptime="$_val"; break ;;
            esac
        done < "$AUTORATE_STATE_FILE"

        case "$_state_uptime" in
            ''|*[!0-9]*) ;;
            *)
                get_uptime
                state_age=$((_time_result - _state_uptime))
                [ "$state_age" -lt 0 ] && state_age=-1
                ;;
        esac

        if [ "$running" -eq 1 ]; then
            echo "Autorate state:"
        else
            echo "Last autorate state snapshot (daemon stopped):"
        fi
        cat "$AUTORATE_STATE_FILE"

        if [ "$state_age" -ge 0 ]; then
            echo "state_age_seconds=$state_age"
            [ "$state_age" -gt "$state_ttl" ] && echo "state_stale=1" || echo "state_stale=0"
        fi
    else
        echo "No autorate state available"
    fi

    [ "$running" -eq 1 ]
}

case "$1" in
    run) run_daemon ;;
    status) show_status ;;
    *) echo "Usage: $0 {run|status}"; exit 1 ;;
esac
