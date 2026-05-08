#!/usr/bin/env bash
# handoffs per RPC (issue #77 probe). small-message bench: should be ~1.0
awk '
    /^handoff_count[[:space:]]/      { h += $2 }
    /^requests_received[[:space:]]/  { r += $2 }
    END {
        if (r == 0) { print "no traffic"; exit }
        printf "handoffs=%d rpcs=%d ratio=%.3f\n", h, r, h/r
    }
' /proc/net/homa_metrics
