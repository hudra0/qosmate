#!/bin/sh
# QoSmate CAKE root qdisc setup. Sourced by qosmate-lib-tc.sh.

# shellcheck disable=SC3043

# append_cake_opt lives in qosmate-lib-tc.sh (shared with hybrid).

# Nested cake_apply sees setup_cake locals (BusyBox ash).
setup_cake() {
    local CAKE_LINK_PARAMS CAKE_QDISC_EGR CAKE_QDISC_IGR

    cake_apply() {
        local ack_filter_egress_val CAKE_OPTS

        case "$DIR" in
            UP)
                case "$ACK_FILTER_EGRESS" in
                    # 'auto' needs a known download rate; keep the filter off without ingress shaping
                    auto) ack_filter_egress_val=$(( DOWNRATE > 0 && (DOWNRATE / UPRATE) >= 15 )) ;;
                    *[!0-9]*|'') qdisc_setup_failed "Invalid value '$ACK_FILTER_EGRESS' for ACK_FILTER_EGRESS." ;;
                    *) ack_filter_egress_val=$ACK_FILTER_EGRESS ;;
                esac

                CAKE_OPTS="bandwidth ${UPRATE}kbit"
                # shellcheck disable=SC2086
                append_cake_opt "$PRIORITY_QUEUE_EGRESS" "1" &&
                append_cake_opt "dual-srchost" "$HOST_ISOLATION" &&
                append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
                append_cake_opt "$CAKE_LINK_PARAMS" "1" &&
                append_cake_opt "$LINK_COMPENSATION" "1" &&
                append_cake_opt "$EXTRA_PARAMETERS_EGRESS" "1" &&
                append_cake_opt "nat" "$NAT_EGRESS" &&
                append_cake_opt "wash" "$WASHDSCPUP" &&
                append_cake_opt "ack-filter" "$ack_filter_egress_val" &&
                tc qdisc add dev "$WAN" root handle 1: "$CAKE_QDISC_EGR" $CAKE_OPTS || qdisc_setup_failed
                debug_log "EGRESS $CAKE_QDISC_EGR opts: '$CAKE_OPTS'" ;;
            DOWN)
                CAKE_OPTS="bandwidth ${DOWNRATE}kbit ingress"
                # shellcheck disable=SC2086
                append_cake_opt "autorate-ingress" "$AUTORATE_INGRESS" &&
                append_cake_opt "$PRIORITY_QUEUE_INGRESS" "1" &&
                append_cake_opt "dual-dsthost" "$HOST_ISOLATION" &&
                append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
                append_cake_opt "$CAKE_LINK_PARAMS" "1" &&
                append_cake_opt "$LINK_COMPENSATION" "1" &&
                append_cake_opt "$EXTRA_PARAMETERS_INGRESS" "1" &&
                append_cake_opt "nat" "$NAT_INGRESS" &&
                append_cake_opt "wash" "$WASHDSCPDOWN" &&
                tc qdisc add dev "$LAN" root "$CAKE_QDISC_IGR" $CAKE_OPTS || qdisc_setup_failed
                debug_log "INGRESS $CAKE_QDISC_IGR opts: '$CAKE_OPTS'" ;;
        esac
    }

    tc qdisc del dev "$WAN" root > /dev/null 2>&1
    tc qdisc del dev "$LAN" root > /dev/null 2>&1

    CAKE_LINK_PARAMS="$(get_cake_link_params)"

    # IFB mirrors the WAN queue count, so one probe decides both directions
    select_cake_qdisc "$WAN"
    CAKE_QDISC_EGR="$REPLY"
    CAKE_QDISC_IGR="$REPLY"

    for_each_shaped_dir cake_apply || return 1

    # Autorate reads the active cake variant from here
    printf '%s\n' "$CAKE_QDISC_EGR" > /tmp/qosmate/cake_type
}
:
