#!/usr/bin/env python3
"""Band Locking: explain when 5G Architecture (nr5g_disable_mode) blocks a band category.

With 5G Architecture = NSA only the modem accepts SA band locks but reads back
`nr5g_band,0`, which upstream counted as one locked band ("1 of 18 locked").
"""
import json
from pathlib import Path
import sys

target = Path(sys.argv[1])


def edit(rel, old, new):
    p = target / rel
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"Band-arch patch anchor changed: {rel}: {old[:90]!r}")
    p.write_text(text.replace(old, new, 1))


# --- Backend: report nr5g_disable_mode and mode_pref with the current bands ---
edit(
    "scripts/www/cgi-bin/quecmanager/bands/current.sh",
    """jq -n --arg lte "$lte_bands" --arg nsa "$nsa_nr5g_bands" --arg sa "$sa_nr5g_bands" \\
    --argjson fe "$failover_enabled" --argjson fa "$failover_activated" --argjson wr "$watcher_running" \\
    '{"success":true,"current":{"lte_bands":$lte,"nsa_nr5g_bands":$nsa,"sa_nr5g_bands":$sa},"failover":{"enabled":$fe,"activated":$fa,"watcher_running":$wr}}'""",
    """# Casa: 5G Architecture / network type, so the page can say why a category is off.
nr5g_mode=$(qcmd 'AT+QNWPREFCFG="nr5g_disable_mode"' 2>/dev/null | grep '^+QNWPREFCFG: "nr5g_disable_mode"' | head -1 | sed 's/.*"nr5g_disable_mode",//' | tr -dc '0-9')
mode_pref=$(qcmd 'AT+QNWPREFCFG="mode_pref"' 2>/dev/null | grep '^+QNWPREFCFG: "mode_pref"' | head -1 | sed 's/.*"mode_pref",//' | tr -d '\\r "')

jq -n --arg lte "$lte_bands" --arg nsa "$nsa_nr5g_bands" --arg sa "$sa_nr5g_bands" \\
    --arg nm "$nr5g_mode" --arg mp "$mode_pref" \\
    --argjson fe "$failover_enabled" --argjson fa "$failover_activated" --argjson wr "$watcher_running" \\
    '{"success":true,"current":{"lte_bands":$lte,"nsa_nr5g_bands":$nsa,"sa_nr5g_bands":$sa,"nr5g_mode":($nm|tonumber? // null),"mode_pref":(if $mp == "" then null else $mp end)},"failover":{"enabled":$fe,"activated":$fa,"watcher_running":$wr}}'""",
)

# --- Types: carry the two values; never count the modem's "0" as a band ---
edit(
    "types/band-locking.ts",
    "  sa_nr5g_bands: string;\n}",
    "  sa_nr5g_bands: string;\n"
    "  /** Casa: nr5g_disable_mode — 0 auto, 1 NSA only (SA off), 2 SA only (NSA off). */\n"
    "  nr5g_mode?: 0 | 1 | 2 | null;\n"
    "  /** Casa: mode_pref, e.g. AUTO, LTE, NR5G, LTE:NR5G. */\n"
    "  mode_pref?: string | null;\n}",
)
edit(
    "types/band-locking.ts",
    "    .filter((n) => !isNaN(n))",
    "    .filter((n) => !isNaN(n) && n > 0) // modem reports 0 for an empty list",
)

