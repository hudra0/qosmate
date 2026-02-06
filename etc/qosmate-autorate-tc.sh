#!/bin/sh
# QoSmate Autorate TC Update Functions
# These functions update bandwidth settings on-the-fly without recreating qdiscs.
# Sourced by autorate.sh daemon

# shellcheck disable=SC3043,SC2034

# Global variable for gamerate result
_gamerate_result=0

# Calculate effective GAMERATE based on user configuration
# Result in _gamerate_result
_autorate_calculate_gamerate() {
    local new_rate="$1" direction="$2"
    local config_gamerate original_rate default_gamerate

    if [ "$direction" = "egress" ]; then
        config_gamerate="$GAMEUP"
        original_rate="$UPRATE"
    else
        config_gamerate="$GAMEDOWN"
        original_rate="$DOWNRATE"
    fi

    default_gamerate=$((original_rate * 15 / 100 + 400))

    if [ -z "$config_gamerate" ] || [ "$config_gamerate" = "$default_gamerate" ]; then
        _gamerate_result=$((new_rate * 15 / 100 + 400))
    else
        _gamerate_result="$config_gamerate"
    fi

    [ "$_gamerate_result" -ge "$new_rate" ] && _gamerate_result=$((new_rate - 100))
    [ "$_gamerate_result" -lt 100 ] && _gamerate_result=100
}

_autorate_update_cake() {
    local new_rate="$1" dev="$2"
    tc qdisc change dev "$dev" root cake bandwidth "${new_rate}kbit" 2>/dev/null || {
        logger -t qosmate-autorate "ERROR: tc qdisc change failed for $dev"
        return 1
    }
}

_autorate_update_htb() {
    local new_rate="$1" dev="$2"
    local htb_quantum=$((1000 * new_rate / 8000))
    [ "$htb_quantum" -lt 1500 ] && htb_quantum=1500
    [ "$htb_quantum" -gt 200000 ] && htb_quantum=200000

    local root_burst=$((1000 * new_rate / 8000))
    [ "$root_burst" -lt 1500 ] && root_burst=1500
    local root_cburst="$root_burst"

    local percent=$((15 + 50000 / new_rate))
    [ "$percent" -gt 40 ] && percent=40
    [ "$percent" -lt 5 ] && percent=5

    local prio_rate=$((new_rate * percent / 100))
    [ 800 -gt "$prio_rate" ] && prio_rate=800

    local prio_ceil=$((new_rate / 3))
    local min_ceil=$((prio_rate * 110 / 100))
    [ "$prio_ceil" -lt "$min_ceil" ] && prio_ceil="$min_ceil"

    local be_min=$((new_rate / 6))
    local bk_min=$((new_rate / 6))
    local be_ceil=$((new_rate - 16))

    local total_min=$((prio_rate + be_min + bk_min))
    if [ "$total_min" -gt "$((new_rate * 90 / 100))" ]; then
        be_min=$((be_min * new_rate * 90 / 100 / total_min))
        bk_min=$((bk_min * new_rate * 90 / 100 / total_min))
    fi

    local prio_burst=$((10000 * prio_rate / 8000))
    [ "$prio_burst" -lt 1500 ] && prio_burst=1500
    local prio_cburst=$((5000 * prio_rate / 8000))
    [ "$prio_cburst" -lt 1500 ] && prio_cburst=1500

    local be_burst=$((10000 * be_min / 8000))
    [ "$be_burst" -lt 1500 ] && be_burst=1500
    local be_cburst=$((5000 * be_min / 8000))
    [ "$be_cburst" -lt 1500 ] && be_cburst=1500

    local bk_burst=$((10000 * bk_min / 8000))
    [ "$bk_burst" -lt 1500 ] && bk_burst=1500
    local bk_cburst=$((5000 * bk_min / 8000))
    [ "$bk_cburst" -lt 1500 ] && bk_cburst=1500

    # Atomic update via tc batch
    printf '%s\n' \
        "class change dev $dev parent 1: classid 1:1 htb quantum $htb_quantum rate ${new_rate}kbit ceil ${new_rate}kbit burst $root_burst cburst $root_cburst" \
        "class change dev $dev parent 1:1 classid 1:11 htb quantum $htb_quantum rate ${prio_rate}kbit ceil ${prio_ceil}kbit burst $prio_burst cburst $prio_cburst prio 1" \
        "class change dev $dev parent 1:1 classid 1:13 htb quantum $htb_quantum rate ${be_min}kbit ceil ${be_ceil}kbit burst $be_burst cburst $be_cburst prio 2" \
        "class change dev $dev parent 1:1 classid 1:15 htb quantum $htb_quantum rate ${bk_min}kbit ceil ${be_ceil}kbit burst $bk_burst cburst $bk_cburst prio 3" \
    | tc -batch - 2>/dev/null || {
        logger -t qosmate-autorate "ERROR: tc batch failed for $dev (htb)"
        return 1
    }
}

