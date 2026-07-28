#!/bin/sh
# QoSmate HFSC and Hybrid (HFSC+CAKE) root qdisc setup. Sourced by qosmate-lib-tc.sh.

# shellcheck disable=SC3043

# Attach the game leaf under HFSC class 1:11 (handle 10:).
# 1:DEV 2:RATE 3:GAMERATE 4:QDISC_TYPE
# DIR comes from for_each_shaped_dir (UP/DOWN); other knobs from config globals.
# netem* are localized so a forced 1ms delay on UP cannot leak into DOWN.
setup_game_qdisc() {
    local DEV="$1" RATE="$2" GAMERATE="$3" QDISC_TYPE="$4"
    local MTU=1500 PACKETSIZE="$PACKETSIZE"
    local netemdelayms="$netemdelayms" netemjitterms="$netemjitterms" netemdist="$netemdist"

    # Ensure rates/packetsize are non-zero to avoid errors in calculations
    [ "$RATE" -le 0 ] && RATE=1
    [ "$GAMERATE" -le 0 ] && GAMERATE=1
    [ "$PACKETSIZE" -le 0 ] && PACKETSIZE=1

    # Calculate REDMIN and REDMAX based on gamerate and MAXDEL
    local REDMIN=$((GAMERATE * MAXDEL / 3 / 8))
    local REDMAX=$((GAMERATE * MAXDEL / 8))
    # Calculate BURST: (min + min + max)/(3 * avpkt) as per RED documentation
    local BURST=$(( (REDMIN + REDMIN + REDMAX) / (3 * 500) )); [ $BURST -lt 2 ] && BURST=2

    # for fq_codel
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))

    # Delete previous qdisc on this handle if it exists (optional, but good practice)
    tc qdisc del dev "$DEV" parent 1:11 handle 10: > /dev/null 2>&1

    case $QDISC_TYPE in
        "drr")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: drr
            tc class add dev "$DEV" parent 10: classid 10:1 drr quantum 8000
            tc qdisc add dev "$DEV" parent 10:1 handle 11: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:2 drr quantum 4000
            tc qdisc add dev "$DEV" parent 10:2 handle 12: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:3 drr quantum 1000
            tc qdisc add dev "$DEV" parent 10:3 handle 13: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
        ;;
        "qfq")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: qfq
            tc class add dev "$DEV" parent 10: classid 10:1 qfq weight 8000
            tc qdisc add dev "$DEV" parent 10:1 handle 11: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:2 qfq weight 4000
            tc qdisc add dev "$DEV" parent 10:2 handle 12: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:3 qfq weight 1000
            tc qdisc add dev "$DEV" parent 10:3 handle 13: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" probability 1.0 burst $BURST
        ;;
        "pfifo")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
        "bfifo")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: bfifo limit $((MAXDEL * GAMERATE / 8))
            #tc qdisc add dev "$DEV" parent 1:11 handle 10: bfifo limit $((MAXDEL * RATE / 8))
        ;;
        "red")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth "${RATE}kbit" burst $BURST probability 1.0
            ## send game packets to 10:, they're all treated the same
        ;;
        "fq_codel")
        tc qdisc add dev "$DEV" parent "1:11" handle 10: fq_codel memory_limit $((RATE*200/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))
        ;;
        "netem")
            # Only apply NETEM if this direction is enabled
            if [ "$NETEM_DIRECTION" = "both" ] || \
               { [ "$NETEM_DIRECTION" = "egress" ] && [ "$DIR" = "UP" ]; } || \
               { [ "$NETEM_DIRECTION" = "ingress" ] && [ "$DIR" = "DOWN" ]; }; then

                NETEM_CMD="tc qdisc add dev \"$DEV\" parent 1:11 handle 10: netem limit $((4+9*RATE/8/500))"

                # If jitter is set but delay is 0, force minimum delay of 1ms
                if [ "$netemjitterms" -ne 0 ] && [ "$netemdelayms" -eq 0 ]; then
                    netemdelayms=1
                fi

                # Add delay parameter if set (either original or forced minimum)
                if [ "$netemdelayms" -ne 0 ]; then
                    NETEM_CMD="$NETEM_CMD delay ${netemdelayms}ms"

                    # Add jitter if set
                    if [ "$netemjitterms" -ne 0 ]; then
                        NETEM_CMD="$NETEM_CMD ${netemjitterms}ms"
                        NETEM_CMD="$NETEM_CMD distribution $netemdist"
                    fi
                fi

                # Add packet loss if set
                if [ "$pktlossp" != "none" ] && [ -n "$pktlossp" ]; then
                    NETEM_CMD="$NETEM_CMD loss $pktlossp"
                fi

                eval "$NETEM_CMD"
            else
                # Direction mismatch: pfifo fallback without changing global gameqdisc
                tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
            fi
        ;;
        *)
            print_msg -err "Unsupported game qdisc type '$QDISC_TYPE'. Using pfifo fallback."
            # pfifo fallback limit calculation
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
    esac
}

