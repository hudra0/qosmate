#!/bin/sh
# shellcheck disable=SC3043,SC1091,SC2155,SC3020,SC3010,SC2016,SC2317,SC3060,SC3057,SC3003

VERSION="1.2.0" # will become obsolete in future releases as version string is now in the init script

_NL_='
'
DEFAULT_IFS=" 	${_NL_}"
IFS="$DEFAULT_IFS"

. /lib/functions.sh
config_load 'qosmate'

# Default values
DEFAULT_WAN="eth1"
DEFAULT_DOWNRATE="90000"
DEFAULT_UPRATE="45000"
DEFAULT_OH="44"

: "${VERSION}" "${DEFAULT_WAN}" "${DEFAULT_DOWNRATE}" "${DEFAULT_UPRATE}" "${DEFAULT_OH}" "${nongameqdisc:=}" "${nongameqdiscoptions:=}"

# Trim leading and trailing whitespaces and tabs in variable $1
trim_spaces() {
    local tr_in tr_out
    eval "tr_in=\"\${$1}\""
    tr_out="${tr_in%"${tr_in##*[! 	]}"}"
    tr_out="${tr_out#"${tr_out%%[! 	]*}"}"
    eval "$1=\"\${tr_out}\""
}

load_config() {
    # Global settings
    config_get ROOT_QDISC settings ROOT_QDISC hfsc
    config_get WAN settings WAN $DEFAULT_WAN
    config_get DOWNRATE settings DOWNRATE $DEFAULT_DOWNRATE
    config_get UPRATE settings UPRATE $DEFAULT_UPRATE

    # Advanced settings
    config_get PRESERVE_CONFIG_FILES advanced PRESERVE_CONFIG_FILES 0
    config_get WASHDSCPUP advanced WASHDSCPUP 1
    config_get WASHDSCPDOWN advanced WASHDSCPDOWN 1
    config_get BWMAXRATIO advanced BWMAXRATIO 20
    config_get ACKRATE advanced ACKRATE $((UPRATE * 5 / 100))
    config_get UDP_RATE_LIMIT_ENABLED advanced UDP_RATE_LIMIT_ENABLED 0
    config_get TCP_UPGRADE_ENABLED advanced TCP_UPGRADE_ENABLED 1
    config_get UDPBULKPORT advanced UDPBULKPORT
    config_get TCPBULKPORT advanced TCPBULKPORT
    config_get VIDCONFPORTS advanced VIDCONFPORTS
    config_get REALTIME4 advanced REALTIME4
    config_get REALTIME6 advanced REALTIME6
    config_get LOWPRIOLAN4 advanced LOWPRIOLAN4
    config_get LOWPRIOLAN6 advanced LOWPRIOLAN6
    config_get MSS advanced MSS 536
    config_get NFT_HOOK advanced NFT_HOOK forward
    config_get NFT_PRIORITY advanced NFT_PRIORITY 0
    config_get TCP_DOWNPRIO_INITIAL_ENABLED advanced TCP_DOWNPRIO_INITIAL_ENABLED 1
    config_get TCP_DOWNPRIO_SUSTAINED_ENABLED advanced TCP_DOWNPRIO_SUSTAINED_ENABLED 1

    # HFSC specific settings
    config_get LINKTYPE hfsc LINKTYPE ethernet
    config_get OH hfsc OH $DEFAULT_OH
    config_get gameqdisc hfsc gameqdisc pfifo
    config_get GAMEUP hfsc GAMEUP $((UPRATE*15/100+400))
    config_get GAMEDOWN hfsc GAMEDOWN $((DOWNRATE*15/100+400))
    config_get nongameqdisc hfsc nongameqdisc fq_codel
    config_get nongameqdiscoptions hfsc nongameqdiscoptions besteffort ack-filter
    config_get MAXDEL hfsc MAXDEL 24
    config_get PFIFOMIN hfsc PFIFOMIN 5
    config_get PACKETSIZE hfsc PACKETSIZE 450
    config_get netemdelayms hfsc netemdelayms 30
    config_get netemjitterms hfsc netemjitterms 7
    config_get netemdist hfsc netemdist normal
    config_get NETEM_DIRECTION hfsc netem_direction both
    config_get pktlossp hfsc pktlossp none

    # CAKE specific settings
    config_get COMMON_LINK_PRESETS cake COMMON_LINK_PRESETS ethernet
    config_get OVERHEAD cake OVERHEAD
    config_get MPU cake MPU
    config_get LINK_COMPENSATION cake LINK_COMPENSATION
    config_get ETHER_VLAN_KEYWORD cake ETHER_VLAN_KEYWORD
    config_get PRIORITY_QUEUE_INGRESS cake PRIORITY_QUEUE_INGRESS diffserv4
    config_get PRIORITY_QUEUE_EGRESS cake PRIORITY_QUEUE_EGRESS diffserv4
    config_get HOST_ISOLATION cake HOST_ISOLATION 1
    config_get NAT_INGRESS cake NAT_INGRESS 1
    config_get NAT_EGRESS cake NAT_EGRESS 0
    config_get ACK_FILTER_EGRESS cake ACK_FILTER_EGRESS auto
    config_get RTT cake RTT
    config_get AUTORATE_INGRESS cake AUTORATE_INGRESS 0
    config_get EXTRA_PARAMETERS_INGRESS cake EXTRA_PARAMETERS_INGRESS
    config_get EXTRA_PARAMETERS_EGRESS cake EXTRA_PARAMETERS_EGRESS

    # Calculated values
    FIRST500MS=$((DOWNRATE * 500 / 8))
    FIRST10S=$((DOWNRATE * 10000 / 8))
}

load_config

validate_and_adjust_rates() {
    if [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ]; then
        if [ -z "$DOWNRATE" ] || [ "$DOWNRATE" -eq 0 ]; then
            echo "Warning: DOWNRATE is zero or not set for $ROOT_QDISC. Setting to minimum value of 1000 kbps."
            DOWNRATE=1000
            uci set qosmate.settings.DOWNRATE=1000
        fi
        if [ -z "$UPRATE" ] || [ "$UPRATE" -eq 0 ]; then
            echo "Warning: UPRATE is zero or not set for $ROOT_QDISC. Setting to minimum value of 1000 kbps."
            UPRATE=1000
            uci set qosmate.settings.UPRATE=1000
        fi
        uci commit qosmate
    fi
}

validate_and_adjust_rates

# Adjust DOWNRATE based on BWMAXRATIO
if [ "$UPRATE" -gt 0 ] && [ $((DOWNRATE > UPRATE*BWMAXRATIO)) -eq 1 ]; then
    echo "We limit the downrate to at most $BWMAXRATIO times the upstream rate to ensure no upstream ACK floods occur which can cause game packet drops"
    DOWNRATE=$((BWMAXRATIO*UPRATE))
fi

##############################
# Function to preserve configuration files
##############################
preserve_config_files() {
    if [ "$PRESERVE_CONFIG_FILES" -eq 1 ]; then
        {
            echo "/etc/qosmate.sh"
            echo "/etc/init.d/qosmate"
            echo "/etc/hotplug.d/iface/13-qosmateHotplug" 
        } | while read LINE; do
            grep -qxF "$LINE" /etc/sysupgrade.conf || echo "$LINE" >> /etc/sysupgrade.conf
        done
        echo "Config files have been added to sysupgrade.conf for preservation."
    else
        echo "Preservation of config files is disabled."
             
        # Remove the config files from sysupgrade.conf if they exist
        sed -i '\|/etc/qosmate.sh|d' /etc/sysupgrade.conf
        sed -i '\|/etc/init.d/qosmate|d' /etc/sysupgrade.conf
        sed -i '\|/etc/hotplug.d/iface/13-qosmateHotplug|d' /etc/sysupgrade.conf
    fi
}

preserve_config_files

##############################
# Variable checks and dynamic rule generation
##############################

# Function to calculate different ACK rates based on the existing ACKRATE variable
calculate_ack_rates() {
    if [ -n "$ACKRATE" ] && [ "$ACKRATE" -gt 0 ]; then
        SLOWACKRATE=$ACKRATE
        MEDACKRATE=$ACKRATE
        FASTACKRATE=$(($ACKRATE * 10))
        XFSTACKRATE=$(($ACKRATE * 100))
    fi
}

# Call the function to perform the ACK rates calculations
calculate_ack_rates

# Function to check if a single IP address is IPv6
# Note: This assumes the input is a single IP, not a space-separated list
# Handles CIDR notation (e.g. ::/0 or 192.168.1.0/24)
is_ipv6() {
    local ip="${1%/*}"  # Remove CIDR suffix if present
    case "$ip" in
        *:*) return 0 ;;
        *) return 1 ;;
    esac
}

