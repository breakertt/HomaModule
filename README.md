# unlink-under-pool-lock

Reproduction package for branch **`fix/unlink-under-pool-lock`** of breakertt/HomaModule: one commit,
`f7087253` "Take the pool lock in homa_pool_unlink", on upstream HomaModule `ae45ada5`.

## Bug

`pool->waiting_for_bufs` holds the RPCs that wait for buffer space. Since `53f825ce` ("Restructure
data for homa_pool.c"), `pool->lock` protects it: `homa_pool_alloc_msg` adds RPCs to it and
`homa_pool_check_waiting` removes them while they hold that lock. `homa_pool_unlink`, which
`homa_rpc_end` calls, still removes the RPC while holding the RPC lock and the socket lock (which
protected the list before), not the pool lock. So an RPC that ends while it waits for buffers races
with the list operations on other cores:

```
 core A: homa_rpc_end(X)  [RPC lock X, socket lock]  list_del_init(X)   <- no pool lock
 core B: homa_pool_alloc_msg(Y)  [RPC lock Y, pool lock]  list_add_tail(Y) before X
 -> the list gets a cycle that does not pass through its head
 core C: homa_pool_alloc_msg(Z)  [bucket lock, pool lock]  list_for_each_entry(...) never ends
```

Core C spins in softirq at `homa_pool.c:412` (the `list_for_each_entry` over `waiting_for_bufs`)
while it holds the bucket lock of its RPC and the pool lock. Other cores then spin on those locks
(`homa_pool_lock_slow`, `homa_bucket_lock_slow` from `homa_abort_rpcs`, `homa_timer`), the watchdog
reports soft lockups on several cores, and the node stops answering.

When its clients close sockets with RPCs in flight, a server gets into this state. The partly
received requests hold buffer space, so other requests wait for buffers. The ICMP port unreachables
for the closed ports then make `homa_abort_rpcs` end waiting RPCs (`homa_rpc_abort` ends a server
RPC at once).

## Change

- `homa_pool_unlink` takes the pool lock around `list_del_init`.
- When the RPC is not on the list, it skips the lock. This is the common case. Only code that holds
  the RPC lock adds the RPC to the list or removes it, and the caller holds that lock. So the check
  needs no pool lock (`homa_rpc_get_info` already reads `buf_links` the same way).

## Results

Close test (`run.sh close`). One run starts a new server on node0, runs the clients for 10000 rounds
(160000 client socket closes), stops the server and checks node0 30 s later. The counters are
node0's during the run:

| node0 module | run | client closes | requests received | buffer allocation failures | server RPCs discarded | node0 afterwards |
|---|---|---|---|---|---|---|
| fix | 1 | 160000 | 2523258 | 2263126 | 2391568 | running, 0 soft lockups |
| fix | 2 | 160000 | 2568886 | 2310197 | 2462010 | running, 0 soft lockups |
| fix | 3 | 160000 | 2519690 | 2272188 | 2412370 | running, 0 soft lockups |
| base | 4 | 160000 | 2661636 | 2512104 | 2601810 | running, 0 soft lockups |
| base | 5 | 160000 | - | - | - | unreachable |

- The race does not hit on every base run. Here node0 kept running after the first base run and
  hung in the second. node0 kept running after each of the three fix runs.
- In both variants, node0 has too little buffer space for this workload. About 90 % of the requests
  fail to get buffer space at first, and node0 discards about 95 % of the server RPCs (for example
  after an ICMP port unreachable or a server stop). This is the path of the race.
- `logs/node0-soft-lockups.log` is the kernel log of the hung boot (host name shortened to node0).
  The first stuck CPU spins at `homa_pool_alloc_msg+0x300`, which is `homa_pool.c:412`, the
  `list_for_each_entry` over `waiting_for_bufs`. Another CPU waits for the pool lock in
  `homa_pool_lock_slow`.

No regression (`run.sh bench`, cp_node). The variants run in the order base, fix, base, fix, each
after a fresh `insmod`, with two measurements of each cell:

| cell | base Kops | fix Kops | fix vs base | base P50 / P99 (us) | fix P50 / P99 (us) |
|---|---|---|---|---|---|
| `1:1:1:100` | 54.4 (53.9-54.8) | 54.1 (53.0-55.2) | -0.5% | 17.11 / 34.4 | 17.23 / 34.3 |
| `3:384:2:100` | 479.7 (473.5-484.3) | 479.5 (477.3-481.4) | 0.0% | 31.21 / 55.5 | 31.15 / 57.8 |
| `3:96:2:8192` | 350.7 (350.6-350.8) | 350.7 (350.6-350.8) | 0.0% | 263.73 / 653.3 | 263.73 / 672.9 |

The mean Kops of fix is 0.5 % lower to equal, and the ranges of the two variants overlap. The 25 Gbps
link limits the 8 KB cell.

## Setup

| | |
|---|---|
| machines | 2x CloudLab `xl170` (Utah): 1x Xeon E5-2640 v4 (10 cores, 2 threads each), 64 GiB |
| NIC | ConnectX-4 Lx 25G, in-tree `mlx5_core`, one port per node on the experiment LAN (10.0.1.x) |
| OS | Ubuntu 24.04, mainline kernel 6.17.8 (`6.17.8-061708-generic`) booted with `mitigations=off` |
| packages | `gcc-14` (the default gcc-13 cannot build the module for this kernel) |

## Node configuration

`run.sh setup` configures both nodes before every bench variant and before each new variant of the
close test (a fresh `insmod` each time). It prints one
`# nic <host>: ...` line with the resulting state. The log keeps this line at the top of each
variant. The lines of the two nodes must agree, and `ko_md5` must match the `md5sum` of that variant.

| what | setting | why |
|---|---|---|
| module | `rmmod homa; insmod <variant>/homa.ko` | fresh module state per variant |
| address | experiment port (found by its 10.0.1.x address) = 10.0.1.1 (node0) / 10.0.1.2 (node1), /24. If the address is missing, `run.sh` sets it | While the address is absent, the node forwards the packets that the other node still sends to it (`ip_forward` is 1 on CloudLab). Homa's GRO crashed the node on these packets (`kernel BUG at net/core/skbuff.c`, from `ip_forward`). That is a separate bug. |
| flow director | all ntuple rules deleted | the NIC uses only the stock RSS path |
| Homa sysctls | HomaModule's `cloudlab/bin/config` `config_homa` for the 25 Gbps link. Everything else stays at the module default | Homa's own reference tuning |
| NIC coalescing | `config_nic`: adaptive RX/TX off, `rx-usecs 0 rx-frames 1`, `tx-usecs 5` | one interrupt per received packet, as Homa's config sets it |
| RPS/RFS | `config_rps`: `rps_sock_flow_entries` 32768, `rps_flow_cnt` 2048, `rps_cpus` = all cores on every RX queue | Homa steers SoftIRQ work through the RFS table |
| CPU | turbo on (`intel_pstate/no_turbo=0`), `performance` governor on every core (`config_power` cannot run `cpupower` on this kernel) | fixed, maximum frequency |
| RSS | `ethtool -X <if> equal 1` (every bucket to queue 0) | NAPI/GRO on core 0 |
| IRQs, XPS | mlx5 completion IRQ i -> core i. Transmit queue i <- CPU i | a core sends and completes on its own queue |
| applications | cp_node and close_race clients on cores 4-9, servers on cores 4-7 (`taskset`) | off the NAPI/SoftIRQ cores 0-3 |

`config_homa`, `config_nic`, `config_power` and `config_rps` are HomaModule's functions. `run.sh` calls
them unchanged and only tells them which interface to use.

## Reproduce

Two CloudLab xl170 nodes as above, named `node0`/`node1` with the experiment LAN on 10.0.1.x. Install
the compiler on both:

```bash
sudo apt-get install -y gcc-14
```

node1 drives node0 over ssh. Run this from your workstation:

```bash
ssh <node1> 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub' | ssh <node0> 'cat >> ~/.ssh/authorized_keys'
ssh <node1> 'ssh -o StrictHostKeyChecking=accept-new node0 true'
```

Then on both nodes:

<!-- quickstart -->
```bash
mkdir -p ~/poolrepro && cd ~/poolrepro
git clone -q --single-branch -b fix-artifact/unlink-under-pool-lock https://github.com/breakertt/HomaModule.git artifact
git clone -q --single-branch -b fix/unlink-under-pool-lock https://github.com/breakertt/HomaModule.git fix
git clone -q --no-checkout fix base && git -C base checkout -q ae45ada5
for v in base fix; do make -C $v -j20 CC=gcc-14; done
make -C base/util cp_node
cp artifact/run.sh .
gcc -O2 -Wall -pthread -I base artifact/close_race.c -o close_race
md5sum base/homa.ko fix/homa.ko
```

and on node1 only:

```bash
cd ~/poolrepro && {
  bash run.sh bench "base fix base fix" 2
  bash run.sh close "fix fix fix" 10000
  bash run.sh close "base base base" 10000
} 2>&1 | tee bench.log
```

The race does not hit on every base run, so base runs up to three times. It runs last because it
hangs node0: `run.sh` stops after the first run after which node0 is not healthy. Then power-cycle
node0 (CloudLab portal: the node's menu, "Power Cycle") and read the kernel log of the hung boot:

```bash
sudo journalctl -k -b -1 | grep -A30 -m3 'soft lockup' | tee soft-lockups.log
```

The raw output of that run is `logs/bench.log`. The node0 kernel log of the hung boot is
`logs/node0-soft-lockups.log`.

## Unit tests

`test/` needs a configured kernel tree with `CONFIG_DEBUG_PREEMPT`, `CONFIG_SECURITY` and
`CONFIG_SECURITY_NETWORK` enabled and `CONFIG_RANDOM_KMALLOC_CACHES` disabled. Without rebuilding a
kernel, mirror a configured 6.17 tree and override only its autoconf.h:

```bash
KDIR=/tmp/kdir-unit; cp -rs <configured-linux-6.17-tree> $KDIR
AC=$KDIR/include/generated/autoconf.h; rm -f $AC; cp <configured-linux-6.17-tree>/include/generated/autoconf.h $AC
printf '#define CONFIG_DEBUG_PREEMPT 1\n#define CONFIG_SECURITY 1\n#define CONFIG_SECURITY_NETWORK 1\n#undef CONFIG_RANDOM_KMALLOC_CACHES\n' >> $AC
cd test && make KDIR=$KDIR unit && ./unit && ./unit --ipv4
```

| tree | `./unit` | `./unit --ipv4` |
|---|---|---|
| upstream `ae45ada5` | 862/862 | 860/862 |
| `fix/unlink-under-pool-lock` | 863/863 | 861/863 |

The two `--ipv4` failures (`homa_outgoing.homa_tx_skb_alloc__shinfo_gso_fields`,
`homa_rpc.homa_rpc_get_info__basics`) also fail on upstream. The race needs several cores, so the
tests check the mechanism instead: `homa_pool_unlink` now makes the pool lock's slow path run once
when its trylock fails (it fails on `ae45ada5`, which never takes the lock), and
`homa_pool_unlink__not_waiting_for_buffers` checks that an RPC that is not on the list does not
take the lock.
