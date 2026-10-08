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
rel = "components/local-network/traffic-engine/selective-setup-card.tsx"
shutil.copy2(templates / rel, target / rel)

runner = "scripts/usr/bin/qmanager_dpi_run"
edit(runner, '    --clear)\n', '''    --clear-selective)
        /usrdata/bin/qmanager_video_selective --clear
        exit 0
        ;;
    --clear)
''')
edit(runner, '        if ! dpi_apply_rule; then\n', '''        if [ "$(dpi_active_mode)" = "video_optimizer" ]; then
            dpi_remove_rule_upstream
            dpi_remove_force_tcp_rule
            qlog_info "run: starting Casa selective video DNS/routing supervisor"
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
text += '''
# Casa experimental: helper owns destination-only rules in video mode.
# Never grant the helper to CGI sudoers: only the root systemd runner executes it.
run_iptables() {
    if [ "$(id -u)" = "0" ]; then
        iptables "$@"
    else
        $_SUDO /usrdata/bin/qmanager_iptables "$@"
    fi
}
dpi_apply_rule() {
    if [ "$(dpi_active_mode)" = "video_optimizer" ]; then
        dpi_remove_rule_upstream
        dpi_remove_force_tcp_rule
        return 0
    fi
    dpi_apply_rule_upstream
}
dpi_rule_present() {
    if [ "$(dpi_active_mode)" = "video_optimizer" ]; then
        [ "$(dpi_service_status)" = "running" ] && jq -e '.state == "running"' /run/qmanager-video-selective/status.json >/dev/null 2>&1
    else
        dpi_rule_present_upstream
    fi
}
dpi_packets_processed() {
    if [ "$(dpi_active_mode)" = "video_optimizer" ]; then
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
    if [ "$(dpi_active_mode)" = "video_optimizer" ]; then
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

edit(runner, '    --clear-selective)\n        /usrdata/bin/qmanager_video_selective --clear\n', '''    --clear-selective)
        dpi_remove_rule_upstream
        /usrdata/bin/qmanager_video_selective --clear
''')

# Existing Casa installer rewrites /usr/bin and /usr/lib/qmanager at install
# time. Only the missing, fixed-verb tpws installer grant is added here.
sudoers = target / "scripts/etc/sudoers.d/qmanager"
sudoers.write_text(sudoers.read_text() + '''
# Selective Video Optimizer: verified tpws provisioning only, no arbitrary args.
www-data ALL=(root) NOPASSWD: /usrdata/bin/qmanager_dpi_install install, /usrdata/bin/qmanager_dpi_install uninstall, /usrdata/bin/qmanager_dpi_install --probe
''')

cgi = "scripts/www/cgi-bin/quecmanager/network/video_optimizer.sh"
edit(cgi, '        hostlist)\n', '''        selective_status)
            if [ "$(dpi_active_mode)" = "video_optimizer" ] && [ "$(dpi_service_status)" = "running" ] && [ -r /run/qmanager-video-selective/status.json ]; then
                jq -c . /run/qmanager-video-selective/status.json
            else
                echo '{"state":"off","dns_queries":0,"selected_replies":0,"addresses":0,"errors":0,"ipv4_only":true}'
            fi
            exit 0
            ;;
        hostlist)
''')

page = "components/local-network/traffic-engine/traffic-engine.tsx"
edit(page, 'import ForceTcpCard from "./force-tcp-card";', 'import ForceTcpCard from "./force-tcp-card";\nimport SelectiveSetupCard from "./selective-setup-card";')
edit(page, '        <ForceTcpCard />', '        {mode === "video_optimizer" ? null : <ForceTcpCard />}\n        <SelectiveSetupCard mode={mode} />')

print("Casa selective video: DNS-before-answer IPv4 routing, root supervisor, setup/status UI, scoped QUIC, stop cleanup")