# checks whether string is an ipv6 mask
is_ipv6_mask() {
    case "$1" in
        ::*/::*) ;;
        *) return 1
    esac
    local inp="${1#"::"}"
    case "${inp%"/::"*}" in *"/"*) return 1; esac
    return 0
}

# checks whether string is nft set reference
is_set_ref() {
    case "$1" in "@"*) return 0; esac
    return 1
}

# Debug function
debug_log() {
    local message="$1"
    logger -t qosmate "$message"
}

# Function to create NFT sets from config
create_nft_sets() {
    local sets_created=""
    
    create_set() {
        local section="$1" name ip_list mode timeout set_flags

        config_get name "$section" name
        # Only process if enabled (default: enabled)
        local enabled=1
        config_get_bool enabled "$section" enabled 1
        [ "$enabled" -eq 0 ] && return 0

        config_get mode "$section" mode "static"
        config_get timeout "$section" timeout "1h"
        config_get family "$section" family "ipv4"

        # Get the IP list based on family
        if [ "$family" = "ipv6" ]; then
            config_get ip_list "$section" ip6
            echo "$name ipv6" >> /tmp/qosmate_set_families
        else
            config_get ip_list "$section" ip4
            echo "$name ipv4" >> /tmp/qosmate_set_families
        fi

        # Use the family parameter from the UCI configuration ("ipv4" or "ipv6")
        if [ "$mode" = "dynamic" ]; then
            set_flags="dynamic, timeout"
            if [ "$family" = "ipv6" ]; then
                debug_log "Creating dynamic IPv6 set: $name"
                echo "set $name { type ipv6_addr; flags $set_flags; timeout $timeout; }"
            else
                debug_log "Creating dynamic IPv4 set: $name"
                echo "set $name { type ipv4_addr; flags $set_flags; timeout $timeout; }"
            fi
        else
            set_flags="interval"
            if [ -n "$ip_list" ]; then
                if [ "$family" = "ipv6" ]; then
                    debug_log "Creating static IPv6 set: $name"
                    echo "set $name { type ipv6_addr; flags $set_flags; elements = { $(echo "$ip_list" | tr ' ' ',') }; }"
                else
                    debug_log "Creating static IPv4 set: $name"
                    echo "set $name { type ipv4_addr; flags $set_flags; elements = { $(echo "$ip_list" | tr ' ' ',') }; }"
                fi
            else
                if [ "$family" = "ipv6" ]; then
                    debug_log "Creating empty static IPv6 set: $name"
                    echo "set $name { type ipv6_addr; flags $set_flags; }"
                else
                    debug_log "Creating empty static IPv4 set: $name"
                    echo "set $name { type ipv4_addr; flags $set_flags; }"
                fi
            fi
        fi
        sets_created="$sets_created $name"
    }
    
    # Clear the temporary file
    rm -f /tmp/qosmate_set_families
    
    config_foreach create_set ipset
    
    export QOSMATE_SETS="$sets_created"
    [ -n "$sets_created" ] && debug_log "Created sets: $sets_created"
}

# Create NFT sets
SETS=$(create_nft_sets)

