#!/usr/bin/env python3
"""Reboot history: one crash.log reboot entry labels one boot only.

Upstream classifies a boot from the newest `|reboot|` line in crash.log and
treats a clock that is behind the line (CFW-3212 can boot with its 2023 default
clock) as "just now", so an old scheduled entry could label a later reboot that
logged nothing. Remember the entry used; a boot with no new entry stays unplanned.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])
p = target / "scripts/usr/lib/qmanager/alert_engine.sh"
text = p.read_text()

old = """    case "$last_epoch" in ''|*[!0-9]*) return 0 ;; esac
"""
new = """    case "$last_epoch" in ''|*[!0-9]*) return 0 ;; esac
    # Casa: each reboot entry labels one boot; a reboot that logged nothing stays unplanned.
    [ "$last_epoch" = "$(cat "${_AE_CRASH_LOG}.used" 2>/dev/null)" ] && return 0
    printf '%s' "$last_epoch" > "${_AE_CRASH_LOG}.used" 2>/dev/null
"""
if text.count(old) != 1:
    raise SystemExit("Reboot-cause patch anchor changed: alert_engine.sh last_epoch check")
p.write_text(text.replace(old, new, 1))
