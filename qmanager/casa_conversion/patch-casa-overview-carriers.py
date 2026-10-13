#!/usr/bin/env python3
"""Public Overview: active carriers only, and the primary's signal from the serving cell.

The pre-login Overview (public/overview.sh) copied carrier_components straight
through, so it summed a standby (SCell state 1) n41 into BANDWIDTH (120 MHz on
n71 alone) and showed "—" for an n71 PCC whose QCAINFO line has no RSRP (Box 4,
2026-10-13). Standby SCCs are left out, and a PCC with no RSRP takes
RSRP/RSRQ/SINR from the serving cell of the same technology when the PCIs agree,
matching the dashboard (patch-casa-ca-standby.py, patch-casa-ca-pcc-signal.py).
"""
from pathlib import Path
import sys

p = Path(sys.argv[1]) / "scripts/www/cgi-bin/quecmanager/public/overview.sh"
text = p.read_text()
if "Casa: active carriers only" in text:
    sys.exit(0)
old = '''    bands: [(.network.carrier_components // [])[] | select(.band != null and .band != "") | {band: .band, bandwidth_mhz: (.bandwidth_mhz // 0), pci: .pci, rsrp: .rsrp, rsrq: .rsrq, sinr: .sinr}],
'''
new = '''    # Casa: active carriers only (no standby SCCs); PCC signal from the serving cell when QCAINFO omits it.
    bands: ($s | [(.network.carrier_components // [])[] | select(.band != null and .band != "") | select(.type == "PCC" or ((.state // 2) != 1)) | (if .type == "PCC" and .rsrp == null then ((if .technology == "NR" then $s.nr else $s.lte end) // {}) as $sv | (if $sv.rsrp != null and ($sv.pci == null or .pci == null or $sv.pci == .pci) then .rsrp = $sv.rsrp | .rsrq = (.rsrq // $sv.rsrq) | .sinr = (.sinr // $sv.sinr) else . end) else . end) | {band: .band, bandwidth_mhz: (.bandwidth_mhz // 0), pci: .pci, rsrp: .rsrp, rsrq: .rsrq, sinr: .sinr}]),
'''
if text.count(old) != 1:
    raise SystemExit("Overview carriers patch: bands anchor changed")
text = text.replace(old, new, 1)
# $s (the whole status file) is bound at the top of the projection.
old2 = "jq '{\n  state: \"ok\",\n"
if text.count(old2) != 1:
    raise SystemExit("Overview carriers patch: projection anchor changed")
text = text.replace(old2, "jq '. as $s | {\n  state: \"ok\",\n", 1)
p.write_text(text)
