#!/usr/bin/env python3
"""Print the README tables of one run as Markdown, read from the raw files (means over the 2 rounds).

usage: python3 analysis/tables.py data/stage1     fixed number of RPCs in flight: throughput, P50, P99
       python3 analysis/tables.py data/stage2     fixed rate: P50, P99, C6 of the RX cores and of the app cores
Every other number is in the sum files (python3 analysis/sum.py data/<stage>).
"""
import re
import sys
from sum import CFGS, cm_key, delta, load

D = sys.argv[1].rstrip("/")
cells = load(D)
RATE = any(cm.startswith("g") for _, cm in cells)
cms = sorted({cm for _, cm in cells}, key=cm_key)


def label(cm):
    if cm == "u":
        return "1 (synchronous)"
    return f"{int(cm[1:]):,} RPC/s" if cm.startswith("g") else cm


def table(title, key, fmt):
    print(f"**{title}**\n")
    print("| " + ("offered rate" if RATE else "RPCs in flight") + " | " + " | ".join(CFGS) + " |")
    print("|---|" + "---|" * len(CFGS))
    for cm in cms:
        print(f"| {label(cm)} | " + " | ".join(fmt % cells[c, cm]["mean"][key] if (c, cm) in cells else "-" for c in CFGS) + " |")
    print()


if RATE:
    for t in (("P50 RTT (us)", "p50", "%.2f"), ("P99 RTT (us)", "p99", "%.1f"),
              ("Time the server RX cores spend in C6 (% of the window. S0: core 0. R: all 16 cores. Others: cores 0-3)",
               "net_c6res", "%.0f"),
              ("C6 entries per second per server app core (R: all 16 cores. Others: cores 4-15)", "app_c6", "%.0f")):
        table(*t)
else:
    for t in (("Throughput (Kops)", "kops", "%.1f"), ("P50 RTT (us)", "p50", "%.2f"), ("P99 RTT (us)", "p99", "%.1f")):
        table(*t)

# Run totals, from every cell of every round.
rounds = [r for v in cells.values() for r in v["rounds"]]
spreads = [(max(r["kops"] for r in v["rounds"]) - min(r["kops"] for r in v["rounds"])) / v["mean"]["kops"] * 100
           for v in cells.values() if len(v["rounds"]) > 1]
print(f"{len(rounds)} cells in {len(cells)} points. The largest round-to-round Kops spread is {max(spreads):.1f} %. "
      f"NIC drops (`rx_out_of_buffer`, both hosts): {sum(r['drops'] for r in rounds)}. "
      f"Homa `resent_packets`: {sum(r['resent'] for r in rounds)}.\n")
if RATE:
    share = [r["kops"] / (int(cm[1:]) / 1e3) * 100 for (c, cm), v in cells.items() for r in v["rounds"]]
    print(f"The achieved rate is {min(share):.1f} to {max(share):.1f} % of the offered rate.\n")
else:   # the client cores at the highest load, round 1
    b = []
    for c in CFGS:
        d = delta(D, f"r1-{c}-cm{cms[-1]}", "client")
        b.append(f"{c} {sum(d[f'stat.{i}.busy'] for i in range(4, 16)) / sum(d[f'stat.{i}.busy'] + d[f'stat.{i}.idle'] for i in range(4, 16)) * 100:.0f} %")
    print(f"Client cores 4-15 busy at {label(cms[-1])} in flight (round 1): " + ", ".join(b) + ".\n")

# Steering check: the RX queues of the server that received packets, in the busiest cell of round 1.
last = cms[-1]
print(f"**Steering check** (server, round 1, {label(last)})\n")
print("| configuration | RX queues used | packets per used queue, min - max (millions) |")
print("|---|---|---|")
for c in CFGS:
    q = [v for k, v in delta(D, f"r1-{c}-cm{last}", "server").items() if re.fullmatch(r"nic\.rx\d+_packets", k) and v > 1000]
    print(f"| {c} | {len(q)} | {min(q) / 1e6:.2f} - {max(q) / 1e6:.2f} |")
