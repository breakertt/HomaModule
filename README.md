# handoff-at-batch-end

Measurement package for `feat/handoff-at-batch-end` (`e9a1d3b4`, "Hand an RPC off at the end of a
batch") on upstream HomaModule `07ce63ef`. Variants: `base` (`07ce63ef`) and `v2` (`e9a1d3b4`).

## Problem

Upstream hands the RPC to the waiting thread on the first packet of a batch, while SoftIRQ still
holds the RPC lock for the rest of the batch:

```
 SoftIRQ (RPC locked)                       receiving thread
 pkt 1: queue, hand off  ----------------->  wakes, sets APP_NEEDS_LOCK, spins on the RPC lock
 pkt 2: sees APP_NEEDS_LOCK, unlocks,
        waits for the thread  <-----------   locks, takes the queued packets, unlocks
 pkt 2: locks again, continues
```

## Change

`homa_dispatch_pkts` hands the RPC off once, after the whole batch and before
`homa_grant_check_rpc`. `homa_data_pkt` and `homa_rpc_alloc_server` no longer hand off.

## Results

cp_node on two xl170 nodes, loads `base v2 base v2`, 5 runs per load. kops is the median of each
load (`MEDIAN` lines of `logs/bench.log`); the other columns are the mean of the two loads, from
server counters.

| receive path | cell | kops (base, base / v2, v2) | change | P99 us | RPC lock waits per 1000 DATA packets | `homa_softirq` ns per DATA packet |
|---|---|---|---|---|---|---|
| NAPI and SoftIRQ on core 0 | `8k-same` | 185.37, 185.25 / 205.24, 204.94 | +10.7 % | 584 / 529 | 216 / 8 | 475 / 388 |
| | `64k-same` | 16.05, 16.04 / 16.94, 16.88 | +5.4 % | 1293 / 1238 | 137 / 26 | 354 / 289 |
| `hijack_tcp`, NAPI and SoftIRQ on cores 0 and 1 | `64k-hijack` | 28.34, 28.39 / 29.55, 29.52 | +4.1 % | 1133 / 1083 | 125 / 29 | 330 / 274 |
| Gen2, NAPI on core 0, SoftIRQ on other cores | `64k-gen2` | 22.54, 22.54 / 22.55, 22.55 | 0.0 % | 1063 / 1073 | 85 / 25 | 352 / 320 |

- v2 removes 70 % to 96 % of the lock waits and 9.1 % to 18.4 % of the SoftIRQ time per packet.
- Throughput goes up when SoftIRQ runs on the NAPI core and that core is the bottleneck. With
  Gen2 it does not.
- In `64k-hijack`, runs 3 and 5 of every load reach only about 16 kops, for both variants. The
  cause was not checked. They are never the median.

## cp_node commands

`run.sh rx <same|hijack|gen2>` on both nodes, then, with `<size>` 8192 or 65536 and `<inflight>`
100 or 20 (4 s warm-up client, then a 12 s client; kops and latency are the means of its last 5
lines):

```
node0$ taskset -c 5-9 cp_node server --protocol homa --ports 4 --port-threads 1
node1$ taskset -c 4-9 cp_node client --protocol homa --servers 0 --id 1 --server-ports 4 --ports 3 --port-receivers 1 --workload <size> --client-max <inflight>
```

## Setup

| | |
|---|---|
| machines | 2x CloudLab `xl170` (Utah), Xeon E5-2640 v4, 10 cores, 64 GiB |
| NIC | ConnectX-4 Lx 25G, `mlx5_core`, firmware 14.18.2030, experiment LAN 10.0.1.x |
| OS | Ubuntu 24.04, kernel `6.17.8-061708-generic`, `mitigations=off`, `gcc-14` |

`run.sh setup` runs on both nodes before every variant and prints one `# nic` line per node:

| what | setting |
|---|---|
| module | `rmmod homa; insmod <variant>/homa.ko` |
| MTU, flow director | 1500; all ntuple rules deleted |
| Homa sysctls | `cloudlab/bin/config` `config_homa` for 25 Gbps; `gro_policy` 114, `gro_busy_usecs` 0 |
| NIC coalescing | `config_nic`: adaptive off, `rx-usecs 0 rx-frames 1`, `tx-usecs 5` |
| CPU | SMT off, turbo off, only C-state POLL, `performance` governor |
| IRQs, XPS | completion IRQ i -> core i; TX queue i <- cpu i |
| `rx same` | `ethtool -X equal 1`; RPS and RFS off (`rps_cpus`, `rps_flow_cnt`, `rps_sock_flow_entries` 0) |
| `rx hijack` | `hijack_tcp` 1; `ethtool -X equal 2`; RPS and RFS off |
| `rx gen2` | `ethtool -X equal 1`; `config_rps` |

## Reproduce

Two xl170 nodes named `node0`/`node1`. On both:

```bash
sudo apt-get update && sudo apt-get install -y gcc-14
```

From your workstation, let node1 ssh to node0:

```bash
ssh <node1> 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub' | ssh <node0> 'cat >> ~/.ssh/authorized_keys'
ssh <node1> 'ssh -o StrictHostKeyChecking=accept-new node0 true'
```

Then on both nodes:

<!-- quickstart -->
```bash
mkdir -p ~/bhrepro && cd ~/bhrepro
git clone -q --single-branch -b feat-artifact/handoff-at-batch-end https://github.com/breakertt/HomaModule.git artifact
git clone -q --single-branch -b feat/handoff-at-batch-end https://github.com/breakertt/HomaModule.git v2
git clone -q --no-checkout v2 base && git -C base checkout -q 07ce63ef
for v in base v2; do make -C $v -j16 CC=gcc-14; done
make -C base/util cp_node CFLAGS="-Wall -Werror -fno-strict-aliasing -O3 -I.. -DSOCKADDR=sockaddr"
cp artifact/run.sh .
md5sum base/homa.ko v2/homa.ko
```

and on node1 only:

```bash
cd ~/bhrepro && bash run.sh "base v2 base v2" | tee bench.log
```

## Unit tests

With gcc 13 and a 6.17 tree configured with `CONFIG_DEBUG_PREEMPT`, `CONFIG_SECURITY`,
`CONFIG_SECURITY_NETWORK` on and `CONFIG_RANDOM_KMALLOC_CACHES` off
(`cd test && make KDIR=<tree> unit && ./unit && ./unit --ipv4`):

| tree | `./unit` | `./unit --ipv4` |
|---|---|---|
| `07ce63ef` | 886/886 | 886/886 |
| `e9a1d3b4` | 885/885 | 885/885 |
