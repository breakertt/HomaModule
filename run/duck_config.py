#!/usr/bin/env python3
"""Apply HomaModule's own cloudlab/bin/config tuning on a duck node, calling its functions unchanged.

Two things in config can't work on duck and are bypassed, nothing else:
- get_interfaces() needs a 10.0.1.x vlan and picks the first 's0f0'/'s1f0' port with link,
  which on n15/n16 is the ixgbe control port enp24s0f0 -> pin interface/vlan instead.
- config_homa() calls get_node_type(), which reads CloudLab's /var/emulab (its result is unused).
usage: duck_config.py <path/to/cloudlab/bin/config> <data-iface> <homa.ko> <rps 0/1>
"""
import importlib.machinery, importlib.util, os, sys

path, iface, ko, rps = sys.argv[1:5]
sys.path.insert(0, os.path.dirname(path))          # for config's `from switch import *`
sys.argv = ["config"]                              # config dispatches on argv at import time
loader = importlib.machinery.SourceFileLoader("homa_config", path)
cfg = importlib.util.module_from_spec(importlib.util.spec_from_loader("homa_config", loader))
loader.exec_module(cfg)
cfg.interface = cfg.vlan = iface
cfg.get_node_type = lambda: "duck"

cfg.config_homa(ko)          # rmmod/insmod + num_priorities, link_mbps, 100G unsched/max_incoming/gso
cfg.config_nic()             # coalescing off, tx-usecs 5, ntuple off
cfg.config_power()           # governor performance, C-states left on (keeps turbo headroom)
with open("/sys/devices/system/cpu/intel_pstate/no_turbo", "w") as f:
    f.write("0")             # turbo explicitly on
if rps == "1":
    cfg.config_rps()         # rps_sock_flow_entries, rps_flow_cnt, rps_cpus = all cores
