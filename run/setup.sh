#!/bin/bash
# Per-node setup for the low-load steering bench; run as root on n08 (server) or n09 (client).
# usage: setup.sh <S0|S1|P4|P4pin|R|client> <data-ip>   -> prints one "# nic <host> <cfg>: ..." line
#   S0     1 RX queue on core 0, RPS/RFS off (gen2 inert)
#   S1     1 RX queue on core 0, RPS/RFS on, rps_cpus = cores 0-3 (gen2 SoftIRQ on 1-3 with CORES_TO_CHECK 3)
#   P4     16 l4data rules on the destination port's low nibble -> queue k%4, RPS/RFS off
#   P4pin  as P4 (the server threads differ, see run.sh)
#   R      the same rules -> queue k (port 4000+j -> queue j -> core j), RPS/RFS off
#   client the P4 rules (its 4 sockets' responses spread over cores 0-3), the same for every server config
set -u
CFG=$1; MYIP=$2; IF=ens1f1np1; R=/root/lowload
KO_MLX=/root/flex-l4-617/build/drivers/net/ethernet/mellanox/mlx5/core/mlx5_core.ko
H=/root/homa-ae45ada5-ctc3; KO_HOMA=$H/homa.ko
pkill -x cp_node
# PCP off until the next reboot: the services and the timers that restart them.
systemctl stop 'pm*.timer' pmcd pmie pmie_farm pmlogger pmlogger_farm pmproxy 2>/dev/null
# mlx5-flex-l4-steering 0001-0003, one binary for every config (no rules = stock behaviour).
if [ "$(cat /sys/module/mlx5_core/srcversion 2>/dev/null)" != "$(modinfo -F srcversion $KO_MLX)" ]; then
  rmmod mlx5_ib 2>/dev/null; rmmod mlx5_core; insmod $KO_MLX || { echo "# $(hostname -s): MLX5 LOAD FAIL"; exit 1; }
  modprobe mlx5_ib 2>/dev/null
fi
for i in $(seq 1 120); do
  ip link set $IF up 2>/dev/null
  [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null)" = 1 ] && break; sleep 0.25
done
ip addr flush dev $IF scope global; ip addr add $MYIP/24 dev $IF
RPS=0; [ "$CFG" = S1 ] && RPS=1
python3 $R/duck_config.py $H/cloudlab/bin/config $IF $KO_HOMA $RPS >/run/lowload-config.log 2>&1 \
  || { echo "# $(hostname -s): duck_config FAILED"; tail -5 /run/lowload-config.log; exit 1; }
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $f; done
# RSS -> queue 0, comp_i -> core i, XPS txq i <- cpu i.
P=$(basename "$(readlink -f /sys/class/net/$IF/device)")
ethtool -X $IF equal 1
i=0; for irq in $(awk -v p="$P" '$0 ~ ("mlx5_comp[0-9]+@pci:" p) {sub(":","",$1); print $1}' /proc/interrupts); do
  echo $i > /proc/irq/$irq/smp_affinity_list; i=$((i+1)); done
q=0; for f in $(ls -v /sys/class/net/$IF/queues/tx-*/xps_cpus); do
  [ $q -lt $(nproc) ] && printf '%x' $((1 << q)) > $f; q=$((q+1)); done
if [ $RPS = 1 ]; then
  for f in /sys/class/net/$IF/queues/rx-*/rps_cpus; do echo f > $f; done
else
  sysctl -q net.core.rps_sock_flow_entries=0
  for f in /sys/class/net/$IF/queues/rx-*/rps_flow_cnt; do echo 0 > $f; done
  for f in /sys/class/net/$IF/queues/rx-*/rps_cpus; do echo 0 > $f; done
fi
for id in $(ethtool -n $IF 2>/dev/null | awk '/^Filter:/{print $2}'); do ethtool -N $IF delete $id; done
case $CFG in
  P4|P4pin|R|client)
    ethtool -K $IF ntuple on
    for k in $(seq 0 15); do
      a=$((k % 4)); [ $CFG = R ] && a=$k
      ethtool -N $IF flow-type ip4 l4proto 146 l4data $k m 0xfffffff0 action $a >/dev/null || echo "# RULE FAIL $k"
    done;;
esac
s() { sysctl -n "net.homa.$1" 2>/dev/null; }
echo "# nic $(hostname -s) $CFG: homa_srcver=$(cat /sys/module/homa/srcversion) mlx5_srcver=$(cat /sys/module/mlx5_core/srcversion) kernel=$(uname -r)" \
     "fw=$(ethtool -i $IF|awk '/^firmware-version/{print $2}') ip=$MYIP" \
     "rules=$(ethtool -n $IF | awk '/^Filter:/{n++} /Action: Direct to queue/{q[$NF]++} END{printf "%d", n; for (k in q) printf ",q%s:%d", k, q[k]}')" \
     "rss=$(ethtool -x $IF | awk '/^ *[0-9]+:/{for(i=2;i<=NF;i++) q[$i]=1} END{for(k in q) printf "%s,", k}') ntuple=$(ethtool -k $IF|awk '/ntuple/{print $2}')" \
     "irq_cores=$(awk -v p="$P" '$0 ~ ("mlx5_comp[0-9]+@pci:" p) {sub(":","",$1); print $1}' /proc/interrupts | while read q; do cat /proc/irq/$q/smp_affinity_list; done | sort -n | uniq | tr "\n" ",")" \
     "xps_tx0=$(cat /sys/class/net/$IF/queues/tx-0/xps_cpus) rps_rx0=$(cat /sys/class/net/$IF/queues/rx-0/rps_cpus) rfs=$(sysctl -n net.core.rps_sock_flow_entries) flowcnt_rx0=$(cat /sys/class/net/$IF/queues/rx-0/rps_flow_cnt)" \
     "coalesce=$(ethtool -c $IF|awk '/Adaptive RX/{a=$3;t=$5}/^rx-usecs:/{u=$2}/^rx-frames:/{f=$2}/^tx-usecs:/{x=$2}END{print "adaptrx"a",adapttx"t",rxus"u",rxfr"f",txus"x}')" \
     "gov=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | sort | uniq -c | awk '{printf "%s:%s", $2, $1}') no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)" \
     "cstates_on=$(for d in /sys/devices/system/cpu/cpu1/cpuidle/state*; do [ "$(cat $d/disable)" = 0 ] && printf '%s,' "$(cat $d/name)"; done)" \
     "pcp=$(systemctl is-active pmcd pmlogger pmie | sort | uniq -c | awk '{printf "%s:%s,", $2, $1}')" \
     "homa:num_priorities=$(s num_priorities),link_mbps=$(s link_mbps),max_nic_est_backlog_usecs=$(s max_nic_est_backlog_usecs),gro_policy=$(s gro_policy),gro_busy_usecs=$(s gro_busy_usecs),poll_usecs=$(s poll_usecs),unsched_bytes=$(s unsched_bytes),max_incoming=$(s max_incoming),max_gso_size=$(s max_gso_size)"