# Nested hfsc_apply sees for_each_shaped_dir locals DIR/DEV/RATE/GAMERATE.
setup_hfsc() {
    hfsc_apply() {
        local MTU=1500

        tc qdisc del dev "$DEV" root > /dev/null 2>&1

        # Get overhead parameters from CAKE configuration
        local TC_OH_PARAMS
        TC_OH_PARAMS=$(get_tc_overhead_params)

        # Apply root qdisc
        # shellcheck disable=SC2086
        tc qdisc replace dev "$DEV" handle 1: root ${TC_OH_PARAMS} hfsc default 13

        # DUR calculation
        local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25

        # Router traffic class (only on ingress IFB)
        if [ "$DIR" = "DOWN" ]; then
            tc class add dev "$DEV" parent 1: classid 1:2 hfsc ls m1 50000kbit d "${DUR}ms" m2 10000kbit
        fi

        # Main link class
        tc class add dev "$DEV" parent 1: classid 1:1 hfsc ls m2 "${RATE}kbit" ul m2 "${RATE}kbit"
        # gameburst calculation
        local gameburst=$((GAMERATE*10)); [ $gameburst -gt $((RATE*97/100)) ] && gameburst=$((RATE*97/100));

        # Define HFSC Classes
        tc class add dev "$DEV" parent 1:1 classid 1:11 hfsc rt m1 "${gameburst}kbit" d "${DUR}ms" m2 "${GAMERATE}kbit" # Realtime
        tc class add dev "$DEV" parent 1:1 classid 1:12 hfsc ls m1 "$((RATE*70/100))kbit" d "${DUR}ms" m2 "$((RATE*30/100))kbit" # Fast
        tc class add dev "$DEV" parent 1:1 classid 1:13 hfsc ls m1 "$((RATE*20/100))kbit" d "${DUR}ms" m2 "$((RATE*45/100))kbit" # Normal (Default)
        tc class add dev "$DEV" parent 1:1 classid 1:14 hfsc ls m1 "$((RATE*7/100))kbit" d "${DUR}ms" m2 "$((RATE*15/100))kbit"  # Low Prio
        tc class add dev "$DEV" parent 1:1 classid 1:15 hfsc ls m1 "$((RATE*3/100))kbit" d "${DUR}ms" m2 "$((RATE*10/100))kbit"  # Bulk

        # Attach game qdisc before non-game leaves
        setup_game_qdisc "$DEV" "$RATE" "$GAMERATE" "$gameqdisc"

        # Attach non-game qdiscs
        local INTVL=$((100+2*1500*8/RATE))
        local TARG=$((540*8/RATE+4))
        for i in 12 13 14 15; do
            if [ "$nongameqdisc" = "cake" ]; then
                # shellcheck disable=SC2086  # nongameqdiscoptions needs word splitting (e.g. "besteffort ack-filter")
                tc qdisc add dev "$DEV" parent "1:$i" cake $nongameqdiscoptions
            elif [ "$nongameqdisc" = "fq_codel" ]; then
                tc qdisc add dev "$DEV" parent "1:$i" fq_codel memory_limit "$((RATE*200/8))" interval "${INTVL}ms" target "${TARG}ms" quantum "$((MTU * 2))"
            else
                print_msg -err "Unsupported qdisc for non-game traffic: $nongameqdisc"
                exit 1
            fi
        done

        apply_dscp_filters "$DEV" "ef cs5 cs6 cs7 cs4 af41 af42 cs2 af11 cs1 cs0" "ef cs5 cs6 cs7 cs4 af41 af42 cs2 af11 cs1 cs0"
    }

    for_each_shaped_dir hfsc_apply || return 1
}

