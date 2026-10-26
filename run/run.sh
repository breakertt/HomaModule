#!/bin/bash
# Low-load steering bench driver. Runs on the dev box: it reaches both nodes as `ssh n08` / `ssh n09`;
# the nodes cannot ssh each other. n08 (192.168.12.1, node1) is the server and the system under test;
# n09 (192.168.12.2) is the client (cell.sh), set up the same way for every config.
# usage: [FIRST=<round>] run.sh <run name> <last round> "<configs>" "<client-max list>" [window s]
#   e.g. run.sh stage1 2 "S0 S1 P4 P4pin R" "u 4 8 16 32 64 128 256"   (u = 1 RPC in flight, synchronous)
#        run.sh stage2 2 "S0 S1 P4 P4pin R" "g1000 g2000 g3000 g5000 ..." (g<rate> = a fixed rate of <rate> RPC/s;
#        rates <= 2000 get a 120 s window)
# Server threads: S0/S1/P4 4 ports x 3 threads floating on cores 4-15 (fix-artifact C:4:*:3 shape);
#   P4pin 12 processes x 1 port x 1 thread, port 4000+j pinned to core 4+j; R 16 processes, port 4000+j on core j.
# Output: n08:/root/lowload/out/<run>/ (shared /root): *.nic, per-cell client files (cell.sh), *.server.{before,after}.
set -u
RUN=$1; ROUNDS=$2; CFGS=$3; CMS=$4; W=${5:-60}
O=/root/lowload/out/$RUN; U=/root/homa-up-ae45ada5/util
ssh n08 "mkdir -p $O"
nports() { case $1 in P4pin) echo 12;; R) echo 16;; *) echo 4;; esac; }
server() {
  case $1 in
    P4pin) ssh n08 "cd $U; for j in \$(seq 0 11); do setsid nohup ./cp_node server --protocol homa --ports 1 \
             --first-port \$((4000+j)) --port-threads 1 --pin \$((4+j)) >/dev/shm/cps-\$j.log 2>&1 </dev/null & done";;
    R)     ssh n08 "cd $U; for j in \$(seq 0 15); do setsid nohup ./cp_node server --protocol homa --ports 1 \
             --first-port \$((4000+j)) --port-threads 1 --pin \$j >/dev/shm/cps-\$j.log 2>&1 </dev/null & done";;
    *)     ssh n08 "cd $U; setsid nohup taskset -c 4-15 ./cp_node server --protocol homa --ports 4 --port-threads 3 \
             >/dev/shm/cps.log 2>&1 </dev/null &";;
  esac
  local want=1; case $1 in P4pin) want=12;; R) want=16;; esac
  for i in $(seq 1 40); do [ "$(ssh n08 'pgrep -c -x cp_node')" = $want ] && return 0; sleep 0.25; done
  echo "# SERVER START FAIL $1"; return 1
}
for r in $(seq ${FIRST:-1} $ROUNDS); do
  order=$CFGS; [ $((r % 2)) = 0 ] && order=$(echo $CFGS | tr ' ' '\n' | tac | tr '\n' ' ')
  for cfg in $order; do
    ssh n08 "bash /root/lowload/setup.sh $cfg 192.168.12.1 | tee $O/r$r-$cfg.n08.nic"
    ssh n09 "bash /root/lowload/setup.sh client 192.168.12.2 | tee $O/r$r-$cfg.n09.nic"
    ssh n09 "ping -c2 -W1 192.168.12.1 >/dev/null" || { echo "# DATA PLANE DOWN"; exit 1; }
    server $cfg || exit 1
    for cm in $CMS; do
      c=r$r-$cfg-cm$cm; w=$W
      case $cm in g*) [ ${cm#g} -le 2000 ] && w=120;; esac
      ssh n09 "bash /root/lowload/cell.sh $O $c $(nports $cfg) $cm $w" &
      sleep 4.2; ssh n08 "/root/lowload/snap.sh > $O/$c.server.before"
      sleep $w;  ssh n08 "/root/lowload/snap.sh > $O/$c.server.after"
      wait
    done
    ssh n08 "pkill -x cp_node"
  done
done
echo "# DONE $(date +%F_%T)"
