#!/usr/bin/env python3
"""Overlay the experimental selective video path onto exact v0.1.16 anchors."""
from pathlib import Path
import shutil
import sys

target, templates, vendor = map(Path, sys.argv[1:])

def edit(rel, old, new):
    p = target / rel
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"Selective-video patch anchor changed: {rel}: {old[:90]!r}")
    p.write_text(text.replace(old, new, 1))

binary = vendor / "scripts/usr/bin/qmanager_video_selective"
if not binary.is_file():
    raise SystemExit("Build video-selective/build-video-selective-cfw3212.sh before conversion")
shutil.copy2(binary, target / "scripts/usr/bin/qmanager_video_selective")
(target / "scripts/usr/bin/qmanager_video_selective").chmod(0o755)
for rel in ["components/local-network/traffic-engine/video-scope-card.tsx", "hooks/use-video-scope.ts"]:
    shutil.copy2(templates / rel, target / rel)

# Casa video defaults must not classify speed tests or whole shared CDNs.
# Preserve the live list; Reset targets uses this separate factory copy.
setup = target / "scripts/usr/bin/qmanager_setup"
setup_text = setup.read_text()
start = setup_text.index("# Seed the default Video Optimizer hostlist if missing.")
end = setup_text.index("# Initialize default JSON config if missing", start)
# Upgrades keep the live list. A list still identical to upstream's old seed
# (speed-test sites, whole shared CDNs) would pull ordinary traffic into the
# proxy in Narrow, so only that untouched list is swapped for Casa targets.
seed_start = setup_text.index("cat > \"$DPI_HOSTLIST\" << 'EOF'\n", start)
seed = setup_text[seed_start:setup_text.index("\nEOF\n", seed_start)].splitlines()[1:]
upstream_seed = " ".join(sorted(l.strip() for l in seed if l.strip() and not l.lstrip().startswith("#")))
if "googlevideo.com" not in upstream_seed or "speedtest.net" not in upstream_seed:
    raise SystemExit("Upstream Video Optimizer seed list changed")
defaults = """# Casa selective-video targets: bare media CDN domains, subdomains included.
# Add other services' actual media domains in the UI after checking them.
googlevideo.com
nflxvideo.net
"""
setup.write_text(setup_text[:start] + '''# Seed focused Casa video targets only when the live list is missing.
# Existing custom and legacy lists are preserved; use Reset targets explicitly.
DPI_HOSTLIST="/etc/qmanager/video_domains.txt"
if [ -f "$DPI_HOSTLIST" ] && [ "$(sed -e 's/[[:space:]]//g' -e '/^#/d' -e '/^$/d' "$DPI_HOSTLIST" | LC_ALL=C sort | tr '\\n' ' ' | sed 's/ $//')" = "''' + upstream_seed + '''" ]; then
    # Untouched upstream seed from an older install: replace with Casa targets.
    rm -f "$DPI_HOSTLIST"
fi
if [ ! -f "$DPI_HOSTLIST" ]; then
    cat > "$DPI_HOSTLIST" << 'CASA_VIDEO_DEFAULTS'
''' + defaults + '''CASA_VIDEO_DEFAULTS
    chown www-data:www-data "$DPI_HOSTLIST"
    chmod 644 "$DPI_HOSTLIST"
fi
# The factory copy is always the Casa list, never a copy of a custom live list.
cat > "/etc/qmanager/video_domains_default.txt" << 'CASA_VIDEO_DEFAULTS'
''' + defaults + '''CASA_VIDEO_DEFAULTS
chown www-data:www-data "/etc/qmanager/video_domains_default.txt"
chmod 644 "/etc/qmanager/video_domains_default.txt"

''' + setup_text[end:])

runner = "scripts/usr/bin/qmanager_dpi_run"
edit(runner, '    --clear)\n', '''    --clear-selective)
        exec /usrdata/bin/qmanager_video_selective --clear
        ;;
    --clear)
''')
edit(runner, '        if ! dpi_apply_rule; then\n', '''        if dpi_narrow_active; then
            dpi_remove_rule_upstream
            dpi_remove_force_tcp_rule
            qlog_info "run: starting Casa selective video DNS/routing supervisor (Narrow)"
            exec /usrdata/bin/qmanager_video_selective --hostlist="$DPI_HOSTLIST" --tpws="$DPI_BINARY" --proxy-port="$DPI_PORT"
        fi
        if ! dpi_apply_rule; then
''')

lib = target / "scripts/usr/lib/qmanager/dpi_state.sh"
text = lib.read_text()
for name in ["dpi_apply_rule", "dpi_remove_rule", "dpi_rule_present", "dpi_packets_processed", "dpi_reconcile_force_tcp"]:
    old = f"{name}() {{"
    if text.count(old) != 1:
        raise SystemExit(f"Selective-video function anchor changed: {name}")
    text = text.replace(old, f"{name}_upstream() {{", 1)
