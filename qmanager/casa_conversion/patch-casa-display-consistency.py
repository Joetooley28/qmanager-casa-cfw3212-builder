#!/usr/bin/env python3
"""Align v0.1.17 Home, Tower Lock and IPPT displays with Casa carrier state.

Standby carriers show their real signal; a missing reading reads "No reading".

Runs after the standby/PCC patches. Raw modem data and network controls stay
unchanged. Validate every anchor before writing any of the patched files.
"""
import json
from pathlib import Path
import sys

target = Path(sys.argv[1])
template = Path(__file__).parent / "templates/hooks/use-resolved-carriers.ts"
network = "components/dashboard/network-status.tsx"
tower = "components/cellular/tower-locking/live-strip.tsx"
if not (target / tower).exists():
    print("Casa display consistency: pre-v0.1.17 layout; skipped")
    raise SystemExit(0)

pending = {}


def swap(rel, old, new):
    text = pending.get(rel, (target / rel).read_text())
    if (new and new in text) or (not new and old not in text):
        return
    if text.count(old) != 1:
        raise SystemExit(f"Casa display consistency: anchor changed in {rel}: {old[:90]!r}")
    pending[rel] = text.replace(old, new, 1)


home = "components/dashboard/home-component.tsx"
swap(home, 'import { useAboutDevice }',
     'import { useResolvedCarriers } from "@/hooks/use-resolved-carriers";\n'
     'import { summarise } from "@/lib/carrier-aggregation";\n'
     'import { useAboutDevice }')
swap(home, '\n  return (\n', '''
  const resolvedCarriers = useResolvedCarriers(
    carrierComponents, networkType, isStale, receivedAtMs,
  );
  const aggregation = summarise(resolvedCarriers, networkType);

  return (
''')
swap(home, '<NetworkStatusComponent\n              data={data?.network ?? null}',
     '<NetworkStatusComponent\n              aggregation={aggregation}\n              data={data?.network ?? null}')
swap(home, '''            carriers={carrierComponents}
            networkType={networkType}
            isLoading={isLoading}
            isStale={isStale}''', '''            resolvedCarriers={resolvedCarriers}
            networkType={networkType}
            isLoading={isLoading}''')

swap(network, 'interface NetworkStatusComponentProps {',
     'import type { AggregationSummary } from "@/lib/carrier-aggregation";\n\n'
     'interface NetworkStatusComponentProps {\n  aggregation: AggregationSummary;')
swap(network, 'const NetworkStatusComponent = ({\n  data,',
     'const NetworkStatusComponent = ({\n  aggregation,\n  data,')
swap(network, '''  const caActive = data?.ca_active ?? false;
  const nrCaActive = data?.nr_ca_active ?? false;''', '''  // Match the CA card, including standby hold and release handling.
  const caActive = aggregation.lteCa;
  const nrCaActive = aggregation.nrCa;''')

card = "components/dashboard/carrier-aggregation.tsx"
swap(card, '  carriers: CarrierComponent[];', '  resolvedCarriers: ResolvedCarrier[];')
swap(card, '''  /** True when the dashboard has stopped trusting its own data. The release
   *  clock must not run on snapshots the app is already disowning. */
  isStale: boolean;
''', '')
swap(card, '  carriers,\n  networkType,\n  isLoading,\n  isStale,',
     '  resolvedCarriers,\n  networkType,\n  isLoading,')
# Keep the card's prior committed chain for its existing entry animations.
text = pending.get(card, (target / card).read_text())
if '  const resolved = resolvedCarriers;' not in text:
    start = text.index('  // Release history lives here')
    end = text.index('  const summary = summarise(resolved, networkType);', start)
    pending[card] = text[:start] + '''  // Home owns reconciliation so its subtitle and this card share one list.
  // Keep the preceding snapshot only for the existing entry animations.
  const [history, setHistory] = React.useState({
    current: resolvedCarriers,
    previous: [] as ResolvedCarrier[],
  });
  if (history.current !== resolvedCarriers) {
    setHistory({ current: resolvedCarriers, previous: history.current });
  }
  const now = receivedAtMs;
  const resolved = resolvedCarriers;

''' + text[end:]
swap(card, '  reconcileCarriers,\n', '')
swap(card, 'import type { CarrierComponent, NetworkType }', 'import type { NetworkType }')
swap(card, 'const previousKeys = new Set(retained.current.map((c) => c.key));',
     'const previousKeys = new Set(history.previous.map((c) => c.key));')
swap(card, 'const hasDrawnChain = retained.current.length > 0;',
     'const hasDrawnChain = history.previous.length > 0;')
