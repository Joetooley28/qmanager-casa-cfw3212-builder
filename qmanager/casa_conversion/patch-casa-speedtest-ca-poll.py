#!/usr/bin/env python3
"""Poller: keep reading AT+QCAINFO while a speed test runs.

The speed test pauses all poller AT traffic, so the dashboard never saw a
secondary carrier activate under load. Box 2 (2026-10-18) showed N25 going
active for under a second mid-download. During a running speed test the poller
now does one QCAINFO read per cycle; scans and the System Health Check share
the same pause flag and stay fully paused.
"""
from pathlib import Path
import sys

p = Path(sys.argv[1]) / "scripts/usr/bin/qmanager_poller"
text = p.read_text()
if "_casa_speedtest_running" in text:
    sys.exit(0)

helper_old = '''poll_cycle() {
'''
helper_new = '''# Casa: true only when the pause flag belongs to a live speed test (its
# wrapper PID), not a scan or the System Health Check.
_casa_speedtest_running() {
    local pid
    pid=$(cat /tmp/qmanager_speedtest.pid 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    grep -q speedtest "/proc/$pid/cmdline" 2>/dev/null
}

poll_cycle() {
'''
read_old = '''        update_conn_uptime
        write_cache
        return
    fi

    errors=""
    system_state="normal"
'''
read_new = '''        # Casa: keep carrier data live during a speed test; keep the last
        # snapshot if the read fails.
        if [ ! -f "$LONG_FLAG" ] && _casa_speedtest_running; then
            local st_ca
            st_ca=$(qcmd_exec 'AT+QCAINFO')
            if [ $? -eq 0 ] && [ -n "$st_ca" ]; then
                parse_ca_info "$st_ca"
            fi
        fi
        update_conn_uptime
        write_cache
        return
    fi

    errors=""
    system_state="normal"
'''
for label, old in (("poll_cycle", helper_old), ("pause branch", read_old)):
    if text.count(old) != 1:
        raise SystemExit(f"Speed test CA poll patch: {label} anchor changed")
text = text.replace(helper_old, helper_new, 1).replace(read_old, read_new, 1)
p.write_text(text)
print("Speed test CA poll: poller reads QCAINFO during speed tests")
