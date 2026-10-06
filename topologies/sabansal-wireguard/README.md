# Sabansal WireGuard

Deploys two Azure Linux 4 VMs in `westus3`, both using
`Standard_D2als_v7`, and creates a WireGuard tunnel between them:

```text
sabansal-wireguard-client                     sabansal-wireguard-server
10.70.0.5                                     10.70.0.4:51820
WireGuard 10.200.0.2  =====================>  WireGuard 10.200.0.1
```

The client connects to the server's private VNet address. TCP and UDP throughput
are measured with iperf3 against the server's WireGuard address, and the test
fails unless the route uses the `wg0` interface.

## Deploy and test

```powershell
.\deploy.ps1
```

Defaults:

- Resource group: `sabansal-wireguard-rg`
- Region: `westus3`
- VM size: `Standard_D2als_v7` (override with `-VmSize`, for example
  `-VmSize Standard_F2als_v7`)
- Server private IP: `10.70.0.4`
- Client private IP: `10.70.0.5`
- Server tunnel IP: `10.200.0.1`
- Client tunnel IP: `10.200.0.2`

For Southeast Asia, with both VMs in the same availability zone:

```powershell
.\deploy.ps1 -ResourceGroupName sabansal-wireguard-sea-rg `
  -Location southeastasia -AvailabilityZone 1
```

Omit `-AvailabilityZone` for a non-zonal deployment when zonal capacity is
unavailable. Zone placement cannot be changed on an existing VM.

Enable the measured two-vCPU MANA tuning with `-OptimizeThroughput`. This
persists supported GRO/GSO/TSO and UDP forwarding offloads, increases the MANA
RX/TX rings to 2,048/4,096 entries, and directs RSS to the RX queue whose IRQ
runs on CPU 0 on two-vCPU VMs. A boot service reapplies NIC settings, and
WireGuard's `PostUp` reapplies tunnel offloads. MANA IRQs are excluded from
automatic `irqbalance` migration; if neither RX queue runs on CPU 0, the tuning
places queue 0 there explicitly. A separate service runs after WireGuard startup and pins its
threaded receive poller to CPU 0 on two-vCPU VMs.
RSS placement is specific to this dedicated benchmark
topology and may reduce receive parallelism for unrelated workloads.
The tuning does not change the 1,500-byte underlay or 1,440-byte WireGuard MTU.
Redeploying without `-OptimizeThroughput` disables the tuning services; existing
NIC settings return to defaults on the next VM reboot, and automatic MANA IRQ
balancing is restored.
For Internet paths with additional encapsulation or smaller path MTU, lower
the WireGuard MTU accordingly; jumbo-frame results do not apply.

```powershell
.\deploy.ps1 -ResourceGroupName sabansal-wireguard-sea-rg `
  -Location southeastasia -AvailabilityZone 1 -OptimizeThroughput `
  -SkipThroughputTest
```

The deployment script creates the resource group, deploys both VMs, exchanges
their WireGuard public keys, configures the server and client, verifies the
tunnel, and runs 30-second TCP and UDP iperf3 tests using eight parallel TCP
streams.
Based on the validated packet-rate envelopes of this two-vCPU topology, the
default UDP aggregate target is 60% of the immediately preceding direct TCP
result or 105% of the WireGuard TCP result. Pass `-UdpTargetMbps` to test a
specific offered load. The deployment installs a pinned,
checksum-verified iperf3 build with UDP GSO/GRO support. UDP uses kernel/NIC
segmentation and receive offload with MTU-safe 1,380-byte datagrams instead of
independent CPU-bound userspace generators. It uses at most one GSO-enabled
iperf3 thread per vCPU and divides the aggregate target across those threads.
The benchmark reports received throughput and whole-VM client CPU utilization
for both protocols, plus UDP packet loss and jitter. The build also applies the
upstream iperf3 GRO receive-loop CPU fix from commit
`ee73f1740f689cafde3cde13d711eecbac985090`.

The topology uses the maximum IPv4 WireGuard MTU of 1,440 bytes over the
1,500-byte Azure VNet MTU, enables supported UDP/GRO NIC offloads, and raises
kernel UDP buffers and the network receive backlog.

Run the throughput test again with:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -ParallelConnections 8 `
  -DurationSeconds 30
```

Benchmark the direct VNet path instead of the WireGuard tunnel:

```powershell
.\test-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -Path Direct `
  -ParallelConnections 8 `
  -DurationSeconds 30