text = pending.get(card, (target / card).read_text())
start = text.index('  // A carrier is "entering"')
end = text.index('  const previousKeys =', start)
pending[card] = text[:start] + '''  // A carrier is "entering" only after an earlier snapshot drew the chain.
  // Compare the two observed snapshots, not time spent rendering the card.
''' + text[end:]
swap(card, '''        {/* ── Per-carrier tiles ──''', '''        {/* Keep reported bubble proportions; small containers get a text legend. */}
        <ul className="flex flex-wrap gap-x-4 gap-y-1 text-xs @md/ca:hidden"
          aria-label={t("ca.legend_label")}>
          {resolved.map((c) => (
            <li key={c.key} className="flex min-w-0 items-center gap-1.5">
              <span aria-hidden="true" className={cn("size-2.5 shrink-0 rounded-sm", segmentTone(c))} />
              <span>
                {c.band} · {c.bandwidth_mhz > 0 ? `${c.bandwidth_mhz} MHz` : t("ca.bw_unknown")} · {c.released ? t("ca.role.released") : c.standby ? t("ca.standby") : t("ca.active")}
              </span>
            </li>
          ))}
        </ul>

        {/* ── Per-carrier tiles ──''')

page = "components/cellular/tower-locking/tower-locking.tsx"
swap(page, 'import { useModemStatus }',
     'import { useResolvedCarriers } from "@/hooks/use-resolved-carriers";\n'
     'import { useModemStatus }')
swap(page, 'const { data: modemData } = useModemStatus();',
     'const { data: modemData, isStale, receivedAtMs } = useModemStatus();')
swap(page, '  const lteCarriers = useMemo(', '''  const resolvedCarriers = useResolvedCarriers(
    carriers, networkType, isStale, receivedAtMs,
  );
  const lteCarriers = useMemo(''')
swap(page, '              carrierComponents={carriers}',
     '              carrierComponents={resolvedCarriers}')

swap(tower, 'import type { TowerModemState }',
     'import type { ResolvedCarrier } from "@/lib/carrier-aggregation";\n'
     'import type { TowerModemState }')
swap(tower, '  /** Live QCAINFO carriers from `useModemStatus`. */\n  carrierComponents: CarrierComponent[];',
     '  /** Reconciled carriers, including configured standby cells. */\n  carrierComponents: ResolvedCarrier[];')
swap(tower, 'function sortCarriers(components: CarrierComponent[]): CarrierComponent[] {',
     'function sortCarriers(components: ResolvedCarrier[]): ResolvedCarrier[] {')
swap(tower, '() => sortCarriers(carrierComponents),',
     '() => sortCarriers(carrierComponents.filter((c) => !c.released)),')
swap(tower, 'const verdict = matchVerdict(modemState, onAir);',
     'const verdict = matchVerdict(modemState, onAir.filter((c) => !c.standby));')
swap(tower, '{t("tower_locking.live.camped_on")}',
     '{t("tower_locking.live.reported_carriers")}')
swap(tower, '<span className={CARRIER_TILE.BAND}>{c.band}</span>', '''<span className={CARRIER_TILE.BAND}>{c.band}</span>
                      {c.standby && (
                        <span className="text-on-surface-variant text-xs">
                          {t("radio_info.bands.standby")}
                        </span>
                      )}''')
# Standby carriers keep their real RSRP; a missing reading says so in words.
swap(tower, '''                          {c.rsrp === null
                            ? t("tower_locking.live.tile_no_value")''', '''                          {c.rsrp === null
                            ? t("radio_info.bands.quality.none")''')

ippt = "components/local-network/ip-passthrough/status-strip.tsx"
swap(ippt, '''          <Figure label={t(`${K}.rows.nat.label`)}>
            <span className={FIGS.VALUE}>
              {t(ipptNat === "1" ? `${K}.options.nat_on` : `${K}.options.nat_off`)}
            </span>
          </Figure>
          <Figure label={t(`${K}.rows.usb.label`)}>
            <span className={FIGS.VALUE}>{usbMode ? USB_SHORT[usbMode] : ""}</span>
          </Figure>''', '''          <Figure label={t(`${K}.status.casa_nat_label`)}>
            <span className={FIGS.VALUE}>
              {t(passing ? `${K}.status.casa_nat_unreported` : `${K}.status.casa_nat_na`)}
            </span>
          </Figure>''')
swap(ippt, '  ipptNat,\n  usbMode,\n', '')

for rel, section, values in [
    ("public/locales/en/dashboard.json", ["ca"],
     {"legend_label": "Carrier bandwidth and state", "active": "Active", "standby": "Standby",
      "no_reading": "No reading"}),
    ("public/locales/en/cellular.json", ["tower_locking", "live"],
     {"reported_carriers": "Active and configured carriers"}),
    ("public/locales/en/common.json", ["ipPassthrough", "status"],
     {"casa_nat_label": "Passthrough NAT",
      "casa_nat_unreported": "Not reported",
      "casa_nat_na": "Not applicable"}),
]:
    data = json.loads((target / rel).read_text())
    node = data
    for key in section:
        node = node[key]
    node.update(values)
    pending[rel] = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

pending["hooks/use-resolved-carriers.ts"] = template.read_text()
for rel, text in pending.items():
    (target / rel).write_text(text)
print("Casa display consistency: Home, Tower Lock and IPPT patched")
