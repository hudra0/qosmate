[![Ko‑Fi][ko_fi_shield]][ko_fi]
[![OpenWrt Forum][openwrt_forum_shield]][openwrt_forum]

[ko_fi_shield]: https://img.shields.io/static/v1.svg?label=%20&message=Ko-Fi&color=F16061&logo=ko-fi&logoColor=white
[ko_fi]: https://ko-fi.com/hudra

[openwrt_forum_shield]: https://img.shields.io/static/v1.svg?label=%20&message=OpenWrt%20Forum&style=popout&color=blue&logo=OpenWrt&logoColor=white
[openwrt_forum]: https://forum.openwrt.org/t/qosmate-yet-another-quality-of-service-tool-for-openwrt/

# QoSmate: Quality of Service for OpenWrt

QoSmate is a Quality of Service (QoS) tool for OpenWrt routers that aims to optimize network performance while allowing for controlled prioritization of specific traffic types. It uses nftables for packet classification and offers CAKE (Common Applications Kept Enhanced), HFSC (Hierarchical Fair Service Curve) and HTB queueing disciplines for traffic management. It uses tc-ctinfo to restore DSCP marks on ingress.

The project builds upon the amazing work of [@dlakelan](https://github.com/dlakelan) and his [SimpleHFSCgamerscript](https://github.com/dlakelan/routerperf/blob/master/SimpleHFSCgamerscript.sh), extending its capabilities and adding a user-friendly interface. QoSmate integrates concepts from various QoS systems, including SQM, DSCPCLASSIFY and cake-qos-simple to provide a comprehensive approach to traffic control.

> **Compatibility Note**: Officially, only OpenWrt is supported. Forks may introduce fundamental changes or adjustments that could impact compatibility or functionality.

Key aspects of QoSmate include
- Support for HFSC, CAKE, Hybrid and HTB queueing disciplines
- A LuCI-based interface for easy configuration
- DSCP marking and traffic prioritization options via CLI and UI
- Automatic package installation and setup
- Support for custom rules
- Dynamic and static IP sets
- Connection statistics

While QoSmate can benefit various types of network traffic, including gaming and other latency-sensitive applications, it is designed to improve overall network performance and should work well out of the box.

### ⚠️ Important Note:

**Effective QoS is about strategic prioritization, not blanket elevation of all traffic.**  
QoSmate allows you to prioritize specific traffic types, but it's crucial to use this capability **judiciously**. Over-prioritization can negate the benefits of QoS, as elevating too much traffic essentially equates to no prioritization at all.

> Remember that for every packet given preferential treatment, others may experience increased delay or even drops. The goal is to create a balanced, efficient network environment, not to prioritize everything.

## Requirements

QoSmate requires OpenWrt version 23.05 or later, utilizing Firewall 4 and nftables. While OpenWrt 22.03 offers nftables support, it lacks certain features essential for QoSmate's full functionality. A legacy branch is available for 22.03 compatibility, but I strongly recommend upgrading to the latest OpenWrt version, as there is generally no compelling reason to remain on 22.03.

## 1. Installation

Before installing QoSmate, ensure that:

1. Any existing QoS services or scripts (e.g., SQM, Qosify, DSCPCLASSIFY, SimpleHFSCgamerscript...) are disabled and stopped to avoid conflicts.
2. Your router is rebooted to clear out old settings for a clean start.

### a) Backend Installation

Install the QoSmate backend (which contains a main script/init script/hotplug and a config-file) with the following command:

```bash
LATEST_TAG=$(uclient-fetch -O - https://api.github.com/repos/hudra0/qosmate/releases/latest 2>/dev/null | grep -o '"tag_name":"[^"]*' | sed 's/"tag_name":"//') && \
uclient-fetch -O /etc/init.d/qosmate https://raw.githubusercontent.com/hudra0/qosmate/$LATEST_TAG/etc/init.d/qosmate && chmod +x /etc/init.d/qosmate && \
uclient-fetch -O /etc/qosmate.sh https://raw.githubusercontent.com/hudra0/qosmate/$LATEST_TAG/etc/qosmate.sh && chmod +x /etc/qosmate.sh && \
[ ! -f /etc/config/qosmate ] && uclient-fetch -O /etc/config/qosmate https://raw.githubusercontent.com/hudra0/qosmate/$LATEST_TAG/etc/config/qosmate; \
/etc/init.d/qosmate enable
```

### b) Frontend Installation

Install [luci-app-qosmate](https://github.com/hudra0/luci-app-qosmate) with this command:

```bash
LATEST_TAG=$(uclient-fetch -O - https://api.github.com/repos/hudra0/luci-app-qosmate/releases/latest 2>/dev/null | grep -o '"tag_name":"[^"]*' | sed 's/"tag_name":"//') && \
mkdir -p /www/luci-static/resources/view/qosmate /usr/share/luci/menu.d /usr/share/rpcd/acl.d /usr/libexec/rpcd && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/settings.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/settings.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/hfsc.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/hfsc.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/cake.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/cake.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/advanced.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/advanced.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/rules.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/rules.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/connections.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/connections.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/custom_rules.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/custom_rules.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/ipsets.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/ipsets.js && \
uclient-fetch -O /www/luci-static/resources/view/qosmate/statistics.js https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/htdocs/luci-static/resources/view/statistics.js && \
uclient-fetch -O /usr/share/luci/menu.d/luci-app-qosmate.json https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/root/usr/share/luci/menu.d/luci-app-qosmate.json && \
uclient-fetch -O /usr/share/rpcd/acl.d/luci-app-qosmate.json https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/root/usr/share/rpcd/acl.d/luci-app-qosmate.json && \
uclient-fetch -O /usr/libexec/rpcd/luci.qosmate https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/root/usr/libexec/rpcd/luci.qosmate && \
uclient-fetch -O /usr/libexec/rpcd/luci.qosmate_stats https://raw.githubusercontent.com/hudra0/luci-app-qosmate/$LATEST_TAG/root/usr/libexec/rpcd/luci.qosmate_stats && \
chmod +x /usr/libexec/rpcd/luci.qosmate && \
chmod +x /usr/libexec/rpcd/luci.qosmate_stats && \
/etc/init.d/rpcd restart && \
/etc/init.d/uhttpd restart
# End of command - Press Enter after pasting

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
   - **Root Queueing Discipline**: Choose between HFSC (default), CAKE, or Hybrid (HFSC + fq_codel realtime/bulk + CAKE for other traffic)
3. Apply the changes

#### Auto-setup Function

For users preferring automatic configuration, QoSmate offers an Auto-setup function:

1. In the QoSmate settings page, click "Start Auto Setup"
2. Optionally, enter your gaming device's IP address for prioritization
3. Wait for the speed test and configuration to complete

**Note**: Router-based speed tests may underestimate your actual connection speed. For more precise settings, run a speed test from a LAN device and manually input the results. The auto-setup provides a useful starting point, but manual fine-tuning may be necessary for optimal performance.

### d) Fine-Tuning Process (Optional)

#### 1. Determining Your Baseline Bandwidth
Before starting with QoSmate configuration:
1. Stop all QoS services on your router (Qosmate, SQM, etc.)
2. Perform multiple speed tests (preferably at different times of the day)
3. Note the lowest consistent speed you can achieve
4. Use 80-90% of this value for your QoSmate settings
   - Example: If your lowest reliable download is 300 Mbps, start with 270 Mbps (270000 kbps)
   - Example: If your lowest reliable upload is 20 Mbps, start with 18 Mbps (18000 kbps)

#### 2. Basic Configuration
1. Set your determined bandwidth values
2. Enable WASH in both directions (WASHDSCPUP and WASHDSCPDOWN)
3. Choose your Root Queueing Discipline:
   - For older/less powerful routers, use HFSC or HTB as it requires fewer system resources
   - Hybrid mode uses HFSC + gameqdisc for realtime and HFSC + fq_codel for bulk classes while CAKE manages all other traffic
4. Consider overhead settings:
   - Default settings are conservative to cover most use cases
   - It's better to overestimate overhead than to underestimate it
   - For specific overhead values based on your connection type, refer to:
     https://openwrt.org/docs/guide-user/network/traffic-shaping/sqm-details
5. Optimization with HFSC:
   - pfifo, bfifo, or fq_codel are good starting points for gameqdisc (personally, I use red with good results)
   - For MAXDEL:
     - Start with values between 8 and 16 ms
     - Important: Don't set it too low, as this could cause packet drops
     - Fine-tune based on your needs if necessary
6. Optimization with CAKE:
   - The default settings usually work well for most scenarios
   - No additional gaming-specific configuration needed

#### 3. Testing and Adjustment
1. Run a Waveform Bufferbloat Test (https://www.waveform.com/tools/bufferbloat)
2. Monitor your latency and jitter during the test
3. If results aren't satisfactory:
   - First, try reducing bandwidth settings in increments of 500-1000 kbps
   - Test again after each adjustment

Remember that these are starting points - optimal settings may depend on your specific hardware, connection etc.

## 2. QoSmate Configuration Settings

### Basic and Global Settings

| Config option | Description                                                                                                                                                                                                                    | Type              | Default |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ------- |
| enabled       | Enables or disables QoSmate. Set to 1 to enable, 0 to disable.                                                                                                             | boolean           | 1       |
| WAN           | Specifies the WAN interface. This is crucial for applying QoS rules to the correct network interface. It's typically the interface connected to your ISP.                                                                      | string            | eth1    |
| DOWNRATE      | Download rate in kbps. Set this to about 80-90% of your actual download speed to allow for overhead and prevent bufferbloat. This creates a buffer that helps maintain low latency even when the connection is fully utilized. | integer           | 90000   |
| UPRATE        | Upload rate in kbps. Set this to about 80-90% of your actual upload speed for the same reasons as DOWNRATE.                                                                                                                    | integer           | 45000   |
| ROOT_QDISC    | Specifies the root queueing discipline. Options are 'hfsc', 'cake', 'hybrid', or 'htb' | enum (hfsc, cake, hybrid, htb) | hfsc    |

### HFSC + Hybrid Specific Settings

| Config option       | Description                                                                                                                                                                                                                                                                                          | Type                                         | Default                 |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- | ----------------------- |
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
All cake settings are described in the tc-cake man. **Note: Link layer settings (COMMON_LINK_PRESETS, OVERHEAD, MPU, etc.) have been moved to Advanced Settings and are now shared by all QDiscs.**

| Config option            | Description                                                                                                                                                    | Type                                       | Default   |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | --------- |
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
| COMMON_LINK_PRESETS    | Link layer preset for overhead calculation. Used by all QDiscs (HTB, HFSC, Hybrid, CAKE) for consistent overhead compensation.                                                                                                                                                   | enum (ethernet, docsis, atm, vdsl, etc.) | ethernet |
| OVERHEAD               | Manual overhead setting in bytes. Overrides preset defaults. Default values: Ethernet=40 (HFSC/HTB), ATM=44, DOCSIS=25                                                                                                                                                          | integer                          |                    |
| MPU                    | Minimum packet unit size. Used primarily by CAKE, ignored by other QDiscs.                                                                                                                                                                                                       | integer                          |                    |
| LINK_COMPENSATION      | Additional link compensation (atm, ptm, noatm). Affects overhead calculations.                                                                                                                                                                                                   | string                           |                    |
| ETHER_VLAN_KEYWORD     | Ethernet VLAN keyword for CAKE. Ignored by other QDiscs.                                                                                                                                                                                                                         | string                           |                    |
| PRESERVE_CONFIG_FILES  | If enabled, configuration files are preserved during system upgrades. Ensures your QoS settings survive firmware updates.                                                                                                                                                        | boolean                          | 1                  | 
| WASHDSCPUP             | Sets DSCP to CS0 for outgoing packets after classification. This can help in networks where DSCP markings might be altered or cause issues downstream. [See detailed explanation](#wash-function-explanation) | boolean                          | 1                  | 
| WASHDSCPDOWN           | Sets DSCP to CS0 for incoming packets before classification. This ensures that any DSCP markings from external sources don't interfere with your internal QoS rules. [See detailed explanation](#wash-function-explanation) | boolean                          | 1                  | 
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

### Wash Function Explanation

The `wash` function in `qosmate` is a crucial feature for managing DSCP markings on network packets. It allows you to control whether DSCP values from external sources (ISP, LAN devices) are preserved or reset to CS0 (Default Forwarding).

**Important**: The wash function behaves differently between CAKE and HFSC/HTB/Hybrid modes.

---

#### CAKE Mode: Interface-Based Washing

In CAKE mode, washing is applied per network interface and corresponds directly to traffic direction:

**WASHDSCPUP (Egress Washing)** - Upload direction (applied on WAN interface):
- **What happens**: CAKE first classifies packets into priority tins based on their DSCP values, then re-marks all packets to CS0 before they leave to your ISP.
- **Why use it**: Prevents leaking DSCP markings to your ISP's network. Some ISPs treat marked packets adversely (increased latency, jitter, or packet loss) rather than honoring the prioritization.

**WASHDSCPDOWN (Ingress Washing)** - Download direction (applied on IFB interface):
- **What happens**: CAKE first classifies packets into priority tins based on their DSCP values, then re-marks all packets to CS0 before they enter your LAN.
- **Why use it**: Prevents ISP-set DSCP values from influencing your LAN devices. For example, on Wi-Fi networks, DSCP markings can affect WMM (Wi-Fi Multimedia) access class selection, where different classes have varying priorities.

---

#### HFSC/HTB/Hybrid Mode: Chain-Position-Based Washing

In HFSC, HTB, and Hybrid modes, washing is achieved through the nftables `dscptag` chain processing, as these qdiscs do not have wash functionality built-in like CAKE does.

**WASHDSCPDOWN (Ingress Washing)** - Applied at chain entry:
- **What happens**: All DSCP values are set to CS0 at the beginning of the nftables chain, affecting both upload and download traffic:
  - *Download*: Packets from the ISP are washed to CS0, then the chain is immediately skipped (these packets were already classified by tc). Result: ISP DSCP markings do not reach your LAN devices.
  - *Upload*: Packets from your LAN are washed to CS0 at chain entry, then continue through the chain where `qosmate` rules can assign new DSCP values based on your configuration.
- **Why use it**: Ensures a clean baseline - all traffic starts at CS0, and only your explicit `qosmate` rules determine DSCP markings. Prevents ISP markings from affecting LAN devices. For upload traffic, it prevents LAN devices from setting their own DSCP values and ensures that only `qosmate` controls DSCP assignment.

**WASHDSCPUP (Egress Washing)** - Applied at chain exit for WAN-bound packets:
- **What happens**: Only affects upload traffic. After all `qosmate` rules have been processed and packets are ready to leave via WAN, DSCP values are reset to CS0.
- **Why use it**: Prevents DSCP leak to your ISP. Works in combination with WASHDSCPDOWN: packets start at CS0, get marked by rules during chain processing, get classified by tc, then optionally washed again before leaving to ISP.
- **Note**: Download packets never reach this point in the chain (they exit earlier), so WASHDSCPUP only affects upload.

---

#### Recommendation

**For most users**: Enable both WASHDSCPUP and WASHDSCPDOWN. This ensures full control over DSCP markings - preventing ISP interference and ensuring only your `qosmate` rules determine traffic priority. 

**Disable washing only if**: You specifically need to preserve DSCP markings from trusted sources (e.g., your ISP actively honors QoS, or you're running a multi-router setup where DSCP values must be preserved across boundaries).

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

#### IPv6 Suffix Matching in Dynamic Prefix Environments

In IPv6 networks, your IP address often has a changing "prefix" (the first part of the address assigned by your ISP) while the "suffix" (the ending part) stays the same for your devices. QoSmate lets you create rules that match just the suffix, so your QoS settings keep working even when the prefix changes.

This is done using the `::suffix/::mask` format, which focuses on the ending bits of the address.

**Example rule:**

```shell
config rule
    option name 'my_device_ipv6'
    option src_ip '::1234:5678:90ab:cdef/::ffff:ffff:ffff:ffff'
    option class 'cs5'
    option enabled '1'
```

This rule matches any IPv6 address ending with `1234:5678:90ab:cdef`, no matter what the prefix is. The mask `::ffff:ffff:ffff:ffff` tells it to check only the last 64 bits (the suffix) of the address.

For more details and discussion, see GitHub Issue [#63](https://github.com/hudra0/qosmate/issues/63).

### Understanding DNS Traffic and DSCP Marking

QoSmate can only mark DNS traffic that passes through the FORWARD chain. Traffic to/from the router itself (INPUT/OUTPUT chains) is not marked by default.

#### DNS Traffic Scenarios

1. **DNS queries to/from the router (INPUT/OUTPUT chains)**
   - Client → Router's dnsmasq (INPUT chain)
   - Router → Upstream DNS servers (OUTPUT chain)
   - **Result**: Not marked by QoSmate's standard rules

2. **Direct external DNS queries (FORWARD chain)**
   - Client → 8.8.8.8, 1.1.1.1, etc.
   - **Result**: Can be marked by QoSmate rules

> **Note**: If you have DNS Intercept or Force DNS enabled, all DNS queries are redirected to the router's local DNS, converting scenario 2 into scenario 1. This prevents DSCP marking of DNS traffic.

#### Testing DNS Marking

Test from a LAN client:
```bash
nslookup google.com 8.8.8.8
```
Then check **Network → QoSmate → Connections** for DNS traffic (UDP port 53) with DSCP markings.

#### Marking Router DNS Traffic

To mark router-originated DNS traffic (e.g., router → upstream DNS), you can use Custom Rules with an OUTPUT hook. However, these rules will only mark egress traffic. If you also want ingress DSCP restoration, you'll need to implement logic that writes DSCP values to conntrack without overwriting existing values set by QoSmate for FORWARD traffic.

### IP Sets in QoSmate
QoSmate features an integrated IP Sets UI which allows you to manage both static and dynamic IP sets directly from the LuCI interface under **Network → QoSmate → IP Sets**. This replaces the "old" method of configuring sets via custom rules manually and simplifies the process of grouping IP addresses for DSCP marking.

> **⚠️ Important:** Mixing IPv4 and IPv6 addresses in the same IP set is not supported and will cause nftables errors. Make sure to create separate sets for IPv4 and IPv6 addresses. The 'family' option must match the IP version of all addresses in the set.

#### Configuration Options

| Option        | Description                                                                                                                                                | Type                     | Default |
|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------|---------|
| name          | Name of the IP set. Used to reference the set in QoS rules with the @ prefix (e.g., @gaming_devices). Must contain only letters, numbers, and underscores.  | string                   |         |
| mode          | Defines how the set is populated. 'static' for manually specified IP lists, 'dynamic' for automatically populated sets (e.g., via DNS resolution).           | enum (static, dynamic)   | static  |
| family        | Specifies the IP version for addresses in this set.                                                                                                         | enum (ipv4, ipv6)       | ipv4    |
| ip4           | List of IPv4 addresses or networks to include in the set. Only applicable when mode is 'static'.                                                            | list(string)            |         |
| ip6           | List of IPv6 addresses or networks to include in the set. Only applicable when mode is 'static'.                                                            | list(string)            |         |
| timeout       | Duration after which entries are removed from the set if not refreshed. Format: number + unit (s/m/h). Only applicable when mode is 'dynamic'.              | string                   | 1h      |
| enabled       | Enables or disables the IP set.                                                                                                                             | boolean                  | 1       |

#### Static IP Sets
Static IP sets are used to group together IP addresses that you want to manage collectively in your QoS rules. For example, you might want to create a set for all gaming devices on your network. Once created, you can reference these sets in your rules using the `@setname` syntax.

**Example:** Creating a static IP set named `@gaming_devices`:
```bash
config ipset
    option name 'gaming_devices'
    option mode 'static'
    option family 'ipv4'
    list ip4 '192.168.1.50'
    list ip4 '192.168.1.51'
    list ip4 '192.168.1.52'
    list ip4 '192.168.1.53'
```
This set can then be referenced in your QoS rules:
```bash
config rule
    option name 'Gaming Priority'
    option proto 'udp'
    list src_ip '@gaming_devices'    
    list dest_port '!=80'
    list dest_port '!=443'    
    option class 'cs5'    
    option counter '1'
    option enabled '1'
```

#### Dynamic IP Sets
Dynamic IP sets are designed to be populated by external processes such as `dnsmasq-full`. With dynamic sets, IP addresses can be added automatically, for example based on DNS resolution of specified domains. This facilitates domain-based marking without manually updating IP addresses. More information can be found in the [Openwrt dnsmasq Ipset documentation](https://openwrt.org/docs/guide-user/base-system/dhcp#ip_sets).

**⚠️ Important:** Requires the dnsmasq-full package.

1. Create a dynamic IP set in QoSmate's UI:
```bash
config ipset
    option name 'streaming_services'
    option mode 'dynamic'
    option family 'ipv4'
    option timeout '2h'
```

2. Configure `/etc/config/dhcp` to populate the set or use LuCI under **Network → DHCP and DNS → IP Sets** - make sure to reference the qosmate nftables table called dscptag:
```bash
config ipset
    list name 'streaming_services'
    list domain 'netflix.com'
    list domain 'youtube.com'
    option table 'dscptag'
    option table_family 'inet'
```

3. Create a rule using the dynamic set:
```bash
config rule
    option name 'Video Streaming'
    option class 'af41'
    list dest_ip '@streaming_services'
    option counter '1'
    option enabled '1'
```

> **Usage Note:** Dynamic IP sets are only tested with `dnsmasq-full`, other DNS resolvers (such as AdGuard or Unbound) are not tested.

## Rate Limiting

QoSmate includes an integrated rate limiting feature that allows you to set bandwidth limits for specific devices or subnets using nftables meters. This is useful for controlling bandwidth usage of individual clients, preventing bandwidth-hogging, or enforcing fair usage policies.

> **Important:** Rate limiting is a **policer**, not a traffic shaper or AQM (Active Queue Management) system. It enforces hard bandwidth limits by dropping packets that exceed the configured rate, but does **not** manage queues or prevent bufferbloat. Rate limits complement QoSmate's QoS system but do not replace it. For optimal latency and bufferbloat control, continue using QoSmate's HFSC/CAKE/HTB traffic shaping with proper bandwidth settings. Use rate limits for **bandwidth enforcement**, not latency optimization.

### Configuration

Rate limits are configured via the LuCI interface under **Network → QoSmate → Rate Limits** or directly in `/etc/config/qosmate` using the `ratelimit` section type.

#### Configuration Options

| Option | Description | Type | Default |
|--------|-------------|------|---------|
| name | Descriptive name for the rate limit rule | string | |
| enabled | Enables or disables this rate limit rule | boolean | 1 |
| target | List of IP/IPv6 addresses or subnets to limit. Supports negation (!=) and set references (@setname) | list(string) | |
| download_limit | Maximum download speed in Kbit/s (0 = unlimited) | integer | 10000 |
| upload_limit | Maximum upload speed in Kbit/s (0 = unlimited) | integer | 10000 |
| burst_factor | Burst allowance multiplier. 0 = strict limiting, 1.0 = rate as burst, higher = more burst | float | 1.0 |

#### Target Format Examples

The `target` option accepts various formats:

- **Single IP**: `192.168.1.100`
- **Subnet**: `192.168.1.0/24`
- **IPv6 address**: `2001:db8::1`
- **IPv6 subnet**: `2001:db8::/64`
- **IP set reference**: `@guest_devices`
- **Negation**: `!=192.168.1.77` (exclude from subnet limit)
- **Multiple targets**: Use multiple `list target` entries or combine in UI

### Usage Examples

#### Example 1: Basic Device Bandwidth Limit

Limit a single device to 10 Mbit/s (10000 Kbit/s) download and upload:

```bash
config ratelimit
    option name 'Guest Device'
    option enabled '1'
    list target '192.168.1.100'
    option download_limit '10000'
    option upload_limit '10000'
    option burst_factor '1.0'
```

#### Example 2: Guest Network with Exceptions

Limit all guest network devices to 5 Mbit/s (5000 Kbit/s), except for VIP guests:

```bash
config ratelimit
    option name 'Guest Network Limit'
    option enabled '1'
    list target '192.168.100.0/24'
    list target '!=192.168.100.77'
    list target '!=192.168.100.88'
    option download_limit '5000'
    option upload_limit '5000'
    option burst_factor '1.5'
```

The `burst_factor` of 1.5 allows temporary speeds up to 7.5 Mbit/s (7500 Kbit/s) for better user experience.

#### Example 3: Using IP Sets for Flexible Management

First, create an IP set for devices to limit:

```bash
config ipset
    option name 'limited_devices'
    option mode 'static'
    option family 'ipv4'
    list ip4 '192.168.1.150'
    list ip4 '192.168.1.151'
    list ip4 '192.168.1.152'
    option enabled '1'
```

Then reference it in a rate limit rule:

```bash
config ratelimit
    option name 'Limited Devices Group'
    option enabled '1'
    list target '@limited_devices'
    option download_limit '20000'
    option upload_limit '10000'
    option burst_factor '1.0'
```

#### Example 4: IPv6 Rate Limiting

Limit IPv6 devices using direct addresses or sets:

```bash
config ipset
    option name 'ipv6_guests'
    option mode 'static'
    option family 'ipv6'
    list ip6 '2001:db8:1234::100'
    list ip6 '2001:db8:1234::101'
    option enabled '1'

config ratelimit
    option name 'IPv6 Guest Limit'
    option enabled '1'
    list target '@ipv6_guests'
    option download_limit '15000'
    option upload_limit '15000'
    option burst_factor '1.2'
```

### Technical Implementation

Rate limits are implemented using nftables meters integrated into the `dscptag` table. The system generates separate rules for IPv4 and IPv6 traffic to ensure correct meter expressions:

- **Download limiting**: Uses `ip daddr` (IPv4) or `ip6 daddr` (IPv6) matching with corresponding meter keys
- **Upload limiting**: Uses `ip saddr` (IPv4) or `ip6 saddr` (IPv6) matching with corresponding meter keys
- **Burst control**: Burst allows temporary exceeding of the rate limit using a "token bucket" mechanism. The `burst_factor` multiplies the rate limit to determine the burst size. For example, with a 10000 Kbit/s (10 Mbit/s) limit and `burst_factor` = 1.0, the device can burst up to 10000 Kbit/s above the rate for short periods (total 20000 Kbit/s briefly). A `burst_factor` of 1.5 allows bursting up to 15000 Kbit/s above the 10000 Kbit/s rate. Without burst (`burst_factor` = 0), traffic is strictly limited to the configured rate with no temporary exceeding. 

Example generated nftables rules:

```bash
# IPv4 download limit (traffic TO device)
ip daddr 192.168.1.100 meter guest_dl4 { ip daddr limit rate over 1250 kbytes/second burst 1875 kbytes } counter drop

# IPv6 upload limit (traffic FROM device)
ip6 saddr 2001:db8::1 meter guest_ul6 { ip6 saddr limit rate over 1250 kbytes/second } counter drop
```

### Important Notes

- **MAC addresses are not supported** due to technical limitations with nftables meters in forward chains. Use IP addresses or DHCP reservations instead.
- **Conversion**: Rate limits are entered in Kbit/s (UI) but converted to kbytes/second for nftables (1 Kbit/s = 0.125 kbytes/second).
- **Decimal format**: Both European (comma) and American (period) decimal separators are supported in the UI (e.g., "1,5" or "1.5").
- **Burst factor range**: Valid values are 0.0 to 10.0. Use lower values (0-2.0) for most scenarios.
- **Integration**: Rate limits work independently of DSCP marking and do not interfere with QoS prioritization.

### Monitoring

Rate limit effectiveness can be monitored by checking the nftables counters:

```bash
nft list table inet dscptag | grep -A 5 'chain ratelimit'
```

The `counter packets` value shows how many packets were dropped due to rate limiting. Active limiting is indicated by increasing counter values.

## Connections Tab

The Connections tab provides a real-time view of all active network connections, including their DSCP markings and traffic statistics. This feature helps you monitor and verify your QoS configuration.

### Key Features:
- Real-time connection monitoring
- DSCP marking visualization
- Traffic statistics (bytes, packets)
- Traffic metrics:
  • Packets per second (PPS) - Often reflects game-server tickrate in games
    - ~20 PPS: Games like Warzone (20 tick)
    - ~60 PPS: Call of Duty multiplayer (60 tick)
    - ~128 PPS: Counter-Strike (128 tick)
  • Bandwidth usage (Kbit/s)
- Advanced filtering capabilities

### Advanced Filtering
The connections table includes a filtering system that allows you to combine multiple search criteria:

- Multiple search terms can be combined using spaces
- Each term is matched against all relevant fields (Protocol, IP, Port, DSCP)
- Search terms work with AND logic (all terms must match)

Example searches:
```
tcp 80           # Shows all TCP connections on port 80
192.168 udp      # Shows all UDP connections involving IPs containing "192.168"
ef 192.168 3074  # Shows connections matching IP "192.168" AND port "3074" AND DSCP class "EF"
```

### Adjustable View
The table view can be customized using the zoom control, allowing you to adjust the display density based on your preferences and screen size.

## Custom Rules Configuration
Custom rules can be used to implement advanced features like rate limiting, domain-based traffic marking, or DSCP marking based on traffic rates and throughput thresholds using nftables syntax. QoSmate offers two distinct approaches for implementing custom nftables rules, each suited for different use cases and requirements:

### Rule Types Overview

#### 1. Custom Rules (Full Table)
Custom Rules create a completely separate nftables table (`qosmate_custom`) where you can use independent chains, hooks, and priorities.

**Advantages:**
- Define custom hooks (input, output, ingress, forward, postrouting) and priorities
- Completely separate from QoSmate's main logic

**Disadvantages:**
- **No QoSmate Integration**: Custom rules bypass some of QoSmate's core features:
  - No automatic DSCP conntrack writing
  - No priority map integration (necessary when using HFSC, Hybrid and HTB)
  - Washing has to be done manually (at least when using non CAKE root qdisc)
- **More Complex Setup**: Requires understanding of nftables table/chain/hook/priority structure

#### 2. Inline Rules (Integrated)
Inline Rules are directly integrated into QoSmate's main `dscptag` chain, running at the same hook and priority as QoSmate's core logic. They are inserted right before the user defined rules which means they can be overwritten by user-defined rules.

**Advantages:**
  - Automatic DSCP conntrack writing/restoring
  - Priority map integration (Only necessary when using HFSC, Hybrid and HTB)
  - Washing functionality
   - No need to define tables, chains, or hooks


**Disadvantages:**
- Cannot use custom hooks/priorities or define custom chain structures

**Best for**: Users who want to add specific/special DSCP markings, rate limits, or packet matching that should integrate with QoSmate's main traffic processing logic.

### Technical Implementation

Before using either approach, ensure you are familiar with nftables syntax and basic networking concepts. Rules are processed in order of their priority values, with lower numbers being processed first.

#### Custom Rules (Full Table)
> **Note**: QoSmate automatically wraps your custom rules in `table inet qosmate_custom { ... }`. You only need to define the sets and chains within this table.

Custom rules are stored in `/etc/qosmate.d/custom_rules.nft` and are validated before being applied. Any syntax errors will prevent the rules from being activated.

#### Inline Rules (Integrated)
Inline rules are stored in `/etc/qosmate.d/inline_dscptag.nft` and contain only nftables statements (no table/chain definitions). These rules are directly included in QoSmate's `dscptag` chain and run at hook `$NFT_HOOK` with priority `$NFT_PRIORITY`.

> **Important**: Inline rules must contain only nftables statements. Do not include `table`, `chain`, `type`, `hook`, or `priority` keywords as they will cause validation errors.

### Inline Rules Examples

#### Example 1: Simple DSCP Marking (Inline)
Mark traffic from a specific gaming device with high priority:

```bash
# Mark gaming traffic from specific IP as high priority
ip saddr 192.168.1.100 ip dscp set cs5 comment "Gaming PC priority"

# Rate limit / mark bulk TCP traffic 
meta l4proto tcp limit rate 100/second ip dscp set cs1 comment "Bulk TCP limit"

# Mark VoIP traffic from specific port range
udp sport 5060-5070 ip dscp set ef comment "SIP/RTP VoIP traffic"
```

#### Example 2: Advanced Traffic Shaping (Inline)
Apply different DSCP markings based on packet rates and protocols:

```bash
# Mark high-volume TCP connections as bulk traffic
tcp flags & (fin|syn|rst|ack) != 0 limit rate over 200/second ip dscp set cs1 comment "High-rate TCP to bulk"

# Prioritize low-latency UDP gaming traffic
udp sport 3074 limit rate under 150/second ip dscp set cs5 comment "Gaming UDP priority"
udp dport 3074 limit rate under 150/second ip dscp set cs5 comment "Gaming UDP priority"

# Mark streaming video traffic  
tcp dport 443 ct bytes > 10000000 ip dscp set af41 comment "HTTPS video streaming"
```

### Custom Rules Examples (Full Table)

#### Example 3: Rate Limiting Marking
This example demonstrates how to mark traffic from a specific IP address when it exceeds a certain packet rate:

```bash
chain forward {
    type filter hook forward priority 0; policy accept;
    
    # Mark high-rate TCP traffic from specific IP
    ip saddr 192.168.138.100 tcp flags & (fin|syn|rst|ack) != 0
    limit rate over 300/second burst 300 packets
    counter ip dscp set cs1
    comment "Mark TCP traffic from 192.168.138.100 exceeding 300 pps as CS1"
}
```
#### Example 4: Domain-Based marking
To mark connections based on their FQDN (Fully Qualified Domain Name), you can utilize IP sets (nftsets) in conjunction with DNS resolution. This approach allows for dynamic DSCP marking of traffic to specific domains. 

**⚠️ Important:** Requires the dnsmasq-full package.

1. Create the custom rules:

```bash
# Define dynamic set for domain IPs
set domain_ips {
    type ipv4_addr
    flags dynamic, timeout
    timeout 1h
}

chain forward {
    type filter hook forward priority -10; policy accept;
    
    # Mark traffic to/from the domains' IPs
    ip daddr @domain_ips counter ip dscp set cs4 \
        comment "Mark traffic to resolved domain IPs"
    ip saddr @domain_ips counter ip dscp set cs4 \
        comment "Mark traffic from resolved domain IPs"
    }
```
> Note: If you want the DSCP value to be restored on ingress (incoming traffic) as well, please consider the following: Especially when using HFSC, the corresponding chain must be executed before QoSmate. In this case, the Ingress DSCP Washing in QoSmate should be disabled.

2. In /etc/config/dhcp, add the ipset configuration:
```
config ipset
        list name 'domain_ips'
        list domain 'example.com'
        option table 'qosmate_custom'
        option table_family 'inet'
```
This setup:
1. Creates an ipset named domain_ips in the qosmate_custom table.
2. Automatically adds resolved IPs for example.com to the set.
3. Uses the custom rules to mark the traffic.

The postrouting priority (10) ensures these rules run after QoSmate's default rules.

### Management via LuCI Interface

Both Custom Rules and Inline Rules can be managed through the QoSmate web interface:

1. Navigate to **Network → QoSmate → Custom Rules**
2. **Custom Rules (Full Table)**: Use the first textarea for complete nftables table definitions with chains and hooks
3. **Inline Rules**: Use the second textarea for simple nftables statements that integrate with QoSmate's dscptag chain
4. **Validation**: Both rule types are automatically validated before being applied
5. **Examples**: Each textarea includes collapsible examples to guide rule creation

Additional management options:
- Use **Network → DHCP and DNS → IP Sets** to configure domain-based rules
- After adding rules, verify they are active:
  ```bash
  nft list table qosmate_custom    # View custom rules (full table)
  nft list table inet dscptag     # View dscptag table (shows inline rules)
  ```
- Monitor rule effectiveness using the **Connections** tab

#### Example 5: Bandwidth Limiting with Custom Rules

QoSmate allows you to implement targeted bandwidth limiting for specific devices, applications, or ports using custom nftables rules. This functionality is particularly useful for restricting the network usage of certain clients or preventing bandwidth-intensive applications from impacting network performance.

> **Note on Conversion**: Nftables doesn't accept kbit/s as a unit. To convert from kbit/s to kbytes/second, simply divide by 8. Example: 4000 kbit/s equals 500 kbytes/second.

#### Basic Rate Limiting Per Direction

This example shows how to limit bandwidth for a specific device (192.168.1.100) to 4000 kbit/s (= 500 kbytes/s) in both directions:

```
chain forward {
    type filter hook forward priority 0; policy accept;
    
    # Limit download traffic to 192.168.1.100 to 4000 kbit/s (= 500 kbytes/s)
    ip daddr 192.168.1.100 limit rate over 500 kbytes/second counter drop
    
    # Limit upload traffic from 192.168.1.100 to 4000 kbit/s (= 500 kbytes/s)
    ip saddr 192.168.1.100 limit rate over 500 kbytes/second counter drop
}
```

These rules use the `limit rate over` matcher to drop packets that exceed the specified threshold. The `counter` allows monitoring of dropped packets.

#### Rate Limiting with Burst Allowance

In many cases, it's beneficial to allow short burst data transfers. The `burst` parameter allows a client to temporarily exceed the limit:

```
chain forward {
    type filter hook forward priority 0; policy accept;
    
    # Limit download with burst allowance
    ip daddr 192.168.1.100 limit rate over 500 kbytes/second burst 500 kbytes counter drop
    
    # Limit upload with burst allowance
    ip saddr 192.168.1.100 limit rate over 500 kbytes/second burst 500 kbytes counter drop
}
```

The `burst` option is particularly useful for applications that transfer data in bursts, as it provides a better user experience while still limiting average bandwidth.

#### Port-Based Rate Limiting

To limit traffic for a specific application port, you can use the conntrack mechanism (`ct`):

```
chain forward {
    type filter hook forward priority 0; policy accept;
    
    # Limit traffic with destination port 3074 to 1 MB/s (8 Mbit/s)
    ct original proto-dst 3074 limit rate over 1 mbytes/second counter drop
}
```

This rule limits all traffic with destination port 3074 in the original conntrack entry to 1 MB/s (8 Mbit/s). This is useful for limiting specific services like gaming traffic (port 3074 is used by Xbox Live, for example).

#### Combined IP and Port Limiting

For more precise control, you can combine IP addresses and ports:

```
chain forward {
    type filter hook forward priority 0; policy accept;
    
    # Limit traffic to/from 192.168.1.100 with destination port 3074 to 1 MB/s
    ip saddr 192.168.1.100 ct original proto-dst 3074 limit rate over 1 mbytes/second counter drop
    ip daddr 192.168.1.100 ct reply proto-src 3074 limit rate over 1 mbytes/second counter drop
}
```

This example shows:
1. The first rule limits outgoing traffic from 192.168.1.100 to port 3074
2. The second rule limits incoming traffic to 192.168.1.100 from port 3074 (reply traffic)

Note the use of `ct reply proto-src` to correctly identify return traffic.

#### Protocol-Specific Rate Limiting

To target bandwidth limits specifically to certain protocols (like UDP), you can combine protocol specification with rate limiting:

```
chain forward {
    type filter hook forward priority 0; policy accept;
    
    # Limit UDP traffic to port 3074 to 1 MB/s (8 Mbit/s)
    meta l4proto udp ct original proto-dst 3074 limit rate over 1 mbytes/second counter drop
    
    # Limit UDP traffic from port 3074 to 1 MB/s (8 Mbit/s)
    meta l4proto udp ct original proto-src 3074 limit rate over 1 mbytes/second counter drop
}
```
This approach specifically targets UDP traffic to/from port 3074 (commonly used for Xbox gaming), ensuring other protocols remain unaffected.

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
QoSmate includes a flexible update system to keep your installation current with the latest features and improvements.

#### Basic Update

To update QoSmate to the latest release version:

```bash
/etc/init.d/qosmate update
```

This command will:
- Check for updates to both backend and frontend components
- Download and install the latest release versions if available
- Restart the service automatically if required

QoSmate will preserve your existing configuration settings during updates.

#### Advanced Update Options

For more control over the update process, QoSmate supports several command-line options:

```bash
/etc/init.d/qosmate update [options]
```

| Option | Description | Example |
| ------ | ----------- | ------- |
| `-c COMPONENT` | Update only a specific component (BACKEND or FRONTEND) | `-c BACKEND` |
| `-v VERSION_OR_CHANNEL` | Specify version or channel in various formats: <br>- Version number: `-v 1.2.0` <br>- Channel selection: `-v release`, `-v snapshot` <br>- Branch selection: `-v branch=dev` <br>- Commit hash: `-v commit=a1b2c3d4` | `-v 1.2.0` |
| `-f` | Force update even if no newer version is available | `-f` |
| `-i` | Ignore cache results | `-i` |
| `-U CHANNEL` | Override update channel (takes precedence over -v) | `-U snapshot` |

#### Update Channels

- `release`: Stable versions (recommended for most users)
- `snapshot`: Latest code from the main branch
- `branch=NAME`: Code from a specific branch
- `commit=HASH`: Specific commit version

#### Usage Examples

Check for available updates without installing them:
```bash
/etc/init.d/qosmate check_version
```

Update only the backend component:
```bash
/etc/init.d/qosmate update -c BACKEND
```

Update to a specific version:
```bash
/etc/init.d/qosmate update -v 1.2.0
```

Update to the latest release version:
```bash
/etc/init.d/qosmate update -v release
```

Update to the latest snapshot (development) version:
```bash
/etc/init.d/qosmate update -v snapshot
```

Update to a specific branch:
```bash
/etc/init.d/qosmate update -v branch=dev
```

Update to a specific commit hash:
```bash
/etc/init.d/qosmate update -v commit=a1b2c3d4e5f6...
```

> **Note**: The default update approach (using the release channel) is recommended for most users. Other update channels and options are primarily intended for testing and development purposes.

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

## QoSmate Issue Report Template

Please use this template when reporting issues with QoSmate. Providing complete information helps identify and resolve problems more quickly.

### System Information and Configuration

Please run this command and provide the complete output:

```bash
/etc/init.d/qosmate status
```

### Connection Details

1. Subscribed bandwidth:
   - Download speed (Mbps): 
   - Upload speed (Mbps):
2. Connection type (DSL/Cable/Fiber):

### Bufferbloat Test Results

Please provide Waveform bufferbloat test results (https://www.waveform.com/tools/bufferbloat):

1. Test without QoSmate:
   - Screenshot or link to test results: 

2. Test with QoSmate enabled:
   - Screenshot or link to test results: 

### Issue Description

1. What's the problem? (Be specific)
2. When did it start? (After an update, configuration change, etc.)
3. Can you reliably reproduce the issue?
4. What have you tried to resolve it?

### Steps to Reproduce

1.
2.
3.

### Expected Behavior

What should happen?

### Actual Behavior

What actually happens?

### Additional Information

- Have you reviewed the QoSmate documentation?
- Have you checked the OpenWrt forum thread for similar issues?
- Are there any relevant log messages? (Check with `logread | grep qosmate`)
- If gaming-related, what game/platform are you using?

### Checklist

Please confirm:
- [ ] I've provided all system information requested above
- [ ] I've included my complete QoSmate configuration
- [ ] I've provided bufferbloat test results both with and without QoSmate
- [ ] I've checked the documentation and forum for similar issues
- [ ] I'm using the latest version of QoSmate
- [ ] I've disabled all other QoS solutions (SQM, etc.)

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

## Resetting to Default Configuration

To reset QoSmate to its default configuration, you can use the following command. This will backup your current configuration and download the default one from the repository:

```bash
mv /etc/config/qosmate /etc/config/qosmate.old && wget -O /etc/config/qosmate https://raw.githubusercontent.com/hudra0/qosmate/main/etc/config/qosmate && /etc/init.d/qosmate restart
```

Note: Make sure to review and adjust the default configuration as needed for your specific setup.

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

## QoSmate Traffic Shaping: HFSC, HTB and CAKE

QoSmate supports three traffic shaping systems: HFSC, HTB and CAKE. Each combines queueing disciplines (qdiscs) with bandwidth control mechanisms to provide different approaches to traffic management and prioritization.

### HFSC (Hierarchical Fair Service Curve)

HFSC in QoSmate creates a hierarchical queueing structure with integrated traffic shaping that divides traffic into distinct classes with different service guarantees. The system offers control over both bandwidth and latency for different traffic types.

#### HFSC Queue Structure
![image](https://github.com/user-attachments/assets/8e2948e9-6ffa-46ff-b9e2-43e0f370bc82)

QoSmate's HFSC implementation organizes traffic into 5 main classes:

1. **Realtime Class (1:11)** - Highest priority class for gaming and latency-sensitive applications
   - Handles packets marked with DSCP values CS5, CS6, CS7, and EF
   - Limited to GAMEUP/GAMEDOWN bandwidth (configurable, defaults to 15% of total bandwidth + 400kbps)
   - Uses configurable qdisc (pfifo, bfifo, red, fq_codel, or netem)

2. **Fast Interactive Class (1:12)** - For interactive, non-gaming applications
   - Handles packets marked with DSCP values CS4, AF41, and AF42
   - Gets 30% of bandwidth under congestion

3. **Normal Class (1:13)** - Default class for general browsing and unmarked traffic
   - Handles packets with default (CS0) DSCP marking
   - Gets 45% of bandwidth under congestion

4. **Low Priority Class (1:14)** - For background transfers
   - Handles packets marked with DSCP value CS2
   - Gets 15% of bandwidth under congestion

5. **Bulk Class (1:15)** - Lowest priority class for long-running transfers
   - Handles packets marked with DSCP value CS1
   - Gets 10% of bandwidth under congestion
   - Perfect for torrents, large backups, and other bandwidth-intensive but delay-tolerant traffic

#### How HFSC Prioritization Works

HFSC uses service curves to control bandwidth allocation and latency:

1. **Realtime Traffic (Gaming)**
   - Gets guaranteed minimum bandwidth regardless of other traffic
   - Uses qdisc configurable via `gameqdisc` option
   - Can use RED, FQ_CODEL, PFIFO, BFIFO or NETEM qdisc for fine-tuned control

2. **Non-Realtime Traffic**
   - Uses either FQ_CODEL or CAKE qdisc (configurable)
   - Fair allocation within each class
   - Classes only compete when link is saturated

3. **Bandwidth Utilization**
   - When bandwidth is available, any class can use more than its allocation
   - When congestion occurs, each class is limited to its fair share according to class priority

#### HFSC Configuration Example

Here's a basic example of how QoSmate configures HFSC queues:

```
# Create root qdisc with proper overhead
tc qdisc replace dev $WAN stab overhead 40 linklayer ethernet handle 1: root hfsc default 13

# Define overall bandwidth limit
tc class add dev $WAN parent 1: classid 1:1 hfsc ls m2 "${RATE}kbit" ul m2 "${RATE}kbit"

# Create realtime class with guaranteed bandwidth
tc class add dev $WAN parent 1:1 classid 1:11 hfsc rt m1 "${gameburst}kbit" d "${DUR}ms" m2 "${gamerate}kbit"

# Create non-realtime classes with different priorities
tc class add dev $WAN parent 1:1 classid 1:12 hfsc ls m1 "$((RATE*70/100))kbit" d "${DUR}ms" m2 "$((RATE*30/100))kbit"
tc class add dev $WAN parent 1:1 classid 1:13 hfsc ls m1 "$((RATE*20/100))kbit" d "${DUR}ms" m2 "$((RATE*45/100))kbit"
tc class add dev $WAN parent 1:1 classid 1:14 hfsc ls m1 "$((RATE*7/100))kbit" d "${DUR}ms" m2 "$((RATE*15/100))kbit"
tc class add dev $WAN parent 1:1 classid 1:15 hfsc ls m1 "$((RATE*3/100))kbit" d "${DUR}ms" m2 "$((RATE*10/100))kbit"
```

### Hybrid Mode (HFSC + CAKE)

Hybrid mode sets HFSC as the root scheduler and uses three classes:

1. **Realtime Class (1:11)**
   - Handles EF/CS5/CS6/CS7 traffic with the selected `gameqdisc`.
2. **CAKE Class (1:13)**
   - Manages most traffic with CAKE for fairness and host isolation.
3. **Bulk Class (1:15)**
   - Uses HFSC with `fq_codel` for CS1 bulk traffic.

This approach keeps latency low for realtime flows while benefiting from CAKE's advanced features for general traffic.

### HTB (Hierarchical Token Bucket)

HTB in QoSmate creates a hierarchical queueing structure with three classes using FQ-CoDel as leaf qdiscs.

#### HTB Queue Structure

QoSmate's HTB implementation organizes traffic into 3 main classes:

1. **Priority Class (1:11)** - Highest priority for realtime/gaming traffic
   - Handles packets marked with DSCP values EF, CS5, CS6, CS7
   - Guaranteed minimum rate scaling with bandwidth (5-40% hyperbolic curve, min 800 kbit)
   - Uses FQ-CoDel with aggressive settings (lower target/interval)

2. **Best Effort Class (1:13)** - Default for general traffic
   - Handles unmarked packets and most traffic
   - Guaranteed ~16% rate, can use up to almost full bandwidth
   - Uses FQ-CoDel with standard settings

3. **Background Class (1:15)** - Lowest priority for bulk traffic
   - Handles packets marked with DSCP CS1
   - Guaranteed ~16% rate, can use up to almost full bandwidth
   - Uses FQ-CoDel with relaxed settings (higher target/interval)

#### How HTB Prioritization Works

- Dynamic scaling of class rates and parameters based on total bandwidth
- Burst allowances for brief speed increases without bufferbloat
- Priority-based scheduling: Higher priority classes get excess bandwidth first (borrowing from unused capacity)
- Fair sharing within classes using FQ-CoDel

HTB provides simple 3-tier prioritization with automatic parameter tuning for different connection speeds.

### CAKE (Common Applications Kept Enhanced)

CAKE is a comprehensive traffic control system that combines queue management with traffic shaping. More information can be found [here](https://www.bufferbloat.net/projects/codel/wiki/CakeTechnical/) and [here](https://man7.org/linux/man-pages/man8/tc-cake.8.html).
#### CAKE Features in QoSmate

1. **Diffserv Traffic Prioritization** (Diffserv3, Diffserv4 and Diffserv8)
   - QoSmate uses diffserv4 by default, creating 4 tiers of service:
     - Highest: Voice (CS7, CS6, EF)
     - High: Video (CS5, CS4, AF4x)
     - Medium: Best Effort (CS0, AF1x, AF2x, AF3x)
     - Low: Background (CS1, CS2, CS3)
   - Each tier gets progressively less bandwidth and priority

2. **Host Isolation**
   - Ensures fair bandwidth allocation between different devices on your network
   - Prevents a single device from monopolizing bandwidth
   - Implemented as dual-srchost (for upload) and dual-dsthost (for download)

3. **Advanced Queue Management**
   - Automatically manages buffers to prevent bufferbloat
   - Built-in ACK filtering for asymmetric connections
   - Wash option to control DSCP marking behavior


### DSCP Marking

QoSmate uses DSCP (Differentiated Services Code Point) marking to classify and prioritize traffic. The dscptag system classifies traffic based on protocols, ports, and IP addresses, stores values in connection tracking for consistent bidirectional handling, and directs packets to the appropriate queues.

## Technical Implementation

### Traffic Shaping Implementation

QoSmate handles Quality of Service in both upload and download directions. The implementation leverages Connection Tracking Information (CTInfo) for efficient traffic management.

#### How CTInfo Works

QoSmate handles traffic in both directions (upload and download) using the following process:

1. **Egress (Upload) Processing:**
   - DSCP values (0-63) are read from outgoing packets
   - Values are stored in connection tracking using: `ct mark = (DSCP OR 128)`
   - The original DSCP value is preserved
   - The additional bit (128) marks the connection as "valid"

2. **Ingress (Download) Processing:**
   - tc filters with the `ctinfo` action check the connection tracking mark
   - If the conditional bit (128) is set, the original DSCP value is restored:
     - DSCP is extracted as `mark & 63`
     - This DSCP value is applied to incoming packets

3. **IFB (Intermediate Functional Block):**
   - Linux can only shape outgoing traffic
   - Download traffic is redirected to a virtual IFB interface
   - This effectively turns "download" traffic into "upload" traffic on the IFB interface
   - QoS rules can then be applied to this redirected traffic

#### Technical Background

Traffic control in Linux presents unique challenges, particularly for ingress (download) traffic. This is because tc rules are applied before firewall rules in the packet processing pipeline. QoSmate's CTInfo method elegantly solves this by:

1. Using connection tracking to maintain state across packet directions
2. Leveraging the IFB interface for download shaping
3. Preserving DSCP marks across the entire connection

This approach offers several advantages:
- Works reliably with complex network setups
- Supports multiple LAN interfaces
- Compatible with network isolation requirements
- Minimal configuration complexity

#### Implementation Command Example

The core implementation uses commands like:
```bash
tc filter add dev $WAN parent ffff: protocol all matchall action ctinfo dscp 63 128 mirred egress redirect dev ifb-$WAN
```
Where:
- `63`: Mask to extract the DSCP value
- `128`: Conditional bit to verify marked connections

### Hardware Compatibility

While QoSmate works on most OpenWrt devices, some older devices or specific hardware or kernel configurations might have limitations in DSCP handling, particularly in how they interpret IP header bits for connection tracking.

## Contributing

Contributions to QoSmate are welcome! Please submit issues and pull requests on the GitHub repository.

## Acknowledgements

QoSmate is inspired by and builds upon the work of SimpleHFSCgamerscript, SQM, cake-qos-simple, qosify and DSCPCLASSIFY. I thank all contributors and the OpenWrt community for their valuable insights and contributions.

## Support

The ultimate reward is seeing people benefit and enjoy using this project - no donations needed! But if you insist on buying me a coffee:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/hudra)