# Create rules
create_nft_rule() {
    local config="$1"
    local src_ip src_port dest_ip dest_port proto class counter name enabled trace
    config_get src_ip "$config" src_ip
    config_get src_port "$config" src_port
    config_get dest_ip "$config" dest_ip
    config_get dest_port "$config" dest_port
    config_get proto "$config" proto
    config_get class "$config" class
    config_get_bool counter "$config" counter 0
    config_get_bool trace "$config" trace 0
    config_get name "$config" name
    config_get_bool enabled "$config" enabled 1  # Default to enabled if not set

    # Check if the rule is enabled
    [ "$enabled" = "0" ] && return 0

    # Convert class to lowercase
    class=$(echo "$class" | tr 'A-Z' 'a-z')

    # Ensure class is not empty
    if [ -z "$class" ]; then
        echo "Error: Class for rule '$config' is empty."
        return 1
    fi
    
    # Function to get set family
    get_set_family() {
        local setname="$1"
        [ -f /tmp/qosmate_set_families ] && awk -v set="$setname" '$1 == set {print $2}' /tmp/qosmate_set_families
    }
    
    # Early check for mixed IPv4/IPv6
    local has_ipv4=0
    local has_ipv6=0
    
    # Variables to store filtered IPs for mixed rules
    local src_ip_v4=""
    local src_ip_v6=""
    local dest_ip_v4=""
    local dest_ip_v6=""
    
    # Function to separate IPs by family
    separate_ips_by_family() {
        local ips="$3" \
            ip prefix setname \
            ipv4_result="" \
            ipv6_result=""
        
        # Debug log (uncomment for troubleshooting)
        # debug_log "separate_ips_by_family: Processing IPs: '$ips'"
        
        for ip in $ips; do
            # Preserve != prefix
            prefix=""
            case "$ip" in '!='*)
                prefix="!="
                ip="${ip#"!="}"
            esac
            
            # debug_log "  Checking IP: '$ip'
            
            # Check if it's a set reference
            if is_set_ref "$ip"; then
                setname="${ip#"@"}"
                if [ "$(get_set_family "$setname")" = "ipv6" ]; then
                    ipv6_result="${ipv6_result}${ipv6_result:+ }${prefix}${ip}"
                    # debug_log "    -> IPv6 set: $setname"
                else
                    ipv4_result="${ipv4_result}${ipv4_result:+ }${prefix}${ip}"
                    # debug_log "    -> IPv4 set: $setname"
                fi
            # Check for IPv6 suffix format
            elif is_ipv6_mask "$ip"; then
                ipv6_result="${ipv6_result}${ipv6_result:+ }${prefix}${ip}"
                # debug_log "    -> IPv6 suffix format"
            # Regular IP check
            elif is_ipv6 "$ip"; then
                ipv6_result="${ipv6_result}${ipv6_result:+ }${prefix}${ip}"
                # debug_log "    -> IPv6 address"
            else
                ipv4_result="${ipv4_result}${ipv4_result:+ }${prefix}${ip}"
                # debug_log "    -> IPv4 address"
            fi
        done
        
        # debug_log "  Results: IPv4='$ipv4_result', IPv6='$ipv6_result'"
        eval "${1}=\"\${ipv4_result}\" ${2}=\"\${ipv6_result}\""
    }
    
    # Check and separate source IPs
    if [ -n "$src_ip" ]; then
        separate_ips_by_family src_ip_v4 src_ip_v6 "$src_ip"
        [ -n "$src_ip_v4" ] && has_ipv4=1
        [ -n "$src_ip_v6" ] && has_ipv6=1
    fi
    
    # Check and separate destination IPs
    if [ -n "$dest_ip" ]; then
        separate_ips_by_family dest_ip_v4 dest_ip_v6 "$dest_ip"
        [ -n "$dest_ip_v4" ] && has_ipv4=1
        [ -n "$dest_ip_v6" ] && has_ipv6=1
    fi
    
    # Log if mixed IPv4/IPv6 addresses are found
    if [ "$has_ipv4" -eq 1 ] && [ "$has_ipv6" -eq 1 ]; then 
        logger -t qosmate "Info: Mixed IPv4/IPv6 addresses in rule '$name' ($config). Splitting into separate rules."
    fi

    # If no IP address was specified, we assume the rule applies to both IPv4 and IPv6
    if [ -z "$src_ip" ] && [ -z "$dest_ip" ] && [ "$has_ipv4" -eq 0 ] && [ "$has_ipv6" -eq 0 ]; then
        debug_log "Rule '$name' ($config): No IP specified, generating rules for both IPv4 and IPv6."
        has_ipv4=1
        has_ipv6=1
    fi

    # Initialize rule string
    local rule_cmd=""

    # Function to handle multiple values with IP family awareness
    gen_rule() {
        local value setname family suffix mask comp_op negation \
            result='' res_set_neg='' res_set_pos='' has_ipv4='' has_ipv6='' set_ref_seen='' ipv6_mask_seen='' reg_val_seen='' \
            values="$1" \
            prefix="$2"
        
        for value in $values; do
            if [ -n "$set_ref_seen" ] || [ -n "$ipv6_mask_seen" ]; then
                logger -t qosmate "Error: invalid entry '$values'. When using nftables set reference or ipv6 mask, other values are not allowed."
                return 1
            fi

            # Check if value starts with '!=' and preserve the '!=' prefix
            negation=
            comp_op="=="
            case "$value" in '!='*)
                negation=" !="
                comp_op="!="
                value="${value#"!="}"
            esac

            # Handle set references (@setname)
            if is_set_ref "$value"; then
                if [ -n "$reg_val_seen" ]; then
                    logger -t qosmate "Error: invalid entry '$values'. When using nftables set reference or ipv6 mask, other values are not allowed."
                    return 1
                fi
                set_ref_seen=1
                setname="${value#@}"
                family="$(get_set_family "$setname")"
                debug_log "Set $setname has family: $family"
                
                if [ "$family" = "ipv6" ]; then
                    prefix="${prefix//ip /ip6 }"
                fi
                result="${prefix}${negation} @${setname}"
                continue
            fi

            # Check for IPv6 suffix format (::suffix/::mask)
            if is_ipv6_mask "$value"; then
                if [ -n "$reg_val_seen" ]; then
                    logger -t qosmate "Error: invalid entry '$values'. When using nftables set reference or ipv6 mask, other values are not allowed."
                    return 1
                fi
                ipv6_mask_seen=1
                # Extract suffix and mask
                suffix="${value%%"/::"*}"
                mask="${value#"${suffix}/"}"
                
                # Force IPv6 prefix and create bitwise AND|NOT match
                result="${prefix//ip /ip6 } & ${mask} ${comp_op} ${suffix}"
                continue
            fi

            # Collect values based on prefix type
            case "$prefix" in 
                *addr*)
                    # IP address handling
                    reg_val_seen=1
                    if is_ipv6 "$value"; then
                        has_ipv6=1
                    else
                        has_ipv4=1
                    fi
                    
                    if [ -n "$negation" ]; then
                        res_set_neg="${res_set_neg}${res_set_neg:+,}${value}"
                    else
                        res_set_pos="${res_set_pos}${res_set_pos:+,}${value}"
                    fi
                    ;;
                    
                "th sport"|"th dport")
                    # Port handling - no IPv4/IPv6 distinction needed
                    reg_val_seen=1
                    if [ -n "$negation" ]; then
                        res_set_neg="${res_set_neg}${res_set_neg:+,}${value}"
                    else
                        res_set_pos="${res_set_pos}${res_set_pos:+,}${value}"
                    fi
                    ;;
                    
                "meta l4proto")
                    # Protocol handling
                    reg_val_seen=1
                    if [ -n "$negation" ]; then
                        res_set_neg="${res_set_neg}${res_set_neg:+,}${value}"
                    else
                        res_set_pos="${res_set_pos}${res_set_pos:+,}${value}"
                    fi
                    ;;
                *)
                    logger -t qosmate "Error: unexpected data in '$prefix'."
                    return 1
                    ;;
            esac
        done

        if [ -n "$set_ref_seen" ] || [ -n "$ipv6_mask_seen" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        # If mixed, log and signal error
        if [ -n "$has_ipv4" ] && [ -n "$has_ipv6" ]; then
            logger -t qosmate "Error: Mixed IPv4/IPv6 addresses within a set: { $values }. Rule skipped."
            return 1
        fi

        # Update prefix based on IP type
        if [ -n "$has_ipv6" ]; then
            prefix="${prefix//ip /ip6 }"
        fi

        # Construct the final rule
        case "$prefix" in
            *addr*)
                # IP address rules
                if [ -z "$res_set_neg" ] && [ -z "$res_set_pos" ]; then
                    logger -t qosmate "Error: no valid values found in '$values'. Rule skipped."
                    return 1
                fi

                if [ -n "$res_set_neg" ]; then
                    result="${result}${result:+ }${prefix} != { ${res_set_neg} }"
                fi

                if [ -n "$res_set_pos" ]; then
                    result="${result}${result:+ }${prefix} { ${res_set_pos} }"
                fi 
                ;;
                
            "th sport"|"th dport")
                # Port rules
                if [ -z "$res_set_neg" ] && [ -z "$res_set_pos" ]; then
                    logger -t qosmate "Error: no valid ports found in '$values'. Rule skipped."
                    return 1
                fi
                
                if [ -n "$res_set_neg" ]; then
                    result="${result}${result:+ }${prefix} != { ${res_set_neg} }"
                fi
                
                if [ -n "$res_set_pos" ]; then
                    result="${result}${result:+ }${prefix} { ${res_set_pos} }"
                fi
                ;;
                
            "meta l4proto")
                # Protocol rules
                if [ -z "$res_set_neg" ] && [ -z "$res_set_pos" ]; then
                    logger -t qosmate "Error: no valid protocols found in '$values'. Rule skipped."
                    return 1
                fi
                
                if [ -n "$res_set_neg" ]; then
                    result="${result}${result:+ }${prefix} != { ${res_set_neg} }"
                fi
                
                if [ -n "$res_set_pos" ]; then
                    result="${result}${result:+ }${prefix} { ${res_set_pos} }"
                fi
                ;;
        esac

        printf '%s\n' "$result"
    }

    # Handle multiple protocols
    if [ -n "$proto" ]; then
        local proto_result
        if ! proto_result="$(gen_rule "$proto" "meta l4proto")"; then
            # Skip rule
            return 0
        fi
        rule_cmd="$rule_cmd $proto_result"
    fi

    # Note: Source IP handling is now done per-family in the rule generation below
    
    # Use connection tracking for source port
    if [ -n "$src_port" ]; then
        local src_port_result
        if ! src_port_result="$(gen_rule "$src_port" "th sport")"; then
            # Skip rule
            return 0
        fi
        rule_cmd="$rule_cmd $src_port_result"
    fi

    # Note: Destination IP handling is now done per-family in the rule generation below
    
    # Use connection tracking for destination port
    if [ -n "$dest_port" ]; then
        local dest_port_result
        if ! dest_port_result="$(gen_rule "$dest_port" "th dport")"; then
            # Skip rule
            return 0
        fi
        rule_cmd="$rule_cmd $dest_port_result"
    fi
    
    # Build final rule(s) based on has_ipv4 and has_ipv6 flags
    local final_rule_v4=""
    local final_rule_v6=""
    local common_rule_part="$rule_cmd"
    trim_spaces common_rule_part # Trim common parts

    # Generate IPv4 rule if needed
    if [ "$has_ipv4" -eq 1 ]; then
        local rule_cmd_v4="$common_rule_part"
        
        # Add IPv4-specific IP addresses
        if [ -n "$src_ip_v4" ]; then
            local src_result
            if ! src_result="$(gen_rule "$src_ip_v4" "ip saddr")"; then
                # Skip rule
                return 0
            fi
            rule_cmd_v4="$rule_cmd_v4 $src_result"
        fi
        if [ -n "$dest_ip_v4" ]; then
            local dest_result
            if ! dest_result="$(gen_rule "$dest_ip_v4" "ip daddr")"; then
                # Skip rule
                return 0
            fi
            rule_cmd_v4="$rule_cmd_v4 $dest_result"
        fi
        
        # Ensure we only add parts if there's something to match on (IP/Port/Proto)
        if [ -n "$proto" ] || [ -n "$src_ip_v4" ] || [ -n "$dest_ip_v4" ] || [ -n "$src_port" ] || [ -n "$dest_port" ]; then
            rule_cmd_v4="$rule_cmd_v4 ip dscp set $class"
        fi
        [ "$counter" -eq 1 ] && rule_cmd_v4="$rule_cmd_v4 counter"
        [ "$trace" -eq 1 ] && rule_cmd_v4="$rule_cmd_v4 meta nftrace set 1"
        [ -n "$name" ] && rule_cmd_v4="$rule_cmd_v4 comment \"ipv4_$name\""
            
        trim_spaces rule_cmd_v4 # Trim final rule
        # Ensure the rule is not just a semicolon
        if [ -n "$rule_cmd_v4" ] && [ "$rule_cmd_v4" != ";" ]; then
            final_rule_v4="$rule_cmd_v4;"
        fi
    fi

    # Generate IPv6 rule if needed
    if [ "$has_ipv6" -eq 1 ]; then
        local rule_cmd_v6="$common_rule_part"
        
        # Add IPv6-specific IP addresses
        if [ -n "$src_ip_v6" ]; then
            local src_result
            if ! src_result="$(gen_rule "$src_ip_v6" "ip6 saddr")"; then
                # Skip rule
                return 0
            fi
            rule_cmd_v6="$rule_cmd_v6 $src_result"
        fi
        if [ -n "$dest_ip_v6" ]; then
            local dest_result
            if ! dest_result="$(gen_rule "$dest_ip_v6" "ip6 daddr")"; then
                # Skip rule
                return 0
            fi
            rule_cmd_v6="$rule_cmd_v6 $dest_result"
        fi
        
        # Ensure we only add parts if there's something to match on (IP/Port/Proto)
        if [ -n "$proto" ] || [ -n "$src_ip_v6" ] || [ -n "$dest_ip_v6" ] || [ -n "$src_port" ] || [ -n "$dest_port" ]; then
            rule_cmd_v6="$rule_cmd_v6 ip6 dscp set $class"
        fi
        [ "$counter" -eq 1 ] && rule_cmd_v6="$rule_cmd_v6 counter"
        [ "$trace" -eq 1 ] && rule_cmd_v6="$rule_cmd_v6 meta nftrace set 1"
        [ -n "$name" ] && rule_cmd_v6="$rule_cmd_v6 comment \"ipv6_$name\""

        trim_spaces rule_cmd_v6 # Trim final rule
        # Ensure the rule is not just a semicolon
        if [ -n "$rule_cmd_v6" ] && [ "$rule_cmd_v6" != ";" ]; then
             final_rule_v6="$rule_cmd_v6;"
        fi
    fi

    # Output the generated rules (if any)
    [ -n "$final_rule_v4" ] && echo "$final_rule_v4"
    [ -n "$final_rule_v6" ] && echo "$final_rule_v6"

}

generate_dynamic_nft_rules() {
    # Check global enable setting
    local global_enabled
    config_get_bool global_enabled global enabled 1  # Default to enabled if not set
    
    if [ "$global_enabled" = "1" ]; then
        config_foreach create_nft_rule rule
    else
        echo "# QoSmate rules are globally disabled"
    fi
}

# Generate dynamic rules
DYNAMIC_RULES=$(generate_dynamic_nft_rules)

# Check if ACKRATE is greater than 0
if [ "$ACKRATE" -gt 0 ]; then
    ack_rules="\
meta length < 100 tcp flags ack add @xfst4ack {ct id . ct direction limit rate over ${XFSTACKRATE}/second} counter jump drop995
        meta length < 100 tcp flags ack add @fast4ack {ct id . ct direction limit rate over ${FASTACKRATE}/second} counter jump drop95
        meta length < 100 tcp flags ack add @med4ack {ct id . ct direction limit rate over ${MEDACKRATE}/second} counter jump drop50
        meta length < 100 tcp flags ack add @slow4ack {ct id . ct direction limit rate over ${SLOWACKRATE}/second} counter jump drop50"
else
    ack_rules="# ACK rate regulation disabled as ACKRATE=0 or not set."
fi

# Check if UDPBULKPORT is set
if [ -n "$UDPBULKPORT" ]; then
    udpbulkport_rules="\
meta l4proto udp ct original proto-src \$udpbulkport counter jump mark_cs1
        meta l4proto udp ct original proto-dst \$udpbulkport counter jump mark_cs1"
else
    udpbulkport_rules="# UDP Bulk Port rules disabled, no ports defined."
fi

# Check if TCPBULKPORT is set
if [ -n "$TCPBULKPORT" ]; then
    tcpbulkport_rules="\
meta l4proto tcp ct original proto-dst \$tcpbulkport counter jump mark_cs1"
else
    tcpbulkport_rules="# TCP Bulk Port rules disabled, no ports defined."
fi

# Check if VIDCONFPORTS is set
if [ -n "$VIDCONFPORTS" ]; then
    vidconfports_rules="\
meta l4proto udp ct original proto-dst \$vidconfports counter jump mark_af42"
else
    vidconfports_rules="# VIDCONFPORTS Port rules disabled, no ports defined."
fi

# Check if REALTIME4 and REALTIME6 are set
if [ -n "$REALTIME4" ]; then
    realtime4_rules="\
meta l4proto udp ip daddr \$realtime4 ip dscp set cs5 counter
        meta l4proto udp ip saddr \$realtime4 ip dscp set cs5 counter"
else
    realtime4_rules="# REALTIME4 rules disabled, address not defined."
fi

if [ -n "$REALTIME6" ]; then
    realtime6_rules="\
meta l4proto udp ip6 daddr \$realtime6 ip6 dscp set cs5 counter
        meta l4proto udp ip6 saddr \$realtime6 ip6 dscp set cs5 counter"
else
    realtime6_rules="# REALTIME6 rules disabled, address not defined."
fi

# Check if LOWPRIOLAN4 and LOWPRIOLAN6 are set
if [ -n "$LOWPRIOLAN4" ]; then
    lowpriolan4_rules="\
meta l4proto udp ip daddr \$lowpriolan4 ip dscp set cs0 counter
        meta l4proto udp ip saddr \$lowpriolan4 ip dscp set cs0 counter"
else
    lowpriolan4_rules="# LOWPRIOLAN4 rules disabled, address not defined."
fi

if [ -n "$LOWPRIOLAN6" ]; then
    lowpriolan6_rules="\
meta l4proto udp ip6 daddr \$lowpriolan6 ip6 dscp set cs0 counter
        meta l4proto udp ip6 saddr \$lowpriolan6 ip6 dscp set cs0 counter"
else
    lowpriolan6_rules="# LOWPRIOLAN6 rules disabled, address not defined."
fi

# Check if UDP rate limiting should be applied
if [ "$UDP_RATE_LIMIT_ENABLED" -eq 1 ]; then
    udp_rate_limit_rules="\
meta l4proto udp ip dscp > cs2 add @udp_meter {ct id . ct direction limit rate over 450/second} counter ip dscp set cs0 counter
        meta l4proto udp ip6 dscp > cs2 add @udp_meter {ct id . ct direction limit rate over 450/second} counter ip6 dscp set cs0 counter"
else
    udp_rate_limit_rules="# UDP rate limiting is disabled."
fi

# Check if TCP upgrade for slow connections should be applied
if [ "$TCP_UPGRADE_ENABLED" -eq 1 ]; then
    tcp_upgrade_rules="
meta l4proto tcp ip dscp != cs1 add @slowtcp {ct id . ct direction limit rate 150/second burst 150 packets } ip dscp set af42 counter
        meta l4proto tcp ip6 dscp != cs1 add @slowtcp {ct id . ct direction limit rate 150/second burst 150 packets} ip6 dscp set af42 counter"
else
    tcp_upgrade_rules="# TCP upgrade for slow connections is disabled"
fi

# Conditionally defining TCP down-prioritization rules based on enabled flags
if [ "$TCP_DOWNPRIO_INITIAL_ENABLED" -eq 1 ]; then
    downprio_initial_rules="meta l4proto tcp ct bytes < \$first500ms jump mark_500ms"
else
    downprio_initial_rules="# Initial TCP down-prioritization disabled"
fi

if [ "$TCP_DOWNPRIO_SUSTAINED_ENABLED" -eq 1 ]; then
    downprio_sustained_rules="meta l4proto tcp ct bytes > \$first10s jump mark_10s"
else
    downprio_sustained_rules="# Sustained TCP down-prioritization disabled"
fi

# Conditionally defining TCPMSS rules based on UPRATE and DOWNRATE

if [ "$UPRATE" -lt 3000 ]; then
    # Clamp MSS between 536 and 1500
    SAFE_MSS=$(( MSS > 1500 ? 1500 : (MSS < 536 ? 536 : MSS) ))
    RULE_SET_TCPMSS_UP="meta oifname \"$WAN\" tcp flags syn tcp option maxseg size set $SAFE_MSS counter;"
else
    RULE_SET_TCPMSS_UP=''
fi

if [ "$DOWNRATE" -lt 3000 ]; then
    # Clamp MSS between 536 and 1500
    SAFE_MSS=$(( MSS > 1500 ? 1500 : (MSS < 536 ? 536 : MSS) ))
    RULE_SET_TCPMSS_DOWN="meta iifname \"$WAN\" tcp flags syn tcp option maxseg size set $SAFE_MSS counter;"
else
    RULE_SET_TCPMSS_DOWN=''
fi

##############################
#       dscptag.nft
##############################

## Check if the folder does not exist
if [ ! -d "/usr/share/nftables.d/ruleset-post" ]; then
    mkdir -p "/usr/share/nftables.d/ruleset-post"
fi

cat << DSCPEOF > /usr/share/nftables.d/ruleset-post/dscptag.nft

define udpbulkport = {$UDPBULKPORT}
define tcpbulkport = {$TCPBULKPORT}
define vidconfports = {$VIDCONFPORTS}
define realtime4 = {$REALTIME4}
define realtime6 = {$REALTIME6}
define lowpriolan4 = {$LOWPRIOLAN4}
define lowpriolan6 = {$LOWPRIOLAN6}

define downrate = $DOWNRATE
define uprate = $UPRATE

define first500ms = $FIRST500MS
define first10s = $FIRST10S

define wan = "$WAN"


table inet dscptag # forward declaration so the next command always works

delete table inet dscptag # clear all the rules

table inet dscptag {

    map priomap { type dscp : classid ;
        elements =  {ef : 1:11, cs5 : 1:11, cs6 : 1:11, cs7 : 1:11,
                    cs4 : 1:12 , af41 : 1:12, af42 : 1:12,
                    cs2 : 1:14 , af11 : 1:14 , cs1 : 1:15, cs0 : 1:13}
    }

# Create sets first
${SETS}

    set xfst4ack { typeof ct id . ct direction
        flags dynamic;
        timeout 5m
    }

    set fast4ack { typeof ct id . ct direction
        flags dynamic;
        timeout 5m
    }
    set med4ack { typeof ct id . ct direction
        flags dynamic;
        timeout 5m
    }
    set slow4ack { typeof ct id . ct direction
        flags dynamic;
        timeout 5m
    }
    set udp_meter {typeof ct id . ct direction
        flags dynamic;
        timeout 5m
    }
    set slowtcp {typeof ct id . ct direction
        flags dynamic;
        timeout 5m
    }

    chain drop995 {
	numgen random mod 1000 ge 995 return
	drop
    }
    chain drop95 {
	numgen random mod 1000 ge 950 return
	drop
    }
    chain drop50 {
	numgen random mod 1000 ge 500 return
	drop
    }

    chain mark_500ms {
        ip dscp < cs4 ip dscp != cs1 ip dscp set cs0 counter return
        ip6 dscp < cs4 ip6 dscp != cs1 ip6 dscp set cs0 counter
    }
    chain mark_10s {
        ip dscp < cs4 ip dscp set cs1 counter return
        ip6 dscp < cs4 ip6 dscp set cs1 counter
    }

    chain mark_cs0 {
        ip dscp set cs0 return
        ip6 dscp set cs0
    }
    chain mark_cs1 {
        ip dscp set cs1 return
        ip6 dscp set cs1
    }
    chain mark_af42 {
        ip dscp set af42 return
        ip6 dscp set af42
    }

    chain dscptag {
        type filter hook $NFT_HOOK priority $NFT_PRIORITY; policy accept;

        iif "lo" accept    
        $(if { [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ]; } && [ "$WASHDSCPDOWN" -eq 1 ]; then
            echo "# wash all the DSCP on ingress ... "
            echo "        counter jump mark_cs0"
          fi
        )
        
        # Skip rule processing for ingress packets since they're already classified by tc-ctinfo
        meta iifname "$WAN" accept

        $RULE_SET_TCPMSS_UP
        $RULE_SET_TCPMSS_DOWN

        $udpbulkport_rules

        $tcpbulkport_rules

        $ack_rules

        $vidconfports_rules

        $realtime4_rules

        $realtime6_rules

        $lowpriolan4_rules

        $lowpriolan6_rules

        $udp_rate_limit_rules
        
        # down prioritize the first 500ms of tcp packets
        $downprio_initial_rules

        # downgrade tcp that has transferred more than 10 seconds worth of packets
        $downprio_sustained_rules

        $tcp_upgrade_rules
        
${DYNAMIC_RULES}

        ## classify for the HFSC queues:
        meta priority set ip dscp map @priomap counter
        meta priority set ip6 dscp map @priomap counter

        # Store DSCP in conntrack for restoration on ingress
        ct mark set ip dscp or 128 counter
        ct mark set ip6 dscp or 128 counter

        $(if { [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ]; } && [ "$WASHDSCPUP" -eq 1 ]; then
            echo "# wash all DSCP on egress ... "
            echo "meta oifname \$wan jump mark_cs0"
          fi
        )
    }
}
DSCPEOF

## Set up ctinfo downstream shaping

# Set up ingress handle for WAN interface
tc qdisc add dev $WAN handle ffff: ingress

# Create IFB interface
ip link add name ifb-$WAN type ifb
ip link set ifb-$WAN up

# Redirect ingress traffic from WAN to IFB and restore DSCP from conntrack
tc filter add dev $WAN parent ffff: protocol all matchall action ctinfo dscp 63 128 mirred egress redirect dev ifb-$WAN
LAN=ifb-$WAN

cat <<EOF

This script prioritizes the UDP packets from / to a set of gaming
machines into a real-time HFSC queue with guaranteed total bandwidth 

Based on your settings:

Game upload guarantee = $GAMEUP kbps
Game download guarantee = $GAMEDOWN kbps

Download direction only works if you install this on a *wired* router
and there is a separate AP wired into your network, because otherwise
there are multiple parallel queues for traffic to leave your router
heading to the LAN.

Based on your link total bandwidth, the **minimum** amount of jitter
you should expect in your network is about:

UP = $(((1500*8)*3/UPRATE)) ms

DOWN = $(((1500*8)*3/DOWNRATE)) ms

In order to get lower minimum jitter you must upgrade the speed of
your link, no queuing system can help.

Please note for your display rate that:

at 30Hz, one on screen frame lasts:   33.3 ms
at 60Hz, one on screen frame lasts:   16.6 ms
at 144Hz, one on screen frame lasts:   6.9 ms

This means the typical gamer is sensitive to as little as on the order
of 5ms of jitter. To get 5ms minimum jitter you should have bandwidth
in each direction of at least:

$((1500*8*3/5)) kbps

The queue system can ONLY control bandwidth and jitter in the link
between your router and the VERY FIRST device in the ISP
network. Typically you will have 5 to 10 devices between your router
and your gaming server, any of those can have variable delay and ruin
your gaming, and there is NOTHING that your router can do about it.

EOF


##############################
#       QoS Setup Functions
##############################

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
            proto=ip prio=1 match_str="ip dsfield $dsfield 0xfc"
            ;;
        ipv6)
            proto=ipv6 prio=2 match_str="u16 $hex_match 0x0FC0 at 0"
            ;;
    esac

    tc filter add dev "$dev" parent 1: protocol "$proto" prio "$prio" u32 match $match_str classid "$class_id"
}

# Function to setup the specific game qdisc (pfifo, red, fq_codel, netem, etc.)
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:QDISC_TYPE, $5:DIR, $6:MTU, ... HFSC params ...
setup_game_qdisc() {
    local DEV="$1" RATE="$2" GAMERATE="$3" QDISC_TYPE="$4" DIR="$5" MTU="$6"
    local MAXDEL="$7" PFIFOMIN="$8" PACKETSIZE="$9"
    local netemdelayms="${10}" netemjitterms="${11}" netemdist="${12}" NETEM_DIRECTION="${13}" pktlossp="${14}"

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
            tc qdisc add dev "$DEV" parent 10:1 handle 11: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:2 drr quantum 4000
            tc qdisc add dev "$DEV" parent 10:2 handle 12: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:3 drr quantum 1000
            tc qdisc add dev "$DEV" parent 10:3 handle 13: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit probability 1.0 burst $BURST
        ;;
        "qfq")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: qfq
            tc class add dev "$DEV" parent 10: classid 10:1 qfq weight 8000
            tc qdisc add dev "$DEV" parent 10:1 handle 11: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:2 qfq weight 4000
            tc qdisc add dev "$DEV" parent 10:2 handle 12: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit probability 1.0 burst $BURST
            tc class add dev "$DEV" parent 10: classid 10:3 qfq weight 1000
            tc qdisc add dev "$DEV" parent 10:3 handle 13: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit probability 1.0 burst $BURST
        ;;
        "pfifo")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
        "bfifo")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: bfifo limit $((MAXDEL * GAMERATE / 8))
            #tc qdisc add dev "$DEV" parent 1:11 handle 10: bfifo limit $((MAXDEL * RATE / 8))
        ;;
        "red")
            tc qdisc add dev "$DEV" parent 1:11 handle 10: red limit 150000 min $REDMIN max $REDMAX avpkt 500 bandwidth ${RATE}kbit burst $BURST probability 1.0
            ## send game packets to 10:, they're all treated the same
        ;;
        "fq_codel")
        tc qdisc add dev "$DEV" parent "1:11" fq_codel memory_limit $((RATE*200/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))
        ;;
        "netem")
            # Only apply NETEM if this direction is enabled
            if [ "$NETEM_DIRECTION" = "both" ] || \
               { [ "$NETEM_DIRECTION" = "egress" ] && [ "$DIR" = "wan" ]; } || \
               { [ "$NETEM_DIRECTION" = "ingress" ] && [ "$DIR" = "lan" ]; }; then
                
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
                # Use pfifo as fallback when NETEM is not applied in this direction
                tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
            fi
        ;;
        *)
            echo "Error: Unsupported game qdisc type '$QDISC_TYPE'. Using pfifo fallback." >&2
            # pfifo fallback limit calculation
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
    esac
}

# Function to setup HFSC qdisc structure
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:GAME_QDISC_TYPE, $5:DIR
setup_hfsc() {
    local DEV=$1 RATE=$2 GAMERATE=$3 GAME_QDISC_TYPE=$4 DIR=$5
    local MTU=1500

    tc qdisc del dev "$DEV" root > /dev/null 2>&1

    # Overhead logic
    local TC_OH_PARAMS=""
    case $LINKTYPE in
        "atm")
            TC_OH_PARAMS="stab mtu 2047 tsize 512 mpu 68 overhead ${OH} linklayer atm"
            ;;
        "DOCSIS")
            TC_OH_PARAMS="stab overhead 25 linklayer ethernet"
            ;;
        *)
            TC_OH_PARAMS="stab overhead 40 linklayer ethernet"
            ;;
    esac
    # Apply root qdisc
    tc qdisc replace dev "$DEV" handle 1: root ${TC_OH_PARAMS} hfsc default 13

    # DUR calculation
    local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25

    # Router traffic class (only on LAN/IFB)
    if [ "$DIR" = "lan" ]; then
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

    # Attach Qdiscs
    setup_game_qdisc "$DEV" "$RATE" "$GAMERATE" "$GAME_QDISC_TYPE" "$DIR" \
                     "$MTU" "$MAXDEL" "$PFIFOMIN" "$PACKETSIZE" \
                     "$netemdelayms" "$netemjitterms" "$netemdist" "$NETEM_DIRECTION" "$pktlossp"

    # Attach non-game qdiscs
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))
    for i in 12 13 14 15; do 
        if [ "$nongameqdisc" = "cake" ]; then
            tc qdisc add dev "$DEV" parent "1:$i" cake $nongameqdiscoptions
        elif [ "$nongameqdisc" = "fq_codel" ]; then
            tc qdisc add dev "$DEV" parent "1:$i" fq_codel memory_limit $((RATE*200/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))
        else
            echo "Unsupported qdisc for non-game traffic: $nongameqdisc"
            exit 1
        fi
    done

    # Apply DSCP Filters (only on LAN/IFB)
    if [ "$DIR" = "lan" ]; then
        # Delete existing filters first
        tc filter del dev "$DEV" parent 1: prio 1 > /dev/null 2>&1
        tc filter del dev "$DEV" parent 1: prio 2 > /dev/null 2>&1 # Also delete prio 2

        local family class_enum
        for family in ipv4 ipv6; do
            for class_enum in ef cs5 cs6 cs7 cs4 af41 af42 cs2 af11 cs1 cs0; do
                add_tc_filter "$DEV" "$class_enum" "$family"
            done
        done
    fi
}


