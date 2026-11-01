## Proof of Concept (PoC): QoSmate and Passwall 2 Coexistence

This section documents a real-world OpenWrt deployment demonstrating that QoSmate can perform traffic classification and DSCP marking before Passwall 2 applies its routing, TProxy, and DNS interception rules.

The purpose of this PoC is to verify the packet-processing order, demonstrate that both systems can coexist, and show how QoSmate's DSCP classification integrates with CAKE's Diffserv8 queueing on both upload and download traffic.

### 1. Verified Netfilter Hook Execution Order

Netfilter processes registered base chains at the same hook in ascending numerical priority order. A lower numerical value executes first.

In the tested configuration, the relevant prerouting priorities are:

| Component | Netfilter Hook | Priority |
|---|---|---:|
| Connection Tracking | prerouting | -200 |
| QoSmate (`dscptag`) | prerouting | -160 |
| Passwall 2 (`mangle_prerouting`) | prerouting | -151 |
| Passwall 2 (`dstnat`) | prerouting | -101 |

The resulting packet-processing pipeline is:

```text
              Incoming LAN packet (br-lan)
                         |
                         v
              Conntrack processing
                    Priority -200
                         |
                         v
       +--------------------------------------+
       |       STEP 1: QoSmate                |
       |       prerouting / priority -160     |
       +--------------------------------------+
       |                                      |
       |  - Identify source device and ports |
       |  - Classify traffic                  |
       |  - Apply DSCP markings               |
       |  - Save DSCP metadata in conntrack   |
       |    using dedicated mark bits         |
       |                                      |
       +--------------------------------------+
                         |
                         v
       +--------------------------------------+
       |       STEP 2: Passwall 2              |
       |       mangle_prerouting / -151       |
       +--------------------------------------+
       |                                      |
       |  - Evaluate Direct / Bypass rules    |
       |  - Evaluate proxy-routing rules      |
       |  - Apply routing marks where needed  |
       |  - Select TProxy handling            |
       |                                      |
       +--------------------------------------+
                         |
                         v
       +--------------------------------------+
       |       STEP 3: Passwall 2              |
       |       dstnat / priority -101         |
       +--------------------------------------+
       |                                      |
       |  - Apply configured DNS redirects   |
       |  - Handle applicable destination NAT|
       |                                      |
       +--------------------------------------+
                         |
                         v
                  Routing Decision
                         |
              +----------+----------+
              |                     |
              v                     v
         Direct Traffic        Proxied Traffic
              |                     |
              v                     v
          WAN Forwarding       TProxy / Xray
              |                     |
              +----------+----------+
                         |
                         v
                  WAN Egress
                         |
                         v
                CAKE Diffserv8
                         |
                         v
                     Internet
```

**Key observation:** QoSmate performs classification and DSCP marking before Passwall 2's relevant prerouting chains. Passwall 2 can subsequently make its own routing decisions without losing the QoS classification.

### 2. Live nftables Runtime Evidence

The following output was captured from the running OpenWrt router.

**QoSmate – `table inet dscptag`:**

```nft
table inet dscptag {
    chain dscptag {
        type filter hook prerouting priority mangle - 10;

        iif "lo" accept
        meta mark 0x50535732 return

        ...
    }
}
```

The configured priority `mangle - 10` resolves to `-160`.

The `meta mark 0x50535732 return` rule also provides a guard for packets already carrying the corresponding Passwall 2 packet mark.

**Passwall 2 – `table inet passwall2`:**

```nft
table inet passwall2 {
    chain mangle_prerouting {
        type filter hook prerouting priority mangle - 1;

        ...
    }

    chain dstnat {
        type filter hook prerouting priority dstnat - 1;

        ...
    }
}
```

These priorities resolve to:

- `mangle - 1` = `-151`
- `dstnat - 1` = `-101`

The runtime configuration therefore confirms the intended execution order:

```text
QoSmate (-160)
    |
    v
Passwall 2 Mangle (-151)
    |
    v
Passwall 2 DSTNAT (-101)
```

This establishes that QoSmate's classification stage executes before the relevant Passwall 2 prerouting processing.

### 3. CAKE Traffic Isolation and Diffserv8 Classification

After packet classification, CAKE handles traffic scheduling on the WAN interface.

The tested configuration uses host-aware flow isolation:

**Upload (WAN egress):**

```text
dual-srchost nat
```

**Download (IFB):**

```text
dual-dsthost nat
```

These options provide hierarchical fairness:

- Upload: fairness is applied across source hosts first, then individual flows.
- Download: fairness is applied across destination hosts first, then individual flows.
- The `nat` option allows CAKE to identify the original LAN hosts behind NAT rather than treating all translated traffic as a single external address.

This prevents a single device from gaining an unfair advantage simply by opening a large number of simultaneous connections.

Alongside host isolation, CAKE uses Diffserv8 to classify packets into eight traffic tins based on their DSCP codepoints.

The relevant standard Diffserv8 mapping is:

| Tin | Traffic class | Relevant DSCP codepoints |
|---|---|---|
| 0 | Low Priority / Background | LE |
| 1 | High Throughput | AF1x, TOS2, CS1 |
| 2 | Best Effort | CS0 / Unclassified |
| 3 | Video Streaming | AF3x, AF4x, CS3 |
| 4 | Low-Latency Transactions | AF2x, TOS4 |
| 5 | Interactive Shell | CS2, TOS1 |
| 6 | Minimum Latency | EF, VA, CS4, CS5 |
| 7 | Network Control | CS6, CS7 |

