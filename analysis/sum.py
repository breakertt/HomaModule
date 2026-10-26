#!/usr/bin/env python3
"""Summarise a low-load steering run: one row per (config, RPCs in flight), means over the rounds.

usage: python3 analysis/sum.py data/<stage> [configs...]   (tables.py and plot.py import load())
Reads <cell>.hist / .window / .{client,server}.{before,after} for cells r<round>-<config>-cm<cm>.
Columns: Kops; in = Kops x mean RTT (RPCs actually in flight); P50/P90/P95/P99/P99.9 (us); spread = round-to-round
Kops range over the mean; server busy % and C6 entries per
second per core and C6 residency %, for the RX cores (S0: 0; S1, P4, P4pin: 0-3; R: 0-15) and the app cores
(4-15; R: 0-15); NIC drops and Homa resends (sum, both hosts). Server rates use each core's own
busy + idle jiffies as its window, so they do not depend on when the snapshots were taken.
"""
import collections, glob, os, re, sys

CFGS = ["S0", "S1", "P4", "P4pin", "R"]
def cm_key(cm):
    """Order of the load points: u (1 in flight), the fixed in-flight counts, then g<rate> by rate."""
    return (0, 1) if cm == "u" else (1, int(cm[1:])) if cm.startswith("g") else (0, int(cm))
RX = {"S0": range(0, 1), "R": range(0, 16)}         # others: 0-3
APP = {"R": range(0, 16)}                             # others: 4-15


def snap(path):
    with open(path) as f:
        return {k: int(v) for k, v in (l.split() for l in f if l.strip())}


def delta(D, cell, host):
    a, b = snap(f"{D}/{cell}.{host}.before"), snap(f"{D}/{cell}.{host}.after")
    return {k: b[k] - a.get(k, 0) for k in b}


def pct(hist, n, p):
    s = 0
    for v, c in hist:
        s += c
        if s >= n * p / 100:
            return v


def cell(D, c):
    with open(f"{D}/{c}.window") as f:
        t0, t1 = (float(l) for l in f)
    with open(f"{D}/{c}.hist") as f:
        hist = [(float(v), int(k)) for v, k in (l.split() for l in f)]
    n = sum(k for _, k in hist)
    if n == 0:
        return None
    mean = sum(v * k for v, k in hist) / n
    srv, cli = delta(D, c, "server"), delta(D, c, "client")
    dur = t1 - t0
    cfg = c.split("-")[1]
    sec = lambda i: (srv[f"stat.{i}.busy"] + srv[f"stat.{i}.idle"]) / 100      # jiffies at 100 Hz
    avg = lambda cores, f: sum(f(i) for i in cores) / len(cores)
    busy = lambda cores: avg(cores, lambda i: srv[f"stat.{i}.busy"] / 100 / sec(i))
    c6n = lambda cores: avg(cores, lambda i: srv.get(f"idle.{i}.C6.usage", 0) / sec(i))
    c6t = lambda cores: avg(cores, lambda i: srv.get(f"idle.{i}.C6.time", 0) / 1e6 / sec(i))
    rx, app = RX.get(cfg, range(0, 4)), APP.get(cfg, range(4, 16))
    return dict(kops=n / dur / 1e3, inflight=n / dur * mean / 1e6,
                **{f"p{p}": pct(hist, n, p) for p in (50, 90, 95, 99, 99.9)},
                net_busy=busy(rx) * 100, app_busy=busy(app) * 100,
                net_c6=c6n(rx), app_c6=c6n(app), net_c6res=c6t(rx) * 100, app_c6res=c6t(app) * 100,
                drops=srv.get("nic.rx_out_of_buffer", 0) + cli.get("nic.rx_out_of_buffer", 0),
                resent=srv.get("homa.resent_packets", 0) + cli.get("homa.resent_packets", 0))


def load(D):
    """{(config, cm): [per-round dicts]} for every cell in run dir D; mean over the rounds in 'mean'."""
    cells = collections.defaultdict(list)
    for h in sorted(glob.glob(f"{D}/r*-cm*.hist")):
        m = re.match(r"r(\d+)-(\w+)-cm(\w+)$", os.path.basename(h)[:-5])
        r = cell(D, m.group(0))
        if r:
            cells[m.group(2), m.group(3)].append(r)
    return {k: dict(rounds=rs, mean={f: sum(r[f] for r in rs) / len(rs) for f in rs[0]}) for k, rs in cells.items()}


def main():
    D, cfgs = sys.argv[1], sys.argv[2:] or CFGS
    cells = load(D)

    hdr = ("cfg", "cm", "kops", "in", "P50", "P90", "P95", "P99", "P99.9", "spread", "busyRX", "busyApp",
           "C6/sRX", "C6/sApp", "C6%RX", "C6%App", "drops", "resent", "n")
    print("%-6s %4s %7s %5s %7s %7s %7s %7s %7s %6s %8s %8s %8s %8s %6s %7s %7s %7s %2s" % hdr)
    for cfg in cfgs:
        for cm in sorted((c for f, c in cells if f == cfg), key=cm_key):
            rs, m = cells[cfg, cm]["rounds"], cells[cfg, cm]["mean"]
            ks = [r["kops"] for r in rs]
            print("%-6s %4s %7.1f %5.1f %7.2f %7.2f %7.2f %7.2f %7.2f %5.1f%% %7.0f%% %7.0f%% %8.0f %8.0f %5.1f%% %6.1f%% %7d %7d %2d" % (
                cfg, cm, m["kops"], m["inflight"], m["p50"], m["p90"], m["p95"], m["p99"], m["p99.9"],
                (max(ks) - min(ks)) / m["kops"] * 100, m["net_busy"], m["app_busy"],
                m["net_c6"], m["app_c6"], m["net_c6res"], m["app_c6res"],
                sum(r["drops"] for r in rs), sum(r["resent"] for r in rs), len(rs)))


if __name__ == "__main__":
    main()
