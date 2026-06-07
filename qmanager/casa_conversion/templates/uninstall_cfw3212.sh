#!/bin/sh
set -e

info() { echo "  ✓  $*"; }
warn() { echo "  !  $*"; }
step() { printf "\n▶ %s\n" "$*"; }

NO_REBOOT=0
PURGE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-reboot) NO_REBOOT=1 ;;
        --purge) PURGE=1 ;;
        --force) ;;
    esac
    shift
done

SERVICES="qmanager-lighttpd lighttpd \
    qmanager-poller qmanager-ping qmanager-firewall qmanager-setup \
    qmanager-ttl qmanager-mtu qmanager-imei-check qmanager-watchcat \
    qmanager-tower-failover qmanager-traffic qmanager-console \
    qmanager-discord qmanager-ethernet qmanager-cfun-fix \
    qmanager_tailscale_install"

step "Stopping QManager services"
systemctl stop --no-block $SERVICES 2>/dev/null \
    && info "Stop requested" \
    || warn "Some services were already stopped or missing"
sleep 2

step "Removing service units"
for svc in $SERVICES; do
    rm -f "/etc/systemd/system/$svc.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/$svc.service"
done
# Casa ships lighttpd masked behind its stock web service. Restore that state
# after removing any older QManager override unit.
systemctl mask lighttpd 2>/dev/null || true
info "QManager service units removed"

step "Removing stale QManager unit files"
find /etc/systemd/system /etc/systemd/system/multi-user.target.wants \
    -maxdepth 1 \( -name 'qmanager*.service' -o -name 'qmanager_*.service' \) \
    -exec rm -f {} \; 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
info "systemd reloaded"

step "Removing QManager files"
rm -rf /usrdata/qmanager
rm -f /usrdata/bin/qmanager_* \
    /usrdata/bin/qcmd \
    /usrdata/bin/atcli_smd11 \
    /usrdata/bin/sms_tool \
    /usrdata/bin/jq \
    /usrdata/bin/sudo \
    /usrdata/bin/speedtest
info "Install files removed"

step "Removing temporary QManager state"
rm -rf /tmp/qmanager_install \
    /tmp/qmanager_update \
    /tmp/qmanager_update_stage \
    /tmp/qmanager-cfw3212-install \
    /tmp/qmanager-cfw3212-uninstall \
    /tmp/qmanager_sessions \
    /tmp/qmanager.tar.gz \
    /tmp/qmanager_staged.tar.gz \
    /tmp/qmanager_staged_version \
    /tmp/qmanager_update.json \
    /tmp/qmanager_update.log \
    /tmp/qmanager_update.pid \
    /tmp/qmanager_status.json \
    /tmp/qmanager_status.json.tmp \
    /tmp/qmanager_* \
    /tmp/qmanager-* \
    /tmp/qmanager.log* \
    /tmp/entware-packages.gz \
    /tmp/entware-packages.txt \
    /tmp/qmipk.* \
    /tmp/qm_cfw3212_update_api_body.json \
    /tmp/qm_cfw3212_update_api_headers.txt \
    /tmp/ookla_speedtest_*.tgz \
    /tmp/speedtest \
    /run/qmanager*.pid \
    /var/lock/qmanager.pid 2>/dev/null || true
info "Temporary files removed"

