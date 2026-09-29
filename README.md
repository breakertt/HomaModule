# bind-ack-with-route

Reproduction package for branch `fix/bind-ack-with-route` of breakertt/HomaModule: one commit,
`80b4d5ed` "Bind pending acks to the route instead of the peer", on upstream HomaModule `1c59d7b6`.

## The change

A Homa client does not send a packet to ack each completed RPC. It banks the ack and piggybacks it on
a later packet to the same server (one ack in every DATA header, a batch in the reply to a NEED_ACK);
the server frees its state for the RPC when the ack arrives.

Upstream banks acks on the `homa_peer`, which is keyed by destination address only, but packets go
out on a `homa_route`, which is keyed by the socket's source address, mark, bound device and so on.
The server looks an ack up with `homa_rpc_find_server(hsk, saddr, id)`, where `saddr` is the source
address of the packet that carries it. A client that reaches one server from several source
addresses therefore has one peer, one shared bank, and several routes:

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

Nothing is lost for the application, but most RPCs cost an extra NEED_ACK/ACK round trip and hold
server state 2-3 ms longer (`request_ack_ticks` = 2 ticks of 1 ms, counted from the first timer pass
that sees the response fully sent).

The fix is on the client: RPC ids come from a per-host counter, so the server needs the address to
find an RPC, and carrying another address in each ack would add 16 bytes to every DATA header. The
commit:

- moves `num_acks` and `acks[]` from `homa_peer` to `homa_route`, guarded by `route->lock` (which
  upstream allocates but never takes), and renames `homa_peer_add_ack` / `homa_peer_get_acks` to
  `homa_route_add_ack` / `homa_route_get_acks`;
- keeps the trylock wrapper and miss metrics the peer lock had (`homa_route_lock()`,
  `route_ack_lock_misses`, `route_ack_lock_miss_cycles`): all sockets with the same routing
  parameters share one route, so the lock is as contended as the peer lock was;
- puts the lock and bank at the end of `homa_route`, on their own cache line (offset 256 on x86_64)
  behind the fields read on every lookup. `homa_route` grows from 216 to 320 bytes (kmalloc-256 ->
  kmalloc-512), `homa_peer` shrinks from 256 to 128;
- removes `peer->lock`, and updates `util/metrics.py`, `protocol.md` and the unit tests.

Acks banked on a route that `homa_route_validate()` replaces or the GC evicts are dropped and
recovered by NEED_ACK, as acks on an evicted peer are today. Not in this commit: `READ_ONCE` on the
unlocked `num_acks == 0` fast path (the race is benign and documented in the `@num_acks` kdoc), and
any limit on how long a server keeps asking for an ack it never gets.

## Results

RESULTS_PLACEHOLDER

## Setup

| | |
|---|---|
| nodes | 2x CloudLab `sm110p` (Wisconsin): Xeon Silver 4314, 16 cores, ConnectX-6 Dx 100 Gbps (`mlx5_core`), data NIC `ens2f0np0` |
| addresses | node0 = 10.0.1.1 (server), node1 = 10.0.1.2 (client) plus aliases 10.0.1.101-108 |
| OS | Ubuntu 24.04, mainline kernel 6.17.8-061708-generic, boot args `intel_pstate=no_hwp nosmt` |
| build | `homa.ko` with `make CC=gcc-14` (the kernel was built with a newer gcc; gcc-13 fails) |
| Homa/NIC config | HomaModule's `cloudlab/bin/config` (`config_homa`, `config_nic`, `config_power`, `config_rps`), turbo on, governor `performance` |
| RX/TX layout | RSS to queues 0 and 4, mlx5 completion IRQ i -> core i, XPS txq i <- cpu i, no ntuple rules; apps on cores 4-11 |
| multi-source | node1 socket with `SO_MARK` 100+i is policy-routed (one table per fwmark) to leave from alias 10.0.1.(101+i) |
| load | `cp_node` (with `cp_node-mark-base.patch`), 4 ports, `--client-max 256`, 100-byte RPCs, 2 server threads per port, 12 s per run, 3 runs per cell, A-B-A |
| cells | `single`: no marks, all client sockets send from 10.0.1.2; `multi`: `--mark-base 100`, 4 client sockets on 4 aliases |
| NEED_ACK | server `packets_sent_NEED_ACK`, client `packets_rcvd_NEED_ACK`, summed over cores, read from second 3 to second 11 of each run; the server is restarted before every run so RPCs left by the previous killed client do not count |

