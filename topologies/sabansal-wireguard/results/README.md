# Fixed-MTU throughput results

These are observed private-VNet measurements on two `Standard_D2als_v7` VMs
in Southeast Asia, availability zone 1, with underlay MTU 1500. They are not
Internet measurements or statistical confidence intervals. The two vCPUs on
each VM are SMT siblings of one physical AMD EPYC core.

## Selected quiche profile

Cloudflare quiche 0.30.0, commit
`be47c5011215b9f13bad06bd7627d3ae49888a19`, native release build with BoringSSL,
TLS 1.3 / AES128_GCM / h3, certificate verification, and no early data.

The selected profile uses two server workers, four connections, one stream per
connection, Cubic, 64 MiB connection and 4 MiB stream windows, UDP payload 1472,
software GSO and socket GRO, and disabled pacing for this dedicated VNet.
NIC rings are RX 2048 / TX 4096, with balanced RSS, normal IRQ balancing,
automatic process placement, default XPS masks, and `mq` / `fq_codel`.

HTTP/3 clients download bodies: `forward` means server to client; `reverse`
means client to server. The quiche JSON files count received application-body
bytes, excluding warmup. Their rate is `bytes_received * 8 / duration_seconds`.

| Measurement | Server to client | Client to server | Window |
|---|---:|---:|---:|
| Selected profile, busy polling off | 8.978 Gbps | 8.925 Gbps | 30 s |
| Paired busy-poll controls | 8.627 Gbps | 8.410 Gbps | 30 s |
| Busy polling at 50 microseconds | 8.910 Gbps | 9.128 Gbps | 30 s |
| Busy polling retained, after reboot | 9.063 Gbps | 8.888 Gbps | 30 s |

The direct TCP baseline received 15.7008 Gbps client to server over 30.015488
seconds; it is not QUIC or encrypted application goodput. No tested quiche
configuration achieved 10 Gbps. Busy polling consumes nearly 100% of receiver
VM CPU; its gains vary between runs.

## Artifact index

| Files | Meaning |
|---|---|
| `quiche-direct-baseline.json` | Direct TCP baseline and raw iperf3 output |
| `quiche-unpaced-final-{forward,reverse}.json` | Selected 30-second profile before busy polling |
| `quiche-busy-control-{forward,reverse}30.json` | Contemporary controls with busy polling off |
| `quiche-busy-repeat-{forward,reverse}30.json` | Paired 50-microsecond busy-poll measurements |
| `quiche-reboot-busy-{forward,reverse}30.json` | 30-second measurements after both VMs rebooted |
| `quiche-placement-*.json` | 20-second automatic, pinned, IRQ/XPS-aligned, and aligned-plus-pinned trials |
| `quiche-ring*.json` | 20-second ring-size trials; sizes are encoded as RX-TX |
| `quiche-tuned-no-gso.json` | 15-second GSO-disabled comparison: 3.757 Gbps |
| `quiche-parent-no-gro.json` | 15-second GRO-disabled comparison: 6.255 Gbps |
| `quiche-final-wrapper-smoke.json` | 10-second final-wrapper check, including actual kernel busy-poll settings |
| `quiche-boot-server-direct-proof.json` | Five-second transfer using the boot-started server without a wrapper restart |
| `quiche-post-reboot-*.txt` | Post-reboot services, MTU, rings, RSS, XPS, and busy-poll observations |
| `quiche-crypto-profile.txt` | System-wide CPU-clock profile under encrypted load |
| `quiche-kernel-txpath-trials.txt` | 20-second qdisc and direct-VF-route comparisons; VF `noqueue` retained |
| `quiche-vf-noqueue-post-reboot.json` | 20-second run after reboot with persistent VF `noqueue` (9.55 Gbps) |

Older comparisons can have different flow-control settings; use each JSON's
`settings` for its actual configuration rather than assuming all runs differ
by only one variable. GSO/GRO counters show actual batching, not only requested
flags. CPU affinity telemetry records effective masks.

The placement trial labels identify temporary host changes not represented in
the older JSON schema. `auto` used normal placement; `pinned` pinned application
processes; `queues-only` aligned MANA IRQs and eth0/MANA XPS queues to CPUs 0/1;
`aligned` combined queue alignment and process pinning. Host tuning was restored
after each trial. None of those placement changes improved throughput.

Busy-poll controls used `net.core.busy_poll=0` and `net.core.busy_read=0`;
busy-poll and post-reboot runs used 50 for both settings on both VMs. The older
results do not include these sysctls in their JSON. The final-wrapper smoke
result records them explicitly.

The five-second boot-server proof and ten-second smoke run are functional
checks, not substitutes for the 30-second measurements. The boot-server
invocation remained unchanged throughout the direct transfer.

The CPU profile confirms VAES/AVX-512 AES-GCM and VPCLMUL GHASH execution.
Individual function sample percentages do not represent total encryption
costs. Profiling adds overhead and is not a final throughput measurement.
