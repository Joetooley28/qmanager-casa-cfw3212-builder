#!/bin/sh
set -e

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

for svc in lighttpd qmanager-poller qmanager-ping qmanager-firewall qmanager-setup qmanager-ttl qmanager-mtu qmanager-imei-check qmanager-watchcat qmanager-tower-failover; do
    systemctl disable --now "$svc.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/$svc.service"
done
systemctl daemon-reload 2>/dev/null || true

rm -rf /usrdata/qmanager
rm -f /usrdata/bin/qmanager_* /usrdata/bin/atcli_smd11 /usrdata/bin/sms_tool

if [ "$PURGE" = "1" ]; then
    rm -rf /etc/qmanager /usrdata/opt
fi

echo "Casa CFW-3212 QManager files removed."
if [ "$NO_REBOOT" != "1" ]; then
    echo "Restart the device when ready."
fi
