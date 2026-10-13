#!/usr/bin/env python3
"""Watchdog ladder: show tiers 2 and 3 as a short "Not available" badge.

v0.1.17's rung grid sizes the control column to its content, so the Casa
notice sentences put there squeezed the rung name to one word per line (Box 1,
2026-10-13). The reason is already in the rung's own text (locale
"consequence"), so the control slot gets a compact badge the size of a pill.
Runs after the converter's tier 2/3 notice patches.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])
p = target / "components/monitoring/watchdog/ladder-card.tsx"
if not p.exists():
    sys.exit(0)
text = p.read_text()

if "casa-rung-unavailable" in text:
    sys.exit(0)
if "Watchdog SIM failover never exists here" not in text or "control = (" not in text:
    # Older (pre-v0.1.17) ladder layout: notices live in a full-width hint row.
    sys.exit(0)

badge = '''      <Badge variant="muted" className="casa-rung-unavailable whitespace-nowrap">
        Not available
      </Badge>
'''
swaps = [
    ('''      <span className={RUNG.COST}>
        Disabled on Casa CFW-3212: the router&apos;s connection manager owns the radio.
      </span>
''', "tier 2"),
    ('''      <span className={RUNG.COST}>
        Disabled on Casa CFW-3212 single-SIM hardware.
      </span>
''', "tier 3"),
]
for old, label in swaps:
    if text.count(old) != 1:
        raise SystemExit(f"Watchdog rung badge patch: {label} notice anchor changed")
    text = text.replace(old, badge, 1)

if "import { Badge }" not in text and "Badge," not in text and "Badge }" not in text:
    raise SystemExit("Watchdog rung badge patch: Badge is not imported in ladder-card.tsx")
p.write_text(text)
