#!/usr/bin/env python3
"""Schedules: show the device time zone, and warn when it disagrees with the network.

QManager starts on UTC and onboarding never asks for a zone, so a Scheduled
Reboot or Tower Lock schedule typed as local time can run hours off (Box 1,
2026-10-13). Both schedule cards now say which zone their times use, with a
link to change it. When the carrier's reported local offset (Casa RDB
wwan.0.networktime.timezone, e.g. "-4 DST 1") differs from the device clock's
offset, the line becomes a warning. The settings GET gains network_offset
("+HHMM", empty when the carrier sends none).

Styling follows each card's own upstream idiom: System Settings uses
ROW.CONSEQUENCE and the TZ_NOTICE warning (Badge + sentence, as for a zone that
did not apply); the Tower Lock tile uses AUTO_TILE.BODY and the same NOTICE
block as its "no days" warning. The shared file only supplies data and words.
"""
from pathlib import Path
import sys

target = Path(sys.argv[1])


def swap(path, old, new, label):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"Zone note patch: {label} anchor changed")
    path.write_text(text.replace(old, new, 1))


# --- Backend: carrier-reported offset in the settings GET -------------------
cgi = target / "scripts/www/cgi-bin/quecmanager/system/settings.sh"
swap(cgi,
     '''    eff_abbr=$(printf '%s' "$eff_tz" | cut -d' ' -f4)
''',
     '''    eff_abbr=$(printf '%s' "$eff_tz" | cut -d' ' -f4)

    # Casa: local offset the carrier sends (NITZ), e.g. "-4 DST 1" -> "-0400".
    # Empty when the network sends none, so the UI shows no warning.
    net_offset=$(rdb_get wwan.0.networktime.timezone 2>/dev/null | awk '
        NF && $1 ~ /^[-+]?[0-9]+(\\.[0-9]+)?$/ {
            m = int($1 * 60 + ($1 < 0 ? -0.5 : 0.5)); s = "+"
            if (m < 0) { s = "-"; m = -m }
            printf "%s%02d%02d", s, int(m / 60), m % 60
        }')
''', "settings.sh effective tz")
swap(cgi,
     '''        --arg effective_zone_abbr "$eff_abbr" \\
''',
     '''        --arg effective_zone_abbr "$eff_abbr" \\
        --arg network_offset "$net_offset" \\
''', "settings.sh jq args")
swap(cgi,
     '''                effective_zone_abbr: $effective_zone_abbr,
''',
     '''                effective_zone_abbr: $effective_zone_abbr,
                network_offset: $network_offset,
''', "settings.sh jq object")

# --- Type ---------------------------------------------------------------------
types = target / "types/system-settings.ts"
swap(types,
     '''  timezone_applied?: boolean; // true = configured zone matches the live clock
''',
     '''  timezone_applied?: boolean; // true = configured zone matches the live clock
  network_offset?: string; // Casa: offset the carrier reports (NITZ), "+HHMM"; "" when none
''', "SystemSettings type")

