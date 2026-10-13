#!/usr/bin/env python3
"""Ping: probe the last winning host first so jitter keeps its history.

Upstream tries target_host_1 then target_host_2 every cycle and clears the
latency history whenever the winner changes. On T-Mobile, cloudflare.com
resolves to an IPv6 address that answers about one ping in six, so the winner
flipped cloudflare.com <-> google.com every ~13 s (Box 1: 2,252 flips in 7 h)
and Jitter never had enough samples. Trying the last winner first means the
history is cleared only on a real failover. Hostname legs still come before
the literal IP legs, as upstream intends.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])
p = target / "scripts/usr/bin/qmanager_ping"
data = p.read_bytes()

if not data.startswith(b"#!"):
    print("ping sticky-winner patch: qmanager_ping is not the shell daemon; skipped")
    sys.exit(0)

text = data.decode()
if "_casa_ping_order" in text:
    sys.exit(0)

old = '''probe_cycle() {
    for _t in "$PING_TARGET_HOST_1" "$PING_TARGET_HOST_2" \\
              "$PING_TARGET_IP_1" "$PING_TARGET_IP_2"; do
'''
new = '''# Casa: within each pair (hostnames, then IPs) try the last winner first, so a
# host that drops some pings cannot flip the winner (and clear the latency
# history) every few cycles.
_casa_ping_order() {
    _casa_h1="$PING_TARGET_HOST_1"; _casa_h2="$PING_TARGET_HOST_2"
    _casa_i1="$PING_TARGET_IP_1";   _casa_i2="$PING_TARGET_IP_2"
    [ -n "$prev_winner" ] || return 0
    if [ "$prev_winner" = "$PING_TARGET_HOST_2" ] && [ "$prev_winner" != "$PING_TARGET_HOST_1" ]; then
        _casa_h1="$PING_TARGET_HOST_2"; _casa_h2="$PING_TARGET_HOST_1"
    fi
    if [ "$prev_winner" = "$PING_TARGET_IP_2" ] && [ "$prev_winner" != "$PING_TARGET_IP_1" ]; then
        _casa_i1="$PING_TARGET_IP_2"; _casa_i2="$PING_TARGET_IP_1"
    fi
}

probe_cycle() {
    _casa_ping_order
    for _t in "$_casa_h1" "$_casa_h2" \\
              "$_casa_i1" "$_casa_i2"; do
'''
if text.count(old) != 1:
    raise SystemExit("ping sticky-winner patch: probe_cycle anchor changed")
p.write_text(text.replace(old, new, 1))
