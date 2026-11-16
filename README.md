# handoff-at-batch-end

Measurement package for branch **`feat/handoff-at-batch-end`** of breakertt/HomaModule: one commit,
`a0313799` "Hand an RPC off on the last packet of a batch", on upstream HomaModule `07ce63ef`.
The variants are `base` (`07ce63ef`) and `fix` (`a0313799`).

## Problem

`homa_dispatch_pkts` holds the RPC lock while it gives a batch of packets of one RPC to
`homa_data_pkt`. Upstream hands the RPC to a waiting thread on the first packet of the batch:

```
 SoftIRQ (RPC locked)                       receiving thread
 pkt 1: queue, hand off  ----------------->  wakes, sets APP_NEEDS_LOCK, spins on the RPC lock
 pkt 2: sees APP_NEEDS_LOCK, unlocks,
        waits for the thread  <-----------   locks, takes the queued packets, unlocks
 pkt 2: locks again, continues
```

The waits are SoftIRQ time. They cost throughput only when the core that runs SoftIRQ is the
bottleneck.

## Change

`homa_data_pkt` hands the RPC off after it queues the last packet of its batch (`skb->next` is
NULL, read before the packet is queued), and `homa_rpc_alloc_server` no longer hands off. A batch
of one packet is handed off as before.

## Results

cp_node between two xl170 nodes: 8 KB requests with 100 in flight and 64 KB requests with 20 in
flight. Responses are as long as requests. The variants are loaded in the order `base fix base fix`,
and each load runs every cell 5 times, each time with a new server. The table gives the median of
the 5 runs of each load (the `MEDIAN` lines of `logs/bench.log`, with one `RUN` line per run), and
the means of the two loads for the other columns. All counters are from the server.

| receive path | cell | kops (base, base / fix, fix) | change | P99 us (base / fix) | RPC lock waits per 1000 DATA packets (base / fix) | `homa_softirq` ns per DATA packet (base / fix) |
|---|---|---|---|---|---|---|
| NAPI and SoftIRQ on core 0 | `8k-same` | 184.64, 184.45 / 202.40, 201.70 | +9.5 % | 585 / 536 | 215 / 16 | 476 / 396 |
| | `64k-same` | 15.87, 15.79 / 16.60, 16.56 | +4.7 % | 1308 / 1259 | 137 / 31 | 358 / 298 |
| TCP hijacking, NAPI and SoftIRQ on cores 0 and 1 | `64k-hijack` | 27.89, 27.88 / 28.98, 28.96 | +3.9 % | 1161 / 1113 | 124 / 34 | 334 / 283 |
| Gen2, NAPI on core 0, SoftIRQ on other cores | `64k-gen2` | 22.33, 22.28 / 22.30, 22.26 | -0.1 % | 1080 / 1088 | 87 / 28 | 360 / 327 |

- **The fix removes 68 % to 92 % of the RPC lock waits and 9.0 % to 16.9 % of the `homa_softirq`
  time per packet, with every receive path.** In `8k-same`, 199 fewer waits per 1000 packets save
  80 ns per packet, about 400 ns per wait.
- **NAPI and SoftIRQ on one core.** This is the receive path of a kernel without RPS: Homa's
  SoftIRQ steering needs the RFS flow table, and RSS hashes Homa packets on the addresses only, so
  one address pair uses one queue. Core 0 is the bottleneck: the SoftIRQ time that the fix saves
  goes to more packets, and throughput increases by 9.5 % and 4.7 %.
- **TCP hijacking** (`hijack_tcp`) makes the NIC hash the Homa ports too. The 12 port pairs of a
  cell go to RX queues 0 and 1, half of the packets each in every run (the `rxq` field), and each
  of cores 0 and 1 does NAPI and SoftIRQ for its own packets. Throughput increases by 3.9 %.
- **Gen2** is Homa's own load balancer: NAPI runs on core 0 and SoftIRQ on the cores after it. The
  fix saves 9.0 % of the SoftIRQ time and throughput does not change, so the SoftIRQ cores are
  not the bottleneck.

## cp_node commands

For each cell, `run.sh` first runs `run.sh rx <same|hijack|gen2>` on both nodes, then these commands
as root, with `<size>` 8192 or 65536 and `<inflight>` 100 or 20. The server starts first. A client
runs 4 s to warm up, then a new client runs 12 s against the same server. The kops and latency of
a run are the means of the client's last 5 one-second lines.

```
node0$ taskset -c 5-9 cp_node server --protocol homa --ports 4 --port-threads 1
node1$ taskset -c 4-9 cp_node client --protocol homa --servers 0 --id 1 --server-ports 4 --ports 3 --port-receivers 1 --workload <size> --client-max <inflight>
```

## Setup