# --- Shared data + sentence (no styling of its own) ---------------------------
note = target / "components/casa-zone-note.tsx"
note.write_text('''"use client";

// Casa CFW-3212: which time zone a schedule's times use, and whether the device
// clock disagrees with the local offset the carrier reports. Each card renders
// the sentence in its own upstream styling; only the link class is passed in.

import Link from "next/link";
import { useEffect, useState } from "react";

import { formatOffset } from "@/components/system-settings/derive";
import { authFetch } from "@/lib/auth-fetch";
import type {
  SystemSettings,
  SystemSettingsResponse,
} from "@/types/system-settings";

export interface CasaZone {
  zone: string;
  abbr?: string;
  device: string;
  network: string;
  /** The carrier reports a different local offset than the device clock uses. */
  mismatch: boolean;
}

/** Pass the page's `settings` where it has them; otherwise this fetches once. */
export function useCasaZone(settings?: SystemSettings | null): CasaZone | null {
  const own = settings === undefined;
  const [fetched, setFetched] = useState<SystemSettings | null>(null);

  useEffect(() => {
    if (!own) return;
    let cancelled = false;
    authFetch("/cgi-bin/quecmanager/system/settings.sh")
      .then((r) => r.json())
      .then((json: SystemSettingsResponse) => {
        if (!cancelled && json.success && json.settings) setFetched(json.settings);
      })
      .catch(() => {
        // No zone line when the settings cannot be read.
      });
    return () => {
      cancelled = true;
    };
  }, [own]);

  const s = own ? fetched : settings;
  if (!s) return null;
  const device = s.effective_offset ?? "";
  const network = s.network_offset ?? "";
  return {
    zone: s.zonename || "UTC",
    abbr: s.effective_zone_abbr?.trim() || undefined,
    device,
    network,
    mismatch: Boolean(network && device && network !== device),
  };
}

/** The words, with a link to System Settings styled by the caller. */
export function CasaZoneSentence({
  zone,
  linkClassName,
}: {
  zone: CasaZone;
  linkClassName: string;
}) {
  if (zone.mismatch) {
    return (
      <>
        These times use {zone.zone} ({formatOffset(zone.device)}), but your
        network reports {formatOffset(zone.network)}.{" "}
        <Link href="/system-settings" className={linkClassName}>
          Set your time zone
        </Link>{" "}
        in System Settings.
      </>
    );
  }
  return (
    <>
      Device time zone: {zone.zone}
      {zone.abbr && zone.abbr !== zone.zone ? ` (${zone.abbr})` : ""}.{" "}
      <Link href="/system-settings" className={linkClassName}>
        Change
      </Link>
    </>
  );
}
''')

# --- Scheduled Reboot (System Settings): the page's settings, upstream idiom ----
card = target / "components/system-settings/scheduled-operations-card.tsx"
swap(card,
     '''import { Switch } from "@/components/ui/switch";
''',
     '''import { Switch } from "@/components/ui/switch";
import { CasaZoneSentence, useCasaZone } from "@/components/casa-zone-note";
''', "reboot card import")
swap(card,
     '''  SKELETON,
} from "./shapes";''',
     '''  SKELETON,
  TZ_NOTICE,
} from "./shapes";''', "reboot card shapes import")
swap(card,
     '''  "scheduledReboot" | "isLoading" | "error" | "saveScheduledReboot" | "refresh"
>;''',
     '''  | "scheduledReboot"
  | "isLoading"
  | "error"
  | "saveScheduledReboot"
  | "refresh"
  | "settings"
>;

/** Casa: the zone line's link, as connection-quality's ROW.LINK. */
const CASA_ZONE_LINK = cn(
  "text-primary-on-surface rounded-inline font-semibold underline-offset-4 hover:underline",
  FOCUS_RING,
);''', "reboot card props type")
swap(card,
     '''  saveScheduledReboot,
  refresh,
}: ScheduledRebootCardProps) => {
  const { t } = useTranslation("system-settings");
''',
     '''  saveScheduledReboot,
  refresh,
  settings,
}: ScheduledRebootCardProps) => {
  const { t } = useTranslation("system-settings");
  const casaZone = useCasaZone(settings);
''', "reboot card props")
swap(card,
     '''              <span className={ROW.CONSEQUENCE}>
                {t(`${K}.rows.time.consequence`)}
              </span>
            </div>
            <div className={ROW.CONTROL}>
              <Input
                id="scheduled-reboot-time"
                type="time"
                host="container"
                className={FIELD}
                value={rebootTime}
                onChange={(e) => handleRebootTimeChange(e.target.value)}
              />
            </div>
          </motion.div>
''',
     '''              <span className={ROW.CONSEQUENCE}>
                {t(`${K}.rows.time.consequence`)}
              </span>
              {casaZone && !casaZone.mismatch ? (
                <span className={ROW.CONSEQUENCE}>
                  <CasaZoneSentence zone={casaZone} linkClassName={CASA_ZONE_LINK} />
                </span>
              ) : null}
            </div>
            <div className={ROW.CONTROL}>
              <Input
                id="scheduled-reboot-time"
                type="time"
                host="container"
                className={FIELD}
                value={rebootTime}
                onChange={(e) => handleRebootTimeChange(e.target.value)}
              />
            </div>
          </motion.div>

          {/* Casa: the zone warning hangs under the Time row, as the zone-apply
              warning does under the Time zone row. */}
          {casaZone?.mismatch ? (
            <motion.div variants={staggerRowItem} className={TZ_NOTICE}>
              <Badge variant="warning">
                <TriangleAlertIcon className="size-3" aria-hidden="true" />
                Time zone
              </Badge>
              <span className={ROW.CONSEQUENCE}>
                <CasaZoneSentence zone={casaZone} linkClassName={CASA_ZONE_LINK} />
              </span>
            </motion.div>
          ) : null}
''', "reboot card time row")

