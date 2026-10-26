#!/bin/bash
# One point, run on the client (n09). A fixed number of RPCs in flight: cp_node client with 4 ports x (1 sender + 2 receivers),
# the shape of fix-artifact/route-cacheline-contention's C:4:256:3:100:2; 4 s warm-up, then a window of W
# one-second dump_times (dump_times writes and clears the RTT ring, so every RPC of the window is kept),
# snapshots around the window, and a lossless histogram of the RTTs (cp_node prints them with 0.01 us steps).
# client-max "u": one RPC in flight instead (1 port, synchronous sender, --port-receivers 0): the RTT floor.
# client-max "g<rate>": a fixed rate instead, Poisson arrivals at <rate> RPC/s (--gbps = rate x 800 / 1e9 for 100 B
#   requests), the same 4-port client; --client-max 256 is only a cap.
#   (cp_node --unloaded fails at ae45ada5 with "measure_rtt got error in recvmsg: Invalid argument".)
# usage: cell.sh <out dir> <cell> <server ports> <client-max|u> [window s]
#   out: <cell>.client.{log,before,after}, <cell>.window (start/end, s), <cell>.hist ("rtt_us count" lines)
set -u
O=$1; C=$2; NP=$3; CM=$4; W=${5:-60}
U=/root/homa-up-ae45ada5/util; T=/dev/shm/lowload; R=/root/lowload
mkdir -p $O $T; rm -f $T/$C.*
G=0; A="--ports 4 --port-receivers 2 --client-max $CM"
case $CM in
  u)  A="--ports 1 --port-receivers 0 --client-max 1";;
  g*) A="--ports 4 --port-receivers 2 --client-max 256"; G=$(awk -v r=${CM#g} 'BEGIN {printf "%.7f", r * 800 / 1e9}');;
esac
{ echo "client --protocol homa --servers 1 --id 0 --server-ports $NP $A --workload 100 --gbps $G"
  sleep 4; $R/snap.sh > $O/$C.client.before; echo "dump_times /dev/null"; date +%s.%N > $O/$C.window
  for s in $(seq -w 1 $W); do sleep 1; echo "dump_times $T/$C.$s.rtts"; done
  date +%s.%N >> $O/$C.window; $R/snap.sh > $O/$C.client.after; echo exit
} | taskset -c 4-15 $U/cp_node > $O/$C.client.log 2>&1
taskset -c 1-3 awk '!/^#/ && NF == 2 {n[$2]++} END {for (v in n) print v, n[v]}' $T/$C.*.rtts | sort -n > $O/$C.hist
rm -f $T/$C.*
awk -v c=$C 'NR == FNR {w[FNR] = $1; next} {v[FNR] = $1; k[FNR] = $2; n += $2}
  END {d = w[2] - w[1]; printf "%s: %d RPCs in %.2f s = %.1f Kops", c, n, d, n / d / 1000
       split("50 95 99 99.9", p); j = 1; s = 0
       for (i = 1; i in v; i++) { s += k[i]; while (j <= 4 && s >= n * p[j] / 100) { printf " P%s %s", p[j], v[i]; j++ } }
       print " us"}' $O/$C.window $O/$C.hist
