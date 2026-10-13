#!/usr/bin/env python3
"""Dashboard Carrier Aggregation: fill the primary's signal from the serving cell.

On the RG520N the AT+QCAINFO PCC line is sometimes only "PCC",freq,bw,band,PCI
with no RSRP (Box 4, 5G-SA n71, 2026-10-13), so the PCC tile showed "—" while
the 5G Primary Status card had the value from the serving-cell read. When the
PCC has no RSRP, take RSRP/RSRQ from the serving cell of the same technology,
only when the PCIs agree (never borrow a value across a handoff).
"""
from pathlib import Path
import sys

p = Path(sys.argv[1]) / "components/dashboard/home-component.tsx"
text = p.read_text()
if "Casa: the PCC line can omit RSRP" in text:
    sys.exit(0)
old = '''  const carrierComponents = data?.network?.carrier_components ?? [];
'''
new = '''  // Casa: the PCC line can omit RSRP (short QCAINFO form); fill it from the
  // serving cell of the same technology when the PCIs agree.
  const carrierComponents = (data?.network?.carrier_components ?? []).map((c) => {
    if (c.type !== "PCC" || c.rsrp != null) return c;
    const serving = c.technology === "NR" ? data?.nr : data?.lte;
    if (!serving || serving.rsrp == null) return c;
    if (serving.pci != null && c.pci != null && serving.pci !== c.pci) return c;
    return { ...c, rsrp: serving.rsrp, rsrq: c.rsrq ?? serving.rsrq };
  });
'''
if text.count(old) != 1:
    raise SystemExit("PCC signal patch: carrierComponents anchor changed")
p.write_text(text.replace(old, new, 1))
