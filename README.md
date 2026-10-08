# bind-ack-with-route

Reproduction package for branch **`fix/bind-ack-with-route`** of breakertt/HomaModule: one commit,
`0dff986a` "Bind pending acks to the route instead of the peer", on upstream HomaModule `20fe2271`.

## Bug

A Homa client does not send a packet to ack each completed RPC. It banks the ack and piggybacks it on a
later packet to the same server: one ack in every DATA header, and a batch in the reply to a NEED_ACK.
The server frees its state for the RPC when the ack arrives.

Upstream banks acks on the `homa_peer`, which is keyed by destination address only. Packets, however,
go out on a `homa_route`, which since `f30a0eff` is keyed by the socket's routing parameters (source
address, `SO_MARK`, bound device, ...). The server finds the RPC an ack refers to with
`homa_rpc_find_server(hsk, saddr, id)`, where `saddr` is the source address of the packet that carries
the ack. A client that reaches one server from several source addresses (multi-homed, or per-socket
policy routing) therefore has one peer and one shared ack bank, but several routes:

```
 CLIENT                                                   SERVER S
 sock1 (src A) -> route(A->S) --+                         RPCs looked up by
                                +--> peer(S) [ack bank]   (RPC id, client address)
 sock2 (src B) -> route(B->S) --+

 sock2: RPC #7 done -> bank [#7]
 sock1: DATA for RPC #8 takes #7 from the bank, leaves from A ==>  find(7, A): no match, dropped
 server, 2-3 ms later: NEED_ACK #7 to B, every tick until freed
 sock2: ACK #7 from B, plus up to 5 more acks from the bank  ==>  #7 freed; extras from A dropped
```

Nothing is lost for the application and every server RPC is eventually freed, but most RPCs now need
their own NEED_ACK/ACK round trip, and each such RPC holds its server state for another 2-3 ms
(`request_ack_ticks` = 2 ticks of 1 ms). With one source address, every ack leaves from the address
its RPC used and the bug does not show.

## Change

The fix is on the client: RPC ids come from a per-host counter, so the server needs the address to find
an RPC, and carrying another address in each ack would add 16 bytes to every DATA header.

- `num_acks` and `acks[]` move from `homa_peer` to `homa_route`, so an ack only leaves from the address
  its RPC used; `homa_peer_add_ack` / `homa_peer_get_acks` become `homa_route_add_ack` /
  `homa_route_get_acks`.
- They are guarded by `route->lock`, which upstream initializes but never takes. It moves to the end of
  `homa_route`, next to the bank, on its own cache line.
- The lock keeps the trylock wrapper and miss metrics the peer lock had (`homa_route_lock()`,
  `route_ack_lock_misses`, `route_ack_lock_miss_cycles`): all sockets with the same routing parameters
  share one route, so in the usual single-address case it is exactly as shared as the peer lock was.
- `peer->lock` has no other users and is removed; `util/metrics.py`, `protocol.md` and the unit tests
  follow.
- Acks banked on a route that `homa_route_validate()` replaces or the GC evicts are dropped and
  recovered by NEED_ACK, as acks on an evicted peer are today.

## Results

cp_node between two xl170 nodes, 100-byte requests and responses. Order base, fix, base, fix:
each variant was loaded twice, and each cell ran 2 x 12 s per load; the numbers are means over the
4 runs per variant. Raw per-run output: `logs/bench.log`.

### Single-homing: one source address

| cell | load | base Kops | fix Kops | change | P50 us (base / fix) | P99 us (base / fix) |
|---|---|---|---|---|---|---|
| `1:1:1` | 1 port, 1 in flight | 54.4 | 53.9 | -0.9 % | 17.2 / 17.3 | 35 / 35 |
| `3:96:2` | 3 ports, 96 in flight | 472.4 | 472.9 | +0.1 % | 31.3 / 31.5 | 50 / 51 |
| `3:384:2` | 3 ports, 384 in flight | 472.2 | 476.8 | +1.0 % | 31.3 / 31.5 | 54 / 56 |

The fix is between -0.9 % and +1.0 % of base, in both directions, about as much as two loads of the
same variant differ (up to 1.2 %); P50 is within 0.2 us and P99 within 2 us. With one source address
all client sockets share one route, as they shared one peer before, so every core still takes the
same ack lock; only its location changed. NEED_ACKs stay at 0.0001-0.0003 per RPC for both.

### Multi-homing: three source addresses

| cell | load | base Kops | fix Kops | change | P50 us (base / fix) | P99 us (base / fix) | NEED_ACK per RPC (base / fix) |
|---|---|---|---|---|---|---|---|
| `3:384:2:m` | 3 ports, 384 in flight, 3 source addresses | 284.4 | 483.2 | +69.9 % | 710.6 / 31.6 | 6687 / 59 | 0.67 / 0.0004 |

The same load as `3:384:2`, except that the three client sockets send from three different source
addresses. Upstream sends a NEED_ACK for two RPCs in three, its throughput is 40 % below `3:384:2`
and swings between runs (236-348 Kops), and median latency rises 23x. With the fix the NEED_ACKs are
gone and throughput and latency are back at the single-homing level.