# Upstream modes start tpws without --user, so it drops to UID 2147483647 and
# cannot read the www-data 0640 target list on installed boxes (exits 1).
# The Narrow helper already passes --user=www-data; do the same here.
bind_args = '"--port=$DPI_PORT --bind-addr=$DPI_BIND_ADDR"'
if text.count(bind_args) != 2:
    raise SystemExit("Selective-video tpws argument anchors changed")
text = text.replace(bind_args, '"--port=$DPI_PORT --bind-addr=$DPI_BIND_ADDR --user=www-data"')
text += '''
# Casa Video Optimizer scope: narrow (default) = only DNS-learned video
# addresses enter tpws; broad = upstream's all bridge0 TCP 80/443 redirect.
dpi_vo_scope() {
    case "$(qm_config_get video_optimizer scope narrow)" in
        broad) echo broad ;;
        *) echo narrow ;;
    esac
}
dpi_narrow_active() {
    [ "$(dpi_active_mode)" = "video_optimizer" ] && [ "$(dpi_vo_scope)" = "narrow" ]
}
# Casa experimental: helper owns destination-only rules in Narrow.
# Never grant the helper to CGI sudoers: only the root systemd runner executes it.
run_iptables() {
    if [ "$(id -u)" = "0" ]; then
        iptables "$@"
    else
        $_SUDO /usrdata/bin/qmanager_iptables "$@"
    fi
}
dpi_apply_rule() {
    if dpi_narrow_active; then
        dpi_remove_rule_upstream
        dpi_remove_force_tcp_rule
        return 0
    fi
    dpi_apply_rule_upstream
}
dpi_rule_present() {
    if dpi_narrow_active; then
        [ "$(dpi_service_status)" = "running" ] && jq -e '.state == "running"' /run/qmanager-video-selective/status.json >/dev/null 2>&1
    else
        dpi_rule_present_upstream
    fi
}
dpi_packets_processed() {
    if dpi_narrow_active; then
        jq -r '.connections // 0' /run/qmanager-video-selective/status.json 2>/dev/null || echo 0
    else
        dpi_packets_processed_upstream
    fi
}
dpi_remove_rule() {
    dpi_remove_rule_upstream
    if [ "$(id -u)" = "0" ]; then
        /usrdata/bin/qmanager_video_selective --clear
    fi
}
dpi_reconcile_force_tcp() {
    if dpi_narrow_active; then
        dpi_remove_force_tcp_rule
    else
        dpi_reconcile_force_tcp_upstream
    fi
}
'''
lib.write_text(text)

unit = "scripts/etc/systemd/system/qmanager-dpi.service"
edit(unit, 'RestartSec=5\n', '''RestartSec=5
ExecStopPost=/usrdata/bin/qmanager_dpi_run --clear-selective
TimeoutStopSec=20
Environment=GOMEMLIMIT=24MiB
''')

edit(runner, '    --clear-selective)\n        exec /usrdata/bin/qmanager_video_selective --clear\n', '''    --clear-selective)
        dpi_remove_rule_upstream
        exec /usrdata/bin/qmanager_video_selective --clear
''')

edit(runner, '        dpi_reconcile_force_tcp\n', '''        if ! dpi_narrow_active; then
            /usrdata/bin/qmanager_video_selective --clear || qlog_warn "ensure: selective cleanup incomplete"
        fi
        dpi_reconcile_force_tcp
''')

# Existing Casa installer rewrites /usr/bin and /usr/lib/qmanager at install
# time. Only the missing, fixed-verb tpws installer grant is added here.
sudoers = target / "scripts/etc/sudoers.d/qmanager"
sudoers.write_text(sudoers.read_text() + '''
# Selective Video Optimizer: verified tpws provisioning only, no arbitrary args.
www-data ALL=(root) NOPASSWD: /usrdata/bin/qmanager_dpi_install install, /usrdata/bin/qmanager_dpi_install uninstall, /usrdata/bin/qmanager_dpi_install --probe
''')

cgi = "scripts/www/cgi-bin/quecmanager/network/video_optimizer.sh"
# Casa CGIs run as root: platform.sh intentionally leaves _SUDO empty.
# A unconditional "$_SUDO -n helper" then tries to execute "-n" itself.
# Keep the fixed installer probe direct for root and noninteractive for sudo.
edit(cgi, 'qlog_init "cgi_video_optimizer"\n', '''dpi_installer_probe() {
    if [ -n "$_SUDO" ]; then
        "$_SUDO" -n /usr/bin/qmanager_dpi_install --probe
    else
        /usr/bin/qmanager_dpi_install --probe
    fi
}

qlog_init "cgi_video_optimizer"
''')
cgi_path = target / cgi
cgi_text = cgi_path.read_text()
probe = 'if ! $_SUDO -n /usr/bin/qmanager_dpi_install --probe >/dev/null 2>&1; then'
if cgi_text.count(probe) != 2:
    raise SystemExit("Selective-video installer preflight anchors changed")
