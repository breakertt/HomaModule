#!/usr/bin/env bash
# Issue #77 reproduce + fix bench on a CloudLab xl170 pair.
# Reboots both nodes, then for {baseline, fix} branches x {unloaded, loaded w1..w5}
# runs 5 trials each with full rmmod+insmod+cloudlab/bin/config every trial.
#
# Assumes:
#   - Linux 6.17.8 (mainline) on both nodes (the upstream README's known-good kernel).
#   - HomaModule lives at ~/HomaModule on both nodes (will clone if missing).
#   - The bench-side NIC is on a 10.10.1.X subnet (current CloudLab small-lan profile).

set -uo pipefail
# (no -e: `timeout` returns 124 when the wrapped command runs the full duration,
# which is expected for cp_node which never self-terminates.)

# === EDIT THESE for your experiment ============================
SERVER=user@nodeA.utah.cloudlab.us       # node0 (server side)
CLIENT=user@nodeB.utah.cloudlab.us       # node1 (client side)
REPO_URL=https://github.com/breakertt/HomaModule.git
# ===============================================================

SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
ssh_s() { ssh "${SSH_OPTS[@]}" "$SERVER" "$@"; }
ssh_c() { ssh "${SSH_OPTS[@]}" "$CLIENT" "$@"; }
ssh_sf() { ssh -f -n "${SSH_OPTS[@]}" "$SERVER" "$@"; }

reboot_both() {
    echo "=== Rebooting both nodes ==="
    ssh_s 'sudo reboot' || true
    ssh_c 'sudo reboot' || true
    sleep 20
    echo "Waiting for both back..."
    for i in $(seq 1 60); do
        if timeout 5 ssh "${SSH_OPTS[@]}" "$SERVER" 'true' 2>/dev/null \
        && timeout 5 ssh "${SSH_OPTS[@]}" "$CLIENT" 'true' 2>/dev/null; then
            echo "Both up after $((i*5))s"
            return 0
        fi
        sleep 5
    done
    echo "Timeout waiting for nodes" >&2
    exit 1
}

setup_repo_on() {
    local host=$1 branch=$2 overlay=$3
    ssh "${SSH_OPTS[@]}" "$host" bash -s <<EOF
set -e
cd ~
[ -d HomaModule ] || git clone $REPO_URL
cd HomaModule
git fetch origin
git checkout -f origin/$branch
git branch -f $branch origin/$branch
git checkout $branch
git reset --hard origin/$branch
# Probe overlay (fix branch only -- pulls metric counters from reproduce branch)
if [ "$overlay" = "yes" ]; then
    git diff origin/main..origin/fix-handoff-twice-reproduce \
        -- homa_metrics.h homa_metrics.c homa_incoming.c | git apply
fi
# cloudlab/bin/config detects the experiment VLAN by looking for inet 10.0.1.X.
# CloudLab's current small-lan profile uses 10.10.1.X -- patch the regex.
sed -i 's|inet 10\\\\.0\\\\.1\\\\.|inet 10\\\\.10\\\\.1\\\\.|' cloudlab/bin/config
sudo apt-get install -y build-essential libssl-dev g++ >/dev/null 2>&1 || true
make -j\$(nproc) all >/dev/null
cd util && make cp_node >/dev/null
echo "[$host] \$(git log --oneline -1)"
EOF
}

reload_module() {
    # Full module reload + every host tuning (NIC coalescing, CPU governor, RPS)
    # via cloudlab/bin/config. NIC/CPU/RPS settings don't persist across reboots
    # so we re-apply them every trial, clean per-trial state.
    ssh_s 'pkill -9 cp_node 2>/dev/null; sleep 1; sudo python3 ~/HomaModule/cloudlab/bin/config homa /users/'"${SERVER%@*}"'/HomaModule/homa.ko nic power rps' >/dev/null 2>&1
    ssh_c 'pkill -9 cp_node 2>/dev/null; sleep 1; sudo python3 ~/HomaModule/cloudlab/bin/config homa /users/'"${CLIENT%@*}"'/HomaModule/homa.ko nic power rps' >/dev/null 2>&1
}

run_trial() {
    # Args: label, mode (unloaded|loaded), [workload-for-loaded]
    local label=$1 mode=$2 wl=${3:-w3} cli duration samples srv_args tag
    if [ "$mode" = "unloaded" ]; then
        # cp_basic shape: 1 port + 1 thread on each side, 1 outstanding, single packet
        cli='--gbps 0 --client-max 1 --ports 1 --port-receivers 0 --workload 64'
        srv_args='--ports 1 --port-threads 1'
        duration=12
        samples='4,9p'
    else
        # cperf.py defaults_25g: client ports=3 port-receivers=3, server ports=3 port-threads=3
        cli="--gbps 0 --client-max 200 --ports 3 --port-receivers 3 --workload $wl"
        srv_args='--ports 3 --port-threads 3'
        duration=32
        samples='4,28p'
    fi
    tag="$mode"
    [ "$mode" = "loaded" ] && tag="loaded-$wl"
    for t in 1 2 3 4 5; do
        reload_module
        ssh_sf "~/HomaModule/util/cp_node server --protocol homa $srv_args </dev/null >/tmp/cps.log 2>&1 & disown; sleep 0.3"
        sleep 2
        out=$(ssh_c "cd ~/HomaModule/util && timeout $duration ./cp_node client --protocol homa --first-server 0 --server-nodes 1 --id 1 $cli" 2>&1 \
            | grep 'Kops/sec' | sed -n "$samples" \
            | awk '
                /Kops\/sec/ {
                    for (i=1; i<=NF; i++) {
                        if ($i == "clients:") k=$(i+1)
                        if ($i == "P50") p50=$(i+1)
                        if ($i == "P99") p99=$(i+1)
                    }
                    kops_sum+=k; p50_sum+=p50; p99_sum+=p99; n++
                }
                END {
                    if (n==0) { print "0,0,0,0"; exit }
                    printf "%.2f,%.3f,%.3f,%d", kops_sum/n, p50_sum/n, p99_sum/n, n
                }')
        ratio=$(ssh_s 'awk "
            /^handoff_count[[:space:]]/      { h += \$2 }
            /^requests_received[[:space:]]/  { r += \$2 }
            END { if (r > 0) printf \"%.3f\n\", h/r; else print \"-\" }
        " /proc/net/homa_metrics')
        echo "[$label-$tag T$t] kops,p50,p99,n=$out  ratio=$ratio"
        ssh_s 'pkill -9 cp_node 2>/dev/null'
    done
}

# === main ===
# Skip reboot if SKIP_REBOOT=1 (useful when re-running after a script bug).
if [ "${SKIP_REBOOT:-0}" != "1" ]; then
    reboot_both
fi

echo ""
echo "=== Setup baseline (probe-only branch) on both nodes ==="
setup_repo_on "$SERVER" fix-handoff-twice-reproduce no
setup_repo_on "$CLIENT" fix-handoff-twice-reproduce no

echo ""
echo "============ BASELINE ============"
run_trial baseline unloaded
for wl in w1 w2 w3 w4 w5; do
    run_trial baseline loaded "$wl"
done

echo ""
echo "=== Setup fix branch (with probe overlay) on both nodes ==="
setup_repo_on "$SERVER" fix-handoff-twice yes
setup_repo_on "$CLIENT" fix-handoff-twice yes

echo ""
echo "============ FIX ============"
run_trial fix unloaded
for wl in w1 w2 w3 w4 w5; do
    run_trial fix loaded "$wl"
done

echo ""
echo "=== DONE ==="
