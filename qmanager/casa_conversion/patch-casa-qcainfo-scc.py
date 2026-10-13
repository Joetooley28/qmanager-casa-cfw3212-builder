#!/usr/bin/env python3
"""QCAINFO: read the PCI of a short NR SCC line that carries the SCell state.

The RG520N can report an NR SCC as "SCC",freq,bw,"NR5G BAND n",<state>,<PCI>,...
with fewer than 9 fields. Upstream treats every short NR line as
type,freq,bw,band,PCI,..., so the state (1 = configured, 2 = active) became the
PCI and Network Events logged fake "NR SCC handoff (PCI 1 -> 2)" pairs.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])
p = target / "scripts/usr/lib/qmanager/parse_at.sh"
text = p.read_text()

if "_casa_scc_state_form" in text:
    sys.exit(0)

helper = '''# Casa: 0 when $1 is an SCell state (0/1/2) and $2 a valid PCI (0-1007).
_casa_scc_state_form() {
    case "$1" in 0|1|2) ;; *) return 1 ;; esac
    case "$2" in ''|*[!0-9]*) return 1 ;; esac
    [ "$2" -le 1007 ]
}

parse_ca_info() {'''
if text.count("parse_ca_info() {") != 1:
    raise SystemExit("QCAINFO SCC patch: parse_ca_info anchor changed")
text = text.replace("parse_ca_info() {", helper, 1)

old = """                else
                    # Short form (PCC or old SCC):
                    # type(1),freq(2),bw(3),band(4),PCI(5)[,RSRP(6),RSRQ(7)[,SNR(8)]]
"""
new = """                elif [ "$1" = "SCC" ] && [ "$nfields" -ge 6 ] && _casa_scc_state_form "$5" "$6"; then
                    # Casa: short SCC with the SCell state before the PCI:
                    # type(1),freq(2),bw(3),band(4),state(5),PCI(6)[,RSRP(7),RSRQ(8)]
                    cc_pci="$6"
                    case "${7:-}" in -[0-9]*) cc_rsrp="$7" ;; esac
                    case "${8:-}" in -[0-9]*) cc_rsrq="$8" ;; esac
                else
                    # Short form (PCC or old SCC):
                    # type(1),freq(2),bw(3),band(4),PCI(5)[,RSRP(6),RSRQ(7)[,SNR(8)]]
"""
if text.count(old) != 1:
    raise SystemExit("QCAINFO SCC patch: NR short-form anchor changed")
text = text.replace(old, new, 1)
p.write_text(text)