# Function to setup CAKE qdisc
setup_cake() {
    tc qdisc del dev "$WAN" root > /dev/null 2>&1
    tc qdisc del dev "$LAN" root > /dev/null 2>&1
    
    # Egress (Upload) CAKE setup
    EGRESS_CAKE_OPTS="bandwidth ${UPRATE}kbit"
    [ -n "$PRIORITY_QUEUE_EGRESS" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS $PRIORITY_QUEUE_EGRESS"
    [ "$HOST_ISOLATION" -eq 1 ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS dual-srchost"
    [ "$NAT_EGRESS" -eq 1 ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS nat" || EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS nonat"
    
    [ "$WASHDSCPUP" -eq 1 ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS wash" || EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS nowash"
    
    if [ "$ACK_FILTER_EGRESS" = "auto" ]; then
        if [ $((DOWNRATE / UPRATE)) -ge 15 ]; then
            EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS ack-filter"
        else
            EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS no-ack-filter"
        fi
    elif [ "$ACK_FILTER_EGRESS" -eq 1 ]; then
        EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS ack-filter"
    else
        EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS no-ack-filter"
    fi
    
    [ -n "$RTT" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS rtt ${RTT}ms"
    [ -n "$COMMON_LINK_PRESETS" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS $COMMON_LINK_PRESETS"
    [ -n "$LINK_COMPENSATION" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS $LINK_COMPENSATION" || EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS noatm"
    [ -n "$OVERHEAD" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS overhead $OVERHEAD"
    [ -n "$MPU" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS mpu $MPU"
    [ -n "$EXTRA_PARAMETERS_EGRESS" ] && EGRESS_CAKE_OPTS="$EGRESS_CAKE_OPTS $EXTRA_PARAMETERS_EGRESS"
    
    tc qdisc add dev $WAN root cake $EGRESS_CAKE_OPTS
    
    # Ingress (Download) CAKE setup
    INGRESS_CAKE_OPTS="bandwidth ${DOWNRATE}kbit ingress"
    [ "$AUTORATE_INGRESS" -eq 1 ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS autorate-ingress"
    [ -n "$PRIORITY_QUEUE_INGRESS" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS $PRIORITY_QUEUE_INGRESS"
    [ "$HOST_ISOLATION" -eq 1 ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS dual-dsthost"
    [ "$NAT_INGRESS" -eq 1 ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS nat" || INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS nonat"
    
    [ "$WASHDSCPDOWN" -eq 1 ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS wash" || INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS nowash"
    
    [ -n "$RTT" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS rtt ${RTT}ms"
    [ -n "$COMMON_LINK_PRESETS" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS $COMMON_LINK_PRESETS"
    [ -n "$LINK_COMPENSATION" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS $LINK_COMPENSATION" || INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS noatm"
    [ -n "$OVERHEAD" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS overhead $OVERHEAD"
    [ -n "$MPU" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS mpu $MPU"
    [ -n "$EXTRA_PARAMETERS_INGRESS" ] && INGRESS_CAKE_OPTS="$INGRESS_CAKE_OPTS $EXTRA_PARAMETERS_INGRESS"
    
    tc qdisc add dev $LAN root cake $INGRESS_CAKE_OPTS
}

# Helper function to set up hybrid qdisc on an interface
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:DIR
setup_hybrid() {
    local DEV=$1 RATE=$2 GAMERATE=$3 DIR=$4
    local MTU=1500

    # Calculate parameters
    local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25
    local gameburst=$((GAMERATE*10)); [ $gameburst -gt $((RATE*97/100)) ] && gameburst=$((RATE*97/100));

    # Setup root HFSC qdisc (default to 1:13 - CAKE class)
    local TC_OH_PARAMS=""
    case $LINKTYPE in
        "atm") TC_OH_PARAMS="stab mtu 2047 tsize 512 mpu 68 overhead ${OH} linklayer atm";;
        "DOCSIS") TC_OH_PARAMS="stab overhead 25 linklayer ethernet";;
        *) TC_OH_PARAMS="stab overhead 40 linklayer ethernet";;
    esac
    # Ensure previous root is deleted before replacing
    tc qdisc del dev "$DEV" root > /dev/null 2>&1
    tc qdisc replace dev "$DEV" handle 1: root ${TC_OH_PARAMS} hfsc default 13

    # Router traffic class (only on LAN/IFB)
    if [ "$DIR" = "lan" ]; then
        tc class add dev "$DEV" parent 1: classid 1:2 hfsc ls m1 50000kbit d "${DUR}ms" m2 10000kbit
    fi

    # Main link class
    tc class add dev "$DEV" parent 1: classid 1:1 hfsc ls m2 "${RATE}kbit" ul m2 "${RATE}kbit"

    # Class 1:11 - High priority realtime (HFSC RT + gameqdisc)
    tc class add dev "$DEV" parent 1:1 classid 1:11 hfsc rt m1 "${gameburst}kbit" d "${DUR}ms" m2 "${GAMERATE}kbit"
    # Attach game qdisc (using $gameqdisc from HFSC config)
    setup_game_qdisc "$DEV" "$RATE" "$GAMERATE" "$gameqdisc" "$DIR" \
                     "$MTU" "$MAXDEL" "$PFIFOMIN" "$PACKETSIZE" \
                     "$netemdelayms" "$netemjitterms" "$netemdist" "$NETEM_DIRECTION" "$pktlossp"

    # Class 1:13 - CAKE class (most traffic - default)
    local cake_rate=$((RATE - GAMERATE)); [ $cake_rate -le 0 ] && cake_rate=1
    tc class add dev "$DEV" parent 1:1 classid 1:13 hfsc ls m1 "${cake_rate}kbit" d "${DUR}ms" m2 "${cake_rate}kbit"
    # Attach CAKE qdisc (using besteffort, allow overrides via EXTRA_PARAMETERS)
    local CAKE_OPTS=""
    if [ "$DIR" = "wan" ]; then
        CAKE_OPTS="besteffort" # Default for non-realtime in hybrid
        [ "$HOST_ISOLATION" -eq 1 ] && CAKE_OPTS="$CAKE_OPTS dual-srchost"
        [ "$NAT_EGRESS" -eq 1 ] && CAKE_OPTS="$CAKE_OPTS nat" || CAKE_OPTS="$CAKE_OPTS nonat"
        [ "$WASHDSCPUP" -eq 1 ] && CAKE_OPTS="$CAKE_OPTS wash" || CAKE_OPTS="$CAKE_OPTS nowash"
        [ -n "$RTT" ] && CAKE_OPTS="$CAKE_OPTS rtt ${RTT}ms"
        [ -n "$COMMON_LINK_PRESETS" ] && CAKE_OPTS="$CAKE_OPTS $COMMON_LINK_PRESETS"
        [ -n "$LINK_COMPENSATION" ] && CAKE_OPTS="$CAKE_OPTS $LINK_COMPENSATION" || CAKE_OPTS="$CAKE_OPTS noatm"
        [ -n "$OVERHEAD" ] && CAKE_OPTS="$CAKE_OPTS overhead $OVERHEAD"
        [ -n "$MPU" ] && CAKE_OPTS="$CAKE_OPTS mpu $MPU"
        [ -n "$EXTRA_PARAMETERS_EGRESS" ] && CAKE_OPTS="$CAKE_OPTS $EXTRA_PARAMETERS_EGRESS"
    else # lan (ingress)
        CAKE_OPTS="besteffort ingress" # Default for non-realtime in hybrid
        [ "$HOST_ISOLATION" -eq 1 ] && CAKE_OPTS="$CAKE_OPTS dual-dsthost"
        [ "$NAT_INGRESS" -eq 1 ] && CAKE_OPTS="$CAKE_OPTS nat" || CAKE_OPTS="$CAKE_OPTS nonat"
        [ "$WASHDSCPDOWN" -eq 1 ] && CAKE_OPTS="$CAKE_OPTS wash" || CAKE_OPTS="$CAKE_OPTS nowash"
        [ -n "$RTT" ] && CAKE_OPTS="$CAKE_OPTS rtt ${RTT}ms"
        [ -n "$COMMON_LINK_PRESETS" ] && CAKE_OPTS="$CAKE_OPTS $COMMON_LINK_PRESETS"
        [ -n "$LINK_COMPENSATION" ] && CAKE_OPTS="$CAKE_OPTS $LINK_COMPENSATION" || CAKE_OPTS="$CAKE_OPTS noatm"
        [ -n "$OVERHEAD" ] && CAKE_OPTS="$CAKE_OPTS overhead $OVERHEAD"
        [ -n "$MPU" ] && CAKE_OPTS="$CAKE_OPTS mpu $MPU"
        [ -n "$EXTRA_PARAMETERS_INGRESS" ] && CAKE_OPTS="$CAKE_OPTS $EXTRA_PARAMETERS_INGRESS"
    fi
    tc qdisc del dev "$DEV" parent 1:13 handle 13: > /dev/null 2>&1
    tc qdisc replace dev "$DEV" parent 1:13 handle 13: cake $CAKE_OPTS

    # Class 1:15 - Bulk traffic (HFSC LS + fq_codel)
    # Use HFSC limits: m1 3%, m2 10%
    local bulk_rate_m1=$((RATE*3/100)); [ $bulk_rate_m1 -le 0 ] && bulk_rate_m1=1
    local bulk_rate_m2=$((RATE*10/100)); [ $bulk_rate_m2 -le 0 ] && bulk_rate_m2=1
    tc class add dev "$DEV" parent 1:1 classid 1:15 hfsc ls m1 "${bulk_rate_m1}kbit" d "${DUR}ms" m2 "${bulk_rate_m2}kbit"
    # Attach fq_codel (using calculations and options from HFSC config)
    local INTVL=$((100+2*1500*8/RATE))
    local TARG=$((540*8/RATE+4))
    tc qdisc del dev "$DEV" parent 1:15 handle 15: > /dev/null 2>&1
    tc qdisc replace dev "$DEV" parent 1:15 handle 15: fq_codel memory_limit $((RATE*100/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))

    # Apply DSCP Filters (only on LAN/IFB)
    if [ "$DIR" = "lan" ]; then
        # Delete existing filters
        tc filter del dev "$DEV" parent 1: prio 1 > /dev/null 2>&1
        tc filter del dev "$DEV" parent 1: prio 2 > /dev/null 2>&1

        local class_enum

        # IPv4 Filters (prio 1)
        # EF, CS5, CS6, CS7 -> Realtime
        # CS1 -> Bulk
        for class_enum in ef cs5 cs6 cs7 cs1; do
            add_tc_filter "$DEV" "$class_enum" "ipv4"
        done
        # Default rule sends to 1:13 (CAKE)

        # IPv6 Filters (prio 2)
        for class_enum in ef cs5 cs6 cs7 cs1 cs0; do
            add_tc_filter "$DEV" "$class_enum" "ipv6"
        done
    fi
}


##############################
#       Main Logic
##############################

# Validate gameqdisc choice (used by HFSC and Hybrid)
if [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ]; then
    case "$gameqdisc" in
        drr|qfq|pfifo|bfifo|red|fq_codel|netem) ;; # Supported qdiscs
        *)
            echo "Warning: Unsupported gameqdisc '$gameqdisc' selected in config. Reverting to 'pfifo'." >&2
            gameqdisc="pfifo" # Revert to a simple default as fallback
            ;;
    esac
fi

# Main logic for selecting and applying the QoS system
case "$ROOT_QDISC" in
    hfsc)
        echo "Applying HFSC queueing discipline."
        # Call the renamed function (formerly setqdisc)
        setup_hfsc "$WAN" "$UPRATE" "$GAMEUP" "$gameqdisc" wan
        setup_hfsc "$LAN" "$DOWNRATE" "$GAMEDOWN" "$gameqdisc" lan
        ;;
    hybrid)
        echo "Applying Hybrid (HFSC+CAKE) queueing discipline."
        # Setup WAN (egress/upload) and LAN (ingress/download) directly
        setup_hybrid "$WAN" "$UPRATE" "$GAMEUP" "wan"
        setup_hybrid "$LAN" "$DOWNRATE" "$GAMEDOWN" "lan"
        ;;
    cake)
        echo "Applying CAKE queueing discipline."
        setup_cake
        ;;
    *) # Fallback for unsupported ROOT_QDISC
        echo "Error: Unsupported ROOT_QDISC: '$ROOT_QDISC'. Check /etc/config/qosmate." >&2
        echo "Warning: Falling back to default HFSC mode with pfifo game qdisc." >&2
        ROOT_QDISC="hfsc"
        gameqdisc="pfifo" # Safe default for fallback
        # Apply the fallback configuration using the renamed function
        setup_hfsc "$WAN" "$UPRATE" "$GAMEUP" "$gameqdisc" wan
        setup_hfsc "$LAN" "$DOWNRATE" "$GAMEDOWN" "$gameqdisc" lan
        ;;
esac

echo "DONE!"

# Conditional output of tc status
if [ "$ROOT_QDISC" = "hfsc" ] && [ "$gameqdisc" = "red" ]; then
   echo "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc, but things are working!"
# Add check for hybrid mode with red gameqdisc
elif [ "$ROOT_QDISC" = "hybrid" ] && [ "$gameqdisc" = "red" ]; then
   echo "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc in hybrid mode, but things are working!"
else
   # Check if tc command exists before trying to run it
   if command -v tc >/dev/null; then
       echo "--- Egress ($WAN) ---"
       tc -s qdisc show dev "$WAN"
       echo "--- Ingress ($LAN) ---"
       tc -s qdisc show dev "$LAN"
   else
        echo "Warning: 'tc' command not found. Cannot display QoS status."
   fi
fi

exit 0
