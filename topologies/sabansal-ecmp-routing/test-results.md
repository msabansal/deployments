# Azure Linux networking test results

This document summarizes the deployment, throughput, migration, and failover tests performed during the development of the Azure Linux routing topologies in this repository. It covers direct VNet, WireGuard, HTTP/3, raw TLS/TCP, internal load balancer (ILB), and equal-cost multipath (ECMP) user-defined route (UDR) tests.

The results are point-in-time measurements from the tested Azure VM sizes, regions, guest configuration, and control-plane state. They aren't service guarantees.

## Executive summary

| Area | Main result |
|---|---|
| Direct VNet | TCP reached about 15.68 Gbit/s. Sustainable UDP reached 9.48 Gbit/s at 0.20% loss. |
| WireGuard | TCP reached 3.31 Gbit/s. UDP reached 3.46 Gbit/s at about 1% loss. |
| HTTP/3 | Direct HTTP/3 reached 2.65 Gbit/s. WireGuard HTTP/3 reached 1.46 Gbit/s. |
| Raw TLS/TCP | Eight direct TLS 1.3 streams reached 15.68 Gbit/s. |
| ILB baseline | The IP-based HA Ports topology carried 4.95 Gbit/s UDP at 0.96% loss. |
| ILB atomic IP move | Static guest `/32` configuration plus `moveIpConfigurations` reduced measured interruption to about 1.7 seconds. |
| ILB established flows | Existing TCP flows survived an atomic move only while the previous router continued forwarding residual traffic. New flows used the new owner successfully. |
| ECMP baseline | A 5.01 Gbit/s UDP run completed with zero measured packet loss and traffic on both routers. |
| ECMP firewall-only failure | Established flows pinned to the blocked router didn't rehash. Aggregate throughput could remain high because one surviving TCP flow saturated the link. |
| ECMP route removal | Removing the failed next hop from both UDRs redirected traffic. UDP recovered quickly; TCP recovery was delayed by retransmission backoff. |
| Staged route then NSG | Waiting for traffic to leave router 1 before applying the NSG avoided measurable additional disruption. |

## Test environment and methodology

The tests used Azure Linux 4 VMs with NVMe disk controllers. The direct and WireGuard tests used `Standard_D2als_v7`. The ECMP topology used four `Standard_D2als_v6` VMs in Central India because `westus3` rejected the ECMP route feature.

Most throughput tests used a checksum-pinned iperf3 `3.22` build:

- Archive SHA-256: `1c0d0fb02c52626111d6e132db80edfbf27bbaff8bd9245df2a371dcb0b35a92`
- UDP GRO receive-loop fix: `ee73f1740f689cafde3cde13d711eecbac985090`
- UDP tests used GSO/GRO and MTU-safe datagrams.
- TCP failover tests inspected each stream instead of relying only on aggregate throughput.
- Guest operations and artifact collection used direct SSH and SCP.

Important interpretation notes:

- One TCP stream can saturate the tested VM NIC. High aggregate throughput doesn't prove that every flow survived.
- ECMP UDRs don't health-probe router VMs and don't automatically rehash an established flow when its selected router drops packets.
- TCP can recover well after route convergence because of retransmission timeout and backoff.
- UDP receiver loss counters can undercount permanently blackholed stream tails. For those runs, loss was calculated from transmitted and received datagram totals.
- The 14 Gbit/s UDP runs exceeded the sustainable packet-processing rate. They characterize overloaded behavior rather than normal steady-state capacity.

## Direct VNet and WireGuard tests

### Initial direct and WireGuard measurements

The first direct UDP test used a fixed 2 Gbit/s target and was therefore rate-limited by the test configuration. A later 60 KB datagram experiment was rejected because fragmentation made the receiver result unusable.

| Path and protocol | Result | Notes |
|---|---:|---|
| Direct TCP, initial | 15.70 Gbit/s | Route verified over `eth0`. |
| Direct UDP, initial | 1.99 Gbit/s received | Explicitly capped at 2 Gbit/s; not a maximum-throughput result. |
| WireGuard TCP, initial | 2.72 Gbit/s | Before later tuning. |
| WireGuard TCP, early comparison | 2.86 Gbit/s | Old test configuration. |
| WireGuard UDP, early comparison | 1.42 Gbit/s received | 3.83% loss; old 2 Gbit/s target. |
| Direct UDP, 1,200-byte datagrams | 3.75 Gbit/s received | 4.53 Gbit/s sent and 17.36% loss; packet-rate limited. |
| Direct UDP, 60 KB datagrams | Invalid | Fragmentation prevented a meaningful receiver result. |