For this particular deployment, gaming traffic is assigned to CS5 (Tin 6), while DNS and network-control traffic are assigned to CS6 (Tin 7).

### 4. Live CAKE Statistics

The following figures were observed from the running CAKE qdisc on the WAN interface:

| CAKE Tin | Traffic category | Packets | Average queue delay |
|---|---|---:|---:|
| Tin 2 | Best Effort / Web / Tunnel | 904,737 | 139 µs |
| Tin 3 | Video / Streaming | 3,993 | 18 µs |
| Tin 6 | Minimum Latency / Gaming | 90 | 5 µs |
| Tin 7 | Network Control / DNS | 406 | 9 µs |

These figures demonstrate that packets are being classified into their respective CAKE tins and that the observed queue delay for latency-sensitive traffic was low at the time of measurement.

In particular, Tin 6 reported an average queue delay of only 5 µs, while the much larger volume of general web and tunnel traffic was handled by Tin 2.

**Important:** These values represent CAKE queue-delay statistics, not end-to-end latency or gaming ping. They are evidence of the observed queueing behavior, not a guarantee that jitter or congestion can never occur.

### 5. Download Path – DSCP Restoration and IFB

The download path also preserves the original traffic classification.

Incoming packets arrive through the WAN interface. The ingress traffic-control filter uses `ctinfo` to restore the previously saved DSCP value from the connection's conntrack mark.

The relevant action is:

```bash
ctinfo dscp 0x0000003f 0x00000080
```

The parameters are:

- `0x0000003f`: The six-bit DSCP field stored in the conntrack mark.
- `0x00000080`: The separate state flag indicating that DSCP restoration is valid.

The mask and state flag occupy non-overlapping bits.

The processing sequence is:

```text
              Internet
                  |
                  v
              WAN Ingress
                  |
                  v
          Conntrack DSCP Lookup
                  |
                  v
          ctinfo DSCP Restoration
                  |
                  v
           mirred IFB Redirect
                  |
                  v
                ifb-wan
                  |
                  v
          CAKE Diffserv8 (600 Mbit)
                  |
                  v
         Host-Aware Flow Isolation
                  |
                  v
             LAN Clients
```

This allows CAKE on the download path to use the restored DSCP markings and retain the original classification, even when packets are processed through the WAN ingress and IFB redirection path.

### 6. Marking and Routing Separation

An important aspect of this configuration is the distinction between QoS classification metadata and routing marks.

QoSmate's DSCP restoration uses dedicated conntrack-mark bits, while the Passwall 2 rule shown above checks the packet mark (`meta mark`) for its routing identifier:

```text
Passwall 2 packet mark:
0x50535732

QoS DSCP storage:
0x0000003f

QoS DSCP restoration flag:
0x00000080
```

These are separate marking fields and can be used independently, provided that the corresponding conntrack-mark bit ranges are reserved and do not overlap with other services' conntrack metadata.

This separation is important because QoS classification should not unintentionally overwrite Passwall 2's packet-routing decisions.

### 7. Final PoC Results

The live router configuration and runtime statistics demonstrate the following:

1. **Correct hook ordering:** QoSmate executes at prerouting priority `-160`, before the relevant Passwall 2 chains at `-151` and `-101`.

2. **Independent responsibilities:** QoSmate handles packet classification and DSCP marking, while Passwall 2 retains control over routing, Direct/Bypass decisions, and proxy redirection.

3. **Mark separation:** QoS classification metadata and Passwall 2 packet-routing marks use separate marking fields.

4. **CAKE integration:** The DSCP markings are consumed by CAKE's Diffserv8 scheduler on the WAN egress path.

5. **Host fairness:** `dual-srchost nat` and `dual-dsthost nat` provide per-host fairness across upload and download traffic.

6. **Download classification preservation:** `ctinfo` restores the saved DSCP values before packets are redirected to the IFB download shaper.

7. **Observed low queue delay:** Live CAKE statistics show low average queue delays for the tested latency-sensitive tins.

**Conclusion:**

This PoC demonstrates that QoSmate and Passwall 2 can coexist within the tested OpenWrt configuration.

By running QoSmate's classification chain before Passwall 2's relevant prerouting rules, traffic can be classified and marked for QoS without interfering with Passwall 2's subsequent routing and TProxy processing.

CAKE can then use these classifications to provide differentiated traffic scheduling, host-aware flow isolation, and queue management on both upload and download paths.

The result is a working architecture in which **QoSmate is responsible for QoS classification, Passwall 2 is responsible for traffic routing, and CAKE is responsible for packet scheduling and traffic shaping.**

---

### References

- [Netfilter Hook Priorities – nftables documentation](https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks)
- [Linux Kernel – CAKE Diffserv8 implementation](https://linux.googlesource.com/linux/kernel/git/davem/net/+/1bdc3d5be7e199ff56f39dafb0e5f63a9b8c975d/net/sched/sch_cake.c)
- [tc-cake(8) – CAKE Queue Discipline](https://man7.org/linux/man-pages/man8/tc-cake.8.html)
- [tc-ctinfo(8) – Conntrack DSCP Restoration](https://man7.org/linux/man-pages/man8/tc-ctinfo.8.html)
