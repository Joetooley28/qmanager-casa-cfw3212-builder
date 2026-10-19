#!/usr/bin/env python3
"""Bypass benefit test: show what Narrow / Broad / Full bypass give you.

Upstream's test compares one Netflix-CDN download direct vs through a
temporary tpws proxy, plus a direct reference (speedtest.net / Cloudflare).
It never measures ordinary (non-video) traffic through the bypass, which is
what Broad costs (Box 2 field test 2026-10-12: Narrow kept ordinary HTTPS at
491 Mbps, Broad 25-49). This adds Cloudflare HTTPS (port 443, what Broad
redirects) direct and through the same temporary proxy, records the live
engine setting, and has the card say what the current setting gives. The
speedtest.net reference stays as Line speed: its plain-HTTP port 8080 server
breaks under the proxy's HTTP tampering (Box 2, 2026-10-18) and Broad never
redirects 8080.
"""
import json
from pathlib import Path
import sys

target = Path(sys.argv[1])
pending = {}


def swap(rel, old, new):
    text = pending.get(rel, (target / rel).read_text())
    if new in text:
        return
    if text.count(old) != 1:
        raise SystemExit(f"Verify scope patch: anchor changed in {rel}: {old[:70]!r}")
    pending[rel] = text.replace(old, new, 1)


V = "scripts/usr/bin/qmanager_dpi_verify"
# Reference sampler can run through the temporary proxy.
swap(V, '''    local url t0 out bw size tt total_size total_time it now
    url="$1"
''', '''    local url socks t0 out bw size tt total_size total_time it now
    url="$1"
    socks="${2:-}"
''')
swap(V, '''        out=$(curl -ksS -m 30 \\
            -o /dev/null -w '%{speed_download} %{size_download} %{time_total}' "$url" 2>/dev/null) || true''',
     '''        out=$(curl -ksS -m 30 \\
            ${socks:+--socks5-hostname "127.0.0.1:$socks"} \\
            -o /dev/null -w '%{speed_download} %{size_download} %{time_total}' "$url" 2>/dev/null) || true''')
swap(V, '''    local url without_mbps with_mbps reference_mbps reference_source
''', '''    local url without_mbps with_mbps reference_mbps reference_source
    local other_bypass_mbps other_direct_mbps other_json direct_json applied_mode obw
''')
# Phase 3 while the temporary proxy is still up.
swap(V, '''    bw=$(_dpi_curl_bw "$url" "$DPI_SOCKS_PORT") || bw=$(_dpi_curl_bw "$url" "$DPI_SOCKS_PORT")
    _dpi_socks_stop''', '''    bw=$(_dpi_curl_bw "$url" "$DPI_SOCKS_PORT") || bw=$(_dpi_curl_bw "$url" "$DPI_SOCKS_PORT")
    # Casa: ordinary HTTPS (Cloudflare, port 443) through the same proxy, then direct.
    qlog_info "verify: phase 3 (ordinary HTTPS, with and without bypass)"
    other_bypass_mbps=""
    other_direct_mbps=""
    obw=$(_dpi_reference_bw "$DPI_REF_CLOUDFLARE_URL" "$DPI_SOCKS_PORT") || obw=""
    [ -n "$obw" ] && other_bypass_mbps=$(awk -v b="$obw" 'BEGIN { printf "%.1f", b * 8 / 1000000 }')
    if [ "$reference_source" = "cloudflare" ] && [ -n "$reference_mbps" ]; then
        other_direct_mbps="$reference_mbps"
    else
        obw=$(_dpi_reference_bw "$DPI_REF_CLOUDFLARE_URL") || obw=""
        [ -n "$obw" ] && other_direct_mbps=$(awk -v b="$obw" 'BEGIN { printf "%.1f", b * 8 / 1000000 }')
    fi
    _dpi_socks_stop''')
