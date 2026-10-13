#!/usr/bin/env python3
"""Carrier aggregation: standby SCCs, prompt release, active-only bandwidth.

Box 1 and Box 4 (2026-10-13, cell edge) showed AT+QCAINFO listing secondary
carriers in SCell state 1 (configured, not carrying data) with filler signal
values (-156 dBm / -43 dB), and the standby n41 swapping cells every few
seconds. Upstream counted every listed SCC as aggregated and held a vanished
carrier "live" for 6 s, so the dashboard showed 210 MHz / NR-CA active while
the box was really on n71 alone.

- parse_at.sh: each carrier gets "state" (SCC field 5: 0/1/2; null otherwise).
- events.sh: SCC handoff events skip standby (state 1) carriers.
- lib/carrier-aggregation.ts: standby SCCs are not active (MHz figure, NR/LTE-CA
  badge); a carrier missing from a NON-empty snapshot is released at once (the
  6 s grace stays only for an empty snapshot = failed AT read).
- Dashboard card: standby tiles in the neutral tone with "Standby", no fake
  meter; header shows active MHz only (no "/ total"). Bubble widths retain
  reported bandwidth, so a configured 100 MHz carrier is not squeezed to zero.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])


def swap(rel, old, new, label):
    p = target / rel
    text = p.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"CA standby patch: {label} anchor changed")
    p.write_text(text.replace(old, new, 1))


# --- parse_at.sh: carry the SCell state ---------------------------------------
P = "scripts/usr/lib/qmanager/parse_at.sh"
swap(P,
     '''        # --- Sanitize numeric fields (empty / dash / non-numeric → null) ---
''',
     '''        # Casa: SCell state (0/1/2) from SCC field 5. LTE always carries it; NR
        # carries it on the long form and on the short state form.
        local cc_state="null"
        if [ "$cc_type" = "SCC" ] && [ "$nfields" -ge 6 ]; then
            if [ "$tech" = "LTE" ] || [ "$nfields" -ge 9 ] || _casa_scc_state_form "$5" "$6"; then
                cc_state="$5"
            fi
        fi
        case "$cc_state" in 0|1|2) ;; *) cc_state="null" ;; esac

        # --- Sanitize numeric fields (empty / dash / non-numeric → null) ---
''', "parse_at state")
swap(P,
     '''        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
            "$cc_type" "$tech" "$band_short" "${freq:-null}" "$mhz" \\
            "$cc_pci" "$cc_rsrp" "$cc_rsrq" "$cc_rssi" "$cc_sinr" >> "$cc_tmpfile"
''',
     '''        printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' \\
            "$cc_type" "$tech" "$band_short" "${freq:-null}" "$mhz" \\
            "$cc_pci" "$cc_rsrp" "$cc_rsrq" "$cc_rssi" "$cc_sinr" "$cc_state" >> "$cc_tmpfile"
''', "parse_at row")
swap(P,
     '''                sinr: (.[9] | if . == "null" then null else tonumber end)
            })''',
     '''                sinr: (.[9] | if . == "null" then null else tonumber end),
                state: (.[10] | if . == null or . == "null" then null else tonumber end)
            })''', "parse_at jq")

# --- events.sh: no handoff events for standby SCCs ----------------------------
# Both the per-change comparison and the initial seeding use the same filter.
E = target / "scripts/usr/lib/qmanager/events.sh"
_t = E.read_text()
_old = '''select(.type == "SCC") | {tech: .technology, band: .band, pci: .pci}'''
_new = '''select(.type == "SCC" and (.state // 2) != 1) | {tech: .technology, band: .band, pci: .pci}'''
if _new not in _t:
    if _t.count(_old) != 2:
        raise SystemExit("CA standby patch: events SCC handoff filter anchor changed")
    E.write_text(_t.replace(_old, _new))

# --- Type ---------------------------------------------------------------------
swap("types/modem-status.ts",
     '''  /** Signal to Interference plus Noise Ratio (dB). NR values are already converted (raw/100). */
  sinr: number | null;
}''',
     '''  /** Signal to Interference plus Noise Ratio (dB). NR values are already converted (raw/100). */
  sinr: number | null;
  /** Casa: SCell state from AT+QCAINFO (0 = deconfigured, 1 = configured but
   *  not active, 2 = active); null for the PCC or when the modem omits it. */
  state?: number | null;
}''', "CarrierComponent type")

# --- lib/carrier-aggregation.ts -------------------------------------------------
L = "lib/carrier-aggregation.ts"
swap(L,
     '''  released: boolean;
  /** Wall-clock ms of the last snapshot this carrier appeared in. */''',
     '''  released: boolean;
  /** Casa: an SCC the modem reports in SCell state 1 (configured, not carrying
   *  data). Shown, but not counted as aggregated. */
  standby: boolean;
  /** Wall-clock ms of the last snapshot this carrier appeared in. */''', "ResolvedCarrier standby")
swap(L,
     '''  /** Wall-clock ms of the last snapshot this carrier appeared in. */
  lastSeenMs: number;
}''',
     '''  /** Wall-clock ms of the last snapshot this carrier appeared in. */
  lastSeenMs: number;
  /** Casa: wall-clock ms of the last snapshot that showed it carrying data. */
  lastActiveMs?: number;
}''', "ResolvedCarrier lastActiveMs")
# Casa: a released carrier stays 30 s (was 120 s) and sorts to the end, behind
# the current primary and the live carriers, so after an LTE -> NR change the old
# PCC does not lead the chain (owner, Box 4, 2026-10-13).
swap(L,
     '''const RELEASE_RETAIN_MS = 120000;
''',
     '''const RELEASE_RETAIN_MS = 30000;
''', "release retain 30 s")
swap(L,
     '''  // Genuinely new carriers join at the end, in the order the radio listed them.
  for (const c of snapshot) {
    const key = carrierKey(c);
    if (placed.has(key)) continue;
    const fresh = live.get(key);
    if (fresh) out.push(fresh);
  }

  return out;''',
     '''  // Genuinely new carriers join at the end, in the order the radio listed them.
  for (const c of snapshot) {
    const key = carrierKey(c);
    if (placed.has(key)) continue;
    const fresh = live.get(key);
    if (fresh) out.push(fresh);
  }

  // Casa: the current primary leads, then live carriers, then released ones
  // (stable sort keeps each group's order).
  const rank = (c: ResolvedCarrier) =>
    c.released ? 2 : isLeadRole(c.role) ? 0 : 1;
  return out.sort((a, b) => rank(a) - rank(b));''', "reconcile order")

swap(L,
     '''const RELEASE_RETAIN_MS = 30000;
''',
     '''const RELEASE_RETAIN_MS = 30000;

/** Casa: an SCC that carried data within this window still counts as active
 *  while the network toggles it between active and standby under load (Box 4,
 *  cell edge: state 1 <-> 2 every few seconds during a speed test). */
const ACTIVE_HOLD_MS = 5000;
''', "active hold constant")
swap(L,
     '''  const live = new Map<string, ResolvedCarrier>();
  snapshot.forEach((c, i) => {
    const key = carrierKey(c);
    live.set(key, {
      ...c,
      key,
      role: roles[i],
      released: false,
      lastSeenMs: nowMs,''',
     '''  const prevByKey = new Map(previous.map((p) => [p.key, p] as const));
  const live = new Map<string, ResolvedCarrier>();
  snapshot.forEach((c, i) => {
    const key = carrierKey(c);
    // Casa: state 1 = configured but not carrying data. Held active for
    // ACTIVE_HOLD_MS after the last active reading so the card does not flicker.
    const reportedStandby = roles[i] === "scc" && c.state === 1;
    const lastActiveMs = reportedStandby ? prevByKey.get(key)?.lastActiveMs : nowMs;
    live.set(key, {
      ...c,
      key,
      role: roles[i],
      released: false,
      standby:
        reportedStandby &&
        !(lastActiveMs !== undefined && nowMs - lastActiveMs < ACTIVE_HOLD_MS),
      lastActiveMs,
      lastSeenMs: nowMs,''', "reconcile standby + hold")
swap(L,
     '''    out.push({
      ...prev,
      released: nowMs - prev.lastSeenMs >= RELEASE_GRACE_MS,
    });''',
     '''    // Casa: the grace only covers an EMPTY snapshot (a failed AT read). When
    // the radio still lists other carriers, this one was really dropped or
    // swapped, and at the cell edge that happens faster than the grace.
    out.push({
      ...prev,
      released:
        snapshot.length > 0 || nowMs - prev.lastSeenMs >= RELEASE_GRACE_MS,
    });''', "reconcile prompt release")
swap(L,
     '''  const active = carriers.filter((c) => !c.released);''',
     '''  // Casa: a standby SCC is listed but carries no data, so it is not aggregated.
  const active = carriers.filter((c) => !c.released && !c.standby);''', "summarise active")
swap(L,
     '''    releasedCount: carriers.length - active.length,''',
     '''    releasedCount: carriers.filter((c) => c.released).length,''', "summarise releasedCount")

# --- Dashboard card -----------------------------------------------------------
C = "components/dashboard/carrier-aggregation.tsx"
for fn in ("segmentTone", "tileTone", "roleChipTone"):
    swap(C,
         f'''function {fn}(c: ResolvedCarrier): string {{
  if (c.released) return''',
         f'''function {fn}(c: ResolvedCarrier): string {{
  if (c.released || c.standby) return''', f"card {fn}")
swap(C,
     '''      if (c.released) return t("ca.role.released");
''',
     '''      if (c.released) return t("ca.role.released");
      if (c.standby) return "Standby";
''', "card role label")
# Keep upstream's reported-bandwidth proportions. Standby is conveyed by tone
# and its role label; only the aggregate total excludes its configured MHz.
# Reapplying to a tree converted before this fix also removes the old override.
card = target / C
old_shares = '''  // Casa: a standby carrier keeps a sliver in the chain, not its bandwidth.
  const shares = computeSegmentShares(
    resolved.map((c) => (c.standby && !c.released ? 0 : c.bandwidth_mhz)),
  );'''
card_text = card.read_text()
reported_shares = '  const shares = computeSegmentShares(resolved.map((c) => c.bandwidth_mhz));'
if card_text.count(old_shares) > 1:
    raise SystemExit("CA standby patch: card shares anchor changed")
updated_card = card_text.replace(old_shares, reported_shares, 1)
if updated_card.count(reported_shares) != 1:
    raise SystemExit("CA standby patch: card shares anchor changed")
if updated_card != card_text:
    card.write_text(updated_card)
swap(C,
     '''              {summary.totalMhz}
              {hasReleased && (
                <span className="text-on-surface-variant">
                  {" / "}
                  {summary.previousTotalMhz}
                </span>
              )}''',
     '''              {/* Casa: active carriers only; released and standby carriers
                  are not bandwidth the radio is using. */}
              {summary.totalMhz}''', "card header total")
swap(C,
     '''                {c.released ? (
                  <p className="text-xs font-medium">''',
     '''                {c.standby && !c.released ? (
                  <p className="text-xs font-medium">
                    Configured, not carrying data
                  </p>
                ) : c.released ? (
                  <p className="text-xs font-medium">''', "card standby body")
