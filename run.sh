#!/bin/bash
# cp_node A/B of Homa module variants on a CloudLab xl170 pair, for feat/handoff-at-batch-end.
#   bash run.sh "<variant...>" [reps]     run on node1 (client, 10.0.1.2); node0 (10.0.1.1) is the server
#   bash run.sh setup <homa.ko> <ip>      configure this node (run.sh calls it on both nodes, as root)
#   bash run.sh rx <same|gen2|hijack>     receive path of this node (as root), see below
# Each variant is <work dir>/<variant>/homa.ko; <work dir>/base is a HomaModule checkout that provides
# cloudlab/bin/config and util/cp_node.
set -u
R=${R:-$(cd "$(dirname "$0")" && pwd)}  # work dir (passed through sudo below)
IF=${IF:-$(ip -4 -br a | awk '$3 ~ /^10\.0\.1\./ {print $1; exit}')}   # experiment LAN port
# cp_node cores: the server's 4 threads run outside physical cores 0-4, which receive the packets;
# the client's 6 threads also take core 4, so that each has a core of its own.
APP=${APP:-$(lscpu -p=CPU,CORE | awk -F, '!/^#/ && $2 > 4 {printf "%s%s", s, $1; s=","}')}
CAPP=${CAPP:-$(lscpu -p=CPU,CORE | awk -F, '!/^#/ && $2 > 3 {printf "%s%s", s, $1; s=","}')}

if [ "${1:-}" = rx ]; then
  # same:   one RX queue (core 0), RPS and RFS off: SoftIRQ runs on core 0 after NAPI (an empty
  #         rps_cpus is not enough: the RFS flow table alone still steers).
  # gen2:   one RX queue (core 0), RPS/RFS as config_rps sets them, and Gen2, which picks a
  #         SoftIRQ core among the cores after core 0.
  # hijack: hijack_tcp, so the NIC hashes the Homa ports too and spreads the packets over RX
  #         queues 0 and 1 (cores 0 and 1); RPS and RFS off: each core runs SoftIRQ for its own
  #         packets.
  case $2 in
    same)   q=1; h=0; n=0;     f=0;    m=0 ;;
    gen2)   q=1; h=0; n=32768; f=2048; m=$(printf %x $(( (1 << $(nproc)) - 1 ))) ;;
    hijack) q=2; h=1; n=0;     f=0;    m=0 ;;
  esac
  ethtool -X $IF equal $q
  sysctl -qw net.core.rps_sock_flow_entries=$n net.homa.gro_policy=114 net.homa.gro_busy_usecs=0 net.homa.hijack_tcp=$h
  for d in /sys/class/net/$IF/queues/rx-*; do echo $f > $d/rps_flow_cnt; echo $m > $d/rps_cpus; done
  exit 0
fi

if [ "${1:-}" = setup ]; then
  KO=$2; MYIP=$3
  pkill -x cp_node; sleep 0.5
  # SMT off before anything counts CPUs. With turbo off (below) and every C-state but POLL off,
  # each core runs at one fixed frequency and never sleeps.
  [ "$(cat /sys/devices/system/cpu/smt/control)" = off ] || echo off > /sys/devices/system/cpu/smt/control
  for f in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do case $f in */state0/*) ;; *) echo 1 > $f;; esac; done
  rmmod homa 2>/dev/null; insmod "$KO" || { echo "# $(hostname -s): INSMOD FAIL $KO"; exit 1; }
  ip -4 addr show dev $IF | grep -q " $MYIP/" || ip addr add "$MYIP/24" dev $IF; ip link set $IF mtu 1500 up
  P=$(basename "$(readlink -f /sys/class/net/$IF/device)")
  for id in $(ethtool -n $IF 2>/dev/null | awk '/^Filter:/{print $2}'); do ethtool -N $IF delete "$id" >/dev/null 2>&1; done
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
    f.write("1")
cfg.config_rps()
PY
  for c in $(seq 0 $(($(nproc) - 1))); do echo performance > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor; done
  # comp IRQ i -> core i and XPS txq i <- cpu i, for the online cores
  i=0; for irq in $(awk -v p="$P" '$0 ~ ("mlx5_comp[0-9]+@pci:" p) {sub(":","",$1); print $1}' /proc/interrupts); do
    [ $i -lt $(nproc) ] && echo $i > /proc/irq/$irq/smp_affinity_list; i=$((i+1)); done
  q=0; for f in $(ls -v /sys/class/net/$IF/queues/tx-*/xps_cpus); do
    [ $q -lt $(nproc) ] && printf '%x' $((1 << q)) > $f || echo 0 > $f; q=$((q+1)); done
  s() { sysctl -n "net.homa.$1" 2>/dev/null; }
  echo "# nic $(hostname -s): if=$IF ko_md5=$(md5sum "$KO"|cut -c1-12) kernel=$(uname -r) fw=$(ethtool -i $IF|awk '/^firmware-version/{print $2}')" \
       "rules=$(ethtool -n $IF|grep -c '^Filter:') xps_tx0=$(cat /sys/class/net/$IF/queues/tx-0/xps_cpus)" \
       "coalesce=$(ethtool -c $IF|awk '/Adaptive RX/{a=$3;t=$5}/^rx-usecs:/{u=$2}/^rx-frames:/{f=$2}/^tx-usecs:/{x=$2}END{print "adaptrx"a",adapttx"t",rxus"u",rxfr"f",txus"x}')" \
       "mtu=$(cat /sys/class/net/$IF/mtu) smt=$(cat /sys/devices/system/cpu/smt/control) cpus=$(cat /sys/devices/system/cpu/online) cstates_on=$(grep -l 0 /sys/devices/system/cpu/cpu0/cpuidle/state*/disable | xargs -n1 dirname | xargs -I{} cat {}/name | tr "\n" ,) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo) gov=$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor)" \
       "homa:link_mbps=$(s link_mbps),num_priorities=$(s num_priorities),unsched_bytes=$(s unsched_bytes),max_incoming=$(s max_incoming),max_gso_size=$(s max_gso_size),poll_usecs=$(s poll_usecs)"
  exit 0