cgi_path.write_text(cgi_text.replace(probe, 'if ! dpi_installer_probe >/dev/null 2>&1; then'))
edit(cgi, '        hostlist)\n', '''        selective_status)
            if [ -r /run/qmanager-video-selective/status.json ] && jq -e '.state == "cleanup_error"' /run/qmanager-video-selective/status.json >/dev/null 2>&1; then
                jq -c . /run/qmanager-video-selective/status.json
            elif dpi_narrow_active && [ "$(dpi_service_status)" = "running" ] && [ -r /run/qmanager-video-selective/status.json ]; then
                jq -c . /run/qmanager-video-selective/status.json
            else
                echo '{"state":"off","dns_queries":0,"selected_replies":0,"addresses":0,"errors":0,"ipv4_only":true}'
            fi
            exit 0
            ;;
        hostlist)
''')

edit(cgi, '''    if [ "$1" = "full_bypass" ]; then
        printf '%s' "$json" | jq''', '''    json=$(printf '%s' "$json" | jq -c --arg scope "$(dpi_vo_scope)" '. + {scope: $scope}')
    if [ "$1" = "full_bypass" ]; then
        printf '%s' "$json" | jq''')
edit(cgi, '        save_force_tcp)\n', '''        save_scope)
            # Casa: Narrow/Broad scope of Video Optimizer. Restart the engine
            # only when Video Optimizer owns it; ExecStopPost clears both paths.
            SCOPE=$(printf '%s' "$POST_DATA" | jq -r '.scope // empty' 2>/dev/null)
            case "$SCOPE" in
                narrow|broad) ;;
                *) cgi_error "invalid_scope" "scope must be narrow or broad"; exit 0 ;;
            esac
            qm_config_set video_optimizer scope "$SCOPE"
            qlog_info "save_scope: scope=$SCOPE"
            if [ "$(dpi_active_mode)" = "video_optimizer" ]; then
                svc_restart qmanager-dpi
            fi
            cgi_success
            exit 0
            ;;
        save_force_tcp)
''')

# Pin tpws to the verified zapret release; never install "latest".
installer = "scripts/usr/bin/qmanager_dpi_install"
edit(installer, 'RELEASE_URL="$API_BASE/releases/latest"', 'RELEASE_URL="$API_BASE/releases/tags/$DPI_DEFAULT_TAG"')
edit(installer, '_dpi_marker_running "Resolving latest zapret release..."', '_dpi_marker_running "Resolving zapret $DPI_DEFAULT_TAG release..."')

page = "components/local-network/traffic-engine/traffic-engine.tsx"
edit(page, 'import ForceTcpCard from "./force-tcp-card";', 'import ForceTcpCard from "./force-tcp-card";\nimport VideoScopeCard from "./video-scope-card";\nimport { useVideoScope } from "@/hooks/use-video-scope";')
edit(page, '  const hostlist = useCdnHostlist();\n', '  const hostlist = useCdnHostlist();\n  // Casa: Narrow/Broad scope of Video Optimizer (video_optimizer.scope).\n  const videoScope = useVideoScope();\n')
edit(page, '''            <VerifyCard binaryInstalled={installed} />
''', '''            <div className={CARD_PAIR_WIDE}>
              <VideoScopeCard
                mode={mode}
                scope={videoScope.scope}
                isSaving={videoScope.isSaving}
                onScopeChange={(next) => {
                  void videoScope.saveScope(next).then((ok) => {
                    if (!ok) toast.error("Couldn't change the Video Optimizer scope");
                  });
                }}
                forceTcp={videoOptimizer.data?.force_tcp}
              />
            </div>

            <VerifyCard binaryInstalled={installed} />
''')
# Narrow pauses the global Force-TCP rule (the helper rejects UDP 443 per
# learned address), so its toggle is hidden there; Broad and Off keep it.
edit(page, '        <ForceTcpCard />', '        {mode === "video_optimizer" && videoScope.scope !== "broad" ? null : <ForceTcpCard />}')

# English labels match the scope card's comparison chart.
locale = "public/locales/en/common.json"
edit(locale, '"video_optimizer_hint": "Only connections matching your target list. Subdomains match too."',
     '"video_optimizer_hint": "Target-list sites get the bypass trick. Choose Narrow or Broad below."')
edit(locale, '"full_bypass_hint": "Every TCP 80/443 connection. No target list, so nothing to configure."',
     '"full_bypass_hint": "All web traffic (TCP 80/443) goes through the proxy and every site gets the trick. High CPU."')
edit(locale, '"description": "Domains the engine desyncs. Saved changes apply immediately, with no restart."',
     '"description": "Bare domains only, like googlevideo.com (no https:// or paths); subdomains match. Narrow: only these sites use the proxy. Broad: these sites get the trick."')

print("Casa selective video: DNS-before-answer IPv4 routing, root supervisor, setup/status UI, scoped QUIC, stop cleanup")
