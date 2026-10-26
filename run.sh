#!/bin/bash
# Pool waiting-list corruption and cp_node A/B of Homa module variants on a CloudLab xl170 pair.
#   bash run.sh close "<variant...>" [rounds]   bug: a server whose clients close sockets with RPCs in flight
#   bash run.sh bench "<variant...>" [reps]     no regression: cp_node throughput and latency
#   bash run.sh setup <homa.ko> <ip>             configure this node (the modes call it on both nodes, as root)
# Run the modes on node1 (client, 10.0.1.2); node0 (10.0.1.1) is the server. Each variant is
# <work dir>/<variant>/homa.ko; <work dir>/base is a HomaModule checkout that provides
# cloudlab/bin/config and util/cp_node.
set -u
R=${R:-$(cd "$(dirname "$0")" && pwd)}  # work dir = where run.sh is (passed through sudo below)
IF=${IF:-$(ip -4 -br a | awk '$3 ~ /^10\.0\.1\./ {print $1; exit}')}   # experiment LAN port

if [ "${1:-}" = setup ]; then
  KO=$2; MYIP=$3
  pkill -x cp_node; pkill -x close_race; sleep 0.5
  rmmod homa 2>/dev/null; insmod "$KO" || { echo "# $(hostname -s): INSMOD FAIL $KO"; exit 1; }
  # Set the address only if it is missing: while it is absent, packets that node0 still sends to it
  # are forwarded (CloudLab nodes have ip_forward=1), and Homa's GRO has crashed node1 on them.
  ip -4 -br addr show dev $IF | grep -qw "$MYIP/24" ||
    { ip addr flush dev $IF scope global; ip addr add "$MYIP/24" dev $IF; ip link set $IF up; }
  P=$(basename "$(readlink -f /sys/class/net/$IF/device)")
  for id in $(ethtool -n $IF 2>/dev/null | awk '/^Filter:/{print $2}'); do ethtool -N $IF delete "$id" >/dev/null 2>&1; done
  for f in /sys/class/net/$IF/queues/tx-*/xps_cpus; do echo 0 > "$f" 2>/dev/null; done
  # HomaModule's own cloudlab/bin/config, functions called unchanged; only the data interface is pinned
  # (its get_interfaces() picks the first s0f0/s1f0 port with link) and get_node_type() is stubbed.
  python3 - "$R/base/cloudlab/bin/config" $IF "$KO" >/run/homa_config.log 2>&1 <<'PY' \
    || { echo "# $(hostname -s): config FAILED"; tail -5 /run/homa_config.log; exit 1; }
import importlib.machinery, importlib.util, os, sys
path, iface, ko = sys.argv[1:4]
sys.path.insert(0, os.path.dirname(path))
sys.argv = ["config"]
loader = importlib.machinery.SourceFileLoader("homa_config", path)
cfg = importlib.util.module_from_spec(importlib.util.spec_from_loader("homa_config", loader))
loader.exec_module(cfg)
cfg.interface = cfg.vlan = iface
cfg.get_node_type = lambda: "unknown"
cfg.config_homa(ko)
cfg.config_nic()
cfg.config_power()
with open("/sys/devices/system/cpu/intel_pstate/no_turbo", "w") as f:
    f.write("0")
cfg.config_rps()
PY
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $f; done
  # every RSS bucket -> queue 0 (NAPI/GRO on core 0), comp IRQ i -> core i, XPS txq i <- cpu i
  ethtool -X $IF equal 1
  i=0; for irq in $(awk -v p="$P" '$0 ~ ("mlx5_comp[0-9]+@pci:" p) {sub(":","",$1); print $1}' /proc/interrupts); do
    echo $i > /proc/irq/$irq/smp_affinity_list; i=$((i+1)); done
  q=0; for f in $(ls -v /sys/class/net/$IF/queues/tx-*/xps_cpus); do
    [ $q -lt $(nproc) ] && printf '%x' $((1 << q)) > $f; q=$((q+1)); done
  dmesg -C
  s() { sysctl -n "net.homa.$1" 2>/dev/null; }
  echo "# nic $(hostname -s): if=$IF ko_md5=$(md5sum "$KO"|cut -c1-12) kernel=$(uname -r) fw=$(ethtool -i $IF|awk '/^firmware-version/{print $2}')" \
       "rules=$(ethtool -n $IF|grep -c '^Filter:') rss=$(ethtool -x $IF | awk '/^ *[0-9]+:/{for(i=2;i<=NF;i++) q[$i]=1} END{for(k in q) printf "%s,", k}') xps_tx0=$(cat /sys/class/net/$IF/queues/tx-0/xps_cpus)" \
       "coalesce=$(ethtool -c $IF|awk '/Adaptive RX/{a=$3;t=$5}/^rx-usecs:/{u=$2}/^rx-frames:/{f=$2}/^tx-usecs:/{x=$2}END{print "adaptrx"a",adapttx"t",rxus"u",rxfr"f",txus"x}')" \
       "rfs=$(sysctl -n net.core.rps_sock_flow_entries) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo) gov=$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor)" \
       "homa:link_mbps=$(s link_mbps),num_priorities=$(s num_priorities),unsched_bytes=$(s unsched_bytes),max_incoming=$(s max_incoming),max_gso_size=$(s max_gso_size),dead_frags_limit=$(s dead_frags_limit)"
  exit 0
fi

MODE=$1; VARIANTS=$2; S="ssh -4 -o StrictHostKeyChecking=no node0"
U=$R/base/util
setup2() { sudo R=$R IF=$IF bash $R/run.sh setup $R/$1/homa.ko 10.0.1.2 && $S "sudo R=$R bash $R/run.sh setup $R/$1/homa.ko 10.0.1.1" </dev/null ||
           { echo "SETUP FAILED for $1: stop"; exit 1; }; }
# server on node0: k ports x pt threads on cores 4..3+k*pt (cores 0-3: NAPI and Homa's SoftIRQ steering)
srv() { $S "sudo pkill -x cp_node; sleep 0.5; cd $U; nohup sudo taskset -c $(seq -s, 4 $((3+$1*$2))) ./cp_node server --protocol homa --ports $1 --port-threads $2 >/tmp/wmem-cps.log 2>&1 &" </dev/null; sleep 2; }

if [ "$MODE" = close ]; then
  # close_race: 16 client threads keep 150 8 KB RPCs each in flight for 20 ms, then all close
  # their sockets at once, ROUNDS times, against a fresh close_race server on node0 (4 sockets,
  # 64 MiB receive region each). The closed sockets leave node0 with partly received requests
  # that hold buffer space, so many server RPCs wait for buffers (homa_pool_alloc_msg out of
  # space), and ICMP port unreachables then abort them (homa_abort_rpcs -> homa_rpc_end).
  # requests, alloc_failures, discards = node0's requests_received, buffer_alloc_failures and
  # server_rpc_discards during the run (summed over cores): how often a server RPC waited for
  # buffers and how often one was ended by an error such as an ICMP port unreachable.
  # responses = responses the clients received; node0_soft_lockups = soft lockups in node0's
  # kernel log 30 s after the server is stopped, or "unreachable" (the counters then read "-").
  ROUNDS=${3:-1000}
  ctr() { timeout 30 $S "sudo cat /proc/net/homa_metrics" </dev/null | awk '$1 ~ /^(requests_received|buffer_alloc_failures|server_rpc_discards)$/ {s[$1] += $2}
          END {if (length(s)) print s["requests_received"], s["buffer_alloc_failures"], s["server_rpc_discards"]}'; }
  prev=
  for V in $VARIANTS; do
    # reload only when the variant changes: a client socket leaked by the destroy race in the
    # module (fix/destroy-wait-for-reapers) would make rmmod fail on node1
    [ "$V" = "$prev" ] || setup2 $V; prev=$V
    $S "cd $R; nohup sudo taskset -c 4-7 ./close_race server 4000 4 >/tmp/cr-server.log 2>&1 &" </dev/null; sleep 1
    read -r q0 f0 d0 <<<"$(ctr)"
    out=$(sudo taskset -c 4-9 $R/close_race client 10.0.1.1 4000 16 150 8192 $ROUNDS 20000)
    sleep 5
    read -r q1 f1 d1 <<<"$(ctr)"
    [ -n "$q1" ] && c="requests=$((q1-q0)) alloc_failures=$((f1-f0)) discards=$((d1-d0))" || c="requests=- alloc_failures=- discards=-"
    # stopping the server ends all its RPCs (homa_sock_shutdown), another way into the race
    timeout 30 $S "sudo pkill -x close_race" </dev/null; sleep 30
    n0=$(timeout 30 $S "sudo dmesg | grep -c 'soft lockup'; true" </dev/null) || n0=unreachable
    echo "CLOSE $V rounds=$ROUNDS closes=$((16*ROUNDS)) $c $out node0_soft_lockups=$n0"
    [ "$n0" = 0 ] || { echo "node0 is not healthy after $V: stop"; exit 1; }
  done
  exit 0
fi

# cells k:cmax:pt:size = cp_node --ports k --server-ports k --client-max cmax --workload size,
# server --port-threads pt; client on cores 4..3+2k
REPS=${3:-2}; DUR=12
CELLS=${CELLS:-"1:1:1:100 3:384:2:100 3:96:2:8192"}
for V in $VARIANTS; do
  setup2 $V
  for c in $CELLS; do IFS=: read -r k cm pt sz <<<"$c"
    cli() { sudo timeout $1 taskset -c $(seq -s, 4 $((3+2*k))) $U/cp_node client --protocol homa --servers 0 --id 1 \
              --server-ports $k --ports $k --port-receivers 1 --workload $sz --client-max $cm; }
    for rep in $(seq 1 $REPS); do
      srv $k $pt; cli 4 >/dev/null 2>&1; srv $k $pt          # warm-up, then a fresh server for the measured run
      cli $DUR >/tmp/wmem-cpc.log 2>&1; out=$(grep Kops /tmp/wmem-cpc.log | tail -5)
      echo "RUN $V $c rep=$rep" \
        "kops=$(echo "$out" | grep -oE '[0-9.]+ Kops' | awk '{s+=$1;n++} END {if (n) printf "%.1f", s/n}')" \
        "p50=$(echo "$out" | grep -oE 'P50 [0-9.]+' | awk '{s+=$2;n++} END {if (n) printf "%.2f", s/n}')" \
        "p99=$(echo "$out" | grep -oE 'P99 [0-9.]+' | awk '{s+=$2;n++} END {if (n) printf "%.1f", s/n}')" \
        "warns=$(sudo dmesg | grep -c 'WARNING.*homa_sock_destroy')"
    done
  done
  $S "sudo pkill -x cp_node" </dev/null
done