`run.sh setup` prints a `# nic` line per node and variant; the two nodes' lines should agree and
`ko_md5` should match `md5sum` of that variant on both nodes. The md5 of `homa.ko` depends on the
build directory (it is embedded in the module), so compare it within one setup, not across machines
with different paths.

## Reproduce

node1 drives node0 over ssh, so first, from your workstation:

```bash
ssh <node1> 'ssh-keygen -q -t ed25519 -N "" -f ~/.ssh/id_ed25519 && cat ~/.ssh/id_ed25519.pub' | ssh <node0> 'cat >> ~/.ssh/authorized_keys'
ssh <node1> 'ssh -o StrictHostKeyChecking=accept-new node0 true'
```

Then on both nodes:

<!-- quickstart -->
```bash
sudo apt-get install -y gcc-14
mkdir -p ~/ackrepro && cd ~/ackrepro
git clone -q --single-branch -b fix-artifact/bind-ack-with-route https://github.com/breakertt/HomaModule.git artifact
git clone -q --single-branch -b fix/bind-ack-with-route https://github.com/breakertt/HomaModule.git fix
git clone -q --no-checkout fix base && git -C base checkout -q 1c59d7b6
for v in base fix; do make -C $v -j16 CC=gcc-14; done
git -C base apply ../artifact/cp_node-mark-base.patch && make -C base/util cp_node
cp artifact/run.sh .
md5sum base/homa.ko fix/homa.ko
```

and on node1 only:

```bash
cd ~/ackrepro && bash run.sh "base fix base" 3 | tee bench.log
```

The raw output of the run above is `logs/bench.log`.

## Unit tests

With `fix/bind-ack-with-route` checked out, `test/` passes 833/833 (832 upstream + 1 new). With
`--ipv4`, 831/833: `homa_tx_skb_alloc__shinfo_gso_fields` and `homa_rpc_get_info__basics` fail the
same way on upstream `1c59d7b6`. The new test, `homa_route_add_ack__separate_bank_per_route`, makes
two client RPCs to one server from sockets with different `sk_mark`s, which get different routes but
the same peer, and checks that after `homa_route_add_ack` only the RPC's own route returns the ack.

`test/` needs a kernel tree configured with `CONFIG_DEBUG_PREEMPT` and `CONFIG_SECURITY_NETWORK`
(`mock.c` defines `preempt_count_add()` and `security_sk_classify_flow()`) and without
`CONFIG_RANDOM_KMALLOC_CACHES` (it leaves `random_kmalloc_seed` undefined at link time). To use an
already configured >= 6.9 tree `$SRC` without changing it:

```bash
KDIR=/tmp/homa-unit-kdir
cp -rs "$(readlink -f $SRC)" $KDIR
rm $KDIR/include/generated/autoconf.h && cp $SRC/include/generated/autoconf.h $KDIR/include/generated/
printf '#define CONFIG_DEBUG_PREEMPT 1\n#define CONFIG_SECURITY 1\n#define CONFIG_SECURITY_NETWORK 1\n#undef CONFIG_RANDOM_KMALLOC_CACHES\n' >> $KDIR/include/generated/autoconf.h
cd test && make KDIR=$KDIR unit && ./unit && ./unit --ipv4
```

The stripped (upstream-submission) variant is only partly checkable: `homa_peer.c`, which holds most
of this change, compiles clean with `-D__STRIP__`, but the whole module does not build that way on
upstream either (`START_MSG` undeclared in `homa_incoming.c`), and `make s_test` does not run
because `test/Makefile` passes `--alt` to `util/strip.py`, which treats it as a file name.