fi

# A cell is name:rx:size:inflight. Every cell runs the same cp_node pair: the server has 4 ports
# with 1 thread each, the client 3 ports (one sender and one receiver thread each), so there are
# 12 port pairs to hash; responses are as long as requests (cp_node's default). The server runs on
# cores $APP, the client on cores $CAPP. Each cell runs REPS times, each time with a new server, and
# a MEDIAN line follows. Server-side counters over the middle of each run (/proc/net/homa_metrics, all cores):
#   misses_per_kpkt   server_lock_misses (RPC lock waits) per 1000 DATA packets received
#   sirq_ns_per_pkt   softirq_cycles (time in homa_softirq) per DATA packet received, in ns
#   rxq               share of the received packets per RX queue that got more than 1 %
REPS=${2:-5}; DUR=12; U=$R/base/util; S="ssh -4 -o StrictHostKeyChecking=no node0"
CELLS=${CELLS:-"8k-same:same:8192:100 64k-same:same:65536:20 64k-hijack:hijack:65536:20 64k-gen2:gen2:65536:20"}
# "<softirq_cycles> <server_lock_misses> <packets_rcvd_DATA> <cpu_khz> <rx0_packets> <rx1_packets> ..."
cnt() { sudo awk '$1=="softirq_cycles" {c+=$2} $1=="server_lock_misses" {m+=$2} $1=="packets_rcvd_DATA" {p+=$2}
        $1=="cpu_khz" {k=$2} END {print c+0, m+0, p+0, k}' /proc/net/homa_metrics | tr '\n' ' '
        ethtool -S $(ip -4 -br a | awk '$3 ~ /^10\.0\.1\./ {print $1; exit}') | awk '/^ *rx[0-9]+_packets:/ {printf "%s ", $2}'; }
for V in $1; do
  sudo R=$R IF=$IF bash $R/run.sh setup $R/$V/homa.ko 10.0.1.2; $S "sudo R=$R bash $R/run.sh setup $R/$V/homa.ko 10.0.1.1" </dev/null
  for c in $CELLS; do IFS=: read -r name rx size inflight <<<"$c"
    sudo IF=$IF bash $R/run.sh rx $rx; $S "sudo bash $R/run.sh rx $rx" </dev/null
    cli() { sudo timeout $1 taskset -c $CAPP $U/cp_node client --protocol homa --servers 0 --id 1 --server-ports 4 --ports 3 --port-receivers 1 --workload $size --client-max $inflight; }
    srv() { $S "sudo pkill -x cp_node; sleep 0.5; cd $U; nohup sudo taskset -c $APP ./cp_node server --protocol homa --ports 4 --port-threads 1 >/tmp/bh-cps.log 2>&1 &" </dev/null; sleep 2; }
    for rep in $(seq 1 $REPS); do
      srv; cli 4 >/dev/null 2>&1
      cli $DUR >/tmp/bh-cpc.log 2>&1 & pid=$!
      sleep 3; s0=$($S "$(declare -f cnt); cnt" </dev/null)
      sleep $((DUR - 4)); s1=$($S "$(declare -f cnt); cnt" </dev/null)
      wait $pid; out=$(grep Kops /tmp/bh-cpc.log | tail -5)
      echo "RUN $V $c rep=$rep" \
        "kops=$(echo "$out" | grep -oE '[0-9.]+ Kops' | awk '{s+=$1;n++} END {if (n) printf "%.2f", s/n}')" \
        "p50=$(echo "$out" | grep -oE 'P50 [0-9.]+' | awk '{s+=$2;n++} END {if (n) printf "%.2f", s/n}')" \
        "p99=$(echo "$out" | grep -oE 'P99 [0-9.]+' | awk '{s+=$2;n++} END {if (n) printf "%.1f", s/n}')" \
        "$(echo "$s0 | $s1" | awk -F'|' '{n=split($1,a," "); split($2,b," "); p=b[3]-a[3]; t=0
           printf "misses_per_kpkt=%.1f sirq_ns_per_pkt=%.0f rxq=", (b[2]-a[2])*1000/p, (b[1]-a[1])*1e6/b[4]/p
           for (i=5; i<=n; i++) t+=b[i]-a[i]
           for (i=5; i<=n; i++) if (b[i]-a[i] > t/100) printf "%s%d:%.0f%%", (s++ ? "," : ""), i-5, 100*(b[i]-a[i])/t}')"
    done | tee /tmp/bh-cell.log
    med() { grep -oE " $1=[0-9.]+" /tmp/bh-cell.log | cut -d= -f2 | sort -g | awk '{a[NR]=$1} END {if (NR) print (NR % 2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }
    echo "MEDIAN $V $c runs=$REPS kops=$(med kops) p50=$(med p50) p99=$(med p99) misses_per_kpkt=$(med misses_per_kpkt) sirq_ns_per_pkt=$(med sirq_ns_per_pkt)"
  done
  $S "sudo pkill -x cp_node" </dev/null
done