# Nested hybrid_apply sees for_each_shaped_dir locals DIR/DEV/RATE/GAMERATE.
setup_hybrid() {
    hybrid_apply() {
        local MTU=1500

        # Calculate parameters
        local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25
        local gameburst=$((GAMERATE*10)); [ $gameburst -gt $((RATE*97/100)) ] && gameburst=$((RATE*97/100));

        # Setup root HFSC qdisc (default to 1:13 - CAKE class)
        local TC_OH_PARAMS
        TC_OH_PARAMS=$(get_tc_overhead_params)

        # Ensure previous root is deleted before replacing
        tc qdisc del dev "$DEV" root > /dev/null 2>&1
        # shellcheck disable=SC2086
        tc qdisc replace dev "$DEV" handle 1: root ${TC_OH_PARAMS} hfsc default 13

        # Router traffic class (only on ingress IFB)
        if [ "$DIR" = "DOWN" ]; then
            tc class add dev "$DEV" parent 1: classid 1:2 hfsc ls m1 50000kbit d "${DUR}ms" m2 10000kbit
        fi

        # Main link class
        tc class add dev "$DEV" parent 1: classid 1:1 hfsc ls m2 "${RATE}kbit" ul m2 "${RATE}kbit"

        # Class 1:11 - High priority realtime (HFSC RT + gameqdisc)
        tc class add dev "$DEV" parent 1:1 classid 1:11 hfsc rt m1 "${gameburst}kbit" d "${DUR}ms" m2 "${GAMERATE}kbit"
        setup_game_qdisc "$DEV" "$RATE" "$GAMERATE" "$gameqdisc"

        # Class 1:13 - CAKE class (most traffic - default)
        local cake_rate=$((RATE - GAMERATE)); [ $cake_rate -le 0 ] && cake_rate=1
        tc class add dev "$DEV" parent 1:1 classid 1:13 hfsc ls m1 "${cake_rate}kbit" d "${DUR}ms" m2 "${cake_rate}kbit"

        # Attach CAKE qdisc - use "hybrid" mode to match HFSC overhead
        local cake_link_params="$(get_cake_link_params "hybrid")"
        local CAKE_OPTS=""
        tc qdisc del dev "$DEV" parent 1:13 handle 13: > /dev/null 2>&1

        # shellcheck disable=SC2086
        if [ "$DIR" = "UP" ]; then
            CAKE_OPTS="besteffort" # Default for non-realtime in hybrid
            append_cake_opt "dual-srchost" "$HOST_ISOLATION" &&
            append_cake_opt "$EXTRA_PARAMETERS_EGRESS" "1" &&
            append_cake_opt "nat" "$NAT_EGRESS" &&
            append_cake_opt "wash" "$WASHDSCPUP"
        else # DOWN (ingress)
            CAKE_OPTS="besteffort ingress" # Default for non-realtime in hybrid
            append_cake_opt "dual-dsthost" "$HOST_ISOLATION" &&
            append_cake_opt "$EXTRA_PARAMETERS_INGRESS" "1" &&
            append_cake_opt "nat" "$NAT_INGRESS" &&
            append_cake_opt "wash" "$WASHDSCPDOWN"
        fi &&
        append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
        append_cake_opt "$cake_link_params" "1" &&
        append_cake_opt "$LINK_COMPENSATION" "1" &&
        tc qdisc replace dev "$DEV" parent 1:13 handle 13: cake $CAKE_OPTS || qdisc_setup_failed
        debug_log "$DIR HYBRID cake opts: '$CAKE_OPTS'"

        # Class 1:15 - Bulk traffic (HFSC LS + fq_codel)
        # Use HFSC limits: m1 3%, m2 10%
        local bulk_rate_m1=$((RATE*3/100)); [ $bulk_rate_m1 -le 0 ] && bulk_rate_m1=1
        local bulk_rate_m2=$((RATE*10/100)); [ $bulk_rate_m2 -le 0 ] && bulk_rate_m2=1
        tc class add dev "$DEV" parent 1:1 classid 1:15 hfsc ls m1 "${bulk_rate_m1}kbit" d "${DUR}ms" m2 "${bulk_rate_m2}kbit"
        # Attach fq_codel (using calculations and options from HFSC config)
        local INTVL=$((100+2*1500*8/RATE))
        local TARG=$((540*8/RATE+4))
        tc qdisc del dev "$DEV" parent 1:15 handle 15: > /dev/null 2>&1
        tc qdisc replace dev "$DEV" parent 1:15 handle 15: fq_codel memory_limit $((RATE*200/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))

        apply_dscp_filters "$DEV" "ef cs5 cs6 cs7 cs1" "ef cs5 cs6 cs7 cs1 cs0"
    }

    for_each_shaped_dir hybrid_apply || return 1
}
:
