#!/bin/sh
# QoSmate HTB root qdisc setup. Sourced by qosmate-lib-tc.sh.

# shellcheck disable=SC3043

# Helper functions for HTB dynamic parameter calculation
# Calculate optimal HTB quantum based on rate
calculate_htb_quantum() {
    local rate="$1"
    local duration_us="${2:-1000}"  # Default 1ms = 1000µs
    local MTU=1500
    
    # Duration-based calculation (SQM-style)
    # rate in kbit/s, duration in µs, result in bytes
    local quantum=$(((duration_us * rate) / 8000))
    
    # ATM-aware minimum
    if [ "$COMMON_LINK_PRESETS" = "atm" ]; then
        local min_quantum=$(((MTU + 48 + 47) / 48 * 53))
        [ $quantum -lt $min_quantum ] && quantum=$min_quantum
    else
        [ $quantum -lt $MTU ] && quantum=$MTU
    fi
    
    # Maximum reasonable quantum (200KB)
    [ $quantum -gt 200000 ] && quantum=200000
    
    echo $quantum
}

# Calculate HTB burst size based on rate and target latency
calculate_htb_burst() {
    local rate="$1"
    local duration_us="${2:-10000}"  # Default 10ms = 10000µs
    
    # burst in bytes for given duration
    local burst=$(((duration_us * rate) / 8000))
    
    # Minimum burst should be at least 1 MTU
    [ $burst -lt 1500 ] && burst=1500
    
    echo $burst
}

# Nested htb_apply sees for_each_shaped_dir locals DIR/DEV/RATE via ash dynamic scoping.
setup_htb() {
    htb_apply() {
        local MTU=1500

        # Ensure rate is valid
        [ "$RATE" -le 0 ] && RATE=1

        # Delete existing qdisc
        tc qdisc del dev "$DEV" root > /dev/null 2>&1

        # Get overhead parameters from CAKE configuration
        local TC_OH_PARAMS
        TC_OH_PARAMS=$(get_tc_overhead_params)

        # Setup HTB root with default to best effort (class 13)
        tc qdisc add dev "$DEV" root handle 1: $TC_OH_PARAMS htb default 13

        # Calculate HTB quantum for root (all use same quantum)
        local HTB_QUANTUM="$(calculate_htb_quantum "$RATE")"

        # Root class gets modest burst since we typically configure 80-90% of physical rate
        # This allows brief bursts into the headroom without causing bufferbloat
        local ROOT_BURST="$(calculate_htb_burst "$RATE" 1000)"   # 1ms burst
        local ROOT_CBURST="$(calculate_htb_burst "$RATE" 1000)"  # 1ms cburst

        # Create main rate limiting class
        tc class add dev "$DEV" parent 1: classid 1:1 htb \
            quantum "$HTB_QUANTUM" \
            rate "${RATE}kbit" ceil "${RATE}kbit" \
            burst "$ROOT_BURST" cburst "$ROOT_CBURST"

        # Smart calculation that scales smoothly across all bandwidths
        # Formula: percent = 15 + (50000 / RATE), capped between 5-40%
        #
        # This creates a hyperbolic curve that provides:
        # - High percentage (up to 40%) for very low bandwidth connections
        # - Smooth decrease as bandwidth increases
        # - Stabilizes around 15% for high bandwidth connections
        #
        # Examples:
        # - 1 Mbit:   15 + 50 = 65% → capped at 40% → 400 kbit → min 800 kbit
        # - 5 Mbit:   15 + 10 = 25% → 1250 kbit
        # - 10 Mbit:  15 + 5  = 20% → 2000 kbit
        # - 50 Mbit:  15 + 1  = 16% → 8000 kbit
        # - 100 Mbit: 15 + 0.5 = 15.5% → 15500 kbit
        #
        # Visualization:
        #   40% |*
        #       |  *
        #   30% |    *
        #       |      *
        #   20% |        * * * * *
        #   15% |                  * * * * * * * *
        #       +---------------------------------> Bandwidth
        #       1    5   10   20   50  100  200 Mbit
        #
        # Two safety mechanisms ensure adequate priority bandwidth:
        # 1. Percentage-based: Scales with total bandwidth
        # 2. Absolute minimum: 800 kbit for gaming/VoIP needs

        # Calculate sliding percentage (higher % for lower rates)
        local percent=$((15 + 50000 / RATE))
        [ $percent -gt 40 ] && percent=40  # Cap at 40%
        [ $percent -lt 5 ] && percent=5     # Floor at 5%

        local percent_based=$((RATE * percent / 100))
        local absolute_min=800              # Gaming/VoIP minimum

        # Take the maximum of percentage-based and absolute minimum
        local PRIO_RATE_MIN=$percent_based
        [ $absolute_min -gt $PRIO_RATE_MIN ] && PRIO_RATE_MIN=$absolute_min

        # Calculate ceiling - ensure it's at least min + some headroom
        local PRIO_CEIL=$((RATE / 3))  # Start with 33%

        # Ensure ceiling is at least min rate + 10%
        local min_ceiling=$((PRIO_RATE_MIN * 110 / 100))
        [ $PRIO_CEIL -lt $min_ceiling ] && PRIO_CEIL=$min_ceiling

        # Calculate BE and BK rates
        local BE_MIN_RATE=$((RATE / 6))    # 16% guaranteed
        local BK_MIN_RATE=$((RATE / 6))    # 16% guaranteed

        # Adjust if total mins exceed available bandwidth
        local total_min=$((PRIO_RATE_MIN + BE_MIN_RATE + BK_MIN_RATE))
        if [ $total_min -gt $((RATE * 90 / 100)) ]; then
            # Scale down proportionally
            BE_MIN_RATE=$((BE_MIN_RATE * RATE * 90 / 100 / total_min))
            BK_MIN_RATE=$((BK_MIN_RATE * RATE * 90 / 100 / total_min))
        fi

        # BE/BK ceiling - almost full rate minus a small reserve
        local BE_CEIL=$((RATE - 16))

        # Calculate individual burst values for each class
        # Priority class burst - based on its own rate
        local PRIO_BURST="$(calculate_htb_burst $PRIO_RATE_MIN 10000)"  # 10ms burst for rate
        local PRIO_CBURST="$(calculate_htb_burst $PRIO_RATE_MIN 5000)"  # 5ms burst for ceiling
        [ "$PRIO_CBURST" -lt 1500 ] && PRIO_CBURST=1500

        # Priority class (1:11) - for realtime/gaming traffic
        tc class add dev "$DEV" parent 1:1 classid 1:11 htb \
            quantum "$HTB_QUANTUM" \
            rate "${PRIO_RATE_MIN}kbit" ceil "${PRIO_CEIL}kbit" \
            burst "$PRIO_BURST" cburst "$PRIO_CBURST" prio 1

        # Calculate BE burst values - based on its own guaranteed rate
        local BE_BURST="$(calculate_htb_burst $BE_MIN_RATE 10000)"  # 10ms burst for rate
        local BE_CBURST="$(calculate_htb_burst $BE_MIN_RATE 5000)"  # 5ms burst for ceiling
        [ "$BE_CBURST" -lt 1500 ] && BE_CBURST=1500

        # Best Effort class (1:13) - default traffic
        tc class add dev "$DEV" parent 1:1 classid 1:13 htb \
            quantum "$HTB_QUANTUM" \
            rate "${BE_MIN_RATE}kbit" ceil "${BE_CEIL}kbit" \
            burst "$BE_BURST" cburst "$BE_CBURST" prio 2

        # Calculate BK burst values - based on its own guaranteed rate
        local BK_BURST="$(calculate_htb_burst $BK_MIN_RATE 10000)"  # 10ms burst for rate
        local BK_CBURST="$(calculate_htb_burst $BK_MIN_RATE 5000)"  # 5ms burst for ceiling
        [ "$BK_CBURST" -lt 1500 ] && BK_CBURST=1500

        # Background/Bulk class (1:15) - low priority
        tc class add dev "$DEV" parent 1:1 classid 1:15 htb \
            quantum "$HTB_QUANTUM" \
            rate "${BK_MIN_RATE}kbit" ceil "${BE_CEIL}kbit" \
            burst "$BK_BURST" cburst "$BK_CBURST" prio 3

        # Attach leaf qdiscs
        # Calculate fq_codel parameters
        local INTVL=$((100+2*1500*8/RATE))
        local TARG=$((540*8/RATE+4))

        # Priority class gets fq_codel with aggressive settings
        tc qdisc add dev "$DEV" parent 1:11 handle 110: fq_codel \
            interval "${INTVL}ms" target "${TARG}ms" \
            quantum 300

        # Best effort with standard settings
        tc qdisc add dev "$DEV" parent 1:13 handle 130: fq_codel \
            interval "${INTVL}ms" target "${TARG}ms" \
            quantum 1500

        # Background with larger target
        tc qdisc add dev "$DEV" parent 1:15 handle 150: fq_codel \
            interval "$((INTVL*2))ms" target "$((TARG*2))ms" \
            quantum 300

        apply_dscp_filters "$DEV" "ef cs5 cs6 cs7 cs1" "ef cs5 cs6 cs7 cs1 cs0"
    }

    for_each_shaped_dir htb_apply || return 1
}
:
