#!/bin/sh
# QoSmate shared traffic control layer.
# Sourced by /etc/qosmate.sh; expects the config to be loaded and print_msg/log_msg/
# error_out/debug_log to be defined by the caller.
#
# Direction convention inside the TC libs: DIR is UP (egress, $WAN) or DOWN
# (ingress, $LAN = ifb-$WAN). The autorate daemon uses egress/ingress instead.

# shellcheck disable=SC3043

# Runs tc and, when QOSMATE_TC_TRACE points to a file, records the invocation.
# Returns tc's exit code unchanged so callers keep their own error handling.
tc_run() {
    [ -z "${QOSMATE_TC_TRACE:-}" ] || {
        printf 'tc'
        for _tc_arg in "$@"; do printf ' %s' "$_tc_arg"; done
        printf '\n'
    } >> "$QOSMATE_TC_TRACE"
    tc "$@"
}

# Get tc stab parameters for HFSC/HTB/Hybrid
get_tc_overhead_params() {
    local preset="$COMMON_LINK_PRESETS"
    local overhead="$OVERHEAD"
    
    # Detect ATM-based presets
    case "$preset" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            printf '%s' "stab mtu 2047 tsize 512 mpu 68 overhead ${overhead:-44} linklayer atm"
            ;;
        docsis)
            printf '%s' "stab overhead ${overhead:-25} linklayer ethernet"
            ;;
        cake-ethernet)
            printf '%s' "stab overhead ${overhead:-38} linklayer ethernet"
            ;;
        raw)
            printf '%s' "stab overhead ${overhead:-0} linklayer ethernet"
            ;;
        *)
            printf '%s' "stab overhead ${overhead:-40} linklayer ethernet"
            ;;
    esac
}

# Get CAKE parameters from common link settings
# $1 = "hybrid": CAKE runs below an HFSC root that already accounts for the overhead
get_cake_link_params() {
    local preset="$COMMON_LINK_PRESETS"
    local oh="${OVERHEAD}"
    local base=""

    # The HFSC root carries a tc stab, which rewrites qdisc_pkt_len for the whole
    # hierarchy. "raw" makes CAKE bill that already adjusted length instead of
    # adding the overhead a second time.
    [ "$1" = "hybrid" ] && { printf 'raw'; return; }

    # Determine base keyword and default overhead
    case "$preset" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            base="${preset}"
            : "${oh:=44}"
            ;;
        docsis)       base="docsis";   : "${oh:=25}" ;;
        cake-ethernet) base="ethernet"; oh="" ;;
        raw)          base="raw";      : "${oh:=0}" ;;
        ethernet|*)   base="ethernet"; : "${oh:=40}" ;;
    esac

    # Build parameters
    printf "%s%s%s%s" \
        "$base" \
        "${oh:+ overhead $oh}" \
        "${MPU:+ mpu $MPU}" \
        "${ETHER_VLAN_KEYWORD:+ $ETHER_VLAN_KEYWORD}"
}

# Select cake or cake_mq based on USE_MQ setting and system capabilities
# $1: interface name to check for multi-queue support
# Sets REPLY to "cake" or "cake_mq"
select_cake_qdisc() {
    local iface="$1" num_queues=0
    REPLY="cake"

    [ "$USE_MQ" != "1" ] && return

    num_queues=$(find /sys/class/net/"$iface"/queues/ -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | wc -l)

    if [ "$num_queues" -gt 1 ] && tc qdisc replace dev "$iface" root cake_mq 2>/dev/null; then
        tc qdisc del dev "$iface" root 2>/dev/null
        log_msg "Using cake_mq for $iface ($num_queues TX queues)"
        REPLY="cake_mq"
    else
        if [ "$num_queues" -le 1 ]; then
            log_msg "cake_mq not used for $iface: only $num_queues TX queue(s), using cake"
        else
            log_msg "cake_mq not available in kernel, using cake for $iface"
        fi
    fi
}

# 1 - device
# 2 - class enum
# 3 - family (ipv4|ipv6)
add_tc_filter() {
    local class_id dsfield hex_match proto prio match_str \
        dev="$1" \
        class_enum="$2" \
        family="$3"

    case "$class_enum" in
        cs0|CS0) class_id=1:13 dsfield=0x00 hex_match=0x0000 ;; # 0 -> Default
        ef|EF) class_id=1:11 dsfield=0xb8 hex_match=0x0B80 ;; # 46
        cs1|CS1) class_id=1:15 dsfield=0x20 hex_match=0x0200 ;; # 8
        cs2|CS2) class_id=1:14 dsfield=0x40 hex_match=0x0400 ;; # 16
        cs4|CS4) class_id=1:12 dsfield=0x80 hex_match=0x0800 ;; # 32
        cs5|CS5) class_id=1:11 dsfield=0xa0 hex_match=0x0A00 ;; # 40
        cs6|CS6) class_id=1:11 dsfield=0xc0 hex_match=0x0C00 ;; # 48
        cs7|CS7) class_id=1:11 dsfield=0xe0 hex_match=0x0E00 ;; # 56
        af11|AF11) class_id=1:14 dsfield=0x28 hex_match=0x0280 ;; # 10
        af41|AF41) class_id=1:12 dsfield=0x88 hex_match=0x0880 ;; # 34
        af42|AF42) class_id=1:12 dsfield=0x90 hex_match=0x0900 ;; # 36
        *) # TODO: throw an error
    esac

    case "$family" in
        ipv4)
            proto=ip prio=10 match_str="ip dsfield $dsfield 0xfc"
            ;;
        ipv6)
            proto=ipv6 prio=11 match_str="u16 $hex_match 0x0FC0 at 0"
            ;;
    esac

    # shellcheck disable=SC2086
    tc filter add dev "$dev" parent 1: protocol "$proto" prio "$prio" u32 match $match_str classid "$class_id"
}

qdisc_setup_failed() {
    [ -n "$1" ] && error_out "$1"
    error_out "Failed to set up $ROOT_QDISC."
    # *** Any additional error handling needed? ***
    exit 1
}

# 1 - device, 2 - IPv4 class enum list, 3 - IPv6 class enum list
add_dscp_filter_sets() {
    local dev="$1" v4_enums="$2" v6_enums="$3" class_enum

    tc filter del dev "$dev" parent 1: prio 1 > /dev/null 2>&1
    tc filter del dev "$dev" parent 1: prio 2 > /dev/null 2>&1

    for class_enum in $v4_enums; do
        add_tc_filter "$dev" "$class_enum" ipv4
    done
    for class_enum in $v6_enums; do
        add_tc_filter "$dev" "$class_enum" ipv6
    done
    :
}

# Applies the DSCP -> class u32 filters for one direction.
# Ingress always needs them; egress only with SFO, because without SFO the
# nftables priomap already sets the class.
# 1 - device, 2 - IPv4 class enum list, 3 - IPv6 class enum list
apply_dscp_filters() {
    local dev="$1" v4_enums="$2" v6_enums="$3"

    [ "$DIR" = "DOWN" ] || [ "$SFO_ENABLED" = "1" ] || return 0

    add_dscp_filter_sets "$dev" "$v4_enums" "$v6_enums"
}

# Appends option to ${CAKE_OPTS}
# 1: parameter: nat|wash|ack_filter|*
# 2: selector (1|0)
#    for wash, nat, ack-filter: selector value '1' translates to prefix '', any other value translates to prefix 'no[-]'
#    for other options: selector value '1' translates to 'don't skip option', any other value translates to 'skip option'
# Also defined in qosmate-lib-cake.sh; kept here so hybrid (still in qosmate.sh) can call it.
append_cake_opt() {
    [ ${#} = 2 ] || { error_out "append_cake_opt: invalid args '$*'."; return 1; }
    local prefix='' \
        param="$1" selector="$2"
    [ -n "$param" ] || return 0
    [ "$selector" != 1 ] &&
        case "$param" in
            wash|nat) prefix='no' ;;
            ack-filter) prefix='no-' ;;
            *) return 0 ;;
        esac
    CAKE_OPTS="${CAKE_OPTS} ${prefix}${param}"
    :
}

# Runs $1 once per shaped direction with DIR/DEV/RATE/GAMERATE preset.
# A rate of 0 disables that direction; this is the only place that decides it.
for_each_shaped_dir() {
    local apply_fn="$1" DIR DEV RATE GAMERATE
    for DIR in UP DOWN; do
        case "$DIR" in
            UP)
                [ "$SHAPE_EGRESS" = 1 ] || continue
                DEV="$WAN" RATE="$UPRATE" GAMERATE="$GAMEUP" ;;
            DOWN)
                [ "$SHAPE_INGRESS" = 1 ] || continue
                DEV="$LAN" RATE="$DOWNRATE" GAMERATE="$GAMEDOWN" ;;
        esac
        "$apply_fn" || return 1
    done
    :
}

: "${QOSMATE_LIB_CAKE:=/etc/qosmate.d/qosmate-lib-cake.sh}"
[ "$ROOT_QDISC" != cake ] || {
    # shellcheck source=/dev/null
    . "$QOSMATE_LIB_CAKE" || { error_out "Failed to load CAKE library '$QOSMATE_LIB_CAKE'."; exit 1; }
}

: