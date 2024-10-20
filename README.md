# QoSmate: Quality of Service for OpenWrt

QoSmate is a Quality of Service (QoS) solution for OpenWrt routers that aims to optimize network performance while allowing for controlled prioritization of specific traffic types. It uses nftables for packet classification and offers both CAKE (Common Applications Kept Enhanced) and HFSC (Hierarchical Fair Service Curve) queueing disciplines for traffic management. It uses tc-ctinfo to restore DSCP marks on ingress.

The project builds upon the amazing work of [@dlakelan](https://github.com/dlakelan) and his [SimpleHFSCgamerscript](https://github.com/dlakelan/routerperf/blob/master/SimpleHFSCgamerscript.sh), extending its capabilities and adding a user-friendly interface. QoSmate integrates concepts from various QoS systems, including SQM, DSCPCLASSIFY and cake-qos-simple to provide a comprehensive approach to traffic control.

Key aspects of QoSmate include
- Support for both HFSC and CAKE queueing disciplines
- A LuCI-based interface for easy configuration
- DSCP marking and traffic prioritization options via CLI and UI
- Automatic package installation and setup

While QoSmate can benefit various types of network traffic, including gaming and other latency-sensitive applications, it is designed to improve overall network performance when configured properly.

Important Note: Effective QoS is about strategic prioritization, not blanket elevation of all traffic. QoSmate allows you to prioritize specific traffic types, but it's crucial to use this capability judiciously. Over-prioritization can negate the benefits of QoS, as elevating too much traffic essentially equates to no prioritization at all. Remember that for every packet given preferential treatment, others may experience increased delay or even drops. The goal is to create a balanced, efficient network environment, not to prioritize everything.

## 1. Installation

Before installing QoSmate, ensure that:

1. Any existing QoS services or scripts (e.g., SQM, Qosify, DSCPCLASSIFY, SimpleHFSCgamerscript...) are disabled and stopped to avoid conflicts.
2. Your router is rebooted to clear out old settings for a clean start.

### a) Backend Installation

Install the QoSmate backend (which contains a main script/init script/hotplug and a config-file) with the following command:

```bash
wget -O /etc/init.d/qosmate https://raw.githubusercontent.com/hudra0/qosmate/main/etc/init.d/qosmate && chmod +x /etc/init.d/qosmate
wget -O /etc/qosmate.sh https://raw.githubusercontent.com/hudra0/qosmate/main/etc/qosmate.sh && chmod +x /etc/qosmate.sh
[ ! -f /etc/config/qosmate ] && wget -O /etc/config/qosmate https://raw.githubusercontent.com/hudra0/qosmate/main/etc/config/qosmate
```

### b) Frontend Installation

Install [luci-app-qosmate](https://github.com/hudra0/luci-app-qosmate) with this command:

```bash
mkdir -p /www/luci-static/resources/view/qosmate /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd && \
wget -O /www/luci-static/resources/view/qosmate/settings.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/settings.js && \
wget -O /www/luci-static/resources/view/qosmate/hfsc.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/hfsc.js && \
wget -O /www/luci-static/resources/view/qosmate/cake.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/cake.js && \
wget -O /www/luci-static/resources/view/qosmate/advanced.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/advanced.js && \
wget -O /www/luci-static/resources/view/qosmate/rules.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/rules.js && \
wget -O /www/luci-static/resources/view/qosmate/connections.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/connections.js && \
wget -O /www/luci-static/resources/view/qosmate/custom_rules.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/htdocs/luci-static/resources/view/custom_rules.js && \
wget -O /usr/share/luci/menu.d/luci-app-qosmate.json https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/root/usr/share/luci/menu.d/luci-app-qosmate.json && \
wget -O /usr/share/rpcd/acl.d/luci-app-qosmate.json https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/root/usr/share/rpcd/acl.d/luci-app-qosmate.json && \
wget -O /usr/libexec/rpcd/luci.qosmate https://raw.githubusercontent.com/hudra0/luci-app-qosmate/main/root/usr/libexec/rpcd/luci.qosmate && \
chmod +x /usr/libexec/rpcd/luci.qosmate && \
/etc/init.d/rpcd restart && \
/etc/init.d/uhttpd restart

```

### c) Usage

1. After installation, start the QoSmate service:
```
/etc/init.d/qosmate start
```
1. Access the LuCI web interface and navigate to Network > QoSmate.
2. Configure the basic settings: For a basic configuration, adjust the following key parameters:
    - **WAN Interface**: Select your WAN interface
    - **Download Rate (kbps)**: Set to 80-90% of your actual download speed
    - **Upload Rate (kbps)**: Set to 80-90% of your actual upload speed
    - **Root Queueing Discipline**: Choose between HFSC (default) and CAKE
3. Apply the changes

#### Auto-setup Function

For users preferring automatic configuration, QoSmate offers an Auto-setup function:

1. In the QoSmate settings page, click "Start Auto Setup"
2. Optionally, enter your gaming device's IP address for prioritization
3. Wait for the speed test and configuration to complete

**Note**: Router-based speed tests may underestimate your actual connection speed. For more precise settings, run a speed test from a LAN device and manually input the results. The auto-setup provides a useful starting point, but manual fine-tuning may be necessary for optimal performance.
## 2. QoSmate Configuration Settings

### Basic and Global Settings

| Config option | Description                                                                                                                                                                                                                    | Type              | Default |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ------- |
| enabled       | Enables or disables QoSmate. Set to 1 to enable, 0 to disable.                                                                                                             | boolean           | 1       |
| WAN           | Specifies the WAN interface. This is crucial for applying QoS rules to the correct network interface. It's typically the interface connected to your ISP.                                                                      | string            | eth1    |
| DOWNRATE      | Download rate in kbps. Set this to about 80-90% of your actual download speed to allow for overhead and prevent bufferbloat. This creates a buffer that helps maintain low latency even when the connection is fully utilized. | integer           | 90000   |
| UPRATE        | Upload rate in kbps. Set this to about 80-90% of your actual upload speed for the same reasons as DOWNRATE.                                                                                                                    | integer           | 45000   |
| ROOT_QDISC    | Specifies the root queueing discipline. Options are 'hfsc' or 'cake'                                                                                                                                                           | enum (hfsc, cake) | hfsc    |

### HFSC Specific Settings

| Config option       | Description                                                                                                                                                                                                                                                                                          | Type                                         | Default                 |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------- |
| LINKTYPE            | Specifies the link type. This affects how overhead is calculated. 'ethernet' is common for most connections, 'atm' for DSL, and 'DOCSIS' for cable internet.                                                                                                                                         | enum (ethernet, atm, DOCSIS)                 | ethernet                |
| OH                  | Overhead in bytes. This accounts for layer 2 encapsulation overhead. Adjust based on your connection type.                                                                                                                                                                                           | integer                                      |                         |
| gameqdisc           | Queueing discipline for game traffic. Options include 'pfifo ' 'bfifo' , 'fq_codel' , 'red' , and 'netem'. Each has different characteristics for managing realtime traffic.                                                                                                                         | enum (pfifo, bfifo fq_codel, red, netem)     | pfifo                   |
| GAMEUP              | Upload bandwidth reserved for gaming in kbps. Formula ensures minimum bandwidth for games even on slower connections.                                                                                                                                                                                | integer                                      | (UPRATE*15/100+400)     |
| GAMEDOWN            | Download bandwidth reserved for gaming in kbps. Similar to GAMEUP, but for download traffic.                                                                                                                                                                                                         | integer                                      | (DOWNRATE*15/100+400)   |
| nongameqdisc        | Queueing discipline for non-realtime traffic. 'fq_codel' or 'cake'.                                                                                                                                                                                                                                  | enum (fq_codel, cake)                        | fq_codel                |
| nongameqdiscoptions | Additional cake options when cake is set as the non-game qdisc.                                                                                                                                                                                                                                      | string                                       | "besteffort ack-filter" |
| MAXDEL              | Maximum delay in milliseconds. This sets an upper bound on queueing delay, helping to maintain responsiveness even under load.                                                                                                                                                                       | integer                                      | 24                      |
| PFIFOMIN            | Minimum number of packets in the pfifo queue.                                                                                                                                                                                                                                                        | integer                                      | 5                       |
| PACKETSIZE          | Pfifo average packet size in bytes. Used in calculations for queue limits. Adjust if you know your game traffic has a significantly different average packet size.                                                                                                                                   | integer                                      | 450                     |
| netemdelayms        | Artificial delay added by netem in milliseconds, only used if 'gameqdisc' is set to 'netem'. This is useful for testing or simulating higher latency connections. Netem applies the delay in both directions, so if you set a delay of 10 ms, you will experience a total of 20 ms cumulative delay. | integer                                      | 30                      |
| netemjitterms       | Jitter added by netem in milliseconds. Simulates network variability, useful for testing how applications handle inconsistent latency.                                                                                                                                                               | integer                                      | 7                       |
| netemdist           | Distribution of delay for netem. Options affect how the artificial delay is applied, simulating different network conditions.                                                                                                                                                                        | enum (uniform, normal, pareto, paretonormal) | normal                  |
| pktlossp            | Packet loss percentage for netem. Simulates network packet loss, useful for testing application resilience.                                                                                                                                                                                          | string                                       | none                    |

### CAKE Specific Settings
All cake settings are described in the tc-cake man.

| Config option            | Description                                                                                                                                                    | Type                                       | Default   |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | --------- |
| COMMON_LINK_PRESETS      | Preset for common link types. Affects overhead calculations and default behaviors. 'ethernet' or 'conservative' is suitable for most connections.              | enum (ethernet, docsis, ... see cake man.) | ethernet  |
| OVERHEAD                 | Manual overhead setting. If set, overrides the preset. Useful for fine-tuning or unusual setups.                                                               | integer                                    |           |
| MPU                      | Minimum packet unit size. If set, overrides the preset.                                                                                                        | integer                                    |           |
| LINK_COMPENSATION        | Additional compensation for link peculiarities.                                                                                                                | string (atm, ptm, noatm)                   |           |
| ETHER_VLAN_KEYWORD       | Keyword for Ethernet VLAN compensation. Used when VLAN tagging affects packet sizes.                                                                           | string                                     |           |
| PRIORITY_QUEUE_INGRESS   | Priority queue handling for incoming traffic. 'diffserv4' uses 4 tiers of priority based on DSCP markings.                                                     | enum (diffserv3, diffserv4, diffserv8)     | diffserv4 |
| PRIORITY_QUEUE_EGRESS    | Priority queue handling for outgoing traffic. Usually matched with INGRESS for consistency.                                                                    | enum (diffserv3, diffserv4, diffserv8)     | diffserv4 |
| HOST_ISOLATION           | Enables host isolation in CAKE. Prevents one client from monopolizing bandwidth, ensuring fair distribution among network devices. (dual-srchost/dual-dsthost) | boolean                                    | 1         |
| NAT_INGRESS              | Enables NAT lookup for incoming traffic. Important for correct flow identification in NAT scenarios.                                                           | boolean                                    | 1         |
| NAT_EGRESS               | Enables NAT lookup for outgoing traffic.                                                                                                                       | boolean                                    | 1         |
| ACK_FILTER_EGRESS        | Controls ACK filtering. 'auto' enables it when download/upload ratio ≥ 15, helping to prevent ACK floods on asymmetric connections.                            | enum (auto, 1, 0)                          | auto      |
| RTT                      | Round Trip Time estimation. If set, used to optimize CAKE's behavior for your specific network latency.                                                        | integer                                    |           |
| AUTORATE_INGRESS         | Enables CAKE's automatic rate limiting for ingress. Can adapt to changing network conditions but may be less predictable.                                      | boolean                                    | 0         |
| EXTRA_PARAMETERS_INGRESS | Additional parameters for ingress CAKE qdisc. For advanced tuning, allows passing custom options directly to CAKE.                                             | string                                     |           |
| EXTRA_PARAMETERS_EGRESS  | Additional parameters for egress CAKE qdisc. Similar to INGRESS, but for outgoing traffic.                                                                     | string                                     |           |

### Advanced Settings

| **Config option**      | **Description**                                                                                                                                                                                                                                                                  | **Type**                         | **Default**        | 
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------- | ------------------ | 
| PRESERVE_CONFIG_FILES  | If enabled, configuration files are preserved during system upgrades. Ensures your QoS settings survive firmware updates.                                                                                                                                                        | boolean                          | 1                  | 
| WASHDSCPUP             | Sets DSCP to CS0 for outgoing packets after classification. This can help in networks where DSCP markings might be altered or cause issues downstream.                                                                                                                           | boolean                          | 1                  | 
| WASHDSCPDOWN           | Sets DSCP to CS0 for incoming packets before classification. This ensures that any DSCP markings from external sources don't interfere with your internal QoS rules.                                                                                                             | boolean                          | 1                  | 
| BWMAXRATIO             | Maximum ratio between download and upload bandwidth. Prevents ACK floods on highly asymmetric connections by limiting download speed relative to upload. For example, a value of 20 means download speed is capped at 20 times the upload speed.                                 | integer                          | 20                 | 
| ACKRATE                | Sets rate limit for TCP ACKs in packets per second. Helps prevent ACK flooding on asymmetric connections. Set to `0` to disable ACK rate limiting. A typical value is 5% of `UPRATE`.                                                                                            | integer                          | (UPRATE * 5 / 100) | 
| UDP_RATE_LIMIT_ENABLED | If enabled, downgrades UDP traffic exceeding 450 packets per second to lower priority. This helps prevent high-volume UDP applications from monopolizing bandwidth.                                                                                                              | boolean                          | 1                  | 
| TCP_UPGRADE_ENABLED    | **Boosts low-volume TCP traffic** by upgrading DSCP to AF42 for TCP connections with less than 150 packets per second. This improves responsiveness for interactive TCP services like SSH, web browsing, and instant messaging by giving them higher priority in the QoS system. | boolean                          | 1                  | 
| UDPBULKPORT            | UDP ports for bulk traffic. Often used for torrent traffic. Helps identify and manage high-bandwidth, lower-priority traffic. Specify ports as a comma-separated list or ranges (e.g., `51413,6881-6889`).                                                                       | string                           |                    | 
| TCPBULKPORT            | TCP ports for bulk traffic. Similar to `UDPBULKPORT`, but for TCP-based bulk transfers.                                                                                                                                                                                          | string                           |                    | 
| VIDCONFPORTS           | [Legacy - use rules] Ports used for video conferencing and other high-priority traffic. Uses the Fast Non-Realtime (1:12) queue. Specify ports as a comma-separated list or ranges.                                                                                              | string                           |                    | 
| REALTIME4              | [Legacy - use rules] IPv4 addresses of devices to receive real-time priority (only UDP). Useful for gaming consoles or VoIP devices that need consistent low latency.                                                                                                            | string                           |                    | 
| REALTIME6              | [Legacy - use rules] IPv6 addresses for real-time priority. Equivalent to `REALTIME4` but for IPv6 networks.                                                                                                                                                                     | string                           |                    | 
| LOWPRIOLAN4            | [Legacy - use rules] IPv4 addresses of devices to receive low priority. Useful for limiting impact of bandwidth-heavy but non-time-sensitive devices.                                                                                                                            | string                           |                    | 
| LOWPRIOLAN6            | [Legacy - use rules] IPv6 addresses for low priority. Equivalent to `LOWPRIOLAN4` but for IPv6 networks.                                                                                                                                                                         | string                           |                    | 
| MSS                    | **TCP Maximum Segment Size** for connections. This setting is only active when the upload or download bandwidth is less than 3000 kbit/s. Adjusting the MSS can help improve performance on low-bandwidth connections. Leave empty to use the default value.                     | integer                          | 536                | 
| NFT_HOOK               | Specifies the `nftables` hook point for the `dscptag` chain. Options are `forward`, and `postrouting`. The choice of hook point affects when in the packet processing the DSCP markings are applied.                                                                             | enum ( `forward`, `postrouting`) | `forward`          | 
| NFT_PRIORITY           | Sets the priority for the `nftables` chain. Lower values are processed earlier. Default is `0` - mangle is `-150`.                                                                                                                                                               | integer                          | 0                  | 

### DSCP Marking Rules

QoSmate allows you to define custom DSCP (Differentiated Services Code Point) marking rules to prioritize specific types of traffic. These rules are defined in the `/etc/config/qosmate` file under the `rule` sections and via luci-app-qosmate.

| Config option | Description                                                                                            | Type                                                                                                                      | Default |
| ------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | ------- |
| name          | A unique name for the rule. Used for identification and logging.                                       | string                                                                                                                    |         |
| proto         | The protocol to match. Determines which type of traffic the rule applies to.                           | enum (tcp, udp, icmp)                                                                                                     |         |
| src_ip        | Source IP address or range to match. Can use CIDR notation for networks.                               | string                                                                                                                    |         |
| src_port      | Source port or range to match. Can use individual ports or ranges like '1000-2000'.                    | string                                                                                                                    |         |
| dest_ip       | Destination IP address or range to match. Similar to src_ip in format.                                 | string                                                                                                                    |         |
| dest_port     | Destination port or range to match. Similar to src_port in format.                                     | string                                                                                                                    |         |
| class         | DSCP class to assign to matching packets. Determines how the traffic is prioritized in the QoS system. | enum (cs0, cs1, cs2, cs3, cs4, cs5, cs6, cs7, af11, af12, af13, af21, af22, af23, af31, af32, af33, af41, af42, af43, ef) |         |
| counter       | Enable packet counting for this rule. Useful for monitoring and debugging.                             | boolean                                                                                                                   | 0       |

#### Example rule configuration:
```
config rule 
	option name 'gaming_traffic' 
	option proto 'udp' 
	option src_ip '192.168.1.100' 
	option dest_port '3074' 
	option class 'cs5' 
	option counter '1'
```
This rule would mark UDP traffic from IP 192.168.1.100 to port 3074 with the CS5 DSCP class, which is typically used for gaming traffic, and enable packet counting for this rule.

#### Additional DSCP Marking Rule Examples

1. Prioritizing Video Conferencing Traffic:
```
config rule
    option name 'zoom_traffic'
    option proto 'tcp udp'
    list dest_port '3478-3479'
    list dest_port '8801-8802'
    option class 'af41'
    option counter '1'
```
Explanation: This rule marks both TCP and UDP traffic to typical Zoom ports with the DSCP class AF41. Using `list` for `dest_port` allows specifying multiple port ranges. AF41 is well-suited for interactive video conferencing as it provides high priority without impacting the highest priority traffic.

2. Low Priority for Peer-to-Peer Traffic:
```
config rule
    option name 'p2p_traffic'
    option proto 'tcp udp'
    list src_port '6881-6889'
    list dest_port '6881-6889'
    option class 'cs1'
    option counter '1'
```
Explanation: This rule assigns low priority to P2P traffic (like BitTorrent) by marking it as CS1. Using `list` for both `src_port` and `dest_port` covers both incoming and outgoing P2P traffic.

3. Call of Duty Game Traffic:
```
config rule
    option name 'cod1'
    option proto 'udp'
    option src_ip '192.168.1.208'
    option src_port '3074'
    option dest_port '30000-65535'
    option class 'cs5'
    option counter '1'

config rule
    option name 'cod2'
    option proto 'udp'
    option dest_ip '192.168.1.208'
    option dest_port '3074'
    option class 'cs5'
    option counter '1'
```
Explanation: These rules prioritize Call of Duty game traffic. The first rule targets outgoing traffic from the game console (IP 192.168.1.208), while the second rule handles incoming traffic. Both use CS5 class, which is typically used for gaming traffic due to its high priority. The wide range of destination ports in the first rule covers the game's server ports.

4. Generic Game Console/Gaming PC Traffic:
```
config rule
    option name 'Game_Console_Outbound'
    option proto 'udp'
    option src_ip '192.168.1.208'
    list dest_port '!=80'
    list dest_port '!=443'
    option class 'cs5'
    option counter '1'

config rule
    option name 'Game_Console_Inbound'
    option proto 'udp'
    option dest_ip '192.168.1.208'
    list src_port '!=80'
    list src_port '!=443'
    option class 'cs5'
    option counter '1'
```
Explanation: These rules provide a more generic approach to prioritizing game console/gaming pc traffic. The outbound rule prioritizes all UDP traffic from the console (192.168.1.208) except for ports 80 and 443 (common web traffic). The inbound rule does the same for incoming traffic. This approach ensures that game-related traffic gets priority while allowing normal web browsing to use default priorities. The use of '!=' (not equal) in the port lists demonstrates how to exclude specific ports from the rule.
This is more or less equivalent to the `realtime4` and `realtime6` variables from the SimpleHFSCgamer script. However, this rule is even better as it excludes UDP port 80 and 443, which are often used for QUIC. This is likely less of an issue on a gaming console than on a gaming PC, where a YouTube video using QUIC might be running alongside the game.

This rule is also applied when the auto-setup is used via CLI or UI and a Gaming Device IP (optional) is entered.

## Command Line Interface
QoSmate can be controlled and configured via the command line. The basic syntax is:
```
/etc/init.d/qosmate [command]
```
```
Available commands:
        start           Start the service
        stop            Stop the service
        restart         Restart the service
        reload          Reload configuration files (or restart if service does not implement reload)
        enable          Enable service autostart
        disable         Disable service autostart
        enabled         Check if service is started on boot
        running         Check if service is running
        status          Service status
        trace           Start with syscall trace
        info            Dump procd service info
        check_version   Check for updates
        update          Update qosmate
        auto_setup      Automatically configure qosmate
        expand_config   Expand the configuration with all possible options
        auto_setup_noninteractive   Automatically configure qosmate with no interaction
```
### Update QoSmate
```
/etc/init.d/qosmate update
```

## Troubleshooting
If you encounter issues with the script or want to verify that it's working correctly, follow these steps:

1. Disable DSCP washing (egress and ingress)
2. Update and install tcpdump: `opkg update && opkg install tcpdump`
3. Mark an ICMP ping to a reliable destination (e.g., 1.1.1.1) with a specific DSCP value using a DSCP Marking Rules.
4. Ping the destination from your LAN client.
5. Use `tcpdump -i <your wan interface> -v -n -Q out icmp` to display outgoing traffic (upload) and verify that the TOS value is not 0x0. Make sure to **set the right interface (WAN Interface).** 
6. Use `tcpdump -i ifb-<your wan interface> -v -n icmp` to display incoming traffic (download) and verify that the TOS value is not 0x0. Make sure to **set the right interface (ifb + <yourwaninterface)**
7. Install watch: `opkg update && opkg install procps-ng-watch`
8. Check traffic control queues:

   - When using HFSC as root qdisc:
     ```
     watch -n 2 'tc -s qdisc | grep -A 2 "parent 1:11"'
     ```
     Replace "1:11" with the desired class. The packet count should increase with the ping in both directions.

   - When using CAKE as root qdisc:
     ```
     watch -n 1 'tc -s qdisc show | grep -A 20 -B 2 "diffserv4"'
     ```

   The output will show you if packets are landing in the correct queue.

WIP...
(Include additional troubleshooting steps, such as how to verify if QoSmate is working correctly, common issues and their solutions, etc.)

## Uninstallation

To remove QoSmate from your OpenWrt router:

1. Stop and disable the QoSmate service:
```
/etc/init.d/qosmate stop
```
2. Remove the QoSmate files:
```
rm /etc/init.d/qosmate /etc/qosmate.sh /etc/config/qosmate
```
3. Remove the LuCI frontend files:
```
rm -r /www/luci-static/resources/view/qosmate
rm /usr/share/luci/menu.d/luci-app-qosmate.json
rm /usr/share/rpcd/acl.d/luci-app-qosmate.json
```
4. vRestart the rpcd and uhttpd services:
```
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```
5. Reboot your router to clear any remaining settings.

## Building qosmate and Luci-app-qosmate Packages for OpenWrt

1. Navigate to Your OpenWrt Buildroot Directory:
`cd /path/to/your/openwrt
`
2. Clone the QoSmate Package:
`mkdir -p package/qosmate
git clone https://github.com/hudra0/qosmate.git package/qosmate
`
3. Clone the LuCI QoSmate Package:
`mkdir -p package/luci-app-qosmate
git clone https://github.com/hudra0/luci-app-qosmate.git package/luci-app-qosmate`

## Contributing

Contributions to QoSmate are welcome! Please submit issues and pull requests on the GitHub repository.

## Acknowledgements

QoSmate is inspired by and builds upon the work of SimpleHFSCgamerscript, SQM, cake-qos-simple, qosify and DSCPCLASSIFY. I thank all contributors and the OpenWrt community for their valuable insights and contributions.
