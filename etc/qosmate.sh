#!/bin/sh
# shellcheck disable=SC3043,SC1091,SC2155,SC3020,SC3010,SC2016,SC2317,SC3060,SC3057,SC3003

VERSION="1.2.0" # will become obsolete in future releases as version string is now in the init script

# uncomment to enable debug messages
# QOSMATE_DEBUG=1

_NL_='
'
DEFAULT_IFS=" 	${_NL_}"
IFS="$DEFAULT_IFS"

: "${VERSION}" "${global_enabled:=}" "${nongameqdisc:=}" "${nongameqdiscoptions:=}" "${OVERHEAD:=}"

. /lib/functions.sh

# Config is loaded by the caller (qosmate init), this is a fallback just in case
[ -n "$QOSMATE_CONFIG_LOADED" ] || {
    . /etc/init.d/qosmate
    load_and_fix_config || exit 1
}

error_out() { log_msg -err "${@}"; }

# prints each argument to a separate line
print_msg() {
    local _arg msgs_dest="/dev/stdout" msgs_prefix=''
    for _arg in "$@"
    do
        case "${_arg}" in
            -err) msgs_dest="/dev/stderr" msgs_prefix="Error: " ;;
            -warn) msgs_dest="/dev/stderr" msgs_prefix="Warning: " ;;
            '') printf '\n' ;; # print out empty lines
            *)
                printf '%s\n' "${msgs_prefix}${_arg}" > "$msgs_dest"
                msgs_prefix=''
        esac
    done
    :
}

# logs each argument separately and prints to a separate line
# optional arguments: '-err', '-warn' to set logged error level
log_msg() {
    local msgs_prefix='' _arg err_l=info msgs_dest

    local IFS="$DEFAULT_IFS"
    for _arg in "$@"
    do
        case "${_arg}" in
            "-err") err_l=err msgs_prefix="Error: " ;;
            "-warn") err_l=warn msgs_prefix="Warning: " ;;
            '') printf '\n' ;; # print out empty lines
            *)
                case "$err_l" in
                    err|warn) msgs_dest="/dev/stderr" ;;
                    *) msgs_dest="/dev/stdout"
                esac
                printf '%s\n' "${msgs_prefix}${_arg}" > "$msgs_dest"
                logger -t qosmate -p user."$err_l" "${msgs_prefix}${_arg}"
                msgs_prefix=''
        esac
    done
    :
}

config_load 'qosmate' || { error_out "Failed to get UCI config."; exit 1; }

# Check if Software Flow Offloading is enabled
SFO_ENABLED=0
[ "$(uci -q get firewall.@defaults[0].flow_offloading)" = "1" ] && SFO_ENABLED=1

# Calculated values
FIRST500MS=$((DOWNRATE * 500 / 8))
FIRST10S=$((DOWNRATE * 10000 / 8))

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
# $1 = "hybrid" to force manual overhead for consistency with HFSC
get_cake_link_params() {
    local preset="$COMMON_LINK_PRESETS"
    local oh="${OVERHEAD}"
    local base=""

    # Determine base keyword and default overhead
    case "$preset" in
        *atm*|*adsl*|*pppoa*|*pppoe*|*bridged*|*ipoa*|conservative)
            [ "$1" = "hybrid" ] && base="atm" || base="${preset}"
            : "${oh:=44}"
            ;;
        docsis)       base="docsis";   : "${oh:=25}" ;;
        cake-ethernet) base="ethernet"; [ "$1" != "hybrid" ] && oh="" || : "${oh:=38}" ;;
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

##############################
# Variable checks and dynamic rule generation
##############################

# Function to calculate different ACK rates based on the existing ACKRATE variable
calculate_ack_rates() {
    if [ -n "$ACKRATE" ] && [ "$ACKRATE" -gt 0 ]; then
        SLOWACKRATE=$ACKRATE
        MEDACKRATE=$ACKRATE
        FASTACKRATE=$((ACKRATE * 10))
        XFSTACKRATE=$((ACKRATE * 100))
    fi
}

# Call the function to perform the ACK rates calculations
calculate_ack_rates

# Debug function
debug_log() {
    [ -n "$QOSMATE_DEBUG" ] || return 0
    logger -s -t qosmate "$1" >&2
}