A cell `k:cmax:pt[:m]` is cp_node `--ports k --server-ports k --client-max cmax`, server
`--port-threads pt`; `:m` adds `--mark-base 100`, so client socket i sends from source address i.

## Setup

| | |
|---|---|
| machines | 2x CloudLab `xl170` (Utah): 1x Xeon E5-2640 v4 (10 cores, 2 threads each), 64 GiB |
| NIC | ConnectX-4 Lx 25G, in-tree `mlx5_core`, one port per node on the experiment LAN (10.0.1.x) |
| OS | Ubuntu 24.04, mainline kernel 6.17.8 (`6.17.8-061708-generic`) booted with `mitigations=off` |
| packages | `gcc-14` (the default gcc-13 cannot build the module for this kernel) |

## Node configuration

`run.sh setup` is applied to both nodes before every variant (a fresh `insmod` each time). It prints
one `# nic <host>: ...` line with the resulting state, which is kept at the top of each variant in the
log; the two nodes' lines should agree, and `ko_md5` should match `md5sum` of that variant.

| what | setting | why |
|---|---|---|
| module | `rmmod homa; insmod <variant>/homa.ko` | fresh module state per variant |
| address | experiment port (found by its 10.0.1.x address) = 10.0.1.1 (node0) / 10.0.1.2 (node1), /24 | |
| flow director | all ntuple rules deleted | only the stock RSS path is used |
| Homa sysctls | HomaModule's `cloudlab/bin/config` `config_homa` for the 25 Gbps link; everything else at the module default | Homa's own reference tuning |
| NIC coalescing | `config_nic`: adaptive RX/TX off, `rx-usecs 0 rx-frames 1`, `tx-usecs 5` | one interrupt per received packet, as Homa's config sets it |
| RPS/RFS | `config_rps`: `rps_sock_flow_entries` 32768, `rps_flow_cnt` 2048, `rps_cpus` = all cores on every RX queue | Homa steers SoftIRQ work through the RFS table |
| CPU | turbo on (`intel_pstate/no_turbo=0`), `performance` governor on every core (`config_power` cannot run `cpupower` on this kernel) | fixed, maximum frequency |
| RSS | `ethtool -X <if> equal 1` (every bucket to queue 0) | NAPI/GRO on core 0 in both cells, so the cells differ only in source addresses |
| IRQs, XPS | mlx5 completion IRQ i -> core i; transmit queue i <- cpu i | a core sends and completes on its own queue |
| applications | cp_node client and server pinned to cores 4-9 (`taskset`) | off the NAPI/SoftIRQ cores 0-3 and their hyperthreads |
| multi-homing | node1 gets aliases 10.0.1.101-104 and, for each, `ip rule add fwmark <100+i> table <100+i>` with `ip route add 10.0.1.1/32 src 10.0.1.<101+i> table <100+i>` | a socket with `SO_MARK` 100+i leaves from alias i |
| cp_node | `cp_node-mark-base.patch`: `--mark-base MB` sets `SO_MARK` MB+i on client socket i | lets one cp_node client use one source address per port |

`config_homa`, `config_nic`, `config_power` and `config_rps` are HomaModule's functions, called unchanged;
`run.sh` only tells them which interface to use.

NEED_ACK counts are
the server's `packets_sent_NEED_ACK` from `/proc/net/homa_metrics`, read from second 3 to second 11
of each 12-second run. The server is restarted before every run: a client killed by `timeout` leaves
server RPCs that NEED_ACK until an ICMP unreachable aborts them, which would otherwise leak into the
next run's window.

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
mkdir -p ~/ackrepro && cd ~/ackrepro
git clone -q --single-branch -b fix-artifact/bind-ack-with-route https://github.com/breakertt/HomaModule.git artifact
git clone -q --single-branch -b fix/bind-ack-with-route https://github.com/breakertt/HomaModule.git fix
git clone -q --no-checkout fix base && git -C base checkout -q 20fe2271
for v in base fix; do make -C $v -j20 CC=gcc-14; done
git -C base apply ../artifact/cp_node-mark-base.patch
make -C base/util cp_node CFLAGS="-Wall -Werror -fno-strict-aliasing -O3 -I.. -DSOCKADDR=sockaddr"
cp artifact/run.sh .
md5sum base/homa.ko fix/homa.ko
```

(`-DSOCKADDR=sockaddr`: since upstream `173d3241`, `util/test_utils.h` uses `SOCKADDR`, which only
`homa_impl.h` defines, so `util/` does not build without it.)

and on node1 only:

```bash
cd ~/ackrepro && bash run.sh "base fix base fix" 2 | tee bench.log
```

The raw output of that run is `logs/bench.log`.

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
| upstream `20fe2271` | 839/839 | 837/839 |
| `fix/bind-ack-with-route` | 840/840 | 838/840 |

The two `--ipv4` failures (`homa_outgoing.homa_tx_skb_alloc__shinfo_gso_fields`,
`homa_rpc.homa_rpc_get_info__basics`) also fail on upstream. The new test,
`homa_route_add_ack__separate_bank_per_route`, makes two client RPCs to one server from sockets with
different `sk_mark`s, which get different routes but the same peer, and checks that after
`homa_route_add_ack` only the RPC's own route returns the ack.