# --- Tower Lock schedule tile: fetches the zone itself, tile idiom -----------
tile = target / "components/cellular/tower-locking/schedule-tile.tsx"
swap(tile,
     '''import { Switch } from "@/components/ui/switch";
''',
     '''import { Switch } from "@/components/ui/switch";
import { CasaZoneSentence, useCasaZone } from "@/components/casa-zone-note";
''', "tower tile import")
swap(tile,
     '''export function ScheduleTile({ config, onScheduleChange }: ScheduleTileProps) {
  const { t } = useTranslation("cellular");
''',
     '''/** Casa: the zone line's link; inside a notice it keeps the notice's ink. */
const CASA_ZONE_LINK =
  "text-primary-on-surface rounded-inline font-semibold underline-offset-4 hover:underline focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none";
const CASA_ZONE_LINK_NOTICE =
  "rounded-inline font-semibold underline underline-offset-4 focus-visible:ring-2 focus-visible:ring-current/40 focus-visible:outline-none";

export function ScheduleTile({ config, onScheduleChange }: ScheduleTileProps) {
  const { t } = useTranslation("cellular");
  const casaZone = useCasaZone();
''', "tower tile hook")
swap(tile,
     '''            id="tower-schedule-end"
            type="time"
            value={endTime}
            onChange={(e) => {
              setEndTime(e.target.value);
              commit({ end_time: e.target.value });
            }}
            host="container"
            className={FIELD_CONTROL}
          />
        </div>
      </div>
''',
     '''            id="tower-schedule-end"
            type="time"
            value={endTime}
            onChange={(e) => {
              setEndTime(e.target.value);
              commit({ end_time: e.target.value });
            }}
            host="container"
            className={FIELD_CONTROL}
          />
        </div>
      </div>

      {/* Casa: which zone these times use; a warning in the tile's own notice
          when the carrier reports a different local offset. */}
      {casaZone && !casaZone.mismatch ? (
        <p className={AUTO_TILE.BODY}>
          <CasaZoneSentence zone={casaZone} linkClassName={CASA_ZONE_LINK} />
        </p>
      ) : null}
      {casaZone?.mismatch ? (
        <div
          role="status"
          className={`${NOTICE.ROOT} ${NOTICE_TONE.warning.fill} text-xs`}
        >
          <span
            aria-hidden="true"
            className={`${NOTICE.DISC} ${NOTICE_TONE.warning.disc}`}
          >
            <MaterialSymbol name={NOTICE_TONE.warning.glyph} size={16} />
          </span>
          <span className="min-w-0 flex-1 leading-relaxed">
            <CasaZoneSentence zone={casaZone} linkClassName={CASA_ZONE_LINK_NOTICE} />
          </span>
        </div>
      ) : null}
''', "tower tile time grid")