# Function to create NFT sets from config
create_nft_sets() {
    local sets_created=""

    # shellcheck disable=SC2329
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
# shellcheck disable=SC2329
create_nft_rule() {
    # Trim leading and trailing whitespaces and tabs in variable $1
    trim_spaces() {
        local tr_in tr_out
        eval "tr_in=\"\${$1}\""
        tr_out="${tr_in%"${tr_in##*[! 	]}"}"
        tr_out="${tr_out#"${tr_out%%[! 	]*}"}"
        eval "$1=\"\${tr_out}\""
    }

    is_set_ref() {
        case "$1" in "@"*) return 0; esac
        return 1
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

    local config="$1"
    local proto class counter name enabled trace

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
        print_msg -err "Class for rule '$config' is empty."
        return 1
    fi
    
    # Function to get set family
    get_set_family() {
        local setname="$1"
        [ -f /tmp/qosmate_set_families ] && awk -v set="$setname" '$1 == set {print $2}' /tmp/qosmate_set_families
    }
    
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
    
    # Check and separate source and destination IPs
    local src_ip dest_ip \
        src_ip_v4='' src_ip_v6='' dest_ip_v4='' dest_ip_v6='' \
        has_ipv4=0 has_ipv6=0 \
        ip_val ip_type

    for ip_type in src_ip dest_ip; do
        config_get "${ip_type}" "$config" "${ip_type}"
        eval "ip_val=\"\${$ip_type}\""
        if [ -n "$ip_val" ]; then
            separate_ips_by_family "${ip_type}_v4" "${ip_type}_v6" "$ip_val"
            eval "
                [ -n \"\${${ip_type}_v4}\" ] && has_ipv4=1
                [ -n \"\${${ip_type}_v6}\" ] && has_ipv6=1
            "
        fi
    done

    # Log if mixed IPv4/IPv6 addresses are found
    if [ "$has_ipv4" -eq 1 ] && [ "$has_ipv6" -eq 1 ]; then 
        log_msg "" "Info: Mixed IPv4/IPv6 addresses in rule '$name' ($config). Splitting into separate rules." >&2
    fi

    # If no IP address was specified, we assume the rule applies to both IPv4 and IPv6
    if [ -z "$src_ip" ] && [ -z "$dest_ip" ] && [ "$has_ipv4" -eq 0 ] && [ "$has_ipv6" -eq 0 ]; then
        debug_log "Rule '$name' ($config): No IP specified, generating rules for both IPv4 and IPv6."
        has_ipv4=1
        has_ipv6=1
    fi

    # Function to handle multiple values with IP family awareness
    gen_rule() {
        add_res_rule() {
            if [ -z "$res_set_neg" ] && [ -z "$res_set_pos" ]; then
                error_out "no valid $1 found in '$values'. Rule skipped."
                return 1
            fi

            if [ -n "$res_set_neg" ]; then
                result="${result}${result:+ }${prefix} != { ${res_set_neg} }"
            fi

            if [ -n "$res_set_pos" ]; then
                result="${result}${result:+ }${prefix} { ${res_set_pos} }"
            fi
            :
        }

        local value setname family suffix mask comp_op negation \
            result='' res_set_neg='' res_set_pos='' has_ipv4='' has_ipv6='' set_ref_seen='' ipv6_mask_seen='' reg_val_seen='' \
            values="$1" \
            prefix="$2"
        
        for value in $values; do
            if [ -n "$set_ref_seen" ] || [ -n "$ipv6_mask_seen" ]; then
                error_out "invalid entry '$values'. When using nftables set reference or ipv6 mask, other values are not allowed."
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
                    error_out "invalid entry '$values'. When using nftables set reference or ipv6 mask, other values are not allowed."
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
                    error_out "invalid entry '$values'. When using nftables set reference or ipv6 mask, other values are not allowed."
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

            # Validate prefix type
            case "$prefix" in 
                "ip saddr"|"ip daddr"|"ip6 saddr"|"ip6 daddr"|"th sport"|"th dport"|"meta l4proto")
                    ;;
                *)
                    error_out "unexpected prefix '$prefix'."
                    return 1
                    ;;
            esac

            case "$prefix" in *addr*)
                if is_ipv6 "$value"; then
                    has_ipv6=1
                else
                    has_ipv4=1
                fi
            esac

            # Collect values
            if [ -n "$negation" ]; then
                res_set_neg="${res_set_neg}${res_set_neg:+,}${value}"
            else
                res_set_pos="${res_set_pos}${res_set_pos:+,}${value}"
            fi

            reg_val_seen=1
        done

        if [ -n "$set_ref_seen" ] || [ -n "$ipv6_mask_seen" ]; then
            printf '%s\n' "$result"
            return 0
        fi

        # If mixed, log and signal error
        if [ -n "$has_ipv4" ] && [ -n "$has_ipv6" ]; then
            error_out "Mixed IPv4/IPv6 addresses within a set: { $values }. Rule skipped."
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
                add_res_rule addresses || return 1
                ;;
                
            "th sport"|"th dport")
                # Port rules
                add_res_rule ports || return 1
                ;;
                
            "meta l4proto")
                # Protocol rules
                add_res_rule protocols || return 1
                ;;
        esac

        printf '%s\n' "$result"
    }

    # Initialize rule string
    local rule_cmd=""

    # Handle multiple protocols
    if [ -n "$proto" ]; then
        local proto_result
        if ! proto_result="$(gen_rule "$proto" "meta l4proto")"; then
            # Skip rule
            return 0
        fi
        rule_cmd="$rule_cmd $proto_result"
    fi

    # Note: Source and Destination IP handling is now done per-family in the rule generation below
    
    # Use connection tracking for source and destination ports
    local port port_type port_res port_seen=''

    for port_type in src_port dest_port; do
        config_get port "$config" "$port_type"
        if [ -n "$port" ]; then
            if ! port_res="$(gen_rule "$port" "th ${port_type%%"${port_type#?}"}port")"; then
                # Skip rule
                return 0
            fi
            rule_cmd="$rule_cmd $port_res"
            port_seen=1
        fi
    done

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
        if [ -n "$proto" ] || [ -n "$src_ip_v4" ] || [ -n "$dest_ip_v4" ] || [ -n "$port_seen" ]; then
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
        if [ -n "$proto" ] || [ -n "$src_ip_v6" ] || [ -n "$dest_ip_v6" ] || [ -n "$port_seen" ]; then
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
    if [ "$global_enabled" = "1" ]; then
        config_foreach create_nft_rule rule
    else
        echo "# QoSmate rules are globally disabled"
    fi
}

##############################
# Rate Limit Functions
##############################

# Build nftables device match conditions from target values with direction support
# Detects IP/IPv6 addresses and generates appropriate match statements
# Args: $1=target_values, $2=direction (saddr/daddr), $3=result_var_name
# shellcheck disable=SC2329
build_device_conditions_for_direction() {
    local target_values="$1" direction="$2" result_var="$3"
    local result="" ipv4_pos="" ipv4_neg="" ipv6_pos="" ipv6_neg=""
    local value negation v
    
    for value in $target_values; do
        negation=""
        v="$value"
        
        # Check for negation prefix
        case "$v" in
            '!='*)
                negation="!="
                v="${v#!=}"
                ;;
        esac
        
        # Check for set reference (@setname)
        case "$v" in
            '@'*)
                # Set reference - determine family and use correct prefix
                local setname="${v#@}"
                local set_family
                set_family="$(awk -v set="$setname" '$1 == set {print $2}' /tmp/qosmate_set_families 2>/dev/null)"
                
                local ip_prefix='ip'
                [ "$set_family" = "ipv6" ] && ip_prefix='ip6'
                
                if [ -n "$negation" ]; then
                    result="${result}${result:+ }${ip_prefix} ${direction} != @${setname}"
                else
                    result="${result}${result:+ }${ip_prefix} ${direction} @${setname}"
                fi
                ;;
            *)
                # Detect address type and collect for set notation
                # Skip MAC addresses (not supported)
                if printf '%s' "$v" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
                    log_msg -warn "MAC address '$v' in rate limit rule ignored (not supported)"
                elif printf '%s' "$v" | grep -q ':' && ! printf '%s' "$v" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
                    # IPv6 address (contains colon, not a MAC address)
                    if [ -n "$negation" ]; then
                        ipv6_neg="${ipv6_neg}${ipv6_neg:+,}${v}"
                    else
                        ipv6_pos="${ipv6_pos}${ipv6_pos:+,}${v}"
                    fi
                else
                    # IPv4 address or CIDR
                    if [ -n "$negation" ]; then
                        ipv4_neg="${ipv4_neg}${ipv4_neg:+,}${v}"
                    else
                        ipv4_pos="${ipv4_pos}${ipv4_pos:+,}${v}"
                    fi
                fi
                ;;
        esac
    done
    
    # Build set-based conditions
    if [ -n "$ipv4_neg" ]; then
        result="${result}${result:+ }ip ${direction} != { ${ipv4_neg} }"
    fi
    if [ -n "$ipv4_pos" ]; then
        result="${result}${result:+ }ip ${direction} { ${ipv4_pos} }"
    fi
    if [ -n "$ipv6_neg" ]; then
        result="${result}${result:+ }ip6 ${direction} != { ${ipv6_neg} }"
    fi
    if [ -n "$ipv6_pos" ]; then
        result="${result}${result:+ }ip6 ${direction} { ${ipv6_pos} }"
    fi
    
    eval "${result_var}=\"\${result}\""
}

# Generate rate limit rules from UCI config
generate_ratelimit_rules() {
    local rules=""
    
    # Process each ratelimit section
    # shellcheck disable=SC2329
    process_ratelimit_section() {
        local section="$1"
        local name enabled download_limit upload_limit burst_factor
        local target_values meter_suffix download_kbytes upload_kbytes
        local download_burst upload_burst
        
        config_get_bool enabled "$section" enabled 1
        [ "$enabled" -eq 0 ] && return 0
        
        config_get name "$section" name
        [ -z "$name" ] && {
            log_msg -warn "Rate limit section '$section' has no name - skipping"
            return 0
        }
        
        config_get download_limit "$section" download_limit "0"
        config_get upload_limit "$section" upload_limit "0"
        config_get burst_factor "$section" burst_factor "1.0"
        
        config_get target_values "$section" target
        
        # Validate: need at least one target and one limit
        [ -z "$target_values" ] && {
            log_msg -warn "Rate limit rule '$name' has no target devices - skipping"
            return 0
        }
        [ "$download_limit" -eq 0 ] && [ "$upload_limit" -eq 0 ] && {
            log_msg -warn "Rate limit rule '$name' has no bandwidth limits - skipping"
            return 0
        }
        
        # Sanitize name for meter usage (only alphanumeric and underscore)
        meter_suffix="$(printf '%s' "$name" | tr ' ' '_' | tr -cd 'a-zA-Z0-9_')"
        [ -z "$meter_suffix" ] && meter_suffix="unnamed_${section}"
        
        # Convert Kbit/s to kbytes/second (1 Kbit/s = 0.125 kbytes/s)
        download_kbytes=$((download_limit / 8))
        upload_kbytes=$((upload_limit / 8))
        
        # Calculate burst using robust decimal parsing
        # If burst_factor is 0, we don't add burst parameter at all (strict rate limit)
        local download_burst_param='' upload_burst_param=''
        
        # Parse burst_factor robustly (handle cases like "1.", ".5", "0.25", etc.)
        case "$burst_factor" in
            0|0.0|0.00) 
                # No burst - strict limiting
                ;;
            *.*) 
                # Has decimal point
                local burst_int="${burst_factor%.*}"
                local burst_dec="${burst_factor#*.}"
                
                # Handle missing parts
                [ -z "$burst_int" ] && burst_int='0'
                [ -z "$burst_dec" ] && burst_dec='0'
                
                # Pad or truncate decimal to 2 digits for centiprecision
                case "${#burst_dec}" in
                    1) burst_dec="${burst_dec}0" ;;  # 0.5 -> 50
                    2) ;;  # 0.25 -> 25
                    *) burst_dec="${burst_dec:0:2}" ;;  # 0.125 -> 12
                esac
                
                # Calculate: burst = rate * (int + dec/100)
                local download_burst=$((download_kbytes * burst_int + download_kbytes * burst_dec / 100))
                local upload_burst=$((upload_kbytes * burst_int + upload_kbytes * burst_dec / 100))
                
                [ "$download_burst" -gt 0 ] && download_burst_param=" burst ${download_burst} kbytes"
                [ "$upload_burst" -gt 0 ] && upload_burst_param=" burst ${upload_burst} kbytes"
                ;;
            *)
                # Integer only (e.g. "1", "2")
                local download_burst=$((download_kbytes * burst_factor))
                local upload_burst=$((upload_kbytes * burst_factor))
                download_burst_param=" burst ${download_burst} kbytes"
                upload_burst_param=" burst ${upload_burst} kbytes"
                ;;
        esac
        
        # Separate targets by IP family
        local targets_v4='' targets_v6='' value prefix setname set_family
        
        for value in $target_values; do
            # Preserve != prefix
            prefix=''
            case "$value" in
                '!='*)
                    prefix='!='
                    value="${value#!=}"
                    ;;
            esac
            
            # Check if it's a set reference
            case "$value" in
                '@'*)
                    setname="${value#@}"
                    set_family="$(awk -v set="$setname" '$1 == set {print $2}' /tmp/qosmate_set_families 2>/dev/null)"
                    if [ "$set_family" = "ipv6" ]; then
                        targets_v6="${targets_v6}${targets_v6:+ }${prefix}${value}"
                    else
                        targets_v4="${targets_v4}${targets_v4:+ }${prefix}${value}"
                    fi
                    ;;
                *)
                    # Check if IPv6 (contains colon and not MAC)
                    if printf '%s' "$value" | grep -q ':' && ! printf '%s' "$value" | grep -qE '^([0-9a-fA-F]{2}[:-]){5}[0-9a-fA-F]{2}$'; then
                        targets_v6="${targets_v6}${targets_v6:+ }${prefix}${value}"
                    else
                        targets_v4="${targets_v4}${targets_v4:+ }${prefix}${value}"
                    fi
                    ;;
            esac
        done
        
        # Generate IPv4 rules
        if [ -n "$targets_v4" ]; then
            if [ "$download_limit" -gt 0 ]; then
                local download_conditions_v4=''
                build_device_conditions_for_direction "$targets_v4" "daddr" download_conditions_v4
                [ -n "$download_conditions_v4" ] && rules="${rules}
        # ${name} - Download limit (IPv4)
        ${download_conditions_v4} meter ${meter_suffix}_dl4 { ip daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
            fi
            
            if [ "$upload_limit" -gt 0 ]; then
                local upload_conditions_v4=''
                build_device_conditions_for_direction "$targets_v4" "saddr" upload_conditions_v4
                [ -n "$upload_conditions_v4" ] && rules="${rules}
        # ${name} - Upload limit (IPv4)
        ${upload_conditions_v4} meter ${meter_suffix}_ul4 { ip saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
            fi
        fi
        
        # Generate IPv6 rules
        if [ -n "$targets_v6" ]; then
            if [ "$download_limit" -gt 0 ]; then
                local download_conditions_v6=''
                build_device_conditions_for_direction "$targets_v6" "daddr" download_conditions_v6
                [ -n "$download_conditions_v6" ] && rules="${rules}
        # ${name} - Download limit (IPv6)
        ${download_conditions_v6} meter ${meter_suffix}_dl6 { ip6 daddr limit rate over ${download_kbytes} kbytes/second${download_burst_param} } counter drop comment \"${name} download\""
            fi
            
            if [ "$upload_limit" -gt 0 ]; then
                local upload_conditions_v6=''
                build_device_conditions_for_direction "$targets_v6" "saddr" upload_conditions_v6
                [ -n "$upload_conditions_v6" ] && rules="${rules}
        # ${name} - Upload limit (IPv6)
        ${upload_conditions_v6} meter ${meter_suffix}_ul6 { ip6 saddr limit rate over ${upload_kbytes} kbytes/second${upload_burst_param} } counter drop comment \"${name} upload\""
            fi
        fi
    }
    
    # Process all ratelimit sections from UCI
    config_foreach process_ratelimit_section ratelimit
    
    # Output rate limit chain if rules exist
    if [ -n "$rules" ]; then
        printf '\n%s\n%s\n%s%s\n%s\n' \
            "    # Rate Limit Chain" \
            "    chain ratelimit {" \
            "        type filter hook forward priority 0; policy accept;" \
            "${rules}" \
            "    }"
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
# Inline Rules Check
##############################
INLINE_FILE="/etc/qosmate.d/inline_dscptag.nft"
INLINE_INCLUDE=""

if [ -s "$INLINE_FILE" ]; then
    TMP_CHECK_FILE="/tmp/qosmate_inline_sh_check.nft"

    {
        printf '%s\n\t%s\n' "table inet __qosmate_sh_ctx {" "chain __dscptag_sh_ctx {"
        cat "$INLINE_FILE"
        printf "\n\t%s\n%s\n" "}" "}"
    } > "$TMP_CHECK_FILE"

    if nft --check --file "$TMP_CHECK_FILE" 2>/dev/null; then
        INLINE_INCLUDE="include \"$INLINE_FILE\""
    fi
    rm -f "$TMP_CHECK_FILE"
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
        $(if { [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ] || [ "$ROOT_QDISC" = "htb" ]; } && [ "$WASHDSCPDOWN" -eq 1 ]; then
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
        
        # --- user inline rules begin ---
        $INLINE_INCLUDE
        # --- user inline rules end   ---
        
${DYNAMIC_RULES}

        ## classify for the HFSC queues:
        meta priority set ip dscp map @priomap counter
        meta priority set ip6 dscp map @priomap counter

        # Store DSCP in conntrack for restoration on ingress
        ct mark set ip dscp or 128 counter
        ct mark set ip6 dscp or 128 counter

        $(if { [ "$ROOT_QDISC" = "hfsc" ] || [ "$ROOT_QDISC" = "hybrid" ] || [ "$ROOT_QDISC" = "htb" ]; } && [ "$WASHDSCPUP" -eq 1 ]; then
            echo "# wash all DSCP on egress ... "
            echo "meta oifname \$wan jump mark_cs0"
          fi
        )
    }

$(generate_ratelimit_rules)
}
DSCPEOF

## Set up ctinfo downstream shaping

print_msg "" "Setting up ctinfo downstream shaping..."

# Set up ingress handle for WAN interface
tc qdisc add dev "$WAN" handle ffff: ingress

# Create IFB interface
ip link add name "ifb-$WAN" type ifb
ip link set "ifb-$WAN" up

# Redirect ingress traffic from WAN to IFB and restore DSCP from conntrack
tc filter add dev "$WAN" parent ffff: protocol all matchall action ctinfo dscp 63 128 mirred egress redirect dev "ifb-$WAN"
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

    # shellcheck disable=SC2086
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
            print_msg -err "Unsupported game qdisc type '$QDISC_TYPE'. Using pfifo fallback."
            # pfifo fallback limit calculation
            tc qdisc add dev "$DEV" parent 1:11 handle 10: pfifo limit $((PFIFOMIN+MAXDEL*RATE/8/PACKETSIZE))
        ;;
    esac
}

# Function to setup HFSC qdisc structure
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:GAME_QDISC_TYPE, $5:DIR
setup_hfsc() {
    local DEV="$1" RATE="$2" GAMERATE="$3" GAME_QDISC_TYPE="$4" DIR="$5"
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
            print_msg -err "Unsupported qdisc for non-game traffic: $nongameqdisc"
            exit 1
        fi
    done

    # Apply DSCP Filters (on ingress always, on egress only when SFO active)
    # Ingress always needs filters, egress needs them only with SFO
    # Without SFO: nftables priomap handles egress classification
    # With SFO: nftables bypassed, tc filters needed for classification
    if [ "$DIR" = "lan" ] || [ "$SFO_ENABLED" = "1" ]; then
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
    :
}


qdisc_setup_failed() {
    [ -n "$1" ] && error_out "$1"
    error_out "Failed to set up $ROOT_QDISC."
    # *** Any additional error handling needed? ***
    exit 1
}

# Appends option to ${CAKE_OPTS}
# 1: parameter: nat|wash|ack_filter|*
# 2: selector (1|0)
#    for wash, nat, ack-filter: selector value '1' translates to prefix '', any other value translates to prefix 'no[-]'
#    for other options: selector value '1' translates to 'don't skip option', any other value translates to 'skip option'
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

# Function to setup CAKE qdisc
setup_cake() {
    tc qdisc del dev "$WAN" root > /dev/null 2>&1
    tc qdisc del dev "$LAN" root > /dev/null 2>&1
    
    # Get CAKE link parameters
    local ack_filter_egress_val cake_link_params="$(get_cake_link_params)"

    # Egress (Upload) CAKE setup
    case "$ACK_FILTER_EGRESS" in
        auto) ack_filter_egress_val=$(( (DOWNRATE / UPRATE) >= 15 )) ;;
        *[!0-9]*|'') qdisc_setup_failed "Invalid value '$ACK_FILTER_EGRESS' for ACK_FILTER_EGRESS." ;;
        *) ack_filter_egress_val=$ACK_FILTER_EGRESS ;;
    esac

    local CAKE_OPTS="bandwidth ${UPRATE}kbit"
    # shellcheck disable=SC2086
    append_cake_opt "$PRIORITY_QUEUE_EGRESS" "1" &&
    append_cake_opt "dual-srchost" "$HOST_ISOLATION" &&
    append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
    append_cake_opt "$cake_link_params" "1" &&
    append_cake_opt "$LINK_COMPENSATION" "1" &&
    append_cake_opt "$EXTRA_PARAMETERS_EGRESS" "1" &&
    append_cake_opt "nat" "$NAT_EGRESS" &&
    append_cake_opt "wash" "$WASHDSCPUP" &&
    append_cake_opt "ack-filter" "$ack_filter_egress_val" &&
    tc qdisc add dev "$WAN" root handle 1: cake $CAKE_OPTS || qdisc_setup_failed
debug_log "EGRESS cake opts: '$CAKE_OPTS'"
    

    # Ingress (Download) CAKE setup
    CAKE_OPTS="bandwidth ${DOWNRATE}kbit ingress"
    # shellcheck disable=SC2086
    append_cake_opt "autorate-ingress" "$AUTORATE_INGRESS" &&
    append_cake_opt "$PRIORITY_QUEUE_INGRESS" "1" &&
    append_cake_opt "dual-dsthost" "$HOST_ISOLATION" &&
    append_cake_opt "rtt ${RTT}ms" "${RTT:+1}" &&
    append_cake_opt "$cake_link_params" "1" &&
    append_cake_opt "$LINK_COMPENSATION" "1" &&
    append_cake_opt "$EXTRA_PARAMETERS_INGRESS" "1" &&
    append_cake_opt "nat" "$NAT_INGRESS" &&
    append_cake_opt "wash" "$WASHDSCPDOWN" &&
    tc qdisc add dev "$LAN" root cake $CAKE_OPTS || qdisc_setup_failed
debug_log "INGRESS cake opts: '$CAKE_OPTS'"
}

# Helper function to set up hybrid qdisc on an interface
# Arguments: $1:DEV, $2:RATE, $3:GAMERATE, $4:DIR
setup_hybrid() {
    local DEV="$1" RATE="$2" GAMERATE="$3" DIR="$4"
    local MTU=1500

    # Calculate parameters
    local DUR=$((5*1500*8/RATE)); [ $DUR -lt 25 ] && DUR=25
    local gameburst=$((GAMERATE*10)); [ $gameburst -gt $((RATE*97/100)) ] && gameburst=$((RATE*97/100));

    # Setup root HFSC qdisc (default to 1:13 - CAKE class)
    local TC_OH_PARAMS
    TC_OH_PARAMS=$(get_tc_overhead_params)
    
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

    # Attach CAKE qdisc - use "hybrid" mode to match HFSC overhead
    local cake_link_params="$(get_cake_link_params "hybrid")"
    local CAKE_OPTS=""
    tc qdisc del dev "$DEV" parent 1:13 handle 13: > /dev/null 2>&1
    
    # shellcheck disable=SC2086
    if [ "$DIR" = "wan" ]; then
        CAKE_OPTS="besteffort" # Default for non-realtime in hybrid
        append_cake_opt "dual-srchost" "$HOST_ISOLATION" &&
        append_cake_opt "$EXTRA_PARAMETERS_EGRESS" "1" &&
        append_cake_opt "nat" "$NAT_EGRESS" &&
        append_cake_opt "wash" "$WASHDSCPUP"
    else # lan (ingress)
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
    tc qdisc replace dev "$DEV" parent 1:15 handle 15: fq_codel memory_limit $((RATE*100/8)) interval "${INTVL}ms" target "${TARG}ms" quantum $((MTU * 2))

    # Apply DSCP Filters (on ingress always, on egress only when SFO active)
    if [ "$DIR" = "lan" ] || [ "$SFO_ENABLED" = "1" ]; then
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
    if [ "$LINKTYPE" = "atm" ]; then
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

# Function to setup HTB qdisc (simple.qos style with 3 classes)
setup_htb() {
    local DEV="$1" RATE="$2" DIR="$3"
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

    # Apply DSCP filters (on ingress always, on egress only when SFO active)
    if [ "$DIR" = "lan" ] || [ "$SFO_ENABLED" = "1" ]; then
        # Delete existing filters
        tc filter del dev "$DEV" parent 1: prio 1 > /dev/null 2>&1
        tc filter del dev "$DEV" parent 1: prio 2 > /dev/null 2>&1

        # IPv4 filters (prio 1)
        # Priority class: EF, CS5, CS6, CS7 -> 1:11
        # Background class: CS1 -> 1:15
        for class_enum in ef cs5 cs6 cs7 cs1; do
            add_tc_filter "$DEV" "$class_enum" "ipv4"
        done

        # IPv6 filters (prio 2)
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
            print_msg -warn "Unsupported gameqdisc '$gameqdisc' selected in config. Reverting to 'pfifo'."
            gameqdisc="pfifo" # Revert to a simple default as fallback
            ;;
    esac
fi

# Main logic for selecting and applying the QoS system
case "$ROOT_QDISC" in
    hfsc)
        print_msg "Applying HFSC queueing discipline."
        # Call the renamed function (formerly setqdisc)
        setup_hfsc "$WAN" "$UPRATE" "$GAMEUP" "$gameqdisc" wan
        setup_hfsc "$LAN" "$DOWNRATE" "$GAMEDOWN" "$gameqdisc" lan
        ;;
    hybrid)
        print_msg "Applying Hybrid (HFSC+CAKE) queueing discipline."
        # Setup WAN (egress/upload) and LAN (ingress/download) directly
        setup_hybrid "$WAN" "$UPRATE" "$GAMEUP" "wan"
        setup_hybrid "$LAN" "$DOWNRATE" "$GAMEDOWN" "lan"
        ;;
    cake)
        print_msg "Applying CAKE queueing discipline."
        setup_cake
        ;;
    htb)
        print_msg "Applying HTB queueing discipline."
        setup_htb "$WAN" "$UPRATE" "wan"
        setup_htb "$LAN" "$DOWNRATE" "lan"
        ;;
    *) # Fallback for unsupported ROOT_QDISC
        print_msg -err "Unsupported ROOT_QDISC: '$ROOT_QDISC'. Check /etc/config/qosmate."
        print_msg -warn "Falling back to default HFSC mode with pfifo game qdisc."
        ROOT_QDISC="hfsc"
        gameqdisc="pfifo" # Safe default for fallback
        # Apply the fallback configuration using the renamed function
        setup_hfsc "$WAN" "$UPRATE" "$GAMEUP" "$gameqdisc" wan
        setup_hfsc "$LAN" "$DOWNRATE" "$GAMEDOWN" "$gameqdisc" lan
        ;;
esac

## Set up ctinfo for upstream (egress) - SFO compatibility
# Restore DSCP values from conntrack for egress packets
# Only needed when Software Flow Offloading is active
if [ "$SFO_ENABLED" = "1" ]; then
    print_msg "" "Software Flow Offloading detected - enabling SFO compatibility mode..."
    tc filter add dev "$WAN" parent 1: protocol all matchall action ctinfo dscp 63 128 continue
else
    print_msg "" "Software Flow Offloading disabled - dynamic rules fully functional..."
fi

print_msg "DONE!"

# Conditional output of tc status
if [ "$ROOT_QDISC" = "hfsc" ] && [ "$gameqdisc" = "red" ]; then
   print_msg "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc, but things are working!"
# Add check for hybrid mode with red gameqdisc
elif [ "$ROOT_QDISC" = "hybrid" ] && [ "$gameqdisc" = "red" ]; then
   print_msg "Can not output tc -s qdisc because it crashes on OpenWrt when using RED qdisc in hybrid mode, but things are working!"
else
   # Check if tc command exists before trying to run it
   if command -v tc >/dev/null; then
       print_msg "--- Egress ($WAN) ---"
       tc -s qdisc show dev "$WAN"
       print_msg "--- Ingress ($LAN) ---"
       tc -s qdisc show dev "$LAN"
   else
        print_msg "Warning: 'tc' command not found. Cannot display QoS status."
   fi
fi

exit 0
