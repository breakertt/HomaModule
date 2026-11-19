# destroy-wait-for-reapers

Reproduction package for branch **`fix/destroy-wait-for-reapers`** of breakertt/HomaModule: one
commit, `04b3f68e` "Release socket resources in homa_rpc_reap before unlocking the socket", on
upstream HomaModule `07ce63ef`. It is the second version of the fix in PlatformLab/HomaModule#153.
The measured version (`afb43320`) differs in one line: it woke up writers also when it reaped no
RPC. The fix now wakes them up only if `num_rpcs > 0`. A reap that frees at least one RPC does
the same in both versions.

## Bug

`homa_rpc_reap` frees dead RPCs in two steps. It takes a batch of RPCs off `hsk->dead_rpcs` while it
holds the socket lock. Then it releases the lock and frees them: it returns their receive buffers
to the buffer pool (`homa_pool_release`), subtracts their `frag_bytes` from `sk_wmem_alloc` and
wakes up writers (`homa_sock_wakeup_wmem`). `homa_timer` and SoftIRQ call it for any socket, also
for a socket that is closing.

`homa_sock_destroy` calls `homa_rpc_reap` until `dead_rpcs` is empty. Then it checks
`sk_wmem_alloc` and frees the buffer pool. An empty list does not mean that the RPCs are free: another
core can still be in the second step for the last batch.

```
 core A: homa_timer -> homa_rpc_reap   [socket lock]  takes the last RPCs off dead_rpcs
                                       [no lock]      frees them: homa_pool_release(rpc),
                                                      sk_wmem_alloc -= frag_bytes, wakeup
 core B: close -> homa_sock_destroy    dead_rpcs is empty
                                       WARN_ON_ONCE(sk_wmem_alloc != 1)    <- core A not done
                                       homa_pool_free(buffer_pool)        <- core A still uses it
```

- The WARN in `homa_sock_destroy` (`homa_sock.c:439`) fires.
- Core A can use the buffer pool after core B freed it (`homa_pool_release`).

`d00a93b6` ("Refactor outbound message management") moved the `sk_wmem_alloc` subtraction out of
the locked step.

## Change

- `homa_rpc_reap` releases the pool space and `sk_wmem_alloc` of each RPC while it holds the socket
  lock, before it takes the RPC off `dead_rpcs`. It wakes up writers before it unlocks the socket.
  An RPC that is off `dead_rpcs` holds no socket resources. The extra work under the lock is at most
  `BATCH_MAX_RPCS` (5) pool releases per batch.
- `homa_sock_destroy` takes and releases the socket lock once after its loop, so a reaper that is
  still in that locked step finishes first.
- `homa_rpc_reap` wakes up writers only if it reaped an RPC. A reap that gets the socket lock after
  `homa_sock_destroy` finds no RPCs and does not touch `sk_wq`, which `sk_common_release` then sets
  to NULL.

## Results

Close test (`run.sh close`, on node1). 16 client threads keep 150 8 KB RPCs each in flight for
20 ms, then close their sockets at the same time, 3000 or 1000 times per run. `count.patch` adds
one kernel log line for every socket that `homa_sock_destroy` finds with `sk_wmem_alloc != 1`. The
WARN itself fires only once per module load. `dead_frags_limit` 0 makes `homa_timer` reap a socket
whenever it has dead RPCs (`homa_timer.c:249`), so it reaps closing sockets more often. node0 runs
the close test's server. Each `run.sh close` command loads the module on node1 once.

| node1 module | load | `dead_frags_limit` | run | socket closes | destroy found `sk_wmem_alloc != 1` | WARN since insmod | sockets leaked |
|---|---|---|---|---|---|---|---|
| v2 | 1 | 0 | 1 | 48000 | 0 | 0 | 0 |
| v2 | 1 | 0 | 2 | 48000 | 0 | 0 | 0 |
| v2 | 1 | 0 | 3 | 48000 | 0 | 0 | 0 |
| base | 2 | 100 (default) | 4 | 48000 | 1 | 1 | 0 |
| base | 2 | 100 (default) | 5 | 48000 | 2 | 1 | 0 |
| base | 3 | 0 | 6 | 16000 | 3, then `homa_timer` oopsed | 1 | 1 |

- With the default `dead_frags_limit`, base found `sk_wmem_alloc != 1` in 3 of 96000 closes and
  fired the WARN. v2 found it in none of 144000 closes with `dead_frags_limit` 0.
- In run 6, right after the WARN, the `homa_timer` thread oopsed: NULL pointer dereference in
  `homa_pool_free_bufs` (`homa_pool.h:217`, `homa_pool_exists` reads `pool->region`), called from
  `homa_rpc_reap`. The timer still freed an RPC's buffers after `homa_sock_destroy` freed the
  pool and set `hsk->buffer_pool` to NULL. The dead timer thread keeps its references to sockets,
  so they are never freed (leaked 1) and the module stays in use. `logs/node1-warn-oops.log` is
  node1's kernel log from the WARN of load 3 on.

No regression (`run.sh bench`, cp_node). The variants run in the order base, v2, base, v2, each
after a fresh `insmod`, with two measurements of each cell:

| cell | base Kops | v2 Kops | v2 vs base | base P50 / P99 (us) | v2 P50 / P99 (us) |
|---|---|---|---|---|---|
| `1:1:1:100` | 55.3 (54.7-56.0) | 56.0 (55.4-56.7) | +1.3% | 16.89 / 34.0 | 16.87 / 33.3 |
| `3:384:2:100` | 481.7 (478.6-483.9) | 481.5 (480.0-484.0) | -0.05% | 30.74 / 55.5 | 30.77 / 56.4 |
| `3:96:2:8192` | 350.9 (350.8-350.9) | 350.9 (350.8-350.9) | -0.01% | 211.07 / 781.5 | 213.61 / 779.8 |

The ranges of the two variants overlap in every cell. The 25 Gbps link limits the 8 KB cell.

## Setup

| | |
|---|---|
| machines | 2x CloudLab `xl170` (Utah): 1x Xeon E5-2640 v4 (10 cores, 2 threads each), 64 GiB |
| NIC | ConnectX-4 Lx 25G, in-tree `mlx5_core`, one port per node on the experiment LAN (10.0.1.x) |
| OS | Ubuntu 24.04, mainline kernel 6.17.8 (`6.17.8-061708-generic`) booted with `mitigations=off` |
| packages | `gcc-14` (the default gcc-13 cannot build the module for this kernel) |

## Node configuration

`run.sh setup` configures both nodes before every bench variant and before each new variant of the
close test (a fresh `insmod` each time). It prints one `# nic <host>: ...` line with the resulting
state. The log keeps this line at the top of each variant. The lines of the two nodes must agree,
and `ko_md5` must match the `md5sum` of that variant. In the close test node0 always loads
`server`, so only its `ko_md5` differs from node1's.

| what | setting | why |
|---|---|---|
| module | `rmmod homa; insmod <variant>/homa.ko`. In the close test, node0 loads `server/homa.ko`, which is `base` | fresh module state per variant. The bug of this package is on the client side (node1) |
| address | experiment port (found by its 10.0.1.x address) = 10.0.1.1 (node0) / 10.0.1.2 (node1), /24. If the address is missing, `run.sh` sets it | While the address is absent, the node forwards the packets that the other node still sends to it (`ip_forward` is 1 on CloudLab). Homa's GRO crashed a node on these packets. That is a separate bug. |
| flow director | all ntuple rules deleted | the NIC uses only the stock RSS path |
| Homa sysctls | HomaModule's `cloudlab/bin/config` `config_homa` for the 25 Gbps link. The close test sets `dead_frags_limit` on node1 (see Results). Everything else stays at the module default | Homa's own reference tuning |
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
sudo apt-get update -q && sudo apt-get install -y gcc-14
```

node1 drives node0 over ssh. Run this from your workstation:

```bash
ssh <node1> 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub' | ssh <node0> 'cat >> ~/.ssh/authorized_keys'
ssh <node1> 'ssh -o StrictHostKeyChecking=accept-new node0 true'
```

Then on both nodes:

<!-- quickstart -->
```bash
mkdir -p ~/destroyrepro && cd ~/destroyrepro
git clone -q --single-branch -b fix-artifact/destroy-wait-for-reapers https://github.com/breakertt/HomaModule.git artifact
git clone -q --single-branch -b fix/destroy-wait-for-reapers https://github.com/breakertt/HomaModule.git v2
git clone -q --no-checkout v2 base && git -C base checkout -q 07ce63ef
for v in base v2; do cp -r $v $v-count && patch -s -d $v-count -p1 < artifact/count.patch; done
ln -s base server
for v in base v2 base-count v2-count; do make -C $v -j20 CC=gcc-14; done
make -C base/util cp_node
cp artifact/run.sh .
gcc -O2 -Wall -pthread -I base artifact/close_race.c -o close_race
md5sum */homa.ko
```

and on node1 only:

```bash
cd ~/destroyrepro && {
  bash run.sh bench "base v2 base v2" 2
  bash run.sh close "v2-count v2-count v2-count" 3000 0
  bash run.sh close "base-count base-count" 3000 100
  bash run.sh close "base-count" 1000 0
} 2>&1 | tee bench.log
```

base runs last, so that v2 runs on a node1 where the race has not happened yet. The raw output of
that run is `logs/bench.log`. After the last command node1's `homa_timer` can be dead: reboot node1
before you load the module again.

## Unit tests

`test/` needs a configured kernel tree. We ran them with a kernel.org 6.17.8 tree and gcc 13:

```bash
cd linux-6.17.8 && make defconfig && scripts/config -e PREEMPT -e DEBUG_KERNEL -e DEBUG_PREEMPT \
  -e SECURITY -e SECURITY_NETWORK -d RANDOM_KMALLOC_CACHES -m TLS && make olddefconfig modules_prepare
cd <HomaModule>/test && make KDIR=<linux-6.17.8> unit && ./unit && ./unit --ipv4
```

| tree | `./unit` | `./unit --ipv4` |
|---|---|---|
| upstream `07ce63ef` | 886/886 | 886/886 |
| `07ce63ef` + v2 (`04b3f68e`) | 888/888 | 888/888 |

The race needs several cores, so the two new tests check the mechanism instead.
`homa_rpc_reap__release_socket_resources_before_unlock` checks at every socket unlock that once
`dead_rpcs` is empty, `sk_wmem_alloc` is 1, the pool is full and no writer waits for a wakeup. It
fails on `07ce63ef`, and it fails when the wakeup moves back after the unlock.
`homa_rpc_reap__no_wakeup_if_no_rpcs_reaped` checks that a reap that frees no RPC does not wake up
writers. It fails without the `num_rpcs > 0` check.
