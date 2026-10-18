// Run from a freshly converted v0.1.17 app (copy into scripts-dev/casa-tests).
import React from "react";
import { beforeAll, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import i18next from "i18next";
import { I18nextProvider, initReactI18next } from "react-i18next";
import NetworkStatusComponent from "@/components/dashboard/network-status";
import { CarrierAggregationComponent } from "@/components/dashboard/carrier-aggregation";
import { TowerLiveStrip } from "@/components/cellular/tower-locking/live-strip";
import { StatusStrip } from "@/components/local-network/ip-passthrough/status-strip";
import { useResolvedCarriers } from "@/hooks/use-resolved-carriers";
import { reconcileCarriers, summarise, type ResolvedCarrier } from "@/lib/carrier-aggregation";
import type { CarrierComponent, NetworkStatus } from "@/types/modem-status";
import type { TowerModemState } from "@/types/tower-locking";
import dashboard from "@/public/locales/en/dashboard.json";
import cellular from "@/public/locales/en/cellular.json";
import common from "@/public/locales/en/common.json";

const i18n = i18next.createInstance();
beforeAll(async () => {
  await i18n.use(initReactI18next).init({
    lng: "en", resources: { en: { dashboard, cellular, common } },
    interpolation: { escapeValue: false },
  });
});

const primary: CarrierComponent = {
  type: "PCC", technology: "NR", band: "N41", earfcn: 500000,
  bandwidth_mhz: 90, pci: 100, rsrp: -95, rsrq: -10,
  rssi: null, sinr: 20, state: null,
};
const standby: CarrierComponent = {
  ...primary, type: "SCC", band: "N25", earfcn: 400000,
  bandwidth_mhz: 20, pci: 200, rsrp: -156, state: 1,
};
const snapshot = [primary, standby];
const network: NetworkStatus = {
  type: "5G-SA", sim_slot: 1, carrier: "Test carrier", service_status: "optimal",
  ca_active: false, ca_count: 0, nr_ca_active: true, nr_ca_count: 1,
  total_bandwidth_mhz: 110, bandwidth_details: "N41: 90 MHz + N25: 20 MHz",
  apn: "test", wan_ipv4: "", wan_ipv6: "", primary_dns: "", secondary_dns: "",
  carrier_components: snapshot,
};
const render = (node: React.ReactNode) => renderToStaticMarkup(
  <I18nextProvider i18n={i18n}>{node}</I18nextProvider>,
);
const home = (resolved: ResolvedCarrier[]) => render(
  <NetworkStatusComponent data={network} aggregation={summarise(resolved, "5G-SA")}
    modemReachable isLoading={false} />,
);

test("shared hook resolves the first received snapshot before rendering Home", () => {
  function ReceivedHome() {
    const resolved = useResolvedCarriers(snapshot, "5G-SA", false, 10000);
    return <NetworkStatusComponent data={network} aggregation={summarise(resolved, "5G-SA")}
      modemReachable isLoading={false} />;
  }
  const html = render(<ReceivedHome />);
  expect(html).toContain("Standalone");
  expect(html).not.toContain("NR-CA");
});

test("Home and the CA card agree despite raw NR-CA=true and 110 MHz", () => {
  const resolved = reconcileCarriers([], snapshot, "5G-SA", 10000);
  expect(summarise(resolved, "5G-SA")).toMatchObject({ nrCa: false, totalMhz: 90 });
  expect(home(resolved)).toContain("Standalone");
  expect(home(resolved)).not.toContain("NR-CA");
  const card = render(<CarrierAggregationComponent resolvedCarriers={resolved}
    networkType="5G-SA" isLoading={false} receivedAtMs={10000} />);
  expect(card).toContain("No aggregation");
  expect(card).toContain("Standby");
  expect(network.nr_ca_active).toBe(true);
  expect(network.total_bandwidth_mhz).toBe(110);
});

test("Home keeps NR-CA through the five-second active hold, then clears it", () => {
  const active = reconcileCarriers([], [primary, { ...standby, state: 2 }], "5G-SA", 10000);
  const held = reconcileCarriers(active, snapshot, "5G-SA", 14999);
  expect(summarise(held, "5G-SA")).toMatchObject({ nrCa: true, totalMhz: 110 });
  expect(home(held)).toContain("NR-CA");
  const idle = reconcileCarriers(held, snapshot, "5G-SA", 15000);
  expect(home(idle)).not.toContain("NR-CA");
  expect(summarise(idle, "5G-SA").totalMhz).toBe(90);
});

test("a disappearing secondary clears Home NR-CA immediately", () => {
  const active = reconcileCarriers([], [primary, { ...standby, state: 2 }], "5G-SA", 10000);
  const released = reconcileCarriers(active, [primary], "5G-SA", 11000);
  expect(released.find((c) => c.band === "N25")?.released).toBe(true);
  expect(home(released)).not.toContain("NR-CA");
});

test("LTE standby does not become LTE-CA; the NSA NR anchor stays active", () => {
  const lte = { ...primary, technology: "LTE" as const, band: "B2" };
  const lteScc = { ...standby, technology: "LTE" as const, band: "B66" };
  expect(summarise(reconcileCarriers([], [lte, lteScc], "LTE", 10000), "LTE").lteCa).toBe(false);
  const nsa = summarise(reconcileCarriers([], [lte, standby], "5G-NSA", 10000), "5G-NSA");
  expect(nsa).toMatchObject({ activeCount: 2, endc: true, nrCa: false });
});

test("Tower Lock labels standby, hides placeholder RSRP and does not claim an active match", () => {
  const modemState: TowerModemState = {
    lte_locked: false, lte_cells: [], nr_locked: true,
    nr_cell: { arfcn: 400000, pci: 200, band: 25, scs: 30 },
    persist_lte: false, persist_nr: false,
  };
  const html = render(<TowerLiveStrip modemState={modemState}
    carrierComponents={reconcileCarriers([], snapshot, "5G-SA", 10000)}
    canTarget={{ lte: { ok: true, reasonKey: null }, nr_sa: { ok: true, reasonKey: null } }}
    isLoading={false} onPickCarrier={() => {}} />);
  expect(html).toContain("Active and configured carriers");
  expect(html).toContain("Standby");
  expect(html).toContain("Configured, not carrying data");
  expect(html).not.toContain("-156");
  expect(html).toContain("Not on target");
});

test.each(["0", "1"] as const)("disabled Casa IPPT makes no NAT claim for raw value %s", (ipptNat) => {
  const html = render(<StatusStrip mode="disabled" targetMac={null} ipptNat={ipptNat}
    usbMode="0" dnsProxy="enabled" failed={false} onRetry={() => {}} />);
  expect(html).toContain("Not applicable");
  expect(html).toContain("Router mode");
  expect(html).not.toContain("Without NAT");
  expect(html).not.toContain("With NAT");
  expect(html).not.toContain("RMNET");
  expect(html).not.toContain("USB connection");
});

test("enabled Ethernet IPPT reports missing NAT information honestly", () => {
  const html = render(<StatusStrip mode="eth" targetMac="02:00:00:00:00:01"
    ipptNat="0" usbMode="0" dnsProxy="enabled" failed={false} onRetry={() => {}} />);
  expect(html).toContain("Not reported");
  expect(html).toContain("02:00:00:00:00:01");
  expect(html).not.toContain("Without NAT");
  expect(html).not.toContain("RMNET");
});
