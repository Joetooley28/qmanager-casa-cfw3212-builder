#!/usr/bin/env python3
"""Network Events: log a secondary-carrier band change even when the count stays.

Upstream reports carrier aggregation only when the SCC count changes (or the
same band changes PCI), so n71+n66 -> n71+n25 was silent. This adds a settled
SCC band-set check per technology that logs "NR carriers changed (+N25, -N66)"
when the bands change at the same count. Count changes and CA on/off stay with
upstream's _ev_ca_check, so nothing is logged twice.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])
p = target / "scripts/usr/lib/qmanager/events.sh"
text = p.read_text()

if "_casa_scc_set_check" in text:
    sys.exit(0)

helpers = r'''# Casa: secondary-carrier band sets, "N25+N66" (sorted), "none" when no SCC,
# blank when QCAINFO gave no reading. In 5G-NSA the first NR SCC is the NR leg
# (as in parse_at.sh), so it is left out. jq runs only when the list changes.
_casa_scc_src=""
_casa_scc_lte=""
_casa_scc_nr=""
_casa_scc_sets() {
    [ "$t2_carrier_components" = "$_casa_scc_src" ] && return 0
    _casa_scc_src="$t2_carrier_components"
    _casa_scc_lte=""
    _casa_scc_nr=""
    [ -z "$t2_carrier_components" ] || [ "$t2_carrier_components" = "[]" ] && return 0
    local _nsa=0 _r
    [ "$network_type" = "5G-NSA" ] && _nsa=1
    _r=$(printf '%s' "$t2_carrier_components" | jq -r --arg nsa "$_nsa" '
        def scc($t): [.[] | select(.type == "SCC" and .technology == $t) | .band];
        def fmt: sort | if length > 0 then join("+") else "none" end;
        (scc("LTE") | fmt) + "|"
        + (scc("NR") | (if $nsa == "1" then .[1:] else . end) | fmt)' 2>/dev/null)
    case "$_r" in *"|"*) ;; *) return 0 ;; esac
    _casa_scc_lte="${_r%%|*}"
    _casa_scc_nr="${_r#*|}"
}

# Casa: settle the SCC band set (channel $1) and log a same-count band change.
# $3 is the band set, $4 the _ev_ca_check channel whose churn report wins.
_casa_scc_set_check() {
    local _ch="$1" _tech="$2" _obs="$3" _cach="$4" _rc _nf _nt _r _add _rem _detail _flapr
    _ev_settle "$_ch" "$_obs"; _rc=$?
    if [ "$_rc" -eq 0 ]; then
        # CA on/off and count changes are logged by _ev_ca_check.
        [ "$_EV_SETTLED_FROM" = "none" ] && return 0
        [ "$_EV_SETTLED_TO" = "none" ] && return 0
        _nf=$(printf '%s\n' "$_EV_SETTLED_FROM" | tr '+' '\n' | grep -c .)
        _nt=$(printf '%s\n' "$_EV_SETTLED_TO" | tr '+' '\n' | grep -c .)
        [ "$_nf" -eq "$_nt" ] || return 0
        _r=$(jq -rn --arg f "$_EV_SETTLED_FROM" --arg t "$_EV_SETTLED_TO" '
            ($f | split("+")) as $F | ($t | split("+")) as $T
            | (($T - $F) | join(", ")) + "|" + (($F - $T) | join(", "))' 2>/dev/null)
        _add="${_r%%|*}"
        _rem="${_r#*|}"
        case "$_r" in *"|"*) ;; *) _add=""; _rem="" ;; esac
        if [ -n "$_add" ] || [ -n "$_rem" ]; then
            _detail="${_add:++$_add}"
            [ -n "$_add" ] && [ -n "$_rem" ] && _detail="$_detail, "
            _detail="$_detail${_rem:+-$_rem}"
        else
            _detail="now $(printf '%s' "$_EV_SETTLED_TO" | sed 's/+/ + /g')"
        fi
        append_event "ca_change" "$_tech carriers changed ($_detail)" "info"
    elif [ "$_rc" -eq 2 ]; then
        # A count churn episode already reported this instability.
        eval "_flapr=\${_ev_flapr_${_cach}:-0}"
        [ "$_flapr" -eq 0 ] && append_event "ca_change" "$_tech carrier bands churning" "warning"
    fi
}

# ---------------------------------------------------------------------------
# SCC PCI change detection via temp JSON'''

anchor = "# ---------------------------------------------------------------------------\n# SCC PCI change detection via temp JSON"
if text.count(anchor) != 1:
    raise SystemExit("SCC band-change patch: detect_scc_pci_changes anchor changed")
text = text.replace(anchor, helpers, 1)

old = '''    _ev_ca_check lte_ca LTE "$t2_ca_count"
    _ev_ca_check nr_ca NR "$t2_nr_ca_count"
'''
new = '''    _ev_ca_check lte_ca LTE "$t2_ca_count"
    _ev_ca_check nr_ca NR "$t2_nr_ca_count"

    # Casa: SCC band swaps at the same count (e.g. N66 -> N25).
    _casa_scc_sets
    _casa_scc_set_check lte_sccset LTE "$_casa_scc_lte" lte_ca
    _casa_scc_set_check nr_sccset NR "$_casa_scc_nr" nr_ca
'''
if text.count(old) != 1:
    raise SystemExit("SCC band-change patch: _ev_ca_check call anchor changed")
text = text.replace(old, new, 1)
p.write_text(text)