| | |
|---|---|
| machines | 2x CloudLab `xl170` (Utah): 1x Xeon E5-2640 v4 (10 cores; SMT turned off by `run.sh`), 64 GiB |
| NIC | ConnectX-4 Lx 25G, in-tree `mlx5_core`, one port per node on the experiment LAN (10.0.1.x); firmware 14.32.1908 (node0) and 14.18.2030 (node1) |
| OS | Ubuntu 24.04, mainline kernel 6.17.8 (`6.17.8-061708-generic`) booted with `mitigations=off` |
| packages | `gcc-14` (the default gcc-13 cannot build the module for this kernel) |

## Node configuration

`run.sh setup` is applied to both nodes before every variant (a fresh `insmod` each time). It prints
one `# nic <host>: ...` line with the resulting state, which is kept at the top of each variant in the
log; the two nodes' lines should agree, and `ko_md5` should match `md5sum` of that variant.

| what | setting | why |
|---|---|---|
| module | `rmmod homa; insmod <variant>/homa.ko` | fresh module state per variant |
| MTU | 1500 | some CloudLab LANs come up with 9000; this keeps the packet rate of a standard Ethernet MTU |
| flow director | all ntuple rules deleted | only the stock RSS path is used |
| Homa sysctls | HomaModule's `cloudlab/bin/config` `config_homa` for the 25 Gbps link; `gro_policy` 114 and `gro_busy_usecs` 0 (as `config` sets them for Gen2) | Homa's own reference tuning |
| NIC coalescing | `config_nic`: adaptive RX/TX off, `rx-usecs 0 rx-frames 1`, `tx-usecs 5` | one interrupt per received packet |
| CPU | SMT off (`smt/control`), turbo off (`intel_pstate/no_turbo` 1), every C-state but POLL disabled, `performance` governor on every core | each core runs at one fixed frequency and never sleeps |
| IRQs, XPS | mlx5 completion IRQ i -> core i; transmit queue i <- cpu i | RX queue i is received on core i |
| `rx same` | `ethtool -X <if> equal 1`; `rps_cpus` 0, `rps_flow_cnt` 0, `rps_sock_flow_entries` 0 | all packets on queue 0, SoftIRQ on core 0 after NAPI. An empty `rps_cpus` alone is not enough: the RFS flow table still steers |
| `rx hijack` | `hijack_tcp` 1; `ethtool -X <if> equal 2`; RPS and RFS off as for `same` | packets spread over queues 0 and 1 by port, SoftIRQ on the core that received them |
| `rx gen2` | `ethtool -X <if> equal 1`; `config_rps` (RFS on, `rps_cpus` = all cores) | all packets on queue 0, Gen2 picks a SoftIRQ core among the cores after core 0 |
| applications | cp_node server (4 threads) pinned to cores 5-9, client (6 threads) to cores 4-9 (`taskset`) | off the receiving cores; one core per client thread, because each thread polls |

## Reproduce

Two CloudLab xl170 nodes as above, named `node0`/`node1` with the experiment LAN on 10.0.1.x. Install
the compiler on both:

```bash
sudo apt-get install -y gcc-14
```

node1 drives node0 over ssh; from your workstation:

```bash
ssh <node1> 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub' | ssh <node0> 'cat >> ~/.ssh/authorized_keys'
ssh <node1> 'ssh -o StrictHostKeyChecking=accept-new node0 true'
```

Then on both nodes:

<!-- quickstart -->
```bash
mkdir -p ~/bhrepro && cd ~/bhrepro
git clone -q --single-branch -b feat-artifact/handoff-at-batch-end https://github.com/breakertt/HomaModule.git artifact
git clone -q --single-branch -b feat/handoff-at-batch-end https://github.com/breakertt/HomaModule.git fix
git clone -q --no-checkout fix base && git -C base checkout -q 07ce63ef
for v in base fix; do make -C $v -j16 CC=gcc-14; done
make -C base/util cp_node CFLAGS="-Wall -Werror -fno-strict-aliasing -O3 -I.. -DSOCKADDR=sockaddr"
cp artifact/run.sh .
md5sum base/homa.ko fix/homa.ko
```

and on node1 only:

```bash
cd ~/bhrepro && bash run.sh "base fix base fix" | tee bench.log
```

The raw output of that run is `logs/bench.log`.

## Unit tests

`test/` needs a configured 6.17 kernel tree with `CONFIG_DEBUG_PREEMPT`, `CONFIG_SECURITY` and
`CONFIG_SECURITY_NETWORK` enabled and `CONFIG_RANDOM_KMALLOC_CACHES` disabled; then
`cd test && make KDIR=<tree> unit && ./unit && ./unit --ipv4`. With gcc 13:

| tree | `./unit` | `./unit --ipv4` |
|---|---|---|
| upstream `07ce63ef` | 886/886 | 886/886 |
| `feat/handoff-at-batch-end` (`a0313799`) | 885/885 | 885/885 |

The fix adds `homa_dispatch_pkts__handoff_after_batch` and `homa_rpc_alloc_server__no_handoff`, and
removes the three tests of the handoff in `homa_rpc_alloc_server`.