swap(V, '''        ref_json="null"
    fi
''', '''        ref_json="null"
    fi
    other_json="null"
    direct_json="null"
    [ -n "$other_bypass_mbps" ] && other_json=$(jq -n --argjson s "$other_bypass_mbps" '{speed_mbps:$s}')
    [ -n "$other_direct_mbps" ] && direct_json=$(jq -n --argjson s "$other_direct_mbps" '{speed_mbps:$s}')
    case "$(dpi_active_mode)" in
        video_optimizer) applied_mode=$(dpi_vo_scope) ;;
        full_bypass) applied_mode="full_bypass" ;;
        *) applied_mode="off" ;;
    esac
''')
swap(V, '''        --argjson refj "$ref_json" \\
''', '''        --argjson refj "$ref_json" \\
        --argjson obj "$other_json" \\
        --argjson odj "$direct_json" \\
        --arg mode "$applied_mode" \\
''')
swap(V, "reference:$refj,improvement:$imp}')\"",
     "reference:$refj,improvement:$imp,ordinary_direct:$odj,ordinary_bypass:$obj,applied_mode:$mode}')\"")
swap(V, '''    qlog_info "verify: complete without=${without_mbps}Mbps with=${with_mbps}Mbps reference=${reference_mbps:-n/a}Mbps"''',
     '''    qlog_info "verify: complete without=${without_mbps}Mbps with=${with_mbps}Mbps reference=${reference_mbps:-n/a}Mbps other_direct=${other_direct_mbps:-n/a}Mbps other_bypass=${other_bypass_mbps:-n/a}Mbps mode=$applied_mode"''')

# The status endpoint passes only listed fields; add the new ones.
G = "scripts/www/cgi-bin/quecmanager/network/video_optimizer.sh"
swap(G, "improvement:$body.improvement,message:$body.message",
     "improvement:$body.improvement,ordinary_direct:$body.ordinary_direct,ordinary_bypass:$body.ordinary_bypass,applied_mode:$body.applied_mode,message:$body.message")

T = "types/traffic-engine.ts"
swap(T, '''  improvement?: string;
  message?: string;''', '''  improvement?: string;
  /** Casa: ordinary HTTPS (Cloudflare) direct and through the temporary proxy. */
  ordinary_direct?: { speed_mbps: number } | null;
  ordinary_bypass?: { speed_mbps: number } | null;
  /** Casa: live engine setting when the test ran. */
  applied_mode?: "narrow" | "broad" | "full_bypass" | "off";
  message?: string;''')

C = "components/local-network/traffic-engine/verify-card.tsx"
swap(C, '''  const reference = result?.reference ?? null;
''', '''  const reference = result?.reference ?? null;
  const otherDirect = result?.ordinary_direct ?? null;
  const otherBypass = result?.ordinary_bypass ?? null;
  const appliedMode = result?.applied_mode;
''')
swap(C, '''    reference?.speed_mbps ?? 0,
  );''', '''    reference?.speed_mbps ?? 0,
    otherDirect?.speed_mbps ?? 0,
    otherBypass?.speed_mbps ?? 0,
  );''')
cloudflareTag = '''<Tag variant="neutral">{t("trafficEngine.verify.source_cloudflare")}</Tag>'''
swap(C, '''              {reference ? (
                <ComparisonRow
                  label={t("trafficEngine.verify.line_speed")}''', '''              {otherDirect ? (
                <ComparisonRow
                  label={t("trafficEngine.verify.other_direct")}
                  speed={otherDirect.speed_mbps}
                  scaleMax={scaleMax}
                  winner={false}
                  index={2}
                  verdict={''' + cloudflareTag + '''}
                />
              ) : null}
              {otherBypass ? (
                <ComparisonRow
                  label={t("trafficEngine.verify.other_bypass")}
                  speed={otherBypass.speed_mbps}
                  scaleMax={scaleMax}
                  winner={false}
                  index={3}
                  verdict={''' + cloudflareTag + '''}
                />
              ) : null}
              {reference ? (
                <ComparisonRow
                  label={t("trafficEngine.verify.line_speed")}''')
