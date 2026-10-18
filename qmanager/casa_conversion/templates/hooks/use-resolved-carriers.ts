"use client";

import { useState } from "react";
import type { CarrierComponent, NetworkType } from "@/types/modem-status";
import { reconcileCarriers, type ResolvedCarrier } from "@/lib/carrier-aggregation";

/** Reconcile only real poll arrivals; stale data must not advance carrier clocks. */
export function useResolvedCarriers(
  carriers: CarrierComponent[],
  networkType: NetworkType,
  isStale: boolean,
  receivedAtMs: number | null,
): ResolvedCarrier[] {
  const [snapshot, setSnapshot] = useState<{
    receivedAtMs: number | null;
    carriers: ResolvedCarrier[];
  }>({ receivedAtMs: null, carriers: [] });
  if (!isStale && receivedAtMs !== null && receivedAtMs !== snapshot.receivedAtMs) {
    const next = {
      receivedAtMs,
      carriers: reconcileCarriers(snapshot.carriers, carriers, networkType, receivedAtMs),
    };
    // Adjust this component's state before commit. Unrelated renders and stale
    // snapshots cannot advance either clock; discarded renders commit nothing.
    setSnapshot(next);
    return next.carriers;
  }
  return snapshot.carriers;
}