_autorate_update_hfsc() {
    local new_rate="$1" dev="$2" direction="$3"
    
    # Calculate gamerate (result in _gamerate_result)
    _autorate_calculate_gamerate "$new_rate" "$direction"
    local gamerate="$_gamerate_result"

    local DUR=$((5 * 1500 * 8 / new_rate))
    [ "$DUR" -lt 25 ] && DUR=25

    local gameburst=$((gamerate * 10))
    [ "$gameburst" -gt "$((new_rate * 97 / 100))" ] && gameburst=$((new_rate * 97 / 100))

    # Atomic update via tc batch
    printf '%s\n' \
        "class change dev $dev parent 1: classid 1:1 hfsc ls m2 ${new_rate}kbit ul m2 ${new_rate}kbit" \
        "class change dev $dev parent 1:1 classid 1:11 hfsc rt m1 ${gameburst}kbit d ${DUR}ms m2 ${gamerate}kbit" \
        "class change dev $dev parent 1:1 classid 1:12 hfsc ls m1 $((new_rate * 70 / 100))kbit d ${DUR}ms m2 $((new_rate * 30 / 100))kbit" \
        "class change dev $dev parent 1:1 classid 1:13 hfsc ls m1 $((new_rate * 20 / 100))kbit d ${DUR}ms m2 $((new_rate * 45 / 100))kbit" \
        "class change dev $dev parent 1:1 classid 1:14 hfsc ls m1 $((new_rate * 7 / 100))kbit d ${DUR}ms m2 $((new_rate * 15 / 100))kbit" \
        "class change dev $dev parent 1:1 classid 1:15 hfsc ls m1 $((new_rate * 3 / 100))kbit d ${DUR}ms m2 $((new_rate * 10 / 100))kbit" \
    | tc -batch - 2>/dev/null || {
        logger -t qosmate-autorate "ERROR: tc batch failed for $dev (hfsc)"
        return 1
    }
}

_autorate_update_hybrid() {
    local new_rate="$1" dev="$2" direction="$3"
    
    # Calculate gamerate (result in _gamerate_result)
    _autorate_calculate_gamerate "$new_rate" "$direction"
    local gamerate="$_gamerate_result"

    local cake_rate=$((new_rate - gamerate))
    [ "$cake_rate" -le 0 ] && cake_rate=1

    local DUR=$((5 * 1500 * 8 / new_rate))
    [ "$DUR" -lt 25 ] && DUR=25
    local gameburst=$((gamerate * 10))
    [ "$gameburst" -gt "$((new_rate * 97 / 100))" ] && gameburst=$((new_rate * 97 / 100))

    local bulk_m1=$((new_rate * 3 / 100))
    [ "$bulk_m1" -le 0 ] && bulk_m1=1
    local bulk_m2=$((new_rate * 10 / 100))
    [ "$bulk_m2" -le 0 ] && bulk_m2=1

    # Atomic update via tc batch
    printf '%s\n' \
        "class change dev $dev parent 1: classid 1:1 hfsc ls m2 ${new_rate}kbit ul m2 ${new_rate}kbit" \
        "class change dev $dev parent 1:1 classid 1:11 hfsc rt m1 ${gameburst}kbit d ${DUR}ms m2 ${gamerate}kbit" \
        "class change dev $dev parent 1:1 classid 1:13 hfsc ls m1 ${cake_rate}kbit d ${DUR}ms m2 ${cake_rate}kbit" \
        "class change dev $dev parent 1:1 classid 1:15 hfsc ls m1 ${bulk_m1}kbit d ${DUR}ms m2 ${bulk_m2}kbit" \
        "qdisc change dev $dev parent 1:13 handle 13: cake bandwidth ${cake_rate}kbit" \
    | tc -batch - 2>/dev/null || {
        logger -t qosmate-autorate "ERROR: tc batch failed for $dev (hybrid)"
        return 1
    }
}

autorate_update_bandwidth() {
    local new_rate="$1" dev="$2" direction="$3"

    [ "$new_rate" -gt 0 ] 2>/dev/null || {
        logger -t qosmate-autorate "ERROR: Invalid rate: $new_rate"
        return 1
    }

    case "$ROOT_QDISC" in
        cake)   _autorate_update_cake   "$new_rate" "$dev" ;;
        htb)    _autorate_update_htb    "$new_rate" "$dev" ;;
        hfsc)   _autorate_update_hfsc   "$new_rate" "$dev" "$direction" ;;
        hybrid) _autorate_update_hybrid "$new_rate" "$dev" "$direction" ;;
        *)
            logger -t qosmate-autorate "ERROR: Unsupported ROOT_QDISC: $ROOT_QDISC"
            return 1
            ;;
    esac
}