```

Direct mode targets `10.70.0.4` and fails if the selected route uses `wg0`.
Pass `-UdpTargetMbps <n>` to override the automatic UDP target.
Pass `-UdpDatagramBytes <n>` to test a different UDP datagram size.
Use `-Reverse` to send from the server to the client. Use `-OutputPath <file>`
to save the received throughput, UDP loss, route, direction, and CPU metrics
as JSON. Whole-VM CPU is sampled on the client VM; iperf CPU values exclude
kernel WireGuard worker utilization.

## Fixed-MTU performance limits

On the Southeast Asia `Standard_D2als_v7` pair, the initial private-VNet
baseline was 15.71 Gbps direct TCP, but only 3.51 Gbps TCP and 3.66 Gbps UDP
through WireGuard. Both vCPUs are SMT siblings of one physical core. The
MANA driver advertises no hardware UDP segmentation, and kernel profiling
already shows AVX-512 ChaCha20/Poly1305 implementations.

Ring/RSS tuning measured about 4.13 Gbps encrypted TCP in 20-second tests at
the original MTU, not 10 Gbps. After recreating the tunnel, pinning its threaded
receive poller to CPU 0 was needed to retain approximately 4 Gbps; unpinned
placement could fall to 2.4 Gbps. Pinning iperf itself, disabling threaded NAPI,
and larger software segmentation batches did not improve it. Increasing stream
counts alone did not remove the CPU limit. These same-VNet tests are an upper bound
for an eventual Internet deployment, not measurements over the Internet.
For 10 Gbps at this MTU, evaluate more physical cores (for example,
`Standard_D8als_v7`) and potentially multiple independently routed WireGuard
peers/tunnels to distribute outer UDP flows across receive queues. Neither
approach guarantees 10 Gbps without a new end-to-end measurement.

The final configuration excludes MANA IRQs from automatic balancing, aligns
RSS with the CPU-0 IRQ, and pins the receive poller to CPU 0. Both VMs were
rebooted, and IRQ placement remained stable through the following 30-second
tests (TCP: eight streams after a three-second warmup; UDP: two streams,
1,380-byte datagrams, requested aggregate load of 10 Gbps):

| Measurement | Client to server | Server to client |
|---|---:|---:|
| TCP received | 4.06 Gbps | 4.09 Gbps |
| UDP actually sent | 3.56 Gbps | 3.61 Gbps |
| UDP received | 3.55 Gbps | 3.60 Gbps |
| UDP packet loss | 0.09% | 0.23% |

The UDP sender could not generate the requested 10 Gbps. An offered-load
setting is not a measurement of achieved throughput. TCP improved approximately
16% over the initial 3.51 Gbps result; 10 Gbps was not achieved.

## quiche HTTP/3 throughput

Use Cloudflare's [quiche](https://github.com/cloudflare/quiche) implementation
directly between the private VM addresses, without a WireGuard tunnel:

```powershell
.\deploy.ps1 -ResourceGroupName sabansal-wireguard-sea-rg `
  -Location southeastasia -AvailabilityZone 1 -Transport Quiche `
  -OptimizeThroughput
```

`-Transport Quiche` stops and disables `wg-quick@wg0` and skips WireGuard peer
configuration, installs the quiche benchmark on both VMs, and retains its server
as a boot-time service. `-SkipThroughputTest` skips measurement, not application
setup. The default transport remains `WireGuard`. With
`-OptimizeThroughput`, `quiche-throughput.service` persistently enables supported
NIC offloads, sets MANA RX/TX rings to 2,048/4,096, restores balanced RSS
across the receive queues, and replaces the MANA VF's root qdisc with `noqueue`.
A udev rule (`90-quiche-mana-vf.rules`) restarts the service whenever the VF is
re-added, for example after Azure host servicing, so this tuning is reapplied.
The synthetic netvsc interface (`eth0`) keeps its default `mq` / `fq_codel`
qdisc. It retains normal IRQ balancing rather than applying
the WireGuard-specific CPU placement.
The underlay remains at MTU 1,500; larger UDP payload settings must not exceed
1,472 bytes on this direct IPv4 path.

The VMs still include the shared diagnostic tools, including iperf3 and
WireGuard tools, but quiche traffic is not encapsulated in WireGuard.

The benchmark pins quiche 0.30.0 at commit
`be47c5011215b9f13bad06bd7627d3ae49888a19`, uses a committed Cargo lockfile,
and builds optimized native release binaries with BoringSSL. It instruments the
upstream HTTP/3 apps to stream generated data and discard received bodies without
disk or console output in the data path. Reported goodput counts only application
body bytes during a synchronized measurement interval, excluding warmup.
TLS 1.3 and certificate verification remain enabled; the measured cipher is
`AES128_GCM`, and 0-RTT is not used.
In quiche mode, deployment's `-OptimizeThroughput` also selects disabled pacing
for the measured isolated-VNet profile; omit it to retain the benchmark's default
pacing.

Run the selected dedicated-VNet performance profile:

```powershell
.\test-quiche-throughput.ps1 -ResourceGroupName sabansal-wireguard-sea-rg `
  -DurationSeconds 30 -ServerWorkers 2 -ParallelConnections 4 `
  -CongestionControl cubic -ConnectionWindowBytes 67108864 `
  -StreamWindowBytes 4194304 -MaxUdpPayloadBytes 1472 `
  -DisablePacing -KeepServerRunning -OutputPath "$env:TEMP\quiche-forward.json"
