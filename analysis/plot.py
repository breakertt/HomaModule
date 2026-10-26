# /// script
# dependencies = ["matplotlib"]
# ///
"""Plot one run of the low-load bench: 8 panels, one line per configuration, one marker per load point (means over
the 2 rounds, from sum.load()).

usage: uv run analysis/plot.py data/<stage> [configs...]   (run it in the root of the branch)
       -> figures/<stage>.svg, or figures/<stage>-<configs>.svg for a subset
Each configuration keeps its colour in every version.

Stage 1 (a fixed number of RPCs in flight): panel 1 is the throughput at each load point; panels 2-6 are the P50, P90, P95, P99 and P99.9
RTT against the throughput; panels 7-8 are the C6 entries per second per server RX core and per server app core.
Stage 2 (a fixed rate): the same, with the offered rate on the x axis; panel 1 is the achieved rate as a share of the
offered rate. The x axes of all panels with a load point on them have one evenly spaced tick per load point.
An axis is logarithmic only when its values span more than a factor of 8 (RTT with the S0 line)."""
import os
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FixedLocator, NullFormatter, ScalarFormatter
from sum import CFGS, cm_key, load

LABEL = {
    "S0": "S0: one RX core (core 0), no steering",
    "S1": "S1: one RX queue (core 0) + Homa gen2 SoftIRQ on cores 1-3",
    "P4": "P4: port steering to 4 RX cores, 4 sockets x 3 threads",
    "P4pin": "P4pin: port steering to 4 RX cores, 12 sockets x 1 pinned thread",
    "R": "R: run to completion, 16 sockets x 1 pinned thread, each on its own RX core",
}
LOG_TICKS = [10, 20, 50, 100, 200, 500, 1000]
D, cfgs = sys.argv[1].rstrip("/"), sys.argv[2:] or CFGS
name = os.path.basename(D)
out = f"figures/{name}.svg" if cfgs == CFGS else f"figures/{name}-{'-'.join(cfgs)}.svg"
os.makedirs("figures", exist_ok=True)
cells = load(D)
OPEN = any(cm.startswith("g") for _, cm in cells)
cms = sorted({cm for _, cm in cells}, key=cm_key)
tick_label = lambda cm: f"{int(cm[1:]):,}" if cm.startswith("g") else ("1 (sync)" if cm == "u" else cm)
offered = lambda cm: int(cm[1:]) / 1e3                           # Kops

# (y key, title, x is the load point, y is logarithmic when it spans > 8x)
PANELS = [("ratio" if OPEN else "kops",
           "Achieved rate as a share of the offered rate (%)" if OPEN else "Throughput (Kops)", True),
          ("p50", "P50 RTT (us)", False), ("p90", "P90 RTT (us)", False), ("p95", "P95 RTT (us)", False),
          ("p99", "P99 RTT (us)", False), ("p99.9", "P99.9 RTT (us)", False),
          ("net_c6", "C6 entries per second, per server RX core", False),
          ("app_c6", "C6 entries per second, per server app core", False)]
CAPTION = (("Stage 2: a fixed rate, 120 s per point at 2,000 RPC/s and below, 60 s above. " if OPEN else "Stage 1: a fixed number of RPCs in flight, 60 s per point. ")
           + "One line per configuration, one marker per load point, mean of 2 rounds. "
           + ("The x axis of every panel is the offered rate in RPC/s, one tick per tested rate. "
              if OPEN else
              "The markers follow the load: 1 (synchronous), 4, 8, 16, 32, 64, 128, 256 RPCs in flight. "
              "The x axis is the load point in the first panel and the throughput in the others. ")
           + "A latency axis is logarithmic only when its values span more than a factor of 8.")

fig, axs = plt.subplots(2, 4, figsize=(28, 15), layout="constrained")
fig.suptitle(CAPTION, fontsize=13, wrap=True)
for a, (key, title, by_load) in zip(axs.flat, PANELS):
    for cfg in cfgs:
        keys = sorted((c for f, c in cells if f == cfg), key=cm_key)
        pts = [cells[cfg, cm]["mean"] for cm in keys]
        for p, cm in zip(pts, keys):
            p["ratio"] = p["kops"] / offered(cm) * 100 if OPEN else 0
        x = list(range(len(keys))) if (OPEN or by_load) else [p["kops"] for p in pts]
        a.plot(x, [p[key] for p in pts], marker="o", label=LABEL[cfg], color=f"C{CFGS.index(cfg)}")
    ys = [v for line in a.get_lines() for v in line.get_ydata()]
    log = key.startswith("p") and key != "ratio" and min(ys) > 0 and max(ys) / min(ys) > 8
    a.set_title(title + (", log scale" if log else ""))
    a.grid(alpha=0.3)
    if OPEN or by_load:
        a.set_xticks(range(len(cms)), [tick_label(cm) for cm in cms])
        a.set_xlabel("offered rate (RPC/s)" if OPEN else "RPCs in flight")
    else:
        a.set_xlabel("throughput (Kops)")
    if key == "ratio":
        a.set_ylim(98, 102)
    if log:
        a.set_yscale("log")
        lo, hi = a.get_ylim()
        a.yaxis.set_major_locator(FixedLocator([t for t in LOG_TICKS if lo <= t <= hi]))
        a.yaxis.set_major_formatter(ScalarFormatter())
        a.yaxis.set_minor_formatter(NullFormatter())
    a.legend(loc="upper center", bbox_to_anchor=(0.5, -0.14), fontsize=8, frameon=False)
fig.savefig(out)
print(out)
