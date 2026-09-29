# route-cacheline-contention

Reproduction package for branch **`fix/route-cacheline-contention`** of HomaModule: one commit on
upstream `1c59d7b6`, "Keep write-hot homa_route fields off the lookup cacheline".

## Change

With a single peer, every core calls `homa_route_get()` on the same `struct homa_route` for every RPC.
Two stores on that path dirtied the cacheline that the other cores read to compare the route key:

- `access_jiffies` was stored on every lookup; it is now stored only when `jiffies` has changed.
- `refs` and `access_jiffies` (written on every get/release) shared the first cacheline with most of the
  64-byte route key; they now sit after the read-mostly fields, on their own cacheline.

A unit test checks the new layout. There is no new state and no behaviour change.

## Results

cp_node between two nodes over one IP pair, 12 application cores per node, 100-byte request and response
unless noted. A-B-A order (base, patch, base); base is the mean of both base passes, 3 reps of 12 s each.
The two base passes differ by less than 1 % in every cell. Raw per-rep output: `logs/bench.log`.

| cell | load | base Kops | patch Kops | gain | P50 us (base / patch) | P99 us (base / patch) |
|---|---|---|---|---|---|---|
| `C:6:192:2` | 6 ports, 192 in flight | 1197 | 1226 | +2.4 % | 43.6 / 43.7 | 78 / 80 |
| `C:6:384:2` | 6 ports, 384 in flight | 1192 | 1217 | +2.1 % | 43.6 / 43.9 | 79 / 74 |
| `C:6:768:2` | 6 ports, 768 in flight | 1196 | 1222 | +2.2 % | 43.5 / 43.9 | 78 / 77 |
| `C:6:384:2:64` | 6 ports, 384 in flight, 64 B | 1195 | 1227 | +2.7 % | 43.7 / 43.6 | 84 / 80 |
| `C:4:256:3:100:2` | 4 ports, 256 in flight, 2 receivers/port | 864 | 874 | +1.1 % | 37.2 / 37.2 | 60 / 60 |

A cell `C:k:cmax:pt[:wl[:pr]]` is cp_node `--ports k --server-ports k --client-max cmax`, server
`--port-threads pt`, workload `wl` bytes (default 100), `--port-receivers pr` (default 1).

## Setup

| | |
|---|---|
| machines | 2x CloudLab `sm110p` (Wisconsin): 1x Xeon Silver 4314 (16 cores), 125 GiB |
| NIC | ConnectX-6 Dx 100G, in-tree `mlx5_core`, one port per node on the experiment LAN (10.0.1.x) |
| OS | Ubuntu 24.04, mainline kernel 6.17.8 (`6.17.8-061708-generic`) booted with `intel_pstate=no_hwp nosmt` |
| packages | `gcc-14` (the default gcc-13 cannot build the module for this kernel) |

## Node configuration

`run.sh setup` is applied to both nodes before every variant. It prints one `# nic <host>: ...` line with
the resulting state, which is kept at the top of each variant in the log.

| what | setting | why |
|---|---|---|
| module | `rmmod homa; insmod <variant>/homa.ko` | fresh module state per variant |
| address | data NIC `ens2f0np0` = 10.0.1.1 (node0) / 10.0.1.2 (node1), /24 | |
| flow director | all ntuple rules deleted, ntuple off | only the stock RSS path is used |
| Homa sysctls | HomaModule's `cloudlab/bin/config` `config_homa`, 100 Gbps table: `num_priorities` 8, `link_mbps` 100000, `max_nic_est_backlog_usecs` 5, `unsched_bytes` 60000, `max_incoming` 1600000, `max_gso_size` 100000; everything else (e.g. `gro_policy` 114, `gro_busy_usecs` 5, `poll_usecs` 50) at the module default | Homa's own reference tuning |
| NIC coalescing | `config_nic`: adaptive RX/TX off, `rx-usecs 0 rx-frames 1`, `tx-usecs 5` | one interrupt per received packet, as Homa's config sets it |
| RPS/RFS | `config_rps`: `rps_sock_flow_entries` 32768, `rps_flow_cnt` 2048 and `rps_cpus` = all cores on every RX queue | Homa steers SoftIRQ work through the RFS table |
| CPU | `config_power`, then turbo on (`intel_pstate/no_turbo=0`) and the `performance` governor on every core; C-states left enabled | fixed, maximum frequency |
| RSS | `ethtool -X ens2f0np0 equal 1` (every RSS bucket to queue 0) | one Homa flow hashes to one queue anyway; this pins it to queue 0, so NAPI/GRO runs on core 0 and Homa's SoftIRQ steering uses cores 1-3 |
| IRQs | mlx5 completion IRQ of queue i -> core i | TX completions of each queue on that queue's core |
| XPS | transmit queue i <- cpu i | a core sends and completes on its own queue |
| applications | cp_node client and server pinned to cores 4-15 (`taskset`) | keeps them off the NAPI/SoftIRQ cores |

`config_homa`, `config_nic`, `config_power` and `config_rps` are HomaModule's functions, called unchanged;
`run.sh` only tells them which interface to use (their own interface detection picks the first
`s0f0`/`s1f0` port with link, which need not be the data NIC).

## Reproduce

Start from two provisioned nodes (kernel and boot arguments as above) and install the compiler:

```bash
sudo apt install gcc-14
```

node1 drives node0 over ssh; from your workstation:

```bash
ssh <node1> 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub' | ssh <node0> 'cat >> ~/.ssh/authorized_keys'
ssh <node1> 'ssh -o StrictHostKeyChecking=accept-new node0 true'
```

On both nodes (the last line on node1 only):

```bash
mkdir -p ~/peercp && cd ~/peercp
git clone --single-branch -b fix-artifact/route-cacheline-contention https://github.com/breakertt/HomaModule.git artifact
git clone --single-branch -b fix/route-cacheline-contention https://github.com/breakertt/HomaModule.git patch
git clone --no-checkout patch base && git -C base checkout 1c59d7b6
for v in base patch; do make -C $v -j16 CC=gcc-14; done
make -C base/util cp_node
cp artifact/run.sh .
bash run.sh "base patch base" 3 2>&1 | tee bench.log      # node1 only
```

## Unit tests

`test/` needs a configured kernel tree with `CONFIG_DEBUG_PREEMPT`, `CONFIG_SECURITY` and
`CONFIG_SECURITY_NETWORK` enabled and `CONFIG_RANDOM_KMALLOC_CACHES` disabled. Without rebuilding a
kernel, mirror a configured 6.17 tree and override only its autoconf.h:

```bash
KDIR=/tmp/kdir-unit; cp -rs <configured-linux-6.17-tree> $KDIR
AC=$KDIR/include/generated/autoconf.h; rm -f $AC; cp <configured-linux-6.17-tree>/include/generated/autoconf.h $AC
printf '#define CONFIG_DEBUG_PREEMPT 1\n#define CONFIG_SECURITY 1\n#define CONFIG_SECURITY_NETWORK 1\n#undef CONFIG_RANDOM_KMALLOC_CACHES\n' >> $AC
cd test && make KDIR=$KDIR unit && ./unit
```

| tree | `./unit` | `./unit --ipv4` |
|---|---|---|
| upstream `1c59d7b6` | 832/832 | 830/832 |
| `fix/route-cacheline-contention` | 833/833 | 831/833 |

The two `--ipv4` failures (`homa_outgoing.homa_tx_skb_alloc__shinfo_gso_fields`,
`homa_rpc.homa_rpc_get_info__basics`) also fail on upstream.