```

Use `-SkipInstall` for subsequent tests, and `-Reverse` to swap the sending and
receiving VMs. The client initiates HTTP/3 downloads, so the default data
direction is server to client; `-Reverse` measures client to server.
`-DisableGso`, `-DisableGro`, `-StreamsPerConnection`, flow-control windows,
and `-CongestionControl bbr` support further controlled comparisons.
`-Transport Ssh` is the default benchmark-control channel; Azure Run Command
is also supported. This control-channel option is separate from deployment's
`-Transport Quiche`.

The selected profile uses two server processes on UDP ports 4433 and 4434,
four connections, one stream per connection, software UDP GSO and socket GRO,
and 64 MiB connection / 4 MiB stream flow-control windows. Disabling pacing
improved this isolated, low-latency VNet workload; retain the benchmark's
default pacing for other paths until measured. MANA does not advertise hardware
UDP segmentation, so software GSO must not be described as hardware offload.
Root or per-queue `fq` replacements were slower and were not retained.

`-KeepServerRunning` retains the selected server configuration as an enabled
boot-time service. Otherwise the benchmark stops its server after the test.
The benchmark certificate lasts seven days and is refreshed by rerunning the
wrapper when near expiry; there is no automatic certificate renewal or client
trust-anchor rotation. See [benchmark implementation details](quiche-benchmark/README.md).

### Measured quiche results

On the Southeast Asia zone-1 `Standard_D2als_v7` pair, a fresh direct TCP
baseline received 15.70 Gbps. With the selected profile above, 30-second
HTTP/3 measurements received 8.98 Gbps server to client and 8.93 Gbps client
to server. These are encrypted application-body goodput, not offered load or
link rate. Both VMs expose two SMT siblings of one physical AMD EPYC core.

For a dedicated throughput workload, opt in to kernel busy polling:

```powershell
.\deploy.ps1 -ResourceGroupName sabansal-wireguard-sea-rg `
  -Location southeastasia -AvailabilityZone 1 -Transport Quiche `
  -OptimizeThroughput -QuicheBusyPolling -SkipThroughputTest
