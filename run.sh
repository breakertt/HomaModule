#!/bin/bash
# Single- and multi-homing cp_node A/B of Homa module variants on a CloudLab xl170 pair.
#   bash run.sh "<variant...>" [reps]     run on node1 (client, 10.0.1.2); node0 (10.0.1.1) is the server
#   bash run.sh setup <homa.ko> <ip>      configure this node (run.sh calls it on both nodes, as root)
# Each variant is <work dir>/<variant>/homa.ko; <work dir>/base is a HomaModule checkout that provides
# cloudlab/bin/config and util/cp_node, built with cp_node-mark-base.patch.
set -u
R=${R:-$HOME/ackrepro}                 # work dir (passed through sudo below)
IF=${IF:-$(ip -4 -br a | awk '$3 ~ /^10\.0\.1\./ {print $1; exit}')}   # experiment LAN port
M=4; MB=100                            # node1 gets M alias addresses; SO_MARK MB+i -> alias i

if [ "${1:-}" = setup ]; then
  KO=$2; MYIP=$3
  pkill -x cp_node; sleep 0.5
  rmmod homa 2>/dev/null; insmod "$KO" || { echo "# $(hostname -s): INSMOD FAIL $KO"; exit 1; }
  ip addr flush dev $IF scope global; ip addr add "$MYIP/24" dev $IF; ip link set $IF up
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
  # node1: alias i = 10.0.1.(101+i) and a policy-routing table per fwmark that reaches node0 from it
  if [ "$MYIP" = 10.0.1.2 ]; then
    for i in $(seq 0 $((M-1))); do ip rule del fwmark $((MB+i)) 2>/dev/null; ip route flush table $((MB+i)) 2>/dev/null
      ip addr add 10.0.1.$((101+i))/24 dev $IF
      ip rule add fwmark $((MB+i)) table $((MB+i)); ip route add 10.0.1.1/32 dev $IF src 10.0.1.$((101+i)) table $((MB+i)); done
  fi
  s() { sysctl -n "net.homa.$1" 2>/dev/null; }
  echo "# nic $(hostname -s): if=$IF ko_md5=$(md5sum "$KO"|cut -c1-12) kernel=$(uname -r) fw=$(ethtool -i $IF|awk '/^firmware-version/{print $2}')" \
       "addrs=$(ip -4 -br a show $IF | awk '{print NF-2}') fwmark_rules=$(ip rule | grep -c fwmark)" \
       "rules=$(ethtool -n $IF|grep -c '^Filter:') rss=$(ethtool -x $IF | awk '/^ *[0-9]+:/{for(i=2;i<=NF;i++) q[$i]=1} END{for(k in q) printf "%s,", k}') xps_tx0=$(cat /sys/class/net/$IF/queues/tx-0/xps_cpus)" \
       "coalesce=$(ethtool -c $IF|awk '/Adaptive RX/{a=$3;t=$5}/^rx-usecs:/{u=$2}/^rx-frames:/{f=$2}/^tx-usecs:/{x=$2}END{print "adaptrx"a",adapttx"t",rxus"u",rxfr"f",txus"x}') ntuple=$(ethtool -k $IF|awk '/ntuple/{print $2}')" \
       "rfs=$(sysctl -n net.core.rps_sock_flow_entries) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo) gov=$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor)" \
       "homa:link_mbps=$(s link_mbps),num_priorities=$(s num_priorities),max_nic_est_backlog_usecs=$(s max_nic_est_backlog_usecs),gro_policy=$(s gro_policy),unsched_bytes=$(s unsched_bytes),max_incoming=$(s max_incoming),max_gso_size=$(s max_gso_size)"
  exit 0
fi

# cells k:cmax:pt[:m] = cp_node --ports k --server-ports k --client-max cmax, server --port-threads pt,
# 100-byte RPCs; ":m" = multi-homing (--mark-base MB: client socket i sends from alias i).
# Client on cores 4..3+2k, server on 4..3+k*pt (cores 0-3: NAPI and Homa's SoftIRQ steering).
# NEED_ACK counts (all cores summed) are read while the client runs, from second 3 to second DUR-1;
# the server is restarted before each run, so RPCs left by the previously killed client cannot count.
REPS=${2:-2}; DUR=12; U=$R/base/util; S="ssh -4 -o StrictHostKeyChecking=no node0"
CELLS=${CELLS:-"1:1:1 3:96:2 3:384:2 3:384:2:m"}
na() { awk -v n="packets_$1_NEED_ACK" '$1==n {s+=$2} END {print s+0}' /proc/net/homa_metrics; }
for V in $1; do
  sudo R=$R IF=$IF bash $R/run.sh setup $R/$V/homa.ko 10.0.1.2; $S "sudo R=$R bash $R/run.sh setup $R/$V/homa.ko 10.0.1.1" </dev/null
  for c in $CELLS; do IFS=: read -r k cm pt mode <<<"$c"
    [ "${mode:-}" = m ] && MARK="--mark-base $MB" || MARK=
    cc=$(seq -s, 4 $((3+2*k))); sc=$(seq -s, 4 $((3+k*pt)))
    cli() { sudo timeout $1 taskset -c $cc $U/cp_node client --protocol homa --servers 0 --id 1 --server-ports $k --ports $k --port-receivers 1 --workload 100 --client-max $cm $MARK; }
    srv() { $S "sudo pkill -x cp_node; sleep 0.5; cd $U; nohup sudo taskset -c $sc ./cp_node server --protocol homa --ports $k --port-threads $pt >/tmp/ack-cps.log 2>&1 &" </dev/null; sleep 2; }
    for rep in $(seq 1 $REPS); do
      srv; cli 4 >/dev/null 2>&1; srv                   # warm-up, then a fresh server for the measured run
      cli $DUR >/tmp/ack-cpc.log 2>&1 & pid=$!
      sleep 3; c0=$(na rcvd); s0=$($S "$(declare -f na); na sent" </dev/null); t0=$(date +%s.%N)
      sleep $((DUR - 4)); c1=$(na rcvd); s1=$($S "$(declare -f na); na sent" </dev/null); t1=$(date +%s.%N)
      wait $pid; out=$(grep Kops /tmp/ack-cpc.log | tail -5)
      kops=$(echo "$out" | grep -oE '[0-9.]+ Kops' | awk '{s+=$1;n++} END {if (n) printf "%.1f", s/n}')
      echo "RUN $V $c rep=$rep kops=$kops" \
        "p50=$(echo "$out" | grep -oE 'P50 [0-9.]+' | awk '{s+=$2;n++} END {if (n) printf "%.2f", s/n}')" \
        "p99=$(echo "$out" | grep -oE 'P99 [0-9.]+' | awk '{s+=$2;n++} END {if (n) printf "%.1f", s/n}')" \
        "window_s=$(awk "BEGIN {printf \"%.2f\", $t1 - $t0}") needack_sent_srv=$((s1 - s0)) needack_rcvd_cli=$((c1 - c0))" \
        "needack_per_rpc=$(echo "$s1 $s0 $t1 $t0 ${kops:-0}" | awk '{r=($3-$4)*$5*1000; if (r>0) printf "%.4f", ($1-$2)/r}')"
    done
  done
  $S "sudo pkill -x cp_node" </dev/null
done