swap(C, '''              ) : null}
            </motion.ul>
''', '''              ) : null}
            </motion.ul>

            {/* Casa: what the live setting gives for video and other traffic. */}
            {appliedMode && otherDirect ? (
              <div className="flex flex-col gap-1 text-sm">
                <p className="font-medium">
                  {appliedMode === "narrow"
                    ? t("trafficEngine.verify.setting_narrow", { video: bypassed.speed_mbps, other: otherDirect.speed_mbps })
                    : appliedMode === "off"
                      ? t("trafficEngine.verify.setting_off", { video: without.speed_mbps, other: otherDirect.speed_mbps })
                      : t(appliedMode === "broad" ? "trafficEngine.verify.setting_broad" : "trafficEngine.verify.setting_full", {
                          video: bypassed.speed_mbps,
                          other: otherBypass ? otherBypass.speed_mbps : "—",
                        })}
                </p>
                {appliedMode === "narrow" && otherBypass ? (
                  <p className="text-on-surface-variant">
                    {t("trafficEngine.verify.hint_broad", { other: otherBypass.speed_mbps })}
                  </p>
                ) : appliedMode === "broad" || appliedMode === "full_bypass" ? (
                  <p className="text-on-surface-variant">
                    {t("trafficEngine.verify.hint_narrow", { other: otherDirect.speed_mbps })}
                  </p>
                ) : null}
              </div>
            ) : null}
''')

loc = "public/locales/en/common.json"
data = json.loads((target / loc).read_text())
v = data["trafficEngine"]["verify"]
updates = {
    "description": "Measures whether the bypass speeds up a video server and what it costs other traffic, then shows what your Narrow or Broad setting gives you. It uses its own temporary proxy, so it doesn't check the engine you have running.",
    "progress": "Downloading a video file and a regular file, each once direct and once through a temporary proxy, plus a line-speed sample. This takes a few minutes.",
    "without": "Video, direct",
    "with": "Video, through bypass",
    "other_direct": "Other traffic, direct",
    "other_bypass": "Other traffic, through bypass",
    "footnote": "Line speed is the reference: if every row is slow, the connection is slow, not throttled.",
    "setting_narrow": "Your setting, Narrow: video {{video}} Mbps through the bypass, other traffic {{other}} Mbps direct.",
    "setting_broad": "Your setting, Broad: video {{video}} Mbps and other traffic {{other}} Mbps, both through the bypass.",
    "setting_full": "Your setting, Full bypass: video {{video}} Mbps and other traffic {{other}} Mbps, both through the bypass.",
    "setting_off": "The engine is off: video {{video}} Mbps and other traffic {{other}} Mbps, both direct.",
    "hint_broad": "Broad would send other traffic through the bypass too: {{other}} Mbps.",
    "hint_narrow": "Narrow would keep other traffic direct: {{other}} Mbps.",
}
if any(v.get(k) != val for k, val in updates.items()):
    v.update(updates)
    pending[loc] = json.dumps(data, ensure_ascii=False, indent=2) + "\n"

# Scope toggle: on the Video Optimizer row when the row is wide, below it when narrow.
M = "components/local-network/traffic-engine/mode-card.tsx"
swap(M, '''              <div key={entry.mode} className="relative">''',
     '''              <div key={entry.mode} className="@container/vorow relative">''')
# Reserve the toggle's width on the text, so the row's right glyph keeps its place.
swap(M, '''                <span className={CHOICE_ROW.TEXT}>
                  <span className={CHOICE_ROW.NAME}>{t(entry.nameKey)}</span>''',
     '''                <span className={cn(CHOICE_ROW.TEXT, entry.mode === "video_optimizer" && scopeSlot && "@xl/vorow:pr-56")}>
                  <span className={CHOICE_ROW.NAME}>{t(entry.nameKey)}</span>''')

for rel, text in pending.items():
    (target / rel).write_text(text)
print("Verify scope: ordinary-traffic leg, live setting summary, adaptive scope toggle")