### Corrected direct UDP rate sweep

The corrected method used iperf3 UDP GSO/GRO, a 1,500-byte path MTU, and a maximum unfragmented IPv4 UDP payload of 1,472 bytes.

| Offered rate | Received throughput | Packet loss | Client VM CPU |
|---:|---:|---:|---:|
| 15.7 Gbit/s | 13.35 Gbit/s | 11.49% | 81.8% |
| 12.5 Gbit/s | 10.77 Gbit/s | 13.87% | Not recorded |
| 10.5 Gbit/s | 10.16 Gbit/s | 3.24% | Not recorded |
| 10.0 Gbit/s | 9.64 Gbit/s | 3.58% | Not recorded |
| 9.5 Gbit/s | 9.48 Gbit/s | 0.20% | 50.6% |

The selected sustainable direct comparison was:

| Protocol | Throughput | Loss | Client VM CPU |
|---|---:|---:|---:|
| TCP | 15.68 Gbit/s | Not applicable | 26.6% |
| UDP | 9.48 Gbit/s | 0.20% | 50.6% |

### Tuned WireGuard results

The WireGuard tuning retained the same VM size and enabled supported GRO/GSO features, UDP GRO forwarding, larger network buffers, a WireGuard MTU of 1,440, TCP zero-copy, a 4 MB TCP window, and eight TCP streams.

| Protocol | Throughput | Loss |
|---|---:|---:|
| TCP | 3.31 Gbit/s | Not applicable |
| UDP | 3.46 Gbit/s | About 1% |

## HTTP/3 and raw TLS/TCP tests

HTTP/3 used a pinned `quic-go v0.63.0` client/server benchmark. The raw TLS test used TLS 1.3 over TCP without HTTP framing.

| Test | Throughput | Client VM CPU | Server VM CPU | Additional result |
|---|---:|---:|---:|---|
| Direct HTTP/3 | 2.65 Gbit/s | 73.4% | 63.3% | Direct VNet path |
| WireGuard HTTP/3 | 1.46 Gbit/s | 84.3% | 74.9% | WireGuard path |
| Direct raw TLS/TCP, 8 streams | 15.68 Gbit/s | 98.8% | 45.3% | 54.77 GiB transferred using `TLS_AES_256_GCM_SHA384` |

An unencrypted HTTP/3 test wasn't run because HTTP/3 uses QUIC with TLS 1.3.

## ILB routing tests

The ILB topology used:

- A Standard internal load balancer with HA Ports and floating IP.
- Symmetric UDRs between VM1 and VM2.
- An IP-based backend address at `10.80.0.5`.
- Router 1 primary IP `10.80.0.4`.
- Router 2 primary IP `10.80.0.6`.
- ILB frontend `10.80.0.10`.

### Baseline UDP routing

| Offered rate | Received throughput | Loss | Jitter | VM1 CPU | Router usage |
|---:|---:|---:|---:|---:|---|
| 5 Gbit/s | 4.95 Gbit/s | 0.96% | 0.007 ms | 30.3% | Router 1 forwarded traffic; router 2 forwarded none. |

### Sequential IP movement

Deleting the secondary IP from router 1 and adding it to router 2 caused severe disruption.

| Received throughput | Loss | Result |
|---:|---:|---|
| 2.02 Gbit/s | 59.66% | Direct traffic reached router 2, but the unchanged ILB backend stopped forwarding. |

Setting the existing IP-based backend address to `adminState: Up` restored forwarding without recreating the backend address or HA Ports rule.

### IMDS-polled guest ownership

Both routers initially used a systemd service that polled IMDS and added or removed the backend `/32` based on NIC ownership.

| Test | Throughput | Loss or retransmits | Recovery | Connection result |
|---|---:|---:|---:|---|
| UDP migration | 4.60 Gbit/s | 8.07% loss | 18.2 seconds | Traffic resumed. |
| TCP baseline, 8 streams | 15.26 Gbit/s | 209,167 retransmits | Not applicable | Completed normally. |
| TCP migration, 8 streams | 14.42 Gbit/s | 246,534 retransmits | 16.4 seconds | All eight original streams completed. |

### Static guest `/32` and atomic NIC ownership movement

The IMDS service was removed. Both router guests permanently configured `10.80.0.5/32`, while Azure retained exclusive NIC ownership. The `moveIpConfigurations` operation moved control-plane ownership atomically.

Standalone moves completed in about 6.4 to 7.6 seconds.