# --- Band card: notice + frozen controls when 5G Architecture turns it off ---
card = "components/cellular/band-locking/band-grid-card.tsx"
edit(
    card,
    'import { Badge } from "@/components/ui/badge";',
    'import Link from "next/link";\n'
    'import { Badge } from "@/components/ui/badge";\n'
    'import { Banner, bannerActionVariants } from "@/components/ui/banner";',
)
edit(
    card,
    "  isGated?: boolean;\n}\n",
    "  isGated?: boolean;\n"
    "  /** Casa: which network-mode setting turns this category off, if any. */\n"
    '  offReason?: "arch_sa" | "arch_nsa" | "lte_only" | "nr_only" | null;\n}\n',
)
edit(card, "  isGated = false,\n}: BandGridCardProps) {", "  isGated = false,\n  offReason = null,\n}: BandGridCardProps) {\n  const archOff = offReason !== null;")
edit(
    card,
    "const isFrozen = isGated || isBusy || isUnavailable;",
    "const isFrozen = isGated || isBusy || isUnavailable || archOff;",
)
edit(
    card,
    "const status = CATEGORY_BADGE[statusKey];",
    'const status = archOff\n'
    '    ? ({ variant: "warning", glyph: "signal_cellular_off" } as const)\n'
    "    : CATEGORY_BADGE[statusKey];",
)
edit(
    card,
    '  const statusLabel =\n    posture === "unavailable"',
    '  const statusLabel = archOff\n'
    '    ? t("band_locking.card.status_arch_off")\n'
    '    : posture === "unavailable"',
)
edit(
    card,
    "      <CardContent className={`${CARD_PAD} flex flex-col gap-4`}>\n",
    "      <CardContent className={`${CARD_PAD} flex flex-col gap-4`}>\n"
    "        {archOff ? (\n"
    "          <Banner\n"
    '            role="degraded"\n'
    "            title={t(`band_locking.card.off_${offReason}_title`)}\n"
    "            description={t(`band_locking.card.off_${offReason}_body`)}\n"
    "            action={\n"
    "              <Link\n"
    '                href="/cellular/settings"\n'
    '                className={bannerActionVariants({ tone: "on-warning" })}\n'
    "              >\n"
    '                {t("band_locking.card.arch_off_action")}\n'
    "              </Link>\n"
    "            }\n"
    "          />\n"
    "        ) : null}\n",
)

# --- Page: pass the setting to the cards and the hero ---
page = "components/cellular/band-locking/band-locking.tsx"
edit(
    page,
    "                isGated={isGated}\n              />",
    "                isGated={isGated}\n"
    "                offReason={\n"
    '                  category === "lte"\n'
    '                    ? currentBands?.mode_pref === "NR5G"\n'
    '                      ? "nr_only"\n'
    "                      : null\n"
    '                    : currentBands?.mode_pref === "LTE"\n'
    '                      ? "lte_only"\n'
    '                      : category === "nsa_nr5g" && currentBands?.mode_pref === "NR5G"\n'
    '                        ? "nr_only"\n'
    '                        : category === "sa_nr5g" && currentBands?.nr5g_mode === 1\n'
    '                          ? "arch_sa"\n'
    '                          : category === "nsa_nr5g" && currentBands?.nr5g_mode === 2\n'
    '                            ? "arch_nsa"\n'
    "                            : null\n"
    "                }\n"
    "              />",
)
edit(
    page,
    "            onToggleFailover={toggleFailover}\n",
    "            onToggleFailover={toggleFailover}\n"
    "            nr5gMode={currentBands?.nr5g_mode ?? null}\n"
    "            modePref={currentBands?.mode_pref ?? null}\n",
)

