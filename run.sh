#!/bin/bash
# A-B-A cp_node benchmark of Homa module variants on a two-node pair.
#   bash run.sh "<variant...>" [reps]     run on node1 (client, 10.0.1.2); node0 (10.0.1.1) is the server
#   bash run.sh setup <homa.ko> <ip>      configure this node (run.sh calls it on both nodes, as root)
# Each variant is <work dir>/<variant>/homa.ko; <work dir>/base is a HomaModule checkout that provides
# cloudlab/bin/config and util/cp_node.
set -u
R=${R:-$HOME/peercp}; IF=ens2f0np0   # R: work dir (passed through sudo below)

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
  ethtool -X $IF equal 1
  i=0; for irq in $(awk -v p="$P" '$0 ~ ("mlx5_comp[0-9]+@pci:" p) {sub(":","",$1); print $1}' /proc/interrupts); do
    echo $i > /proc/irq/$irq/smp_affinity_list; i=$((i+1)); done
  q=0; for f in $(ls -v /sys/class/net/$IF/queues/tx-*/xps_cpus); do
    [ $q -lt $(nproc) ] && printf '%x' $((1 << q)) > $f; q=$((q+1)); done
  s() { sysctl -n "net.homa.$1" 2>/dev/null; }
  echo "# nic $(hostname -s): ko_md5=$(md5sum "$KO"|cut -c1-12) kernel=$(uname -r) fw=$(ethtool -i $IF|awk '/^firmware-version/{print $2}')" \
       "rules=$(ethtool -n $IF|grep -c '^Filter:') rss=$(ethtool -x $IF | awk '/^ *[0-9]+:/{for(i=2;i<=NF;i++) q[$i]=1} END{for(k in q) printf "%s,", k}') xps_tx0=$(cat /sys/class/net/$IF/queues/tx-0/xps_cpus)" \
       "coalesce=$(ethtool -c $IF|awk '/Adaptive RX/{a=$3;t=$5}/^rx-usecs:/{u=$2}/^rx-frames:/{f=$2}/^tx-usecs:/{x=$2}END{print "adaptrx"a",adapttx"t",rxus"u",rxfr"f",txus"x}') ntuple=$(ethtool -k $IF|awk '/ntuple/{print $2}')" \
       "rfs=$(sysctl -n net.core.rps_sock_flow_entries) flowcnt_rx0=$(cat /sys/class/net/$IF/queues/rx-0/rps_flow_cnt) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo) gov=$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor)" \
       "homa:num_priorities=$(s num_priorities),link_mbps=$(s link_mbps),max_nic_est_backlog_usecs=$(s max_nic_est_backlog_usecs),gro_policy=$(s gro_policy),gro_busy_usecs=$(s gro_busy_usecs),poll_usecs=$(s poll_usecs),unsched_bytes=$(s unsched_bytes),max_incoming=$(s max_incoming),max_gso_size=$(s max_gso_size)"
  exit 0
fi

# cells: C:k:cmax:pt[:wl[:pr]] = cp_node --ports k --server-ports k --client-max cmax, server
# --port-threads pt, workload wl bytes (100), --port-receivers pr (1); apps on cores 4.. (0-3: NAPI/softirq)
REPS=${2:-3}; DUR=12; U=$R/base/util; C0=4; S="ssh -o StrictHostKeyChecking=no node0"
CP="C:6:192:2 C:6:384:2 C:6:768:2 C:6:384:2:64 C:4:256:3:100:2"
for V in $1; do
  sudo R=$R bash $R/run.sh setup $R/$V/homa.ko 10.0.1.2; $S "sudo R=$R bash $R/run.sh setup $R/$V/homa.ko 10.0.1.1" </dev/null
  for c in $CP; do IFS=: read -r set k cm pt wl pr <<<"$c"; wl=${wl:-100}; pr=${pr:-1}; cc=$(seq -s, $C0 $((C0-1+k*(1+pr)))); sc=$(seq -s, $C0 $((C0-1+k*pt)))
    $S "sudo pkill -x cp_node; sleep 0.3; cd $U; nohup sudo taskset -c $sc ./cp_node server --protocol homa --ports $k --port-threads $pt >/tmp/cps.log 2>&1 &" </dev/null
    sleep 2; cd $U
    for rep in $(seq 1 $REPS); do
      sudo timeout 4 taskset -c $cc ./cp_node client --protocol homa --servers 0 --id 1 --server-ports $k --ports $k --port-receivers $pr --workload $wl --client-max $cm >/dev/null 2>&1
      out=$(sudo timeout $DUR taskset -c $cc ./cp_node client --protocol homa --servers 0 --id 1 --server-ports $k --ports $k --port-receivers $pr --workload $wl --client-max $cm 2>&1 | grep Kops | tail -5)
      echo "CP $V $c rep=$rep kops=$(echo "$out" | grep -oE '[0-9.]+ Kops' | awk '{s+=$1;n++}END{if(n)printf "%.1f",s/n}') p99=$(echo "$out" | grep -oE 'P99 [0-9.]+' | awk '{s+=$2;n++}END{if(n)printf "%.1f",s/n}') p50=$(echo "$out" | grep -oE 'P50 [0-9.]+' | awk '{s+=$2;n++}END{if(n)printf "%.2f",s/n}')"
    done
    $S "sudo pkill -x cp_node" </dev/null
  done
done