| Test | Throughput | Loss or retransmits | Measured interruption | Connection result |
|---|---:|---:|---:|---|
| UDP migration, 120 seconds, 5 Gbit/s offered | 4.92 Gbit/s | 1.66% loss | About 1.68 seconds | Traffic resumed. |
| TCP migration, 120 seconds, 8 streams | 14.91 Gbit/s | 199,755 retransmits | About 1.75 seconds | All eight streams completed. |

Compared with IMDS polling:

- UDP loss improved from 8.07% to 1.66%.
- UDP recovery improved from 18.2 seconds to about 1.68 seconds.
- TCP recovery improved from 16.4 seconds to about 1.75 seconds.

### Blocking the previous router after the move

An nftables forwarding drop rule was installed on the previous router after Azure reported that ownership had moved.

| Result | Measurement |
|---|---:|
| Established streams completed | 0 of 8 |
| Retransmissions before termination | 348,151 |
| Previous-router drop counter | 190 packets / 1,719,133 bytes |
| Test completion | Timed out |

Residual packets continued to reach the previous router after the control-plane move. Blocking those packets stranded the established TCP flows. This showed that the successful atomic-move test depended on the previous router continuing to forward during data-plane convergence.

### New TCP connections after the move

New connections were created only after the IP move and previous-router block.

| Test | Throughput | Retransmits | Previous-router drops |
|---|---:|---:|---:|
| Fresh 60-second, 8-stream TCP run | 14.33 Gbit/s | Not recorded | 0 |
| 30 seconds before move | 15.31 Gbit/s | 30,121 | Not applicable |
| 30 seconds after move, new connections | 14.14 Gbit/s | 37,083 | 0 |

The combined active-test throughput for the before-and-after test was 14.73 Gbit/s. Including 18.87 seconds of move and script time, the combined wall-clock throughput was 11.20 Gbit/s.

## ECMP routing tests

The ECMP topology used two directional `VirtualApplianceEcmp` UDRs:

- Router 1: `10.81.0.4`
- Router 2: `10.81.0.6`
- VM1: `10.81.1.4`
- VM2: `10.81.2.4`

The configured routes contain both router IPs. Azure's effective-route API represented the active route as `VirtualAppliance` with both next-hop IP addresses.

### Baseline UDP distribution

| Duration | Sent and received | Loss | Jitter | VM1 CPU | Router 1 delta | Router 2 delta |
|---:|---:|---:|---:|---:|---:|---:|
| 30 seconds | 5.01 Gbit/s | 0 of 13,912,272 packets | 0.005 ms | 27.7% | 556,178 datagrams | 296,864 datagrams |

This verified that both routers participated in forwarding and that no load balancer or shared third router IP was required.

### TCP with firewall-only failure

Eight TCP streams were started, then router 1 forwarding was blocked at about test second 30 without changing the ECMP UDR.

| Phase | Result |
|---|---|
| Before block | 11.885 Gbit/s aggregate; all eight streams active. |
| After block | Seven streams gradually stalled. |
| Steady failed state | One stream through router 2 remained active and reached about 11.8 Gbit/s by itself. |
| Completion | Client hit the 90-second outer timeout. |
| Router 1 nftables counter | 171 packets / 1,019,637 bytes dropped. |

The high aggregate throughput after failure didn't represent successful failover. Seven established flows remained pinned to router 1 and didn't rehash.

### TCP with simultaneous route removal and firewall block

At test second 30, router 1 was blocked and both directional UDRs were changed to use only router 2.

| Measurement | Result |
|---|---:|
| Route and effective-route convergence | 7.28 seconds |
| Router 2 flows unaffected | 2 |
| First affected flows recovered | 3 flows after 13-14 seconds |
| Remaining affected flows recovered | 3 flows after about 27 seconds |
| Receiver throughput | 11.81 Gbit/s |
| Retransmissions | 275,929 |
| Completion | All eight streams completed normally |

The route converged before all TCP flows resumed. The additional delay came from TCP retransmission timeout and backoff.

### UDP at about 5 Gbit/s with route removal

The test used 16 streams, 1,350-byte datagrams, and a 5.008 Gbit/s offered rate. Router 1 was removed from both UDRs while traffic was running.

| Measurement | Result |
|---|---:|
| Streams already using router 2 | 5 |
| Affected streams | 11 |
| Route convergence | 4.26 seconds |
| Stream recovery after convergence | About 2-3 seconds |
| Average received throughput | 4.889 Gbit/s |
| Total loss | 2.369% |