```

This persists `net.core.busy_poll=50` and `net.core.busy_read=50` on both
VMs. It is CPU polling, not hardware offload, and can consume almost all
available CPU. It remains disabled by default. Redeploying without
`-QuicheBusyPolling`, or switching back to WireGuard, removes the topology's
busy-poll configuration and resets these two settings to zero.

In paired 30-second trials, busy polling measured 8.91 / 9.13 Gbps versus
8.63 / 8.41 Gbps without it (server-to-client / client-to-server).
After rebooting both VMs with busy polling retained, the selected configuration
measured **9.06 / 8.89 Gbps**. The server and NIC tuning started at boot;
MTU remained 1,500, rings remained 2,048 / 4,096, and RSS remained balanced.
The receiver used approximately 99.5-99.7% of VM CPU. Busy polling's gain
varies between runs and did not consistently exceed the earlier best results.
No configuration achieved 10 Gbps; these are private-VNet results, not
Internet measurements.

The [saved benchmark results](results/README.md) include the raw JSON
measurements, optimization comparisons, CPU profile, and boot-service checks.

### Offload capabilities and remaining optimization options

On this deployment, both the synthetic interface and MANA VF report hardware
TLS TX/RX/record offload, UDP segmentation, and LRO as `off [fixed]`.
MANA interrupt-coalescing configuration is unsupported, and its two combined
queues are already at the advertised maximum. Checksum and scatter-gather
offloads are enabled. TSO helps the TCP baseline, not QUIC's UDP packet path.

Linux kTLS operates on TLS records over TCP and cannot replace quiche's QUIC
packet AEAD encryption or header protection. A sender CPU profile confirmed
actual `aes_gcm_enc_update_vaes_avx512` and
`gcm_gmult_vpclmulqdq_avx512` execution, so CPU crypto acceleration is already
active. The main AES-GCM assembly routine accounted for approximately 4.3% of
the system-wide CPU-clock samples; this is not a total call-tree estimate of
all encryption costs. MANA transmit processing, locking, software packet
segmentation, allocations, and copies were also prominent.

Software GSO and socket GRO materially improve this workload: short controlled
tests received 3.76 Gbps with GSO disabled and 6.26 Gbps with GRO disabled,
compared with approximately 9 Gbps with both enabled. Larger rings are not
automatically faster; the measured 2,048 RX / 4,096 TX baseline outperformed
the initial 8,192-TX comparisons.

Additional controlled comparisons retained MTU 1,500 and the same quiche
connection/stream profile:

| Change | Received application goodput | Outcome |
|---|---:|---|
| Automatic placement, baseline rings | 8.75 Gbps | Retained |
| Explicit process pinning | 8.53 Gbps | Not retained; optional `-PinProcesses` |
| IRQ/XPS alignment without pinning | 8.33 Gbps | Not retained |
| IRQ/XPS alignment with pinning | 7.67 Gbps | Not retained |
| Larger RX/TX rings, up to 8,192 / 16,384 | 8.26-8.74 Gbps | No gain; restored 2,048 / 4,096 |
| Root or per-queue `fq` | 7.71-8.31 Gbps | Not retained |
| Kernel busy polling, 50 microseconds | 8.91 / 9.13 Gbps | Explicit opt-in; near-100% receiver CPU |
| `noqueue` on the MANA VF (`ens1`) | 8.66-9.33 Gbps, mean 9.10 (n=7) vs 8.47 (n=5) | Retained with `-OptimizeThroughput` |
| `noqueue` on both `eth0` and the VF | 9.10 / 9.16 Gbps | No clear gain over VF only; not retained |
| Route peer traffic directly via the VF, plus VF `noqueue` | 9.14-9.42 Gbps, mean 9.31 (n=5) | Not retained; unsupported |

Placement and ring trials used 20-second windows; the busy-poll comparison
used 30 seconds in both directions. The qdisc and VF-route trials used
20-second server-to-client runs with busy polling enabled. These are observed runs, not statistical
confidence intervals. Normal `irqbalance`, automatic process placement, and
default XPS masks remain selected. More queues, interrupt coalescing, hardware
UDP segmentation, and TLS offload cannot be enabled on this VM datapath.

With Accelerated Networking, every transmitted packet passes through two
qdiscs: one on the synthetic netvsc interface and one on the MANA VF. In the
sender profile, paravirtual spinlock release accounted for about 11% of samples.
Removing the VF's redundant qdisc kept queueing on `eth0` and raised mean
goodput by about 7%. After rebooting both VMs with this setting persisted, a
20-second server-to-client run measured 9.55 Gbps. Sending through the VF directly with a static neighbor
(`12:34:56:78:9a:bc`), a `/32` route on `ens1`, and loose `rp_filter` added about
2% more. It is not retained because Azure can revoke the VF during host
servicing; that route would then black-hole peer traffic instead of falling
back to the synthetic path. Loose reverse-path filtering is also weaker.

MANA's [DPDK poll-mode driver](https://doc.dpdk.org/guides/nics/mana.html)
provides a kernel-bypass option. The VMs expose MANA RDMA devices and have the
`mana_ib`, `libmana`, and `libibverbs` prerequisites, but the current quiche apps
use UDP sockets. DPDK would require a new packet-I/O integration, buffer/queue
ownership, and a management-network plan; no DPDK throughput gain has been
measured. It is packet-I/O bypass, not TLS offload, and polling competes for this
VM's single physical core. Likewise, `io_uring` zero-copy sends require completion
and buffer-lifetime integration rather than a safe flag on the existing sender.
More physical cores and a kernel-bypass sender are architectural options for
further investigation, not measured improvements on this VM size. Neither
guarantees 10 Gbps without a new end-to-end benchmark.

## quinn throughput

`test-quinn-throughput.ps1` measures QUIC goodput with the upstream
[quinn](https://github.com/quinn-rs/quinn) `perf` crate. It is a raw QUIC
stream benchmark (TLS 1.3 via rustls/ring, AES-128-GCM), not HTTP/3. The
measurements below used `Standard_F2als_v7`:

```powershell
.\deploy.ps1 -ResourceGroupName sabansal-wireguard-sea-rg `
  -Location southeastasia -AvailabilityZone 1 -OptimizeThroughput `
  -VmSize Standard_F2als_v7
