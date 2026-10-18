#!/usr/bin/env python3
"""Tower and Frequency Locking: keep text inside its tile at mid widths.

Owner screenshots (2026-10-18, ~1280 px with the sidebar open): the Frequency
Locking carrier tile pushed "-114 dBm" past its edge, the NR add row squeezed
the NR-ARFCN input to one letter, and the Tower Locking spacing select clipped
its "Subcarrier spacing" placeholder. Reproduced in a local preview.
"""
import json
from pathlib import Path
import sys

target = Path(sys.argv[1])
pending = {}


def swap(rel, old, new):
    text = pending.get(rel, (target / rel).read_text())
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"Lock layout patch: anchor changed in {rel}: {old[:70]!r}")
    pending[rel] = text.replace(old, new, 1)


hero = "components/cellular/frequency-locking/freq-lock-hero.tsx"
# The RSRP wraps under the channel instead of out of the tile.
swap(hero, '''      <div className="flex items-baseline gap-2">
        <span className={CARRIER_TILE.VALUE_LABEL}>''',
     '''      <div className="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <span className={`${CARRIER_TILE.VALUE_LABEL} whitespace-nowrap`}>''')
swap(hero, 'className="text-on-surface-variant ms-auto text-[13px] font-semibold tabular-nums"',
     'className="text-on-surface-variant ms-auto text-[13px] font-semibold whitespace-nowrap tabular-nums"')

nr = "components/cellular/frequency-locking/nr-freq-card.tsx"
# A floor width makes the add row wrap before the channel input collapses.
swap(nr, '''                id="nr-freq-add-arfcn"
                type="text"
                inputMode="numeric"
                autoComplete="off"
                className={SLOT_INPUT}''',
     '''                id="nr-freq-add-arfcn"
                type="text"
                inputMode="numeric"
                autoComplete="off"
                className={`${SLOT_INPUT} min-w-28`}''')

tower = "components/cellular/tower-locking/nr-sa-tower-card.tsx"
# The tile label already says "Subcarrier spacing"; the placeholder stays short.
swap(tower, '<SelectValue placeholder={t("tower_locking.fields.scs")} />',
     '<SelectValue placeholder={t("tower_locking.fields.scs_placeholder")} />')

loc = "public/locales/en/cellular.json"
data = json.loads((target / loc).read_text())
if data["tower_locking"]["fields"].get("scs_placeholder") != "Spacing":
    data["tower_locking"]["fields"]["scs_placeholder"] = "Spacing"
    pending[loc] = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

for rel, text in pending.items():
    (target / rel).write_text(text)
print("Lock layout: Frequency/Tower Locking text kept inside tiles")