UDP resumed faster than TCP because it didn't wait for retransmission timers, but packets were lost during the route transition.

### UDP with a 14 Gbit/s requested rate

The endpoints generated about 12.05 Gbit/s rather than the requested 14 Gbit/s. Baseline ECMP receive throughput was already about 9.5 Gbit/s with about 21% loss, showing endpoint or packet-processing saturation.

| Failure method | Stream outcome | Steady post-failure receive rate | Whole-test receive rate | Whole-test loss | Completion |
|---|---|---:|---:|---:|---|
| Remove router 1 from UDRs and block it | All streams recovered | 10.68 Gbit/s | 10.20 Gbit/s | 15.35% | Completed |
| Block router 1 only; keep ECMP unchanged | 7 of 16 streams survived | 5.24 Gbit/s | Not used | 44.44% derived | Timed out at 125 seconds |

The firewall-only loss value was derived from transmitted and received datagrams because receiver-side iperf counters under-reported permanently blackholed stream tails.

### Staged TCP route removal followed by NSG denial

This test changed the ECMP routes first, waited for traffic to leave router 1, and only then applied a router-1-only outbound NSG deny.

Procedure:

1. Start a 120-second, eight-stream TCP test.
2. At test second 30, remove router 1 from both directional UDRs.
3. Wait for effective routes to contain only router 2.
4. Wait for two consecutive forwarding-counter samples showing router 1 idle and router 2 active.
5. Apply an outbound deny on router 1 for the endpoint subnets.
6. Continue the test and restore the original ECMP routes during cleanup.

| Measurement | Result |
|---|---:|
| ARM route update and effective-route convergence | 6.87 seconds |
| Forwarding-counter redirect confirmation | 31.07 seconds after trigger |
| NSG update duration | 5.30 seconds |
| NSG effective | 51.24 seconds after route trigger |
| Receiver throughput | 11.803 Gbit/s |
| Total retransmissions | 229,253 |
| Active streams | 8 in every one-second interval |
| Lowest one-second throughput | 11.706 Gbit/s |
| Test completion | Normal, client exit code 0 |

Five-second windows around the changes:

| Window | Before | After |
|---|---:|---:|
| Route trigger | 11.810 Gbit/s | 11.797 Gbit/s |
| NSG application start | 11.808 Gbit/s | 11.792 Gbit/s |
| NSG effective time | 11.809 Gbit/s | 11.796 Gbit/s |

Router counters showed:

- Router 1 forwarded 1,181,400 datagrams by NSG application and 1,181,402 by test end.
- Router 2 increased from 5,059,168 datagrams at NSG application to 7,881,114 at test end.

Only two additional forwarded datagrams appeared on router 1 after the NSG stage. The NSG caused no measurable additional throughput disruption because traffic had already moved to router 2.

## Conclusions

1. **Use corrected UDP methodology.** Fixed-rate caps, oversized fragmented datagrams, and receiver-only tail-loss counters can produce misleading results.
2. **Atomic ILB IP movement is much faster than guest IMDS polling.** Static guest `/32` configuration plus `moveIpConfigurations` reduced the measured interruption from about 16-18 seconds to about 1.7 seconds.
3. **Control-plane completion doesn't guarantee that every established flow has left the previous router.** Immediately blocking the old ILB router stranded established TCP connections.
4. **A firewall drop doesn't make an ECMP next hop unhealthy.** Azure continued to hash flows to the blocked router while it remained in the UDR.
5. **Remove a failed router from both directional UDRs to redirect ECMP traffic.** UDP resumed quickly after dataplane convergence, while TCP recovery depended on retransmission timing.
6. **Wait for observed traffic redirection before enforcing a router block.** The staged TCP test maintained all eight streams at about 11.8 Gbit/s and showed no additional disruption when the NSG was applied after router 1 became idle.
7. **Inspect per-flow behavior.** Aggregate throughput alone can hide failed or stalled flows.

## Final validated state

After the staged TCP test:

- Both configured routes were restored to `VirtualApplianceEcmp`.
- Both effective routes contained `10.81.0.4` and `10.81.0.6`.
- The temporary router-1 NIC NSG was detached and deleted.
- VM1-to-VM2 ping completed with 0% loss.
- No iperf3 processes remained on the endpoint VMs.

## Related files

- [ECMP topology overview](README.md)
- [ECMP deployment template](main.bicep)
- [ECMP validation script](test-throughput.ps1)
- [ILB topology overview](../sabansal-ilb-routing/README.md)
- [WireGuard topology overview](../sabansal-wireguard/README.md)