.\test-quinn-throughput.ps1 -ResourceGroupName sabansal-wireguard-sea-rg
```

`quinn-benchmark/install.sh` builds a pinned quinn commit on both VMs under
`/var/tmp` (about five minutes) and installs two binaries in
`/opt/quinn-perf/bin`:

- `quinn-perf`: unmodified upstream.
- `quinn-perf-gsocap`: adds `QUINN_MAX_TRANSMIT_SEGMENTS` and
  `QUINN_MAX_TRANSMIT_DATAGRAMS` environment overrides for the two per-send
  batching constants in `quinn/src/connection.rs`. This is a local patch, not
  an upstream option.

The install is skipped when the script fingerprint matches; use `-SkipInstall`
to skip the check. The wrapper stops `quiche-benchmark` during the run and
restarts it afterwards. Use `-Build stock` for upstream, `-Reverse` for
client-to-server, and `-Pairs` to change the number of connections.

`quinn-perf` runs on a single-threaded Tokio runtime, so the wrapper starts one
server/client process pair per connection (ports 5433 and up). Three pairs
spread load over both vCPUs; one pair reached only 5.5 Gbps.

quinn already uses GSO (`UDP_SEGMENT`) and GRO (`UDP_GRO`). strace shows
14,720-byte `sendmsg` calls (10 × 1472) and coalesced `recvmmsg` reads. Upstream
limits one GSO send to 10 segments and one drive call to 20 datagrams, which
costs about 10× more syscalls than one full 64 KiB send. Raising the segment
cap to 44 (44 × 1472 = 64,768 bytes, the largest that fits in one UDP GSO send)
gave the largest improvement. A cap of 64 exceeds the 64 KiB limit and collapses
throughput to about 0.2 Gbps.

| quinn configuration, 3 pairs, 30 s | Server to client | Client to server |
|---|---:|---:|
| Upstream (segments 10, datagrams 20) | 10.5–10.9 Gbps | 10.9 Gbps |
| Segments 20, datagrams 40 | 12.3–12.4 Gbps | — |
| Segments 32, datagrams 64 | 12.9–13.0 Gbps | — |
| **Segments 44, datagrams 88** (default) | **13.3–13.6 Gbps** | **13.4–13.5 Gbps** |

On the same F2 VMs, quiche HTTP/3 measured 11.3–11.8 Gbps and direct TCP 15.6
Gbps. Both VMs ran at about 85–90% CPU. quinn needs busy polling: with
`net.core.busy_poll=0` it fell from about 10 to 8 Gbps. Pinning, 32 MiB socket
buffers, BBR, and ACK frequency did not help. See `results/quinn-f2-trials.txt`.

## HTTP/3 throughput

The topology includes a purpose-built HTTP/3 client and server based on
`quic-go`. The server streams generated data over QUIC without reading from
disk, and the client reports application goodput plus whole-VM CPU utilization
on both VMs over the same measurement interval.

Run the 30-second direct VNet test:

```powershell
.\test-http3-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -Path Direct `
  -ParallelRequests 8 `
  -DurationSeconds 30
```

To benchmark HTTP/3 inside WireGuard, use `-Path WireGuard`. The script verifies
the selected route, installs and builds the pinned HTTP/3 benchmark on both VMs,
opens UDP port 4433 in the guest firewall, starts the server, runs the timed
transfer, and stops the server. The private benchmark uses an ephemeral
self-signed certificate and disables certificate verification on its dedicated
client.

## TLS-encrypted TCP throughput

Run a raw TLS 1.3 over TCP benchmark on the direct VNet path:

```powershell
.\test-tls-throughput.ps1 `
  -ResourceGroupName sabansal-wireguard-rg `
  -ParallelConnections 8 `
  -DurationSeconds 30
```

This is not HTTP or HTTP/3. The server streams generated bytes over parallel
TLS 1.3 TCP connections, so storage is not in the data path. The benchmark
reports application goodput, the negotiated cipher suite, and synchronized
whole-VM CPU utilization on both VMs.
