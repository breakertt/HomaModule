#!/bin/bash
# Counter snapshot, one "key value" per line: per-CPU cpuidle usage and time (us) per state, per-CPU busy and
# idle jiffies, NIC drops and per-queue RX packets, NET_RX softirqs per CPU, Homa resent packets.
IF=ens1f1np1
for c in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -d $c/cpuidle ] || continue; n=${c##*cpu}
  for s in $c/cpuidle/state*; do
    m=$(cat $s/name); echo "idle.$n.$m.usage $(cat $s/usage)"; echo "idle.$n.$m.time $(cat $s/time)"
  done
done
awk '/^cpu[0-9]/{n=substr($1,4); print "stat."n".busy", $2+$3+$4+$7+$8+$9; print "stat."n".idle", $5+$6}' /proc/stat
ethtool -S $IF | awk '$1=="rx_out_of_buffer:"{print "nic.rx_out_of_buffer", $2}
  $1 ~ /^rx[0-9]+_packets:$/ {sub(":","",$1); print "nic."$1, $2}'
awk '/NET_RX/{for(i=2;i<=NF;i++) print "softirq.net_rx."(i-2), $i}' /proc/softirqs
awk '/^resent_packets /{s+=$2} END{print "homa.resent_packets", s+0}' /proc/net/homa_metrics