# --- Hero: name the setting when it is why there is no 5G carrier ---
hero = "components/cellular/band-locking/live-band-hero.tsx"
edit(
    hero,
    "  /** True when a Custom SIM Profile or Connection Scenario owns radio config. */\n  isGated?: boolean;\n}",
    "  /** True when a Custom SIM Profile or Connection Scenario owns radio config. */\n  isGated?: boolean;\n"
    "  /** Casa: nr5g_disable_mode and mode_pref from current.sh. */\n"
    "  nr5gMode?: 0 | 1 | 2 | null;\n"
    "  modePref?: string | null;\n}",
)
edit(
    hero,
    "  isGated = false,\n}: LiveBandHeroProps) {",
    "  isGated = false,\n  nr5gMode = null,\n  modePref = null,\n}: LiveBandHeroProps) {",
)
edit(
    hero,
    "<AbsentLegCell technology={onAir[0].technology} />",
    "<AbsentLegCell\n"
    "                  technology={onAir[0].technology}\n"
    "                  nr5gMode={nr5gMode}\n"
    "                  modePref={modePref}\n"
    "                />",
)
edit(
    hero,
    'function AbsentLegCell({ technology }: { technology: "LTE" | "NR" }) {\n'
    '  const { t } = useTranslation("cellular");\n'
    "  // The lone carrier is LTE => the NR leg is what is absent, and vice versa.\n"
    '  const absent = technology === "LTE" ? "nr" : "lte";\n',
    "function AbsentLegCell({\n"
    "  technology,\n"
    "  nr5gMode = null,\n"
    "  modePref = null,\n"
    "}: {\n"
    '  technology: "LTE" | "NR";\n'
    "  nr5gMode?: 0 | 1 | 2 | null;\n"
    "  modePref?: string | null;\n"
    "}) {\n"
    '  const { t } = useTranslation("cellular");\n'
    "  // The lone carrier is LTE => the NR leg is what is absent, and vice versa.\n"
    '  const absent = technology === "LTE" ? "nr" : "lte";\n'
    "  // Casa: when a network-mode setting is the reason, say so and link to it.\n"
    "  const settingCause =\n"
    '    absent !== "nr"\n'
    "      ? null\n"
    '      : modePref === "LTE"\n'
    '        ? "lte_only"\n'
    "        : nr5gMode === 1\n"
    '          ? "nsa_only"\n'
    "          : null;\n",
)
edit(
    hero,
    "        {t(`band_locking.live.absent_${absent}_body`)}\n",
    "        {settingCause\n"
    "          ? t(`band_locking.live.absent_nr_body_${settingCause}`)\n"
    "          : t(`band_locking.live.absent_${absent}_body`)}\n",
)
edit(
    hero,
    '      <Link href="/cellular/cell-scanner" className={HERO_ONAIR_ABSENT.LINK}>\n'
    '        {t("radio_info.bands.scanner.link")}\n',
    "      <Link\n"
    '        href={settingCause ? "/cellular/settings" : "/cellular/cell-scanner"}\n'
    "        className={HERO_ONAIR_ABSENT.LINK}\n"
    "      >\n"
    "        {settingCause\n"
    '          ? t("band_locking.live.settings_link")\n'
    '          : t("radio_info.bands.scanner.link")}\n',
)

# --- English strings (other locales fall back to English) ---
loc = target / "public/locales/en/cellular.json"
data = json.loads(loc.read_text())
bl = data["band_locking"]
bl["card"].update({
    "status_arch_off": "Off in network settings",
    "off_arch_sa_title": "5G SA is turned off",
    "off_arch_sa_body": "5G Architecture is set to NSA only, so the modem ignores 5G SA bands. SA band locks won't apply until you set it to Auto or SA only.",
    "off_arch_nsa_title": "5G NSA is turned off",
    "off_arch_nsa_body": "5G Architecture is set to SA only, so the modem ignores 5G NSA bands. NSA band locks won't apply until you set it to Auto or NSA only.",
    "off_lte_only_title": "5G is turned off",
    "off_lte_only_body": "Preferred Network Type is set to LTE only, so the modem does not use 5G. 5G band locks won't apply until you change it.",
    "off_nr_only_title": "LTE is turned off",
    "off_nr_only_body": "Preferred Network Type is set to 5G only, so the modem does not use LTE (and 5G NSA, which needs an LTE anchor). These band locks won't apply until you change it.",
    "arch_off_action": "Open network settings",
})
bl["live"].update({
    "absent_nr_body_nsa_only": "5G Architecture is set to NSA only, so standalone 5G cells are not used. If your carrier offers 5G only as standalone, set it to Auto.",
    "absent_nr_body_lte_only": "Preferred Network Type is set to LTE only, so the modem does not use 5G.",
    "settings_link": "Network mode settings",
})
loc.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