if [ "$PURGE" = "1" ]; then
    step "Purging optional QManager-installed tools"
    systemctl stop --no-block tailscaled 2>/dev/null || true
    rm -f /etc/systemd/system/tailscaled.service \
        /etc/systemd/system/multi-user.target.wants/tailscaled.service \
        /usr/bin/tailscale \
        /usrdata/root/bin/tailscale \
        /usrdata/overlay/rwdata/data/usr/bin/tailscale 2>/dev/null || true
    rm -rf /usrdata/tailscale \
        /etc/tailscale \
        /usrdata/overlay/rwdata/data/var/lib/tailscale \
        /usrdata/overlay/rwdata/data/root/.config/ookla \
        /tmp/tailscaled-log-* 2>/dev/null || true
    # Email Alerts helper (msmtp) is installed under both /usrdata/bin and the
    # Entware tree; remove both copies. /usrdata/opt/bin/msmtp is also covered by
    # the /usrdata/opt purge below, but /usrdata/bin/msmtp would otherwise survive.
    rm -f /usrdata/bin/msmtp /usrdata/opt/bin/msmtp 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed tailscaled 2>/dev/null || true
    info "Optional Tailscale/Ookla/msmtp state removed"

    step "Removing QManager DNS config from /etc/data/dnsmasq.conf"
    # QManager writes two managed blocks into Casa's persistent dnsmasq config:
    #   # QMANAGER-CUSTOM-DNS-BEGIN/END v1   (user-set Custom DNS upstreams)
    #   # QMANAGER-DNS-RECOVERY-BEGIN/END    (auto public 1.1.1.1/8.8.8.8 fallback,
    #                                         with no-resolv, when carrier DNS is down)
    # Left behind, these keep forcing the router/LAN resolver after QManager is
    # gone, with no UI to manage them. Strip both on --purge and restart dnsmasq.
    DNSMASQ_CONF="/etc/data/dnsmasq.conf"
    if [ -f "$DNSMASQ_CONF" ] && grep -qE '^# QMANAGER-(CUSTOM-DNS|DNS-RECOVERY)-BEGIN' "$DNSMASQ_CONF"; then
        DNS_TMP="$(mktemp /tmp/qmanager-dnsmasq.purge.XXXXXX 2>/dev/null || echo "/tmp/qmanager-dnsmasq.purge.$$")"
        if awk '
            /^# QMANAGER-CUSTOM-DNS-BEGIN/   { skip = 1; next }
            /^# QMANAGER-CUSTOM-DNS-END/     { skip = 0; next }
            /^# QMANAGER-DNS-RECOVERY-BEGIN/ { skip = 1; next }
            /^# QMANAGER-DNS-RECOVERY-END/   { skip = 0; next }
            skip != 1 { print }
        ' "$DNSMASQ_CONF" > "$DNS_TMP"; then
            cp "$DNSMASQ_CONF" "$DNSMASQ_CONF.bak-qmanager-purge-$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
            cat "$DNS_TMP" > "$DNSMASQ_CONF"
            chown radio:radio "$DNSMASQ_CONF" 2>/dev/null || true
            chmod 0644 "$DNSMASQ_CONF" 2>/dev/null || true
            systemctl restart dnsmasq_service@0.service 2>/dev/null || true
            info "QManager Custom DNS / public-fallback blocks removed; dnsmasq restarted"
        else
            info "Could not rewrite $DNSMASQ_CONF; left unchanged"
        fi
        rm -f "$DNS_TMP"
    else
        info "No QManager DNS blocks present in $DNSMASQ_CONF"
    fi

    step "Purging preserved config and bundled Entware state"
    # Remove only include lines written by this installer. The bundled Entware
    # sudoers file is ours; /etc/sudoers may contain a pre-existing include.
    if [ -f /usrdata/opt/etc/sudoers ]; then
        sed -i '\|^#includedir /usrdata/opt/etc/sudoers\.d\( # qmanager-cfw3212\)\?$|d' \
            /usrdata/opt/etc/sudoers
    fi
    if [ -f /etc/sudoers ]; then
        sed -i '\|^#includedir /etc/sudoers\.d # qmanager-cfw3212$|d' /etc/sudoers
    fi
    rm -f /etc/sudoers.d/qmanager /usrdata/opt/etc/sudoers.d/qmanager 2>/dev/null || true
    rm -rf /etc/qmanager /usrdata/opt
    if [ -L /opt ] && [ "$(readlink /opt 2>/dev/null || true)" = "/usrdata/opt" ]; then
        rm -f /opt
    fi
    info "Purge cleanup complete"
fi

step "Clearing old systemd status"
systemctl reset-failed $SERVICES 2>/dev/null || true
info "Old systemd status cleared"

echo "Casa CFW-3212 QManager files removed."
if [ "$NO_REBOOT" != "1" ]; then
    echo "Restart the device when ready."
fi
