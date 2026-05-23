#!/usr/bin/env bash
set -euo pipefail

# Convert an upstream dr-dolomite/QManager-RM520N tag/release into a Casa
# CFW-3212 work tree and, when Bun/Node are available, build release artifacts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QMANAGER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_REF_DIR="$QMANAGER_DIR/qmanager_work_v0.1.9_casa"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/dr-dolomite/QManager-RM520N.git}"
UPSTREAM_API="${UPSTREAM_API:-https://api.github.com/repos/dr-dolomite/QManager-RM520N/releases}"
WORK_PREFIX="${WORK_PREFIX:-qmanager_work}"
CASA_BUILD="${CASA_BUILD:-1}"
CASA_PROFILE_AUTO_APPLY="${CASA_PROFILE_AUTO_APPLY:-0}"
export CASA_PROFILE_AUTO_APPLY

VERSION=""
REF_DIR="$DEFAULT_REF_DIR"
SKIP_FETCH=0
SKIP_BUILD=0
FORCE=0
KEEP_FETCH=0

usage() {
    cat <<'EOF'
Usage:
  bash qmanager/casa_conversion/build-casa-port.sh --version v0.1.9 [options]
  bash qmanager/casa_conversion/build-casa-port.sh --version latest [options]

Options:
  --version <tag>       Upstream tag/release to fetch, for example v0.1.9.
                        Use "latest" to select the newest app release that
                        has qmanager.tar.gz and sha256sum.txt assets.
  --ref-dir <path>      Casa reference tree to copy overlays from.
                        Default: qmanager/qmanager_work_v0.1.9_casa
  --skip-fetch          Use an existing target folder instead of fetching upstream.
  --skip-build          Apply patches and checks only; do not run Bun/build.sh.
  --force               Replace an existing qmanager_work_<version>_casa target.
  --keep-fetch          Keep temporary upstream fetch folder for inspection.
  -h, --help            Show this help.

Environment:
  UPSTREAM_REPO         Git repo URL. Default: dr-dolomite/QManager-RM520N.
  UPSTREAM_API          GitHub releases API. Default: dr-dolomite/QManager-RM520N.
  WORK_PREFIX           Folder prefix. Default: qmanager_work.
  CASA_BUILD            Casa build number suffix. Default: 1.
  CASA_PROFILE_AUTO_APPLY
                        Set to 1 to leave upstream ICCID-matched SIM profile
                        auto-apply enabled. Default: 0, disabled for Casa.
EOF
}

log() { printf '[casa-port] %s\n' "$*"; }
warn() { printf '[casa-port] WARN: %s\n' "$*" >&2; }
fail() { printf '[casa-port] ERROR: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --ref-dir)
            [ $# -ge 2 ] || fail "--ref-dir requires a value"
            REF_DIR="$2"
            shift 2
            ;;
        --skip-fetch)
            SKIP_FETCH=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        --keep-fetch)
            KEEP_FETCH=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

[ -n "$VERSION" ] || { usage; fail "--version is required"; }

resolve_latest_version() {
    local tmp py_bin
    tmp="$(mktemp /tmp/qmanager_upstream_releases.XXXXXX.json)"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$UPSTREAM_API?per_page=50" -o "$tmp" \
            || fail "Could not fetch upstream releases from $UPSTREAM_API"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$tmp" "$UPSTREAM_API?per_page=50" \
            || fail "Could not fetch upstream releases from $UPSTREAM_API"
    else
        fail "curl or wget is required to resolve --version latest"
    fi

    py_bin="$(command -v python3 || command -v python || true)"
    [ -n "$py_bin" ] || fail "python3/python is required to resolve --version latest"

    "$py_bin" - "$tmp" <<'PY'
import json
import re
import sys
from pathlib import Path

releases = json.loads(Path(sys.argv[1]).read_text())
for rel in releases:
    tag = rel.get("tag_name") or ""
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        continue
    assets = {asset.get("name") for asset in rel.get("assets", [])}
    if {"qmanager.tar.gz", "sha256sum.txt"}.issubset(assets):
        print(tag)
        raise SystemExit(0)
raise SystemExit(1)
PY
    local resolved_status=$?
    rm -f "$tmp"
    [ "$resolved_status" = "0" ] || fail "Could not find an upstream app release with qmanager.tar.gz and sha256sum.txt"
}

if [ "$VERSION" = "latest" ]; then
    VERSION="$(resolve_latest_version)"
    log "Resolved latest upstream app release: $VERSION"
fi

case "$VERSION" in
    v*) VERSION_NAME="$VERSION" ;;
    *) VERSION_NAME="v$VERSION" ;;
esac
CASA_VERSION_NAME="${VERSION_NAME}-cfw3212.${CASA_BUILD}"

if command -v cygpath >/dev/null 2>&1; then
    REF_DIR="$(cygpath -u "$REF_DIR")"
fi

[ -d "$REF_DIR" ] || fail "Casa reference tree not found: $REF_DIR"
[ -f "$REF_DIR/install_cfw3212.sh" ] \
    || [ -f "$QMANAGER_DIR/qmanager_work/install_cfw3212.sh" ] \
    || fail "Reference tree missing install_cfw3212.sh and no legacy fallback was found"

TARGET="$QMANAGER_DIR/${WORK_PREFIX}_${VERSION_NAME}_casa"
FETCH_ROOT="$QMANAGER_DIR/.casa_fetch"
FETCH_DIR="$FETCH_ROOT/QManager_${VERSION_NAME}"
REF_ABS="$(cd "$REF_DIR" && pwd)"
TARGET_ABS="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"

case "$(basename "$TARGET")" in
    ${WORK_PREFIX}_*_casa) ;;
    *) fail "Refusing unexpected target path: $TARGET" ;;
esac

copy_file() {
    local rel="$1"
    local src="$REF_DIR/$rel"
    local dst="$TARGET/$rel"
    [ -f "$src" ] || fail "Reference overlay missing: $rel"
    local src_abs dst_abs
    src_abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
    if [ -d "$(dirname "$dst")" ]; then
        dst_abs="$(cd "$(dirname "$dst")" && pwd)/$(basename "$dst")"
    else
        dst_abs=""
    fi
    if [ "$src_abs" = "$dst_abs" ]; then
        return 0
    fi
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
}

copy_file_or_fallback() {
    local rel="$1"
    local fallback="$2"
    if [ -f "$REF_DIR/$rel" ]; then
        copy_file "$rel"
        return
    fi
    [ -f "$fallback" ] || fail "Reference overlay missing: $rel"
    mkdir -p "$(dirname "$TARGET/$rel")"
    cp "$fallback" "$TARGET/$rel"
    sed -i 's/\r$//' "$TARGET/$rel" 2>/dev/null || true
}

copy_template_or_fallback() {
    local rel="$1"
    local template="$2"
    if [ -f "$template" ]; then
        mkdir -p "$(dirname "$TARGET/$rel")"
        cp "$template" "$TARGET/$rel"
        sed -i 's/\r$//' "$TARGET/$rel" 2>/dev/null || true
        return
    fi
    if [ -f "$REF_DIR/$rel" ]; then
        copy_file "$rel"
        return
    fi
    fail "Template/reference overlay missing: $rel"
}

patch_build_script() {
    local build="$TARGET/build.sh"
    [ -f "$build" ] || fail "Target missing build.sh"

    cat > "$build" <<'EOF'
#!/usr/bin/env bash
set -eu

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$ROOT_DIR/out"
SCRIPTS_DIR="$ROOT_DIR/scripts"
DEPS_DIR="$ROOT_DIR/dependencies"
BUILD_DIR="$ROOT_DIR/qmanager-build"
STAGING_DIR="$BUILD_DIR/qmanager_install"
ARCHIVE="$BUILD_DIR/qmanager.tar.gz"

step() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$1" >&2; exit 1; }

[ -d "$OUT_DIR" ] || fail "'out/' not found - run 'bun run build' first"
[ -d "$DEPS_DIR" ] || fail "'dependencies/' not found at repo root"
[ -f "$DEPS_DIR/atcli_smd11" ] || fail "Missing required binary: dependencies/atcli_smd11"
[ -f "$DEPS_DIR/sms_tool" ] || fail "Missing required binary: dependencies/sms_tool"
[ -f "$DEPS_DIR/jq.ipk" ] || fail "Missing required package: dependencies/jq.ipk"
DROPBEAR_IPK=$(ls "$DEPS_DIR"/dropbear_*.ipk 2>/dev/null | head -n1)
[ -n "$DROPBEAR_IPK" ] || fail "Missing required package: dependencies/dropbear_*.ipk"

step "Preparing staging directory..."
mkdir -p "$BUILD_DIR"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

step "Copying frontend build output..."
cp -r "$OUT_DIR" "$STAGING_DIR/out"
( cd "$OUT_DIR" && find . -type f -print | sort | while IFS= read -r f; do sha256sum "$f"; done ) \
    > "$STAGING_DIR/frontend.sha256"

step "Copying backend scripts..."
mkdir -p "$STAGING_DIR/scripts"
for item in "$SCRIPTS_DIR"/*; do
    name="$(basename "$item")"
    case "$name" in install_rm520n.sh|uninstall_rm520n.sh) continue ;; esac
    cp -r "$item" "$STAGING_DIR/scripts/$name"
done

step "Copying Casa install & uninstall scripts..."
cp "$ROOT_DIR/install_cfw3212.sh" "$STAGING_DIR/install_cfw3212.sh"
cp "$ROOT_DIR/uninstall_cfw3212.sh" "$STAGING_DIR/uninstall_cfw3212.sh"

CASA_BUILD="${CASA_BUILD:-1}"
PKG_VERSION=$(sed -n 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT_DIR/package.json" | head -n1)
[ -n "$PKG_VERSION" ] || fail "Could not read version from package.json"
PKG_CASA_VERSION="${PKG_VERSION}-cfw3212.${CASA_BUILD}"
if grep -q '^VERSION=' "$STAGING_DIR/install_cfw3212.sh"; then
    tmp="$STAGING_DIR/install_cfw3212.sh.tmp"
    sed "s|^VERSION=\"[^\"]*\"|VERSION=\"$PKG_CASA_VERSION\"|" "$STAGING_DIR/install_cfw3212.sh" > "$tmp" && mv "$tmp" "$STAGING_DIR/install_cfw3212.sh"
fi
chmod +x "$STAGING_DIR/install_cfw3212.sh" "$STAGING_DIR/uninstall_cfw3212.sh"

step "Copying bundled dependencies..."
mkdir -p "$STAGING_DIR/dependencies"
cp "$DEPS_DIR/atcli_smd11" "$STAGING_DIR/dependencies/atcli_smd11"
cp "$DEPS_DIR/sms_tool" "$STAGING_DIR/dependencies/sms_tool"
cp "$DEPS_DIR/jq.ipk" "$STAGING_DIR/dependencies/jq.ipk"
cp "$DEPS_DIR"/dropbear_*.ipk "$STAGING_DIR/dependencies/"
chmod 755 "$STAGING_DIR/dependencies/atcli_smd11" "$STAGING_DIR/dependencies/sms_tool"

if [ -f "$ROOT_DIR/build-discord-bot.sh" ] && command -v go >/dev/null 2>&1; then
    step "Building Discord bot..."
    ( cd "$ROOT_DIR" && ./build-discord-bot.sh ) || fail "build-discord-bot.sh failed"
    if [ -f "$ROOT_DIR/qmanager-build/bin/qmanager_discord" ]; then
        cp "$ROOT_DIR/qmanager-build/bin/qmanager_discord" "$STAGING_DIR/dependencies/qmanager_discord"
        chmod 755 "$STAGING_DIR/dependencies/qmanager_discord"
    fi
else
    step "Skipping Discord bot build; Go is not available"
fi

step "Creating qmanager.tar.gz..."
tar czf "$ARCHIVE" -C "$BUILD_DIR" qmanager_install

step "Generating sha256sum.txt..."
(cd "$BUILD_DIR" && sha256sum qmanager.tar.gz > sha256sum.txt)

rm -rf "$STAGING_DIR"
printf '\nBuild complete: %s\n' "$ARCHIVE"
printf 'SHA-256: %s\n' "$(awk '{print $1}' "$BUILD_DIR/sha256sum.txt")"
EOF
    chmod 755 "$build"
}

write_uninstall_cfw3212() {
    cat > "$TARGET/uninstall_cfw3212.sh" <<'EOF'
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

SERVICES="lighttpd \
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
    systemctl daemon-reload 2>/dev/null || true
    systemctl reset-failed tailscaled 2>/dev/null || true
    info "Optional Tailscale/Ookla state removed"

    step "Purging preserved config and bundled Entware state"
    rm -rf /etc/qmanager /usrdata/opt
    rm -f /etc/sudoers.d/qmanager /usrdata/opt/etc/sudoers.d/qmanager 2>/dev/null || true
    info "Purge cleanup complete"
fi

step "Clearing old systemd status"
systemctl reset-failed $SERVICES 2>/dev/null || true
info "Old systemd status cleared"

echo "Casa CFW-3212 QManager files removed."
if [ "$NO_REBOOT" != "1" ]; then
    echo "Restart the device when ready."
fi
EOF
    chmod 755 "$TARGET/uninstall_cfw3212.sh"
}

write_qmanager_installer_cfw3212() {
    cat > "$TARGET/qmanager-installer-cfw3212.sh" <<'EOF'
#!/bin/sh
set -e

TARBALL="${1:-/tmp/qmanager.tar.gz}"
[ -f "$TARBALL" ] || { echo "Missing tarball: $TARBALL" >&2; exit 1; }
rm -rf /tmp/qmanager_install
tar xzf "$TARBALL" -C /tmp
exec sh /tmp/qmanager_install/install_cfw3212.sh
EOF
    chmod 755 "$TARGET/qmanager-installer-cfw3212.sh"
}

write_ippt_backend_cfw3212() {
    mkdir -p "$TARGET/scripts/www/cgi-bin/quecmanager/network"
    cat > "$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh" <<'EOF'
#!/bin/sh
. /usrdata/qmanager/lib/cgi_base.sh

qlog_init "cgi_ip_passthrough"
cgi_headers
cgi_handle_options

PROFILE_ID="${QMANAGER_PROFILE_ID:-1}"
CONFIG="/etc/qmanager/ippt_config.json"
PROFILE_ENABLE_RDB="link.profile.${PROFILE_ID}.ip_handover.enable"
PROFILE_MODE_RDB="link.profile.${PROFILE_ID}.ip_handover.mode"
SERVICE_ENABLE_RDB="service.ip_handover.enable"
SERVICE_LAST_IP_RDB="service.ip_handover.last_wwan_ip"

rdb_read() {
    rdb_get "$1" 2>/dev/null || echo ""
}

rdb_write() {
    rdb_set "$1" "$2" 2>/dev/null
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    enabled="$(rdb_read "$PROFILE_ENABLE_RDB")"
    mode="$(rdb_read "$PROFILE_MODE_RDB")"
    [ "$enabled" = "1" ] || mode="disabled"
    case "$mode" in eth|enabled|1) mode="eth" ;; *) mode="disabled" ;; esac
    jq -n --arg mode "$mode" '{
        success: true,
        passthrough_mode: $mode,
        target_mac: "",
        ippt_nat: "1",
        usb_mode: "1",
        dns_proxy: "disabled"
    }'
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post
    mode="$(printf '%s' "$POST_DATA" | jq -r '.passthrough_mode // "disabled"')"
    case "$mode" in
        disabled)
            rdb_write "$PROFILE_ENABLE_RDB" 0 || { cgi_error "rdb_write_failed" "Failed to disable Casa ip_handover"; exit 0; }
            rdb_write "$SERVICE_ENABLE_RDB" 0 || true
            rdb_setflags "$SERVICE_ENABLE_RDB" p 2>/dev/null || true
            rdb_write "$SERVICE_LAST_IP_RDB" "" || true
            rdb_setflags "$SERVICE_LAST_IP_RDB" p 2>/dev/null || true
            ;;
        eth)
            rdb_write "$PROFILE_ENABLE_RDB" 1 || { cgi_error "rdb_write_failed" "Failed to enable Casa ip_handover"; exit 0; }
            rdb_write "$PROFILE_MODE_RDB" eth || true
            rdb_write "$SERVICE_ENABLE_RDB" 1 || true
            ;;
        *)
            cgi_error "unsupported_on_cfw3212" "Casa CFW-3212 supports Disabled or Enabled Ethernet only"
            exit 0
            ;;
    esac
    mkdir -p "$(dirname "$CONFIG")"
    jq -n --arg mode "$mode" '{mode:$mode, mac:"", nat:"1", usb_mode:"1", dns_proxy:"disabled"}' > "$CONFIG" 2>/dev/null || true
    jq -n --arg mode "$mode" '{success:true, passthrough_mode:$mode}'
    exit 0
fi

cgi_error "method_not_allowed" "Unsupported method"
EOF
    chmod 755 "$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh"
}

write_update_stub_cfw3212() {
    mkdir -p "$TARGET/scripts/www/cgi-bin/quecmanager/system"
    cat > "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh" <<'EOF'
#!/bin/sh
. /usrdata/qmanager/lib/cgi_base.sh

cgi_headers
cgi_handle_options

jq -n '{
    success: true,
    current_version: null,
    latest_version: null,
    update_available: false,
    check_error: "unsupported_on_cfw3212",
    status: "disabled",
    message: "Software updates are disabled in the Casa CFW-3212 build."
}'
EOF
    chmod 755 "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh"
}

write_update_cfw3212() {
    mkdir -p "$TARGET/scripts/www/cgi-bin/quecmanager/system"
    if [ -f "$TEMPLATE_DIR/update_cfw3212.sh" ]; then
        cp "$TEMPLATE_DIR/update_cfw3212.sh" "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh"
    else
        write_update_stub_cfw3212
    fi
    chmod 755 "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh"
}

write_qmanager_update_cfw3212() {
    mkdir -p "$TARGET/scripts/usr/bin"
    if [ -f "$TEMPLATE_DIR/qmanager_update_cfw3212" ]; then
        cp "$TEMPLATE_DIR/qmanager_update_cfw3212" "$TARGET/scripts/usr/bin/qmanager_update"
    else
        replace_with_stub "scripts/usr/bin/qmanager_update" \
            "QManager package updates are disabled in this Casa CFW-3212 build."
    fi
    chmod 755 "$TARGET/scripts/usr/bin/qmanager_update"
}

write_qmanager_auto_update_cfw3212() {
    mkdir -p "$TARGET/scripts/usr/bin"
    if [ -f "$TEMPLATE_DIR/qmanager_auto_update_cfw3212" ]; then
        cp "$TEMPLATE_DIR/qmanager_auto_update_cfw3212" "$TARGET/scripts/usr/bin/qmanager_auto_update"
    else
        replace_with_stub "scripts/usr/bin/qmanager_auto_update" \
            "QManager auto-updates are disabled in this Casa CFW-3212 build."
    fi
    chmod 755 "$TARGET/scripts/usr/bin/qmanager_auto_update"
}

write_ippt_card_cfw3212() {
    mkdir -p "$TARGET/components/local-network/ip-passthrough"
    if [ -f "$TEMPLATE_DIR/ip-passthrough-card.tsx" ]; then
        cp "$TEMPLATE_DIR/ip-passthrough-card.tsx" "$TARGET/components/local-network/ip-passthrough/ip-passthrough-card.tsx"
        return
    fi

    cat > "$TARGET/components/local-network/ip-passthrough/ip-passthrough-card.tsx" <<'EOF'
"use client";

import { useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";
import { RotateCcwIcon } from "lucide-react";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Field, FieldGroup, FieldLabel, FieldSet } from "@/components/ui/field";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Button } from "@/components/ui/button";
import { SaveButton, useSaveFlash } from "@/components/ui/save-button";
import { Skeleton } from "@/components/ui/skeleton";
import { useIpPassthrough } from "@/hooks/use-ip-passthrough";
import type { PassthroughMode } from "@/types/ip-passthrough";

const IPPassthroughCard = () => {
  const { passthroughMode, isLoading, isSaving, error, saveSettings, refresh } = useIpPassthrough();
  const { saved, markSaved } = useSaveFlash();
  const [localMode, setLocalMode] = useState<PassthroughMode>("disabled");

  useEffect(() => {
    if (passthroughMode === "eth" || passthroughMode === "disabled") {
      setLocalMode(passthroughMode);
    }
  }, [passthroughMode]);

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    const success = await saveSettings({
      passthrough_mode: localMode,
      target_mac: "",
      ippt_nat: "1",
      usb_mode: "1",
      dns_proxy: "disabled",
    });
    if (success) {
      markSaved();
      toast.success("IP Passthrough settings saved");
    } else {
      toast.error("Failed to save IP Passthrough settings");
    }
  };

  if (isLoading) {
    return (
      <Card className="@container/card">
        <CardHeader>
          <CardTitle>IP Passthrough Configuration</CardTitle>
          <CardDescription>Casa CFW-3212 Ethernet handoff state.</CardDescription>
        </CardHeader>
        <CardContent>
          <Skeleton className="h-9 w-full" />
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="@container/card">
      <CardHeader>
        <CardTitle>IP Passthrough Configuration</CardTitle>
        <CardDescription>Casa CFW-3212 Ethernet handoff state.</CardDescription>
      </CardHeader>
      <CardContent>
        <form onSubmit={handleSubmit} className="space-y-6">
          <FieldSet>
            <FieldGroup>
              <Field>
                <FieldLabel>Mode</FieldLabel>
                <Select value={localMode} onValueChange={(value) => setLocalMode(value as PassthroughMode)}>
                  <SelectTrigger className="w-full">
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    <SelectItem value="disabled">Disabled</SelectItem>
                    <SelectItem value="eth">Enabled Ethernet</SelectItem>
                  </SelectContent>
                </Select>
              </Field>
            </FieldGroup>
          </FieldSet>

          {error ? <p className="text-sm text-destructive">{error}</p> : null}

          <div className="flex items-center justify-end gap-2">
            <Button type="button" variant="outline" size="icon" onClick={refresh} disabled={isSaving} title="Refresh">
              <RotateCcwIcon className="size-4" />
            </Button>
            <SaveButton type="submit" isSaving={isSaving} saved={saved} label="Save" />
          </div>
        </form>
      </CardContent>
    </Card>
  );
};

export default IPPassthroughCard;
EOF
}

patch_qmanager_poller() {
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"

    # Keep future upstream poller changes, but preserve Casa-safe boot behavior.
    local py_bin
    py_bin="$(command -v python3 || command -v python || true)"
    [ -n "$py_bin" ] || fail "python3/python is required to patch qmanager_poller safely"
    "$py_bin" - "$poller" <<'PY'
import os
from pathlib import Path
import sys
import re

path = Path(sys.argv[1])
text = path.read_text()
disable_profile_auto_apply = os.environ.get("CASA_PROFILE_AUTO_APPLY", "0") != "1"

old = '''# Group A: Identity reads — compound AT (7 → 1 call)
    # CVERSION, CGMM, CGSN, CIMI return bare responses (no +PREFIX:).
    # CGMM: bare model name; CGSN/CIMI: bare 15-digit numbers.
    # Order is deterministic: first 15-digit line = IMEI, second = IMSI.
    # =========================================================================
    result=$(qcmd 'AT+CVERSION;+CGMM;+CGSN;+CIMI;+QCCID;+CNUM;+QGETCAPABILITY' 2>/dev/null)'''
new = '''# Group A: Identity reads — compound AT (6 -> 1 call)
    # CVERSION, CGMM, CGSN, CIMI return bare responses (no +PREFIX:).
    # CGMM: bare model name; CGSN/CIMI: bare 15-digit numbers.
    # Order is deterministic: first 15-digit line = IMEI, second = IMSI.
    #
    # AT+QGETCAPABILITY is intentionally separated: it is unsupported on some
    # platforms (e.g. CFW-3212/RG520N-NA) and returns ERROR, which poisons the
    # entire compound response causing all device identity fields to go blank.
    #
    # On CFW-3212 the modem can still reject this read during early boot. Retry
    # briefly so one transient ERROR does not cache empty identity fields until
    # qmanager-poller is manually restarted.
    # =========================================================================
    result=""
    local identity_try
    for identity_try in 1 2 3 4 5 6; do
        result=$(qcmd 'AT+CVERSION;+CGMM;+CGSN;+CIMI;+QCCID;+CNUM' 2>/dev/null)
        if printf '%s\n' "$result" | tr -d '\r' | grep -q '^OK$' && printf '%s\n' "$result" | tr -d '\r' | grep -q '^+QCCID:'; then
            break
        fi
        result=""
        qlog_warn "Boot identity read not ready; retry ${identity_try}/6"
        sleep 3
    done'''
text = text.replace(old, new)

old = '''

        # QGETCAPABILITY: prefixed (multi-line)
        parse_capability "$result"
    fi'''
new = '''
    fi

    # QGETCAPABILITY: separate non-blocking call; fails gracefully if unsupported.
    local cap_result
    cap_result=$(qcmd 'AT+QGETCAPABILITY' 2>/dev/null) && parse_capability "$cap_result"'''
text = text.replace(old, new)

old = '''    # Group B: Enables + post-enable reads
    # Enable commands (,1) are unconditional — idempotent, safe in any mode.
    # MIMO reads are gated by network_type (lte_mimo_layers crashes in SA,
    # nr5g_mimo_layers crashes in LTE/NSA).
    # =========================================================================
    local boot_cmd='AT+QCAINFO=1;+QNWCFG="lte_mimo_layers",1;+QNWCFG="nr5g_mimo_layers",1;+QNWCFG="lte_time_advance",1;+QNWCFG="nr5g_time_advance",1'
    # Append mode-appropriate MIMO read
    if [ "$network_type" = "5G-SA" ]; then
        boot_cmd="${boot_cmd}"';+QNWCFG="nr5g_mimo_layers"'
    elif [ "$network_type" = "LTE" ] || [ "$network_type" = "5G-NSA" ]; then
        boot_cmd="${boot_cmd}"';+QNWCFG="lte_mimo_layers"'
    fi'''
new = '''    # Group B: Enables + post-enable reads
    # Casa/RG520N-NA returns ERROR for lte_mimo_layers while camped on 5G-SA,
    # so keep MIMO enable/read commands gated by current network mode.
    # =========================================================================
    local boot_cmd='AT+QCAINFO=1;+QNWCFG="lte_time_advance",1;+QNWCFG="nr5g_time_advance",1'
    # Append mode-appropriate MIMO read
    if [ "$network_type" = "5G-SA" ]; then
        boot_cmd="${boot_cmd}"';+QNWCFG="nr5g_mimo_layers",1;+QNWCFG="nr5g_mimo_layers"'
    elif [ "$network_type" = "LTE" ] || [ "$network_type" = "5G-NSA" ]; then
        boot_cmd="${boot_cmd}"';+QNWCFG="lte_mimo_layers",1;+QNWCFG="lte_mimo_layers"'
    fi'''
text = text.replace(old, new)

old = '''
    # Remaining mode-independent reads
    boot_cmd="${boot_cmd}"';+QMAP="MPDN_RULE";+QMAP="IPPT_NAT";+QCFG="usbnet";+QMAP="DHCPV4DNS"'
    result=$(qcmd "$boot_cmd" 2>/dev/null)

    if [ -n "$result" ]; then
        # MIMO layers (parser greps for each prefix independently)
        parse_mimo "$result" "$result"

        # IP Passthrough settings (all parsers grep for their specific keywords)
        parse_ippt_mpdn_rule "$result"
        parse_ippt_nat "$result"
        parse_ippt_usbnet "$result"
        parse_ippt_dhcpv4dns "$result"
    fi'''
new = '''
    result=$(qcmd "$boot_cmd" 2>/dev/null)

    if [ -n "$result" ]; then
        # MIMO layers (parser greps for each prefix independently)
        parse_mimo "$result" "$result"
    fi

    # Casa CFW-3212 keeps IP Passthrough mapped to ip_handover/RDB state.
    # Do not query upstream MPDN/QMAP/QCFG usbnet status here; it is
    # unsupported on this device and creates noisy qcmd errors.
    boot_ippt_mode="disabled"
    boot_ippt_mac=""
    boot_ippt_nat="0"
    boot_ippt_usbnet="0"
    boot_ippt_dhcpv4dns="disabled"'''
text = text.replace(old, new)

old = '''
    # IP Passthrough queries: separate non-blocking call.
    # These Quectel MPDN-stack commands are unsupported on CFW-3212/RG520N-NA.
    # Keeping them out of the MIMO compound prevents one ERROR from poisoning
    # unrelated boot-time modem data.
    local ippt_result
    ippt_result=$(qcmd 'AT+QMAP="MPDN_RULE";+QMAP="IPPT_NAT";+QCFG="usbnet";+QMAP="DHCPV4DNS"' 2>/dev/null)
    if [ -n "$ippt_result" ]; then
        parse_ippt_mpdn_rule "$ippt_result"
        parse_ippt_nat "$ippt_result"
        parse_ippt_usbnet "$ippt_result"
        parse_ippt_dhcpv4dns "$ippt_result"
    fi'''
new = '''
    # Casa CFW-3212 keeps IP Passthrough mapped to ip_handover/RDB state.
    # Do not query upstream MPDN/QMAP/QCFG usbnet status here; it is
    # unsupported on this device and creates noisy qcmd errors.
    boot_ippt_mode="disabled"
    boot_ippt_mac=""
    boot_ippt_nat="0"
    boot_ippt_usbnet="0"
    boot_ippt_dhcpv4dns="disabled"'''
text = text.replace(old, new)

if disable_profile_auto_apply:
    old = '''# Active profile auto-apply at boot
    # =========================================================================
    # If ICCID matches a saved profile, (re-)apply all its settings.
    # The apply script skips any setting that already matches — no-op if
    # nothing drifted. Also handles SIM swap: if the old active profile was
    # deactivated above (ICCID mismatch), this finds and applies the profile
    # for the new SIM instead.
    # =========================================================================
    if [ -n "$boot_iccid" ]; then
        auto_apply_profile "$boot_iccid" "boot"
    fi'''
    new = '''# Casa CFW-3212 safety: profile auto-apply disabled
    # =========================================================================
    # Manual SIM profile apply is enabled, including APN, TTL/HL, IMEI, and
    # AT+CFUN=1,1. Blind ICCID-matched boot auto-apply stays off by default.
    # =========================================================================
    qlog_info "Casa profile auto-apply disabled"'''
    text = text.replace(old, new)

    if "Casa profile auto-apply disabled" not in text:
        text = re.sub(
            r'''    # --- Auto-apply profile matching current SIM \(boot\) ---\n    if \[ -n "\$boot_iccid" \]; then\n        \( \. /usr/lib/qmanager/profile_mgr\.sh && auto_apply_profile "\$boot_iccid" "boot" \)\n    fi''',
            '''    # --- Casa CFW-3212 safety: profile auto-apply disabled ---
    # Manual SIM profile apply is enabled, including APN, TTL/HL, IMEI, and
    # AT+CFUN=1,1. Blind ICCID-matched boot auto-apply stays off by default.
    qlog_info "Casa profile auto-apply disabled"''',
            text,
            count=1,
        )

if "boot_qmanager_version=$(cat /etc/qmanager/VERSION" not in text:
    marker = '    log_info "Boot data: FW=$boot_firmware BUILD=$boot_build_date MFG=$boot_manufacturer MODEL=$boot_model"'
    version_block = '''    boot_qmanager_version=$(cat /etc/qmanager/VERSION 2>/dev/null | tr -d '[:space:]')
    boot_qmanager_version="${boot_qmanager_version:-unknown}"

'''
    if marker not in text:
        raise SystemExit("boot data log marker not found for qmanager version")
    text = text.replace(marker, version_block + marker, 1)

if '--arg qmanager_version "$boot_qmanager_version"' not in text:
    marker = '        --arg firmware "$boot_firmware" \\\n'
    if marker not in text:
        raise SystemExit("firmware jq arg marker not found for qmanager version")
    text = text.replace(marker, '        --arg qmanager_version "$boot_qmanager_version" \\\n' + marker, 1)

if 'qmanager_version: $qmanager_version' not in text:
    marker = '                temperature: $temp, cpu_usage: $cpu,\n'
    if marker not in text:
        raise SystemExit("device json marker not found for qmanager version")
    text = text.replace(marker, '                qmanager_version: $qmanager_version,\n' + marker, 1)

path.write_text(text)
PY

    grep -q "QGETCAPABILITY is intentionally separated" "$poller" \
        || fail "Could not apply Casa QGETCAPABILITY poller patch"
    grep -q "Casa/RG520N-NA returns ERROR for lte_mimo_layers while camped on 5G-SA" "$poller" \
        || fail "Could not apply Casa MIMO poller patch"
    grep -q "Do not query upstream MPDN/QMAP/QCFG usbnet status here" "$poller" \
        || fail "Could not apply Casa IPPT poller patch"
    if [ "$CASA_PROFILE_AUTO_APPLY" = "1" ]; then
        warn "CASA_PROFILE_AUTO_APPLY=1: leaving boot SIM profile auto-apply enabled"
    else
        grep -q "Casa profile auto-apply disabled" "$poller" \
            || fail "Could not apply Casa profile auto-apply poller patch"
    fi
    grep -q "qmanager_version: \$qmanager_version" "$poller" \
        || fail "Could not apply Casa QManager version poller patch"
}

pin_casa_stable_ping_rust() {
    local ref_ping="$REF_DIR/scripts/usr/bin/qmanager_ping"
    local target_ping="$TARGET/scripts/usr/bin/qmanager_ping"
    [ -f "$ref_ping" ] || fail "Casa reference missing stable qmanager_ping: $ref_ping"
    [ -f "$target_ping" ] || fail "Target missing qmanager_ping: $target_ping"

    local ref_size
    ref_size=$(wc -c < "$ref_ping" | tr -d ' ')
    [ "$ref_size" -gt 100000 ] \
        || fail "Casa reference qmanager_ping is not the expected Rust binary: $ref_ping"
    if head -c 64 "$ref_ping" | grep -q '#!/bin/sh'; then
        fail "Casa reference qmanager_ping is a shell wrapper, not the stable Rust binary: $ref_ping"
    fi

    cp "$ref_ping" "$target_ping"
    chmod 755 "$target_ping"
    log "Pinned qmanager_ping Rust binary from Casa-tested reference"
}

patch_qmanager_health_check_paths_cfw3212() {
    local worker="$TARGET/scripts/usr/bin/qmanager_health_check"
    [ -f "$worker" ] || fail "Target missing qmanager_health_check worker"

    python3 - "$worker" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Single-pass replacements — each rule uses a distinct upstream-only key so
# the output of one rule never re-matches another. (str.replace is
# non-overlapping by default; we still build the rule list to avoid any
# cascade between similar paths like /etc/sudoers.d/qmanager vs
# /opt/etc/sudoers.d/qmanager.)
rules = [
    ("/usr/bin/atcli_smd11",          "/usrdata/bin/atcli_smd11"),
    ("/usr/bin/sms_tool",             "/usrdata/bin/sms_tool"),
    ("/usr/bin/qcmd",                 "/usrdata/bin/qcmd"),
    ("/opt/bin/jq",                   "/usrdata/opt/bin/jq"),
    ("/opt/bin/curl",                 "/usrdata/opt/bin/curl"),
    ("/opt/bin/openssl",              "/usrdata/opt/bin/openssl"),
    ("/opt/bin/msmtp",                "/usrdata/opt/bin/msmtp"),
    # Order matters: rewrite the /opt/etc form first, then the bare /etc
    # form. Both ultimately resolve to /usrdata/opt/etc/sudoers.d/qmanager
    # on Casa, so doing the long key first lets the short rule run on a
    # string that no longer contains a /opt/etc prefix.
    ("/opt/etc/sudoers.d/qmanager",   "/usrdata/opt/etc/sudoers.d/qmanager"),
    ("/etc/sudoers.d/qmanager",       "/usrdata/opt/etc/sudoers.d/qmanager"),
    ("/lib/systemd/system/multi-user.target.wants",
     "/etc/systemd/system/multi-user.target.wants"),
    # Lighttpd port check — Casa exposes 9080/9000 instead of 80/443.
    (r"grep -qE '[:.](80)\b'",        r"grep -qE '[:.](9080)\b'"),
    (r"grep -qE '[:.](443)\b'",       r"grep -qE '[:.](9000)\b'"),
    # Cosmetic strings tied to the port test — labels and result messages.
    ("lighttpd listening on 80/443",  "lighttpd listening on 9080/9000"),
    ("listening on 80 and 443",       "listening on 9080 and 9000"),
    ("not listening on 80 or 443",    "not listening on 9080 or 9000"),
    # qmanager-console (ttyd web console) and qmanager-traffic (live traffic
    # counter) are opt-in features. Mark them optional so a fresh install
    # reports them as skip rather than warn when they aren't enabled.
    ("_svc_check qmanager-console.service 1",
     "_svc_check qmanager-console.service 0"),
    ("_svc_check qmanager-traffic.service 1",
     "_svc_check qmanager-traffic.service 0"),
    # cfg.cgi_path_opt — the test looks for /opt/bin in lighttpd.conf /
    # cgi_base.sh, but on Casa the PATH includes /usrdata/opt/bin instead.
    # cgi_base.sh also lives at /usrdata/qmanager/lib/, not /usr/lib/qmanager/.
    ("local cgi_base=/usr/lib/qmanager/cgi_base.sh",
     "local cgi_base=/usrdata/qmanager/lib/cgi_base.sh"),
    (r"'PATH.*\/opt\/bin'",           r"'PATH.*\/usrdata\/opt\/bin'"),
    (r"'PATH=.*\/opt\/bin'",          r"'PATH=.*\/usrdata\/opt\/bin'"),
    ('"pass|PATH includes /opt/bin in lighttpd.conf"',
     '"pass|PATH includes /usrdata/opt/bin in lighttpd.conf"'),
    ('"fail|/opt/bin not in lighttpd.conf and not in cgi_base.sh"',
     '"fail|/usrdata/opt/bin not in lighttpd.conf and not in cgi_base.sh"'),
    ("lighttpd CGI PATH includes /opt/bin",
     "lighttpd CGI PATH includes /usrdata/opt/bin"),
]

# Build a single replacement table indexed by left-most match position so
# no rule's output is fed back into another rule's input.
positions = []
for src, dst in rules:
    idx = 0
    while True:
        i = text.find(src, idx)
        if i < 0:
            break
        positions.append((i, src, dst))
        idx = i + len(src)
positions.sort()

# Stitch the new string from the original, replacing each found range.
parts = []
cursor = 0
last_end = -1
for i, src, dst in positions:
    if i < last_end:
        # Overlapping match (shouldn't happen with our rule set, but guard
        # so we never silently corrupt the file).
        continue
    parts.append(text[cursor:i])
    parts.append(dst)
    cursor = i + len(src)
    last_end = cursor
parts.append(text[cursor:])
new_text = "".join(parts)

# _svc_check capture bug: `systemctl is-active` exits non-zero for inactive
# / failed services, so the original `|| echo unknown` fallback fires AND
# the real state is also captured, producing a two-line $active string that
# falls through the case statement to the catch-all `*) warn "state=$active"`.
# Capture stdout only and explicitly fall back to "unknown" only when empty.
svc_check_old = (
    '    local active; active=$(systemctl is-active "$unit" 2>/dev/null '
    '|| echo unknown)\n'
)
svc_check_new = (
    '    local active; active=$(systemctl is-active "$unit" 2>/dev/null)\n'
    '    [ -z "$active" ] && active="unknown"\n'
)
if svc_check_old in new_text:
    new_text = new_text.replace(svc_check_old, svc_check_new, 1)

if new_text != text:
    path.write_text(new_text)
PY

    # Verify the swaps applied and nothing cascaded.
    grep -q "/usrdata/bin/atcli_smd11" "$worker" \
        || fail "Health-check worker missing /usrdata/bin/atcli_smd11 after patch"
    grep -q "/usrdata/opt/bin/jq" "$worker" \
        || fail "Health-check worker missing /usrdata/opt/bin/jq after patch"
    grep -q "/etc/systemd/system/multi-user.target.wants" "$worker" \
        || fail "Health-check worker missing Casa systemd wants path"
    ! grep -q "/usrdata/usrdata/" "$worker" \
        || fail "Health-check worker cascaded paths (double /usrdata/) — patch ordering broken"
    ! grep -q "/usr/bin/atcli_smd11" "$worker" \
        || fail "Health-check worker still has upstream /usr/bin/atcli_smd11"
    # Every /etc/sudoers.d/qmanager occurrence must be the Casa form
    # (/usrdata/opt/etc/sudoers.d/qmanager). Compare counts to confirm.
    sudoers_total=$(grep -c "/etc/sudoers\.d/qmanager" "$worker" || echo 0)
    sudoers_casa=$(grep -c "/usrdata/opt/etc/sudoers\.d/qmanager" "$worker" || echo 0)
    [ "$sudoers_total" = "$sudoers_casa" ] \
        || fail "Health-check worker has non-Casa /etc/sudoers.d/qmanager references"
    grep -q "lighttpd listening on 9080/9000" "$worker" \
        || fail "Health-check worker still has 80/443 in lighttpd_listen label"
    ! grep -q "|| echo unknown)" "$worker" \
        || fail "Health-check worker _svc_check still has || echo unknown bug"
    grep -qE '\[ -z "\$active" \] && active="unknown"' "$worker" \
        || fail "Health-check worker _svc_check fallback patch did not apply"
    grep -q "_svc_check qmanager-console.service 0" "$worker" \
        || fail "Health-check worker did not mark qmanager-console optional"
    grep -q "_svc_check qmanager-traffic.service 0" "$worker" \
        || fail "Health-check worker did not mark qmanager-traffic optional"
    grep -q "local cgi_base=/usrdata/qmanager/lib/cgi_base.sh" "$worker" \
        || fail "Health-check worker still has upstream /usr/lib/qmanager/cgi_base.sh path"
    grep -q "lighttpd CGI PATH includes /usrdata/opt/bin" "$worker" \
        || fail "Health-check worker cfg.cgi_path_opt label still says /opt/bin"
}

patch_disable_profile_auto_apply() {
    if [ "$CASA_PROFILE_AUTO_APPLY" = "1" ]; then
        warn "CASA_PROFILE_AUTO_APPLY=1: leaving upstream SIM profile auto-apply enabled"
        return 0
    fi

    local settings_sh="$TARGET/scripts/www/cgi-bin/quecmanager/cellular/settings.sh"
    local watchcat="$TARGET/scripts/usr/bin/qmanager_watchcat"

    [ -f "$settings_sh" ] || fail "Target missing cellular/settings.sh"
    [ -f "$watchcat" ] || fail "Target missing qmanager_watchcat"

    python3 - "$settings_sh" "$watchcat" <<'PY'
from pathlib import Path
import sys

settings = Path(sys.argv[1])
watchcat = Path(sys.argv[2])

text = settings.read_text()
old = '''                    # Auto-apply matching profile for the new SIM
                    sleep 1  # let SIM initialize after CFUN=1
                    _new_iccid=$(qcmd 'AT+QCCID' 2>/dev/null | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
                    if [ -n "$_new_iccid" ]; then
                        . /usr/lib/qmanager/profile_mgr.sh 2>/dev/null
                        auto_apply_profile "$_new_iccid" "sim_switch"
                    fi
'''
new = '''                    # Casa CFW-3212 safety: do not auto-apply SIM profiles.
                    qlog_info "Casa profile auto-apply disabled after SIM switch"
'''
if old in text:
    text = text.replace(old, new, 1)
settings.write_text(text)

text = watchcat.read_text()
text = text.replace(
    '''    # Auto-apply matching profile for the reverted SIM
    local _revert_iccid
    _revert_iccid=$(qcmd 'AT+QCCID' 2>/dev/null | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
    [ -n "$_revert_iccid" ] && auto_apply_profile "$_revert_iccid" "watchdog_revert"
''',
    '''    # Casa CFW-3212 safety: do not auto-apply SIM profiles.
    qlog_info "Casa profile auto-apply disabled after watchdog SIM revert"
''',
)
text = text.replace(
    '''            # Auto-apply matching profile for the new SIM
            if [ -n "$curr_iccid" ]; then
                auto_apply_profile "$curr_iccid" "watchdog"
            fi
''',
    '''            # Casa CFW-3212 safety: do not auto-apply SIM profiles.
            qlog_info "Casa profile auto-apply disabled after watchdog SIM failover"
''',
)
watchcat.write_text(text)
PY

    grep -q "Casa profile auto-apply disabled after SIM switch" "$settings_sh" \
        || fail "Could not disable SIM-switch profile auto-apply"
    grep -q "Casa profile auto-apply disabled after watchdog SIM revert" "$watchcat" \
        || fail "Could not disable watchdog revert profile auto-apply"
    grep -q "Casa profile auto-apply disabled after watchdog SIM failover" "$watchcat" \
        || fail "Could not disable watchdog failover profile auto-apply"
}

patch_casa_iccid_and_staleness_cfw3212() {
    local profile_mgr="$TARGET/scripts/usr/lib/qmanager/profile_mgr.sh"
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    local table="$TARGET/components/cellular/custom-profiles/custom-profile-table.tsx"
    local modem_hook="$TARGET/hooks/use-modem-status.ts"

    [ -f "$profile_mgr" ] || fail "Target missing profile_mgr.sh"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"
    [ -f "$table" ] || fail "Target missing custom-profile-table.tsx"
    [ -f "$modem_hook" ] || fail "Target missing use-modem-status.ts"

    python3 - "$profile_mgr" "$poller" "$table" "$modem_hook" <<'PY'
from pathlib import Path
import sys

profile_mgr, poller, table, modem_hook = map(Path, sys.argv[1:5])

text = profile_mgr.read_text()
if "_normalize_iccid()" not in text:
    text = text.replace(
        '# Ensure profile directory exists\nmkdir -p "$PROFILE_DIR" 2>/dev/null\n',
        '''# Ensure profile directory exists
mkdir -p "$PROFILE_DIR" 2>/dev/null

# Casa/RG520N may report ICCID with a trailing hexadecimal padding nibble
# ("F"). QManager profile matching should compare the decimal ICCID only.
_normalize_iccid() {
    printf '%s' "$1" | tr -d ' \\r\\n' | sed 's/[Ff]$//'
}
''',
        1,
    )
if 'sim_iccid=$(_normalize_iccid "$sim_iccid")' not in text:
    text = text.replace(
        '    sim_iccid=$(printf \'%s\' "$input" | jq -r \'.sim_iccid // empty\')\n',
        '    sim_iccid=$(printf \'%s\' "$input" | jq -r \'.sim_iccid // empty\')\n    sim_iccid=$(_normalize_iccid "$sim_iccid")\n',
        1,
    )
if 'iccid=$(_normalize_iccid "$1")' not in text:
    text = text.replace(
        '''find_profile_by_iccid() {
    local iccid="$1"
    [ -z "$iccid" ] && return 1
    local pf pf_iccid
''',
        '''find_profile_by_iccid() {
    local iccid
    iccid=$(_normalize_iccid "$1")
    [ -z "$iccid" ] && return 1
    local pf pf_iccid
''',
        1,
    )
    text = text.replace(
        '''        pf_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$pf" 2>/dev/null)
        if [ "$pf_iccid" = "$iccid" ]; then
''',
        '''        pf_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$pf" 2>/dev/null)
        pf_iccid=$(_normalize_iccid "$pf_iccid")
        if [ "$pf_iccid" = "$iccid" ]; then
''',
        1,
    )
profile_mgr.write_text(text)

text = poller.read_text()
if "_normalize_iccid()" not in text:
    text = text.replace(
        'qcmd_exec() {\n',
        '''_normalize_iccid() {
    printf '%s' "$1" | tr -d ' \\r\\n' | sed 's/[Ff]$//'
}

qcmd_exec() {
''',
        1,
    )
if 'boot_iccid=$(_normalize_iccid "$boot_iccid")' not in text:
    text = text.replace(
        '''        # QCCID: prefixed
        boot_iccid=$(printf '%s\\n' "$result" | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
''',
        '''        # QCCID: prefixed. Strip Casa/RG520N trailing ICCID padding nibble.
        boot_iccid=$(printf '%s\\n' "$result" | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
        boot_iccid=$(_normalize_iccid "$boot_iccid")
''',
        1,
    )
if 'stored_iccid=$(_normalize_iccid "$stored_iccid")' not in text:
    text = text.replace(
        '            stored_iccid=$(cat "$LAST_ICCID_FILE" 2>/dev/null | tr -d \' \\r\\n\')\n',
        '            stored_iccid=$(cat "$LAST_ICCID_FILE" 2>/dev/null | tr -d \' \\r\\n\')\n            stored_iccid=$(_normalize_iccid "$stored_iccid")\n',
        1,
    )
if 'pf_iccid=$(_normalize_iccid "$pf_iccid")' not in text:
    text = text.replace(
        '''                    pf_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$pf" 2>/dev/null)
                    if [ "$pf_iccid" = "$boot_iccid" ]; then
''',
        '''                    pf_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "$pf" 2>/dev/null)
                    pf_iccid=$(_normalize_iccid "$pf_iccid")
                    if [ "$pf_iccid" = "$boot_iccid" ]; then
''',
        1,
    )
if '_ap_iccid=$(_normalize_iccid "$_ap_iccid")' not in text:
    text = text.replace(
        '''                _ap_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "/etc/qmanager/profiles/${_ap_id}.json" 2>/dev/null)
                if [ -n "$_ap_iccid" ] && [ "$_ap_iccid" != "$boot_iccid" ]; then
''',
        '''                _ap_iccid=$(jq -r '(.sim_iccid) | if . == null then empty else . end' "/etc/qmanager/profiles/${_ap_id}.json" 2>/dev/null)
                _ap_iccid=$(_normalize_iccid "$_ap_iccid")
                if [ -n "$_ap_iccid" ] && [ "$_ap_iccid" != "$boot_iccid" ]; then
''',
        1,
    )
poller.write_text(text)

text = table.read_text()
if "normalizeIccid" not in text:
    marker = 'import { formatProfileDate } from "@/types/sim-profile";\n'
    if marker not in text:
        raise SystemExit("custom-profile-table.tsx import marker not found")
    text = text.replace(
        marker,
        marker + '''
function normalizeIccid(value: string | null | undefined): string {
  return (value ?? "").trim().replace(/[Ff]$/, "");
}
''',
        1,
    )
if 'normalizeIccid(row.original.sim_iccid)' not in text:
    text = text.replace(
        '''            const profileIccid = row.original.sim_iccid;
            const isMismatch =
              profileIccid && currentIccid && profileIccid !== currentIccid;
''',
        '''            const profileIccid = normalizeIccid(row.original.sim_iccid);
            const liveIccid = normalizeIccid(currentIccid);
            const isMismatch =
              profileIccid && liveIccid && profileIccid !== liveIccid;
''',
        1,
    )
table.write_text(text)

text = modem_hook.read_text()
if "lastTimestampRef" not in text:
    text = text.replace(
        '''  // Use ref for the interval so we can clear it
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
''',
        '''  // Use ref for the interval so we can clear it
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const lastTimestampRef = useRef<number | null>(null);
  const lastTimestampAdvanceMsRef = useRef<number>(Date.now());
''',
        1,
    )
if "timestampAdvanced" not in text:
    text = text.replace(
        '''      // Check staleness: compare the JSON timestamp to current time
      const now = Math.floor(Date.now() / 1000);
      const age = now - json.timestamp;
      setIsStale(age > STALE_THRESHOLD_SECONDS);
''',
        '''      // Check staleness. Prefer an advancing router timestamp because
      // some Casa units can boot with an incorrect wall clock until time sync.
      const nowMs = Date.now();
      const previousTimestamp = lastTimestampRef.current;
      const timestampAdvanced =
        typeof previousTimestamp !== "number" || json.timestamp > previousTimestamp;
      if (timestampAdvanced) {
        lastTimestampRef.current = json.timestamp;
        lastTimestampAdvanceMsRef.current = nowMs;
        setIsStale(false);
      } else {
        const stalledAge =
          (nowMs - lastTimestampAdvanceMsRef.current) / 1000;
        setIsStale(stalledAge > STALE_THRESHOLD_SECONDS);
      }
''',
        1,
    )
modem_hook.write_text(text)
PY

    grep -q "_normalize_iccid" "$profile_mgr" \
        || fail "profile_mgr.sh missing ICCID normalization"
    grep -q "_normalize_iccid" "$poller" \
        || fail "qmanager_poller missing ICCID normalization"
    grep -q "normalizeIccid" "$table" \
        || fail "custom-profile-table.tsx missing ICCID normalization"
    grep -q "function normalizeIccid" "$table" \
        || fail "custom-profile-table.tsx missing normalizeIccid function"
    grep -q "lastTimestampAdvanceMsRef" "$modem_hook" \
        || fail "use-modem-status.ts missing Casa timestamp staleness patch"
}

patch_logging_cfw3212() {
    local qlog="$TARGET/scripts/usr/lib/qmanager/qlog.sh"
    local logs_card="$TARGET/components/monitoring/logs/system-logs-card.tsx"
    local data_used="$TARGET/scripts/www/cgi-bin/quecmanager/network/data_used.sh"

    [ -f "$qlog" ] || fail "Target missing qlog.sh"
    if [ ! -f "$logs_card" ]; then
        logs_card="$TARGET/components/system-settings/logs/system-logs-card.tsx"
    fi
    [ -f "$logs_card" ] || fail "Target missing system-logs-card.tsx"

    local py_bin
    py_bin="$(command -v python3 || command -v python || true)"
    [ -n "$py_bin" ] || fail "python3/python is required to patch logging safely"

    "$py_bin" - "$qlog" "$logs_card" "$data_used" <<'PY'
from pathlib import Path
import sys

qlog_path = Path(sys.argv[1])
logs_card_path = Path(sys.argv[2])
data_used_path = Path(sys.argv[3])

qlog = qlog_path.read_text()
qlog = qlog.replace(
    "# Format timestamp — ISO-ish for readability, compact for space\n"
    "    local ts\n"
    "    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%s')",
    "# Format timestamp with an explicit timezone offset so the UI does not have\n"
    "    # to guess whether the router is logging in UTC or local time.\n"
    "    local ts\n"
    "    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date '+%s')",
)
qlog_path.write_text(qlog)

logs_card = logs_card_path.read_text()
logs_card = logs_card.replace(
    """const formatLogTimestamp = (timestamp: string) => {
  const parsed = new Date(`${timestamp.replace(" ", "T")}Z`);
  if (Number.isNaN(parsed.getTime())) return timestamp;
  return parsed.toLocaleString();
};""",
    """const formatLogTimestamp = (timestamp: string) => {
  const hasTimeZone = /(?:[zZ]|[+-]\\d{2}:?\\d{2})$/.test(timestamp);
  const normalized = hasTimeZone ? timestamp : `${timestamp.replace(" ", "T")}Z`;
  const parsed = new Date(normalized);
  if (Number.isNaN(parsed.getTime())) return timestamp;
  return parsed.toLocaleString();
};""",
)
logs_card = logs_card.replace(
    '<span title={`${entry.timestamp} UTC`}>',
    '<span title={entry.timestamp}>',
)
logs_card_path.write_text(logs_card)

if data_used_path.exists():
    data_used = data_used_path.read_text()
    data_used = data_used.replace(
        'qlog_warn "data_used block absent in status cache, returning zeroed fallback"',
        'qlog_debug "data_used block absent in status cache, returning zeroed fallback"',
    )
    data_used_path.write_text(data_used)
PY

    grep -q "%Y-%m-%dT%H:%M:%S%z" "$qlog" \
        || fail "Could not apply timezone-aware qlog patch"
    if grep -q "formatLogTimestamp" "$logs_card"; then
        grep -q "hasTimeZone" "$logs_card" \
            || fail "Could not apply system logs timestamp patch"
    fi
    if [ -f "$data_used" ]; then
        grep -q 'qlog_debug "data_used block absent' "$data_used" \
            || fail "Could not quiet data_used fallback log"
    fi
}

replace_with_stub() {
    local rel="$1"
    local message="$2"
    local dst="$TARGET/$rel"
    mkdir -p "$(dirname "$dst")"
    cat > "$dst" <<EOF
#!/bin/sh
echo "$message" >&2
exit 1
EOF
    chmod 755 "$dst"
}

patch_qmanager_display_version() {
    local about_sh="$TARGET/scripts/www/cgi-bin/quecmanager/device/about.sh"
    local about_card="$TARGET/components/about-device/about-qmanager-card.tsx"
    local about_types="$TARGET/types/about-device.ts"
    local modem_types="$TARGET/types/modem-status.ts"
    local device_status="$TARGET/components/dashboard/device-status.tsx"

    [ -f "$about_sh" ] || fail "Target missing device/about.sh"
    [ -f "$about_card" ] || fail "Target missing about-qmanager-card.tsx"
    [ -f "$about_types" ] || fail "Target missing about-device.ts"
    [ -f "$modem_types" ] || fail "Target missing modem-status.ts"
    [ -f "$device_status" ] || fail "Target missing dashboard/device-status.tsx"

    python3 - "$about_sh" "$about_card" "$about_types" "$modem_types" "$device_status" <<'INNERPY'
from pathlib import Path
import sys

about_sh = Path(sys.argv[1])
about_card = Path(sys.argv[2])
about_types = Path(sys.argv[3])
modem_types = Path(sys.argv[4])
device_status = Path(sys.argv[5])

text = about_sh.read_text()
if "sys_qmanager_version=" not in text:
    marker = "# =============================================================================\n# 5. Collect public IP results (wait for background jobs, bounded by timeout)\n"
    if marker not in text:
        raise SystemExit("about public IP marker not found")
    version_block = '''sys_qmanager_version=$(cat /etc/qmanager/VERSION 2>/dev/null | tr -d '[:space:]')
sys_qmanager_version="${sys_qmanager_version:-unknown}"

'''
    text = text.replace(marker, version_block + marker, 1)
if '--arg qmver "$sys_qmanager_version"' not in text:
    text = text.replace(
        '    --arg owrt "$sys_openwrt" \\\n',
        '    --arg owrt "$sys_openwrt" \\\n    --arg qmver "$sys_qmanager_version" \\\n',
        1,
    )
if 'qmanager_version: $qmver' not in text:
    text = text.replace(
        '            openwrt_version: $owrt\n',
        '            openwrt_version: $owrt,\n            qmanager_version: $qmver\n',
        1,
    )
about_sh.write_text(text)

text = about_types.read_text()
if "qmanager_version: string;" not in text:
    text = text.replace("    openwrt_version: string;\n", "    openwrt_version: string;\n    qmanager_version: string;\n", 1)
about_types.write_text(text)

text = about_card.read_text()
text = text.replace("{packageJson.version}", "{data?.system.qmanager_version || packageJson.version}")
about_card.write_text(text)

text = modem_types.read_text()
if "qmanager_version: string;" not in text:
    text = text.replace(
        '  /** Average modem temperature in °C across all available sensors (null if unavailable) */\n',
        '  /** Installed QManager package version from /etc/qmanager/VERSION */\n  qmanager_version: string;\n  /** Average modem temperature in °C across all available sensors (null if unavailable) */\n',
        1,
    )
modem_types.write_text(text)

text = device_status.read_text()
text = text.replace(
    '{ label: "QManager Version", value: packageJson.version, mono: true },',
    '{ label: "QManager Version", value: data?.qmanager_version || packageJson.version, mono: true },',
)
device_status.write_text(text)
INNERPY

    grep -q "sys_qmanager_version=" "$about_sh" \
        || fail "Could not apply Casa about-page QManager version patch"
    grep -q "qmanager_version: string;" "$modem_types" \
        || fail "Could not apply Casa dashboard QManager version type patch"
    grep -q "data?.qmanager_version" "$device_status" \
        || fail "Could not apply Casa dashboard QManager version display patch"
}

patch_casa_display_name() {
    local settings_sh="$TARGET/scripts/www/cgi-bin/quecmanager/system/settings.sh"
    [ -f "$settings_sh" ] || fail "Target missing system/settings.sh"

    python3 - "$settings_sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''    # --- Hostname (display name) ---
    hostname=$(uci -q get system.@system[0].hostname 2>/dev/null)
    [ -z "$hostname" ] && hostname="OpenWrt"
'''
new = '''    # --- Hostname (display name) ---
    hostname=$(uci -q get system.@system[0].hostname 2>/dev/null)
    case "$hostname" in
        ""|OpenWrt|openwrt) hostname="Casa CFW-3212" ;;
    esac
'''
if "hostname=\"Casa CFW-3212\"" not in text:
    if old in text:
        text = text.replace(old, new)
    else:
        marker = '''    # --- Hostname (display name) ---
    hostname=$(sys_get_hostname)
'''
        replacement = '''    # --- Hostname (display name) ---
    hostname=$(sys_get_hostname)
    case "$hostname" in
        ""|OpenWrt|openwrt) hostname="Casa CFW-3212" ;;
    esac
'''
        if marker not in text:
            raise SystemExit("hostname marker not found")
        text = text.replace(marker, replacement, 1)
path.write_text(text)
PY

    grep -q 'hostname="Casa CFW-3212"' "$settings_sh" \
        || fail "Could not apply Casa display name fallback patch"
}

patch_casa_reboot() {
    local reboot_sh="$TARGET/scripts/www/cgi-bin/quecmanager/system/reboot.sh"
    [ -f "$reboot_sh" ] || fail "Target missing system/reboot.sh"

    python3 - "$reboot_sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''        qlog_info "Device reboot requested via system menu"
        echo '{"success":true}'
        _reboot_cmd="reboot"
        command -v run_reboot >/dev/null 2>&1 && _reboot_cmd="run_reboot"
        ( ( sleep 1 && $_reboot_cmd ) </dev/null >/dev/null 2>&1 & )
        exit 0
'''
new = '''        qlog_info "Device reboot requested via system menu"
        echo '{"success":true}'
        (
            sleep 1
            if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get service.system.reset >/dev/null 2>&1; then
                rdb_set service.system.reset_reason "QManager web reboot"
                rdb_set service.system.reset.delay 5
                rdb_set service.system.reset 1
            else
                _reboot_cmd="reboot"
                command -v run_reboot >/dev/null 2>&1 && _reboot_cmd="run_reboot"
                $_reboot_cmd
            fi
        ) </dev/null >/dev/null 2>&1 &
        exit 0
'''
if "service.system.reset_reason" not in text:
    if old not in text:
        raise SystemExit("reboot command block not found")
    text = text.replace(old, new, 1)

path.write_text(text)
PY

    grep -q 'service.system.reset_reason "QManager web reboot"' "$reboot_sh" \
        || fail "Could not apply Casa RDB reboot patch"
    grep -q 'service.system.reset.delay 5' "$reboot_sh" \
        || fail "Could not apply Casa RDB reboot delay"
}

patch_casa_poller_boot_identity_cfw3212() {
    # Upstream qmanager_poller's boot-identity gate has a broken OK/QCCID
    # detection: it pipes the compound AT response through `tr -d '<newline>'`
    # which collapses the multi-line response into one long line, and then
    # tries to match `^OK$` and `^+QCCID:` — neither can match after the
    # newlines are gone. The gate therefore fails all 6 retries on a healthy
    # CFW-3212 and the poller caches empty IMEI/IMSI/ICCID/manufacturer/model
    # for the whole session. The actual problem is `\r` from the modem
    # confusing `^OK$`, not `\n`. Stripping `\r` instead preserves line
    # boundaries so the anchored greps match.
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"

    python3 - "$poller" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = "tr -d '\n'"
new = "tr -d '\\r'"

count = text.count(old)
if count == 0:
    # Already patched in a previous run, or upstream changed shape.
    if "Casa CFW-3212 boot-identity tr fix" in text:
        sys.exit(0)
    sys.exit("expected tr -d '\\n' literal not found in qmanager_poller")
if count > 4:
    sys.exit(f"too many tr -d '\\n' matches ({count}); refusing to patch blindly")

# Leave a sentinel comment near the top of the file (after shebang/header) so
# we can detect prior runs without re-scanning the whole file.
patched = text.replace(old, new)
sentinel = "# Casa CFW-3212 boot-identity tr fix applied by build-casa-port.sh\n"
lines = patched.splitlines(keepends=True)
for i, line in enumerate(lines):
    if line.startswith("#!"):
        lines.insert(i + 1, sentinel)
        break
else:
    lines.insert(0, sentinel)
path.write_text("".join(lines))
print(f"patched {count} occurrence(s)")
PY

    grep -q "Casa CFW-3212 boot-identity tr fix" "$poller" \
        || fail "Could not apply Casa boot-identity tr fix to qmanager_poller"
}

patch_casa_ippt_disable_clears_service_cfw3212() {
    # Casa IP Passthrough disable left service.ip_handover.enable=1 and
    # service.ip_handover.last_wwan_ip=192.0.0.2 stuck across reboots
    # because they were marked persistent (`p` flag) but never cleared.
    # The data session stayed bound to the Casa handover placeholder so the
    # router had no real WAN until manual recovery.
    local ippt="$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh"
    [ -f "$ippt" ] || return 0
    python3 - "$ippt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "Casa CFW-3212 ippt service-clear" in text:
    sys.exit(0)

if 'SERVICE_LAST_IP_RDB="service.ip_handover.last_wwan_ip"' not in text:
    text = text.replace(
        'SERVICE_ENABLE_RDB="service.ip_handover.enable"',
        'SERVICE_ENABLE_RDB="service.ip_handover.enable"\n'
        'SERVICE_LAST_IP_RDB="service.ip_handover.last_wwan_ip"',
        1,
    )

if 'PROFILE_WRITEFLAG_RDB' in text:
    target = (
        'if ! rdb set "$PROFILE_ENABLE_RDB" "$ENABLED" 2>/dev/null; then\n'
        '        cgi_error "rdb_write_failed" "Failed to write Casa ip_handover flag"\n'
        '        exit 0\n'
        '    fi\n'
    )
    inject = (
        target
        + '\n'
        + '    # Casa CFW-3212 ippt service-clear: when disabling, also clear the\n'
        + '    # service-level handover flag and cached last WAN IP so the data\n'
        + '    # session stops binding to the Casa handover placeholder across\n'
        + '    # reboots. Keys are persistent (`p` flag) so we set them, not unset.\n'
        + '    if [ "$ENABLED" = "0" ]; then\n'
        + '        rdb set "$SERVICE_ENABLE_RDB" 0 2>/dev/null || true\n'
        + '        rdb setflags "$SERVICE_ENABLE_RDB" p 2>/dev/null || true\n'
        + '        rdb set "$SERVICE_LAST_IP_RDB" "" 2>/dev/null || true\n'
        + '        rdb setflags "$SERVICE_LAST_IP_RDB" p 2>/dev/null || true\n'
        + '    fi\n'
    )
else:
    target = '            rdb_write "$SERVICE_ENABLE_RDB" 0 || true\n'
    inject = (
        target
        + '            # Casa CFW-3212 ippt service-clear: clear service state that\n'
        + '            # persists across reboots after disabling IP Passthrough.\n'
        + '            rdb_setflags "$SERVICE_ENABLE_RDB" p 2>/dev/null || true\n'
        + '            rdb_write "$SERVICE_LAST_IP_RDB" "" || true\n'
        + '            rdb_setflags "$SERVICE_LAST_IP_RDB" p 2>/dev/null || true\n'
    )

if target not in text:
    sys.exit("expected IPPT disable write block not found in ip_passthrough.sh")
text = text.replace(target, inject, 1)
path.write_text(text)
PY

    grep -q "Casa CFW-3212 ippt service-clear" "$ippt" \
        || fail "Could not apply Casa IPPT disable service-clear patch"
}

patch_casa_custom_dns_cfw3212() {
    # Upstream QManager v0.1.11+ Custom DNS feature gates the UI on:
    #   1. get_dns_mode()           — expects <DNSMode> in mobileap_cfg.xml
    #   2. get_passthrough_bypass() — TODO stub, always returns "false"
    # Neither works on Casa CFW-3212:
    #   - Casa's mobileap_cfg.xml has no <DNSMode> element, so the function
    #     always returns "UNKNOWN" and the frontend hides the feature.
    #   - Casa stores IP passthrough state in RDB
    #     (link.profile.1.ip_handover.*), not in the QCMAP XML.
    # This patch rewrites both functions for Casa semantics.
    local dns_cgi="$TARGET/scripts/www/cgi-bin/quecmanager/network/custom_dns.sh"
    [ -f "$dns_cgi" ] || return 0

    python3 - "$dns_cgi" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

new_get_dns_mode = '''get_dns_mode() {
    # Casa CFW-3212: mobileap_cfg.xml has no <DNSMode> element. Detect
    # liveness of the dnsmasq DNS proxy on bridge0 — that is the actual
    # condition the frontend cares about.
    if ps | grep "[ /]dnsmasq .*dnsmasq.conf.bridge0.updated" >/dev/null 2>&1 \\
       && grep -q "^interface=bridge0" /var/run/data/dnsmasq.conf.bridge0.updated 2>/dev/null; then
        printf "PROXY"
    else
        printf "UNKNOWN"
    fi
}'''

new_get_passthrough_bypass = '''get_passthrough_bypass() {
    # Casa CFW-3212: IP passthrough state lives in RDB, not mobileap_cfg.xml.
    # Mirrors the keys QManager ip_passthrough.sh authoritatively writes.
    local enable mode svc
    enable=$(rdb get link.profile.1.ip_handover.enable 2>/dev/null)
    mode=$(rdb get link.profile.1.ip_handover.mode 2>/dev/null)
    svc=$(rdb get service.ip_handover.enable 2>/dev/null)
    if [ "$enable" = "1" ] && [ "$svc" = "1" ] && [ "$mode" = "eth" ]; then
        printf "true"
    else
        printf "false"
    fi
}'''

dns_pattern = re.compile(
    r"get_dns_mode\(\)\s*\{.*?\n\}",
    re.DOTALL,
)
ippt_pattern = re.compile(
    r"get_passthrough_bypass\(\)\s*\{.*?\n\}",
    re.DOTALL,
)

if not dns_pattern.search(text):
    raise SystemExit("get_dns_mode() not found in custom_dns.sh")
if not ippt_pattern.search(text):
    raise SystemExit("get_passthrough_bypass() not found in custom_dns.sh")

text = dns_pattern.sub(new_get_dns_mode, text, count=1)
text = ippt_pattern.sub(new_get_passthrough_bypass, text, count=1)
text = text.replace(
    'STAGING_FILE="/etc/data/qmanager/dnsmasq.conf.new"',
    'STAGING_FILE="/tmp/qmanager-dnsmasq.conf.new"',
)
path.write_text(text)
PY

    grep -q 'Casa CFW-3212: mobileap_cfg.xml has no <DNSMode>' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS get_dns_mode patch"
    grep -q 'link.profile.1.ip_handover.enable' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS get_passthrough_bypass patch"
    grep -q 'STAGING_FILE="/tmp/qmanager-dnsmasq.conf.new"' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS staging path patch"
}

patch_email_alerts_casa_msmtp() {
    local cgi="$TARGET/scripts/www/cgi-bin/quecmanager/monitoring/email_alerts.sh"
    local lib="$TARGET/scripts/usr/lib/qmanager/email_alerts.sh"
    local card="$TARGET/components/monitoring/email-alerts/email-alerts-settings-card.tsx"

    [ -f "$cgi" ] || return 0

    python3 - "$cgi" "$lib" "$card" <<'PY'
from pathlib import Path
import sys

cgi_path = Path(sys.argv[1])
lib_path = Path(sys.argv[2])
card_path = Path(sys.argv[3])

cgi = cgi_path.read_text()

old_detect = '''# Detect package manager (Entware on RM520N-GL, system opkg on OpenWRT)
if [ -x /opt/bin/opkg ]; then
    OPKG="/opt/bin/opkg"
else
    OPKG="opkg"
fi
'''

new_detect = '''# Casa CFW-3212 does not ship Entware opkg. Install msmtp the same way
# the package installer handles Entware tools: download the IPK and extract it
# under /usrdata/opt, then expose a tiny wrapper in /usrdata/bin for CGI/PATH use.
ENTWARE_BASE="${ENTWARE_BASE:-http://bin.entware.net/armv7sf-k3.2}"
ENTWARE_PACKAGES_GZ="/tmp/qmanager_msmtp_packages.gz"
ENTWARE_PACKAGES_TXT="/tmp/qmanager_msmtp_packages.txt"
ENTWARE_STATE_DIR="/usrdata/opt/var/lib/qmanager-entware"
MSMTP_BIN="/usrdata/opt/bin/msmtp"
MSMTP_WRAPPER="/usrdata/bin/msmtp"

msmtp_available() {
    command -v msmtp >/dev/null 2>&1 || [ -x "$MSMTP_WRAPPER" ] || [ -x "$MSMTP_BIN" ]
}

fetch_url() {
    local url="$1"
    local out="$2"
    wget -q "$url" -O "$out" \\
        || curl -fsSL "$url" -o "$out" \\
        || return 1
}

entware_refresh_index() {
    fetch_url "$ENTWARE_BASE/Packages.gz" "$ENTWARE_PACKAGES_GZ" || return 1
    gzip -dc "$ENTWARE_PACKAGES_GZ" > "$ENTWARE_PACKAGES_TXT" || return 1
}

entware_pkg_field() {
    local pkg="$1"
    local field="$2"
    awk -v pkg="$pkg" -v field="$field" '
        $0 == "Package: " pkg { in_pkg=1; next }
        in_pkg && $0 == "" { exit }
        in_pkg && index($0, field ": ") == 1 {
            sub("^" field ": ", "", $0)
            print
            exit
        }
    ' "$ENTWARE_PACKAGES_TXT"
}

entware_pkg_marker() {
    printf "%s/%s.version" "$ENTWARE_STATE_DIR" "$1"
}

extract_ipk_to_usrdata() {
    local ipk="$1"
    local tmpdir data_tar

    tmpdir="$(mktemp -d /tmp/qm-msmtp-ipk.XXXXXX)" || return 1
    data_tar="$tmpdir/data.tar.gz"

    tar xzf "$ipk" -C "$tmpdir" ./data.tar.gz >/dev/null 2>&1 \\
        || { rm -rf "$tmpdir"; return 1; }
    tar xzf "$data_tar" -C /usrdata >/dev/null 2>&1 \\
        || { rm -rf "$tmpdir"; return 1; }

    rm -rf "$tmpdir"
    return 0
}

entware_install_pkg() {
    local pkg="$1"
    local version filename installed marker deps dep cleaned dep_filename tmp_ipk old_ifs

    version="$(entware_pkg_field "$pkg" Version)"
    filename="$(entware_pkg_field "$pkg" Filename)"
    [ -n "$version" ] || return 1
    [ -n "$filename" ] || return 1

    marker="$(entware_pkg_marker "$pkg")"
    installed=""
    [ -f "$marker" ] && installed="$(cat "$marker" 2>/dev/null)"
    if [ "$installed" = "$version" ]; then
        return 0
    fi

    deps="$(entware_pkg_field "$pkg" Depends)"
    if [ -n "$deps" ]; then
        old_ifs="$IFS"
        IFS=','
        for dep in $deps; do
            cleaned="$(printf '%s' "$dep" | sed 's/ *(.*//; s/^ *//; s/ *$//')"
            [ -n "$cleaned" ] || continue
            dep_filename="$(entware_pkg_field "$cleaned" Filename)"
            [ -n "$dep_filename" ] || continue
            if ! entware_install_pkg "$cleaned"; then
                IFS="$old_ifs"
                return 1
            fi
        done
        IFS="$old_ifs"
    fi

    tmp_ipk="/tmp/$(basename "$filename")"
    fetch_url "$ENTWARE_BASE/$filename" "$tmp_ipk" || return 1
    extract_ipk_to_usrdata "$tmp_ipk" || { rm -f "$tmp_ipk"; return 1; }
    rm -f "$tmp_ipk"

    mkdir -p "$ENTWARE_STATE_DIR"
    printf '%s\\n' "$version" > "$marker"
    return 0
}

write_msmtp_wrapper() {
    mkdir -p /usrdata/bin
    cat > "$MSMTP_WRAPPER" <<'EOF'
#!/bin/sh
export LD_LIBRARY_PATH="/usrdata/opt/lib:/usrdata/opt/usr/lib:${LD_LIBRARY_PATH:-}"
exec /usrdata/opt/bin/msmtp "$@"
EOF
    chmod 755 "$MSMTP_WRAPPER"
}
'''

if old_detect in cgi:
    cgi = cgi.replace(old_detect, new_detect, 1)
elif "ENTWARE_PACKAGES_TXT=\"/tmp/qmanager_msmtp_packages.txt\"" not in cgi:
    raise SystemExit("email alert package-manager detection block not found")

old_install = '''    # -------------------------------------------------------------------------
    # action: install — install msmtp via opkg (background)
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "install" ]; then
        MSMTP_INSTALL_RESULT="/tmp/qmanager_msmtp_install.json"
        MSMTP_INSTALL_PID="/tmp/qmanager_msmtp_install.pid"

        # Check if already running
        if [ -f "$MSMTP_INSTALL_PID" ] && pid_alive "$(cat "$MSMTP_INSTALL_PID" 2>/dev/null)"; then
            cgi_error "already_running" "Installation already in progress"
            exit 0
        fi

        # Already installed?
        if command -v msmtp >/dev/null 2>&1; then
            cgi_error "already_installed" "msmtp is already installed"
            exit 0
        fi

        qlog_info "Starting msmtp installation via opkg"

        # Spawn background installer
        (
            echo $$ > "$MSMTP_INSTALL_PID"
            trap 'rm -f "$MSMTP_INSTALL_PID"' EXIT

            printf '{"success":true,"status":"running","message":"Updating package lists..."}' > "$MSMTP_INSTALL_RESULT"
            if ! $OPKG update >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"Failed to update package lists","detail":"Check internet connection and package manager feeds"}' > "$MSMTP_INSTALL_RESULT"
                exit 1
            fi

            printf '{"success":true,"status":"running","message":"Installing msmtp..."}' > "$MSMTP_INSTALL_RESULT"
            if ! $OPKG install msmtp >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"Package manager install failed","detail":"Package may not be available for this architecture"}' > "$MSMTP_INSTALL_RESULT"
                exit 1
            fi

            # Verify
            if command -v msmtp >/dev/null 2>&1; then
                printf '{"success":true,"status":"complete","message":"msmtp installed successfully"}' > "$MSMTP_INSTALL_RESULT"
            else
                printf '{"success":false,"status":"error","message":"Package installed but binary not found"}' > "$MSMTP_INSTALL_RESULT"
            fi
        ) </dev/null >/dev/null 2>&1 &

        cgi_success
        exit 0
    fi
'''

new_install = '''    # -------------------------------------------------------------------------
    # action: install — install msmtp via Casa Entware IPK extraction (background)
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "install" ]; then
        MSMTP_INSTALL_RESULT="/tmp/qmanager_msmtp_install.json"
        MSMTP_INSTALL_PID="/tmp/qmanager_msmtp_install.pid"

        # Check if already running
        if [ -f "$MSMTP_INSTALL_PID" ] && pid_alive "$(cat "$MSMTP_INSTALL_PID" 2>/dev/null)"; then
            cgi_error "already_running" "Installation already in progress"
            exit 0
        fi

        # Already installed?
        if msmtp_available; then
            cgi_error "already_installed" "msmtp is already installed"
            exit 0
        fi

        qlog_info "Starting msmtp installation via Casa Entware IPK extraction"

        # Spawn background installer
        (
            echo $$ > "$MSMTP_INSTALL_PID"
            trap 'rm -f "$MSMTP_INSTALL_PID"' EXIT

            printf '{"success":true,"status":"running","message":"Downloading Entware package index..."}' > "$MSMTP_INSTALL_RESULT"
            if ! entware_refresh_index >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"Failed to download Entware package index","detail":"Check internet connectivity from the modem"}' > "$MSMTP_INSTALL_RESULT"
                exit 1
            fi

            printf '{"success":true,"status":"running","message":"Installing msmtp and dependencies..."}' > "$MSMTP_INSTALL_RESULT"
            if ! entware_install_pkg msmtp >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"Failed to install msmtp","detail":"Entware package download or extraction failed"}' > "$MSMTP_INSTALL_RESULT"
                exit 1
            fi

            if ! write_msmtp_wrapper >/dev/null 2>&1; then
                printf '{"success":false,"status":"error","message":"Failed to create msmtp launcher","detail":"Could not write /usrdata/bin/msmtp"}' > "$MSMTP_INSTALL_RESULT"
                exit 1
            fi

            # Verify
            if msmtp_available; then
                printf '{"success":true,"status":"complete","message":"msmtp installed successfully"}' > "$MSMTP_INSTALL_RESULT"
            else
                printf '{"success":false,"status":"error","message":"Package installed but binary not found"}' > "$MSMTP_INSTALL_RESULT"
            fi
        ) </dev/null >/dev/null 2>&1 &

        cgi_success
        exit 0
    fi
'''

if old_install in cgi:
    cgi = cgi.replace(old_install, new_install, 1)
elif "Casa Entware IPK extraction" not in cgi:
    raise SystemExit("email alert install action block not found")

old_uninstall = '''    # -------------------------------------------------------------------------
    # action: uninstall — remove msmtp package from the device
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "uninstall" ]; then
        # Safety: refuse if email alerts are still enabled
        if [ -f "$CONFIG" ]; then
            ea_enabled=$(jq -r '(.enabled) | if . == null then "false" else tostring end' "$CONFIG" 2>/dev/null)
            if [ "$ea_enabled" = "true" ]; then
                cgi_error "still_enabled" "Disable email alerts before uninstalling msmtp"
                exit 0
            fi
        fi

        qlog_info "Uninstalling msmtp package"

        # Remove package
        $OPKG remove msmtp 2>/dev/null

        # Clean up generated msmtp config
        rm -f "$MSMTP_CONFIG"

        # Verify removal
        if command -v msmtp >/dev/null 2>&1; then
            qlog_error "msmtp binary still present after package manager remove"
            cgi_error "uninstall_failed" "Failed to remove msmtp package"
            exit 0
        fi

        qlog_info "msmtp uninstalled successfully"
        cgi_success
        exit 0
    fi
'''

new_uninstall = '''    # -------------------------------------------------------------------------
    # action: uninstall — remove the Casa-installed msmtp launcher and binary
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "uninstall" ]; then
        # Safety: refuse if email alerts are still enabled
        if [ -f "$CONFIG" ]; then
            ea_enabled=$(jq -r '(.enabled) | if . == null then "false" else tostring end' "$CONFIG" 2>/dev/null)
            if [ "$ea_enabled" = "true" ]; then
                cgi_error "still_enabled" "Disable email alerts before uninstalling msmtp"
                exit 0
            fi
        fi

        qlog_info "Removing Casa-installed msmtp files"

        # Clean up generated config and the package files QManager installs.
        rm -f "$MSMTP_CONFIG" "$MSMTP_WRAPPER" "$MSMTP_BIN" "$(entware_pkg_marker msmtp)"

        # Verify removal. A system-provided msmtp would still be reported.
        if [ -x "$MSMTP_WRAPPER" ] || [ -x "$MSMTP_BIN" ]; then
            qlog_error "Casa msmtp files still present after removal"
            cgi_error "uninstall_failed" "Failed to remove msmtp package"
            exit 0
        fi

        qlog_info "msmtp uninstalled successfully"
        cgi_success
        exit 0
    fi
'''

if old_uninstall in cgi:
    cgi = cgi.replace(old_uninstall, new_uninstall, 1)
elif "Removing Casa-installed msmtp files" not in cgi:
    raise SystemExit("email alert uninstall action block not found")

cgi_path.write_text(cgi)

if lib_path.exists():
    lib = lib_path.read_text()
    old = "for _p in /opt/bin/msmtp /usr/bin/msmtp; do"
    new = "for _p in /usrdata/bin/msmtp /usrdata/opt/bin/msmtp /opt/bin/msmtp /usr/bin/msmtp; do"
    if old in lib:
        lib = lib.replace(old, new, 1)
    elif new not in lib:
        raise SystemExit("email alert msmtp binary search path not found")
    lib_path.write_text(lib)

if card_path.exists():
    card = card_path.read_text()
    card = card.replace('import { CopyableCommand } from "@/components/ui/copyable-command";\n', '')
    card = card.replace(
        "Install automatically or run the command manually.",
        "Install automatically using the Casa Entware package flow.",
    )
    manual = '''            <div className="w-full flex items-center gap-3 text-xs text-muted-foreground">
              <div className="h-px flex-1 bg-border" />
              <span>or install manually</span>
              <div className="h-px flex-1 bg-border" />
            </div>

            <CopyableCommand command="opkg update && opkg install msmtp" />
'''
    if manual in card:
        card = card.replace(manual, "", 1)
    elif 'opkg update && opkg install msmtp' in card:
        raise SystemExit("email alert manual opkg command still present")
    card_path.write_text(card)
PY

    grep -q 'ENTWARE_PACKAGES_TXT="/tmp/qmanager_msmtp_packages.txt"' "$cgi" \
        || fail "Could not apply Casa msmtp Entware installer patch"
    grep -q 'Casa Entware IPK extraction' "$cgi" \
        || fail "Could not apply Casa msmtp install action patch"
    if [ -f "$card" ]; then
        ! grep -q 'opkg update && opkg install msmtp' "$card" \
            || fail "Email alerts UI still references opkg msmtp install"
    fi
}

patch_package_version() {
    local pkg="$TARGET/package.json"
    [ -f "$pkg" ] || fail "package.json missing in target"
    if command -v perl >/dev/null 2>&1; then
        perl -0pi -e "s/\"version\"\\s*:\\s*\"[^\"]+\"/\"version\": \"$VERSION_NAME\"/" "$pkg"
    else
        sed -i.bak "0,/\"version\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/s//\"version\": \"$VERSION_NAME\"/" "$pkg"
        rm -f "$pkg.bak"
    fi
}

patch_ping_profile_service_toggle_cfw3212() {
    local cgi="$TARGET/scripts/www/cgi-bin/quecmanager/settings/ping_profile.sh"
    local hook="$TARGET/hooks/use-ping-profile.ts"
    local card="$TARGET/components/system-settings/connection-quality/connectivity-sensitivity-card.tsx"
    [ -f "$cgi" ] || return 0
    [ -f "$hook" ] || return 0
    [ -f "$card" ] || return 0

    python3 - "$cgi" "$hook" "$card" <<'PY'
from pathlib import Path
import sys

cgi, hook, card = map(Path, sys.argv[1:4])

text = cgi.read_text()
text = text.replace(
    'RELOAD_FLAG="${PING_PROFILE_RELOAD_FLAG:-/tmp/qmanager_ping_reload}"\n',
    'RELOAD_FLAG="${PING_PROFILE_RELOAD_FLAG:-/tmp/qmanager_ping_reload}"\nSERVICE_NAME="${PING_SERVICE_NAME:-qmanager-ping.service}"\n',
    1,
) if 'PING_SERVICE_NAME' not in text else text
text = text.replace(
    '    if [ -f "$CONFIG" ]; then\n        v=$(jq -r \'.profile // empty\' "$CONFIG" 2>/dev/null) || v=""\n',
    '    service_enabled=false\n    service_active=false\n    service_available=false\n    if command -v systemctl >/dev/null 2>&1; then\n        service_available=true\n        systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1 && service_enabled=true\n        systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1 && service_active=true\n    fi\n    runtime="unknown"\n    if pgrep -f "/usrdata/bin/qmanager_ping_rust" >/dev/null 2>&1; then\n        runtime="rust"\n    elif pgrep -f "/usrdata/bin/qmanager_ping_shell" >/dev/null 2>&1; then\n        runtime="shell"\n    elif [ "$service_active" = "false" ]; then\n        runtime="stopped"\n    fi\n\n    if [ -f "$CONFIG" ]; then\n        v=$(jq -r \'.profile // empty\' "$CONFIG" 2>/dev/null) || v=""\n',
    1,
) if 'service_available=false' not in text else text
text = text.replace(
'''    jq -n \\
        --arg profile "$profile" \\
        --arg target_1 "$target_1" \\
        --arg target_2 "$target_2" \\
        '{success: true, settings: {profile: $profile, target_1: $target_1, target_2: $target_2}}'
''',
'''    jq -n \\
        --arg profile "$profile" \\
        --arg target_1 "$target_1" \\
        --arg target_2 "$target_2" \\
        --argjson service_enabled "$service_enabled" \\
        --argjson service_active "$service_active" \\
        --argjson service_available "$service_available" \\
        --arg runtime "$runtime" \\
        '{success: true, settings: {profile: $profile, target_1: $target_1, target_2: $target_2, service_enabled: $service_enabled, service_active: $service_active, service_available: $service_available, runtime: $runtime}}'
''',
    1,
) if 'service_enabled: $service_enabled' not in text else text
if 'set_service_enabled' not in text:
    text = text.replace(
'''    if [ "$ACTION" != "save_settings" ]; then
''',
'''    if [ "$ACTION" = "set_service_enabled" ]; then
        enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end' 2>/dev/null)
        case "$enabled" in
            true|1)
                systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || { cgi_error "service_enable_failed" "Failed to enable qmanager-ping"; exit 0; }
                systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || { cgi_error "service_start_failed" "Failed to start qmanager-ping"; exit 0; }
                ;;
            false|0)
                systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
                ;;
            *)
                cgi_error "invalid_enabled" "enabled must be true or false"
                exit 0
                ;;
        esac
        service_enabled=false
        service_active=false
        systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1 && service_enabled=true
        systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1 && service_active=true
        runtime="unknown"
        if pgrep -f "/usrdata/bin/qmanager_ping_rust" >/dev/null 2>&1; then runtime="rust"; elif pgrep -f "/usrdata/bin/qmanager_ping_shell" >/dev/null 2>&1; then runtime="shell"; elif [ "$service_active" = "false" ]; then runtime="stopped"; fi
        jq -n --argjson service_enabled "$service_enabled" --argjson service_active "$service_active" --arg runtime "$runtime" '{success:true, service_enabled:$service_enabled, service_active:$service_active, runtime:$runtime}'
        exit 0
    fi

    if [ "$ACTION" != "save_settings" ]; then
''',
        1,
    )
cgi.write_text(text)

text = hook.read_text()
text = text.replace('  target_2: string;\n}', '  target_2: string;\n  service_enabled?: boolean;\n  service_active?: boolean;\n  service_available?: boolean;\n  runtime?: "rust" | "shell" | "stopped" | "unknown";\n}', 1) if 'service_enabled?: boolean;' not in text else text
text = text.replace('  detail?: string;\n}', '  detail?: string;\n  service_enabled?: boolean;\n  service_active?: boolean;\n  runtime?: "rust" | "shell" | "stopped" | "unknown";\n}', 1) if 'service_active?: boolean;' not in text.split('interface PingProfileResponse', 1)[1].split('export interface', 1)[0] else text
if 'serviceEnabled: boolean | undefined;' not in text:
    text = text.replace('  target2: string | undefined;\n', '  target2: string | undefined;\n  serviceEnabled: boolean | undefined;\n  serviceActive: boolean | undefined;\n  serviceAvailable: boolean | undefined;\n  runtime: "rust" | "shell" | "stopped" | "unknown" | undefined;\n')
    text = text.replace('  isSaving: boolean;\n', '  isSaving: boolean;\n  isTogglingService: boolean;\n')
    text = text.replace('  }) => Promise<PingProfileResponse>;\n}', '  }) => Promise<PingProfileResponse>;\n  toggleService: (enabled: boolean) => Promise<PingProfileResponse>;\n}')
if 'const [serviceEnabled' not in text:
    text = text.replace('  const [target2, setTarget2] = useState<string | undefined>(undefined);\n', '  const [target2, setTarget2] = useState<string | undefined>(undefined);\n  const [serviceEnabled, setServiceEnabled] = useState<boolean | undefined>(undefined);\n  const [serviceActive, setServiceActive] = useState<boolean | undefined>(undefined);\n  const [serviceAvailable, setServiceAvailable] = useState<boolean | undefined>(undefined);\n  const [runtime, setRuntime] = useState<"rust" | "shell" | "stopped" | "unknown" | undefined>(undefined);\n')
    text = text.replace('  const [isSaving, setIsSaving] = useState(false);\n', '  const [isSaving, setIsSaving] = useState(false);\n  const [isTogglingService, setIsTogglingService] = useState(false);\n')
if 'setServiceEnabled(json.settings.service_enabled);' not in text:
    text = text.replace('      setTarget2(json.settings.target_2);\n', '      setTarget2(json.settings.target_2);\n      setServiceEnabled(json.settings.service_enabled);\n      setServiceActive(json.settings.service_active);\n      setServiceAvailable(json.settings.service_available);\n      setRuntime(json.settings.runtime);\n', 1)
if 'const toggleService = useCallback' not in text:
    text = text.replace('  return {\n', '''  const toggleService = useCallback(async (enabled: boolean): Promise<PingProfileResponse> => {
    setSaveError(null);
    setIsTogglingService(true);
    try {
      const resp = await authFetch(ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action: "set_service_enabled", enabled }),
      });
      const json: PingProfileResponse = await resp.json();
      if (!mountedRef.current) return json;
      if (!json.success) throw new Error(json.detail ?? json.error ?? "Service toggle failed");
      setServiceEnabled(json.service_enabled ?? enabled);
      setServiceActive(json.service_active ?? enabled);
      setRuntime(json.runtime);
      fetchProfile(true);
      return json;
    } catch (err) {
      const msg = err instanceof Error ? err.message : "Service toggle failed";
      if (mountedRef.current) setSaveError(msg);
      throw err;
    } finally {
      if (mountedRef.current) setIsTogglingService(false);
    }
  }, [fetchProfile]);

  return {
''', 1)
if '\n    serviceEnabled,\n' not in text:
    text = text.replace('    target2,\n', '    target2,\n    serviceEnabled,\n    serviceActive,\n    serviceAvailable,\n    runtime,\n')
    text = text.replace('    isSaving,\n', '    isSaving,\n    isTogglingService,\n')
    text = text.replace('    save,\n', '    save,\n    toggleService,\n')
hook.write_text(text)

text = card.read_text()
if 'components/ui/switch' not in text:
    text = text.replace('import { Button } from "@/components/ui/button";\n', 'import { Button } from "@/components/ui/button";\nimport { Switch } from "@/components/ui/switch";\n', 1)
if 'serviceEnabled,' not in text:
    text = text.replace('    target2,\n    isLoading,', '    target2,\n    serviceEnabled,\n    serviceActive,\n    serviceAvailable,\n    runtime,\n    isTogglingService,\n    isLoading,')
    text = text.replace('    save,\n  } = usePingProfile();', '    save,\n    toggleService,\n  } = usePingProfile();')
if 'id="ping-service-enabled"' not in text:
    text = text.replace('        {saveError && (\n', '''        {serviceAvailable && (
          <div className="mb-4 flex items-center justify-between gap-4 rounded-md border p-3">
            <div className="space-y-0.5">
              <div className="flex items-center gap-2">
                <Label htmlFor="ping-service-enabled">Latency monitor</Label>
                <span className={`inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[11px] font-medium ${runtime === "rust" ? "text-emerald-600" : runtime === "shell" ? "text-amber-600" : "text-muted-foreground"}`}>
                  <span className={`size-1.5 rounded-full ${runtime === "rust" ? "bg-emerald-500" : runtime === "shell" ? "bg-amber-500" : "bg-muted-foreground"}`} />
                  {runtime === "rust" ? "Rust" : runtime === "shell" ? "Shell" : runtime === "stopped" ? "Off" : "Unknown"}
                </span>
              </div>
              <p className="text-xs text-muted-foreground">
                {serviceActive ? "Service is running." : "Service is stopped."}
              </p>
            </div>
            <Switch
              id="ping-service-enabled"
              checked={serviceEnabled ?? false}
              disabled={isTogglingService}
              onCheckedChange={async (checked) => {
                try {
                  await toggleService(checked);
                  toast.success(checked ? "Latency monitor enabled" : "Latency monitor disabled");
                } catch (e) {
                  const msg = e instanceof Error ? e.message : "Failed to update latency monitor";
                  toast.error(msg);
                }
              }}
              aria-label="Enable latency monitor service"
            />
          </div>
        )}

        {saveError && (
''', 1)
card.write_text(text)
PY
}

patch_software_update_reboot_required_cfw3212() {
    local hook="$TARGET/hooks/use-software-update.ts"
    local page="$TARGET/components/monitoring/software-update/software-update.tsx"
    local card="$TARGET/components/monitoring/software-update/update-status-card.tsx"
    if [ ! -f "$page" ]; then
        page="$TARGET/components/system-settings/software-update/software-update.tsx"
    fi
    if [ ! -f "$card" ]; then
        card="$TARGET/components/system-settings/software-update/update-status-card.tsx"
    fi
    [ -f "$hook" ] || fail "use-software-update.ts missing in target"
    [ -f "$page" ] || fail "software-update.tsx missing in target"
    [ -f "$card" ] || fail "update-status-card.tsx missing in target"

    python3 - "$hook" "$page" "$card" <<'PY'
from pathlib import Path
import sys

hook, page, card = map(Path, sys.argv[1:4])

def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if new in text:
        return
    if old not in text:
        raise SystemExit(f"patch target not found in {path}: {old[:80]!r}")
    path.write_text(text.replace(old, new, 1))

replace_once(
    hook,
    '  current_changelog: string | null;\n',
    '  current_changelog: string | null;\n  joetooley_changelog: string | null;\n  upstream_changelog: string | null;\n  current_joetooley_changelog: string | null;\n  current_upstream_changelog: string | null;\n  upstream_release_url: string | null;\n',
)

replace_once(
    hook,
    '  status: "idle" | "downloading" | "installing" | "rebooting" | "error";',
    '  status: "idle" | "downloading" | "installing" | "reboot_required" | "rebooting" | "error";',
)
hook_text = hook.read_text()
if '  rebootNow: () => Promise<void>;' not in hook_text:
    if '  installUpdate: () => Promise<void>;\n  togglePrerelease:' in hook_text:
        hook.write_text(hook_text.replace(
            '  installUpdate: () => Promise<void>;\n  togglePrerelease:',
            '  installUpdate: () => Promise<void>;\n  rebootNow: () => Promise<void>;\n  togglePrerelease:',
            1,
        ))
    elif '  installUpdate: () => Promise<void>;\n  rebootDevice:' in hook_text:
        hook.write_text(hook_text.replace(
            '  installUpdate: () => Promise<void>;\n  rebootDevice:',
            '  installUpdate: () => Promise<void>;\n  rebootNow: () => Promise<void>;\n  rebootDevice:',
            1,
        ))
    else:
        raise SystemExit("patch target not found in use-software-update.ts: installUpdate return type")
hook_text = hook.read_text()
if 'json.status === "reboot_required"' not in hook_text:
    hook.write_text(hook_text.replace(
        '''        if (json.status === "rebooting") {
''',
        '''        if (json.status === "reboot_required") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          sessionStorage.removeItem("qm_update_reload_scheduled");
          setIsUpdating(false);
          return;
        }

        if (json.status === "rebooting") {
''',
        1,
    ))
hook_text = hook.read_text()
if "QManager services are restarting; reconnecting" not in hook_text:
    old_catch = '''      } catch {
        // Fetch failed — device is likely rebooting already. Navigate
        // immediately; if the static page is uncached and lighttpd is
        // already gone the user will see a connection error, but waiting
        // doesn't help since the device won't come back any sooner.
        if (pollRef.current) clearInterval(pollRef.current);
        pollRef.current = null;
        sessionStorage.setItem("qm_rebooting", "1");
        document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
        window.location.href = "/reboot/";
      }
'''
    if old_catch not in hook_text:
        old_catch = '''      } catch {
        clearInstallStallTimer();
        // Device may be rebooting — stop polling and redirect
        if (pollRef.current) clearInterval(pollRef.current);
        pollRef.current = null;

        setTimeout(() => {
          sessionStorage.setItem("qm_rebooting", "1");
          document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
          window.location.href = "/reboot/";
        }, 2000);
      }
'''
    if old_catch not in hook_text:
        raise SystemExit("patch target not found in use-software-update.ts: install status catch")
    hook.write_text(hook_text.replace(old_catch, '''      } catch {
        // Casa restarts QManager/lighttpd during install. A failed poll here is
        // expected while services restart, so keep polling until the worker
        // reports reboot_required or a real error. Navigate once to the UI
        // root as a fallback for users left on a stale nested route.
        if (!sessionStorage.getItem("qm_update_reload_scheduled")) {
          sessionStorage.setItem("qm_update_reload_scheduled", "1");
          window.setTimeout(() => {
            window.location.assign("/");
          }, 30000);
        }
        setError(null);
        setUpdateStatus({
          status: "installing",
          message: "QManager services are restarting; reconnecting. This page will return to the main QManager screen in about 30 seconds if the status does not recover.",
        });
      }
''', 1))
replace_once(
    hook,
    '  const togglePrerelease = useCallback(async (enabled: boolean) => {\n',
    '''  const rebootNow = useCallback(async () => {
    setError(null);
    setUpdateStatus({ status: "rebooting", message: "Rebooting device..." });
    sessionStorage.setItem("qm_rebooting", "1");
    document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
    fetch(CGI_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "reboot_now" }),
      keepalive: true,
    }).catch(() => {});
    window.location.href = "/reboot/";
  }, []);

  const togglePrerelease = useCallback(async (enabled: boolean) => {
''',
)
hook_text = hook.read_text()
if '\n    rebootNow,\n' not in hook_text:
    if '    installStaged,\n    installUpdate,\n    togglePrerelease,\n' in hook_text:
        hook.write_text(hook_text.replace(
            '    installStaged,\n    installUpdate,\n    togglePrerelease,\n',
            '    installStaged,\n    installUpdate,\n    rebootNow,\n    togglePrerelease,\n',
            1,
        ))
    elif '    installStaged,\n    installUpdate,\n    rebootDevice,\n' in hook_text:
        hook.write_text(hook_text.replace(
            '    installStaged,\n    installUpdate,\n    rebootDevice,\n',
            '    installStaged,\n    installUpdate,\n    rebootNow,\n    rebootDevice,\n',
            1,
        ))
    else:
        raise SystemExit("patch target not found in use-software-update.ts: returned installUpdate block")

replace_once(
    page,
    '''  // ── Updating state (replaces entire card grid) ────────────────────────
  if (isUpdating && updateStatus.status !== "error") {
''',
    '''  // ── Updating state (replaces entire card grid) ────────────────────────
  if (isUpdating && updateStatus.status !== "error" && updateStatus.status !== "reboot_required") {
''',
)
replace_once(
    page,
    '  downloading: 0,\n  installing: 1,\n  rebooting: 2,\n',
    '  downloading: 0,\n  installing: 1,\n  reboot_required: 2,\n  rebooting: 2,\n',
)
replace_once(
    page,
    '          installStaged={hookData.installStaged}\n',
    '          installStaged={hookData.installStaged}\n          rebootNow={hookData.rebootNow}\n',
)
page_text = page.read_text()
if 'updateStatus.status === "reboot_required"' not in page_text.split('export function StatusBadge', 1)[1].split('if (isDownloading)', 1)[0]:
    old_badge = '''  if (isUpdating && updateStatus.status !== "error") {
    return (
      <Badge variant="outline" className="bg-info/15 text-info hover:bg-info/20 border-info/30">
        <DownloadIcon className="size-3" />
        {t("software_update.badge_updating")}
      </Badge>
    );
  }
'''
    new_badge = '''  if (updateStatus.status === "reboot_required") {
    return (
      <Badge variant="outline" className="bg-warning/15 text-warning hover:bg-warning/20 border-warning/30">
        <TriangleAlertIcon className="size-3" />
        Reboot required
      </Badge>
    );
  }
  if (isUpdating && updateStatus.status !== "error") {
    return (
      <Badge variant="outline" className="bg-info/15 text-info hover:bg-info/20 border-info/30">
        <DownloadIcon className="size-3" />
        {t("software_update.badge_updating")}
      </Badge>
    );
  }
'''
    if old_badge not in page_text:
        old_badge = '''  if (isUpdating && updateStatus.status !== "error") {
    return (
      <Badge variant="outline" className="bg-info/15 text-info hover:bg-info/20 border-info/30">
        <DownloadIcon className="h-3 w-3" />
        Updating
      </Badge>
    );
  }
'''
        new_badge = '''  if (updateStatus.status === "reboot_required") {
    return (
      <Badge variant="outline" className="bg-warning/15 text-warning hover:bg-warning/20 border-warning/30">
        <TriangleAlertIcon className="h-3 w-3" />
        Reboot required
      </Badge>
    );
  }
  if (isUpdating && updateStatus.status !== "error") {
    return (
      <Badge variant="outline" className="bg-info/15 text-info hover:bg-info/20 border-info/30">
        <DownloadIcon className="h-3 w-3" />
        Updating
      </Badge>
    );
  }
'''
    if old_badge not in page_text:
        raise SystemExit("patch target not found in software-update.tsx: StatusBadge updating block")
    page.write_text(page_text.replace(old_badge, new_badge, 1))

replace_once(card, '  RefreshCwIcon,\n', '  RefreshCwIcon,\n  RotateCwIcon,\n')
replace_once(card, '  installStaged: () => Promise<void>;\n', '  installStaged: () => Promise<void>;\n  rebootNow: () => Promise<void>;\n')
replace_once(card, '  installStaged,\n}: UpdateStatusCardProps) {\n', '  installStaged,\n  rebootNow,\n}: UpdateStatusCardProps) {\n')
replace_once(card, '  const [showInstallDialog, setShowInstallDialog] = useState(false);\n  const [showChangelog, setShowChangelog] = useState(false);\n', '  const [showInstallDialog, setShowInstallDialog] = useState(false);\n  const [showChangelog, setShowChangelog] = useState(false);\n  const [releaseNotesSource, setReleaseNotesSource] = useState<"joetooley" | "upstream">("joetooley");\n')
replace_once(
    card,
    '''  const updateAvailable = updateInfo?.update_available ?? false;
  const displayError = updateInfo?.check_error || error;
''',
    '''  const updateAvailable = updateInfo?.update_available ?? false;
  const displayError = updateInfo?.check_error || error;
  const rebootRequired = updateStatus.status === "reboot_required";
  const releaseNotes = (() => {
    if (!updateInfo) {
      return { body: null as string | null, hasStructuredNotes: false };
    }
    const joetooleyBody = updateAvailable
      ? updateInfo.joetooley_changelog
      : updateInfo.current_joetooley_changelog;
    const upstreamBody = updateAvailable
      ? updateInfo.upstream_changelog
      : updateInfo.current_upstream_changelog;
    const fallbackBody = updateAvailable
      ? updateInfo.changelog
      : updateInfo.current_changelog;
    const hasStructuredNotes = Boolean(joetooleyBody || upstreamBody);

    if (releaseNotesSource === "upstream") {
      const upstreamLink = updateInfo.upstream_release_url
        ? `[View upstream release notes](${updateInfo.upstream_release_url})`
        : null;
      return {
        body: upstreamBody || upstreamLink || fallbackBody,
        hasStructuredNotes,
      };
    }

    return {
      body: joetooleyBody || fallbackBody,
      hasStructuredNotes,
    };
  })();
''',
)
card_text = card.read_text()
if "releaseNotes.hasStructuredNotes" not in card_text:
    start = card_text.find('            {/* ── Inline release notes (clickable → dialog) ────────── */}')
    end = card_text.find('            {/* ── Download progress', start)
    if start == -1 or end == -1:
        raise SystemExit("patch target not found in update-status-card.tsx: release notes block")
    new_release_notes = '''            {/* ── Inline release notes (clickable → dialog) ────────── */}
            {releaseNotes.body && (
              <>
                <Separator />
                <motion.div variants={itemVariants} className="flex flex-col gap-2 min-w-0">
                  <div className="flex flex-wrap items-center justify-between gap-2">
                    <p className="font-semibold text-sm">
                      {updateAvailable
                        ? "Release Notes"
                        : "Current Release Notes"}
                    </p>
                    <div className="flex flex-wrap items-center gap-2">
                      {releaseNotes.hasStructuredNotes && (
                        <div className="inline-flex rounded-md border bg-background p-0.5">
                          <Button
                            type="button"
                            variant={releaseNotesSource === "joetooley" ? "secondary" : "ghost"}
                            size="sm"
                            className="h-7 px-2 text-xs"
                            onClick={() => setReleaseNotesSource("joetooley")}
                          >
                            Joetooley
                          </Button>
                          <Button
                            type="button"
                            variant={releaseNotesSource === "upstream" ? "secondary" : "ghost"}
                            size="sm"
                            className="h-7 px-2 text-xs"
                            onClick={() => setReleaseNotesSource("upstream")}
                          >
                            Rus | Ame / Dr. D
                          </Button>
                        </div>
                      )}
                      <Button
                        variant="ghost"
                        size="sm"
                        className="text-xs text-muted-foreground"
                        onClick={() => setShowChangelog(true)}
                      >
                        <FileTextIcon className="size-3.5" />
                        View full
                      </Button>
                    </div>
                  </div>
                  <div
                    role="region"
                    aria-label="Release notes"
                    tabIndex={0}
                    className={`max-h-64 overflow-y-auto overflow-x-hidden wrap-break-word rounded-lg border bg-muted/50 p-4 ${PROSE_CLASSES}`}
                  >
                    <Markdown>{releaseNotes.body}</Markdown>
                  </div>
                </motion.div>
              </>
            )}
'''
    card.write_text(card_text[:start] + new_release_notes + card_text[end:])
replace_once(
    card,
    '''            <Markdown>
              {(updateAvailable ? updateInfo?.changelog : updateInfo?.current_changelog) ?? ""}
            </Markdown>
''',
    '''            <Markdown>
              {releaseNotes.body ?? ""}
            </Markdown>
''',
)
replace_once(
    card,
    '''          <motion.div
            className="grid gap-2 min-w-0"
''',
    '''          {rebootRequired && (
            <Alert className="mb-4 border-warning/30 bg-warning/10">
              <AlertTriangleIcon className="size-4 text-warning" />
              <AlertDescription className="flex flex-col gap-3 text-warning">
                <span>
                  {updateStatus.message || "Installation complete. Reboot when ready to finish applying the update."}
                </span>
                <span className="flex flex-wrap gap-2">
                  <Button variant="outline" size="sm" onClick={rebootNow}>
                    <RotateCwIcon className="size-4" />
                    Reboot Now
                  </Button>
                  <span className="self-center text-xs text-muted-foreground">
                    Or reboot later from the user menu.
                  </span>
                </span>
              </AlertDescription>
            </Alert>
          )}

          <motion.div
            className="grid gap-2 min-w-0"
''',
)
card_text = card.read_text()
old_auto_reboot_text = '''              The device will reboot automatically after installation. Do not
              power off the device during the update.
'''
if old_auto_reboot_text in card_text and "QManager will restart its services after installation" not in card_text:
    card.write_text(card_text.replace(old_auto_reboot_text, '''              QManager will restart its services after installation and then
              ask you to reboot when ready. Do not power off the device during
              the update.
''', 1))

for path in (hook, page, card):
    if "reboot_required" not in path.read_text():
        raise SystemExit(f"reboot_required patch missing from {path}")
PY
}

patch_installer_version_cfw3212() {
    local installer="$TARGET/install_cfw3212.sh"
    [ -f "$installer" ] || fail "Casa installer missing in target"

    local py_bin
    py_bin="$(command -v python3 || command -v python || true)"
    [ -n "$py_bin" ] || fail "python3/python is required to patch install_cfw3212.sh safely"

    "$py_bin" - "$installer" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if 'VERSION="' not in text:
    marker = 'CONF_DIR="/etc/qmanager"\n'
    if marker not in text:
        raise SystemExit("CONF_DIR marker not found")
    text = text.replace(marker, marker + 'VERSION="v0.0.0-cfw3212.0"\n', 1)

write_marker = 'mkdir -p "$CONF_DIR/profiles" "$CONF_DIR/backups"\n'
write_block = (
    'mkdir -p "$CONF_DIR/profiles" "$CONF_DIR/backups"\n'
    'printf \'%s\\n\' "$VERSION" > "$CONF_DIR/VERSION"\n'
    'info "Version recorded: $VERSION"\n'
)
if 'Version recorded: $VERSION' not in text:
    if write_marker not in text:
        raise SystemExit("config mkdir marker not found")
    text = text.replace(write_marker, write_block, 1)

path.write_text(text)
PY

    grep -q '^VERSION=' "$installer" \
        || fail "Casa installer must expose VERSION for build-time replacement"
    if command -v perl >/dev/null 2>&1; then
        perl -0pi -e "s/^VERSION=\"[^\"]*\"/VERSION=\"$CASA_VERSION_NAME\"/m" "$installer"
    else
        sed -i.bak "s|^VERSION=\"[^\"]*\"|VERSION=\"$CASA_VERSION_NAME\"|" "$installer"
        rm -f "$installer.bak"
    fi
    grep -q 'Version recorded: \$VERSION' "$installer" \
        || fail "Casa installer must write /etc/qmanager/VERSION"
}

prepare_target() {
    if [ "$SKIP_FETCH" = "1" ]; then
        [ -d "$TARGET" ] || fail "--skip-fetch requested but target does not exist: $TARGET"
        log "Using existing target: $TARGET"
        return
    fi

    if [ -e "$TARGET" ]; then
        [ "$FORCE" = "1" ] || fail "Target exists: $TARGET (rerun with --force to replace it)"
        [ "$TARGET_ABS" != "$REF_ABS" ] || fail "Refusing to replace the Casa reference tree with --force: $TARGET"
        log "Removing existing target because --force was supplied"
        rm -rf "$TARGET"
    fi

    mkdir -p "$FETCH_ROOT"
    rm -rf "$FETCH_DIR"

    log "Fetching upstream $VERSION_NAME from $UPSTREAM_REPO"
    if git clone --depth 1 --branch "$VERSION_NAME" "$UPSTREAM_REPO" "$FETCH_DIR"; then
        :
    else
        fail "Could not clone tag $VERSION_NAME from upstream"
    fi

    rm -rf "$FETCH_DIR/.git"
    cp -R "$FETCH_DIR" "$TARGET"
    [ "$KEEP_FETCH" = "1" ] || rm -rf "$FETCH_DIR"
}

apply_casa_overlays() {
    log "Applying Casa CFW-3212 overlays from $REF_DIR"

    patch_build_script

    copy_template_or_fallback "install_cfw3212.sh" "$TEMPLATE_DIR/install_cfw3212.sh"
    patch_installer_version_cfw3212

    if [ -f "$TEMPLATE_DIR/uninstall_cfw3212.sh" ] || [ -f "$REF_DIR/uninstall_cfw3212.sh" ]; then
        copy_template_or_fallback "uninstall_cfw3212.sh" "$TEMPLATE_DIR/uninstall_cfw3212.sh"
    else
        write_uninstall_cfw3212
    fi

    if [ -f "$REF_DIR/qmanager-installer-cfw3212.sh" ]; then
        copy_file "qmanager-installer-cfw3212.sh"
    elif [ -f "$TEMPLATE_DIR/qmanager-installer-cfw3212.sh" ]; then
        copy_file_or_fallback "qmanager-installer-cfw3212.sh" "$TEMPLATE_DIR/qmanager-installer-cfw3212.sh"
    else
        write_qmanager_installer_cfw3212
    fi

    if [ -f "$REF_DIR/components/local-network/ip-passthrough/ip-passthrough-card.tsx" ] \
        && ! grep -q "ECM\\|MBIM\\|RNDIS\\|USB Tethering\\|Enter Manually\\|QCFG" "$REF_DIR/components/local-network/ip-passthrough/ip-passthrough-card.tsx"; then
        copy_file "components/local-network/ip-passthrough/ip-passthrough-card.tsx"
    else
        write_ippt_card_cfw3212
    fi

    if [ -f "$REF_DIR/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh" ] \
        && grep -q "ip_handover" "$REF_DIR/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh"; then
        copy_file "scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh"
    else
        write_ippt_backend_cfw3212
    fi

    write_update_cfw3212

    pin_casa_stable_ping_rust
    patch_qmanager_health_check_paths_cfw3212
    patch_qmanager_poller
    patch_disable_profile_auto_apply
    patch_casa_iccid_and_staleness_cfw3212
    patch_logging_cfw3212
    patch_qmanager_display_version
    patch_casa_display_name
    patch_casa_reboot
    patch_casa_custom_dns_cfw3212
    patch_casa_poller_boot_identity_cfw3212
    patch_casa_ippt_disable_clears_service_cfw3212
    patch_email_alerts_casa_msmtp
    patch_ping_profile_service_toggle_cfw3212
    patch_software_update_reboot_required_cfw3212

    write_qmanager_update_cfw3212
    write_qmanager_auto_update_cfw3212

    patch_package_version
}

write_smoke_checklist() {
    local file="$TARGET/CFW3212_SMOKE_TEST_CHECKLIST.md"
    cat > "$file" <<'EOF'
# Casa CFW-3212 QManager Smoke Test Checklist

Build: @VERSION_NAME@-cfw3212.1

## Before install

- Confirm target is Casa CFW-3212 and `/usrdata` has at least 30 MB free.
- Confirm `/dev/smd11` exists.
- Confirm `/etc` overlay is writable.
- Keep an SSH or serial recovery path available.
- Do not run on the old known-good folder: `qmanager/qmanager_work`.

## Install

- Copy `qmanager-build/qmanager.tar.gz` to `/tmp/qmanager.tar.gz` on the router.
- Run: `tar xzf /tmp/qmanager.tar.gz -C /tmp/`
- Run: `sh /tmp/qmanager_install/install_cfw3212.sh`
- Confirm the installer reports HTTP `9080` and HTTPS `9000`.

## Service checks

- `systemctl status lighttpd`
- `systemctl status qmanager-poller`
- `systemctl status qmanager-ping`
- `/usrdata/opt/lib/ld-linux.so.3 --library-path /usrdata/opt/lib /usrdata/opt/sbin/lighttpd -tt -f /usrdata/qmanager/lighttpd.conf`

## Web UI checks

- Open QManager at `https://<router-lan-ip>:9000/`.
- Create or verify the QManager login.
- Dashboard loads modem identity, signal, and latency data.
- AT terminal uses `/dev/smd11` through bundled `atcli_smd11`.
- IP Passthrough page only exposes Disabled and Enabled Ethernet.
- IP Passthrough never offers USB, ECM, MBIM, RNDIS, NAT, DNS offload, or MAC editing.

## Safety checks on device

- `grep -R 'QCFG="usbnet",' /usrdata/qmanager/www/cgi-bin/quecmanager /usrdata/bin || true`
- `grep -R 'QMAP="MPDN_rule"' /usrdata/qmanager/www/cgi-bin/quecmanager /usrdata/bin || true`
- `grep -R 'qmanager_auto_update' /var/spool/cron/crontabs /etc/crontabs 2>/dev/null || true`
- Confirm package update checks Casa package releases only.
- Confirm auto-update remains disabled and no qmanager_auto_update cron entry exists.
- Confirm package download verifies SHA-256 before install is useful.
- Confirm manual SIM Profile save/apply/delete/deactivate works.
- Confirm SIM Profile apply can set APN, TTL/HL, IMEI, and AT+CFUN=1,1.
- Confirm boot/SIM-switch/watchdog profile auto-apply remains disabled unless
  intentionally building with CASA_PROFILE_AUTO_APPLY=1.

## Rollback

- Run: `sh /tmp/qmanager_install/uninstall_cfw3212.sh --force --no-reboot`
- Reboot manually when ready.
- Entware under `/usrdata/opt` and config under `/etc/qmanager` are preserved unless purge is requested.
EOF
    sed -i "s/@VERSION_NAME@/$VERSION_NAME/g" "$file"
}

syntax_checks() {
    log "Running shell syntax checks"
    local failed=0
    while IFS= read -r f; do
        if [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ]; then
            bash -n "$f" || failed=1
        fi
    done < <(
        {
            find "$TARGET" -type f -name '*.sh'
            find "$TARGET/scripts/usr/bin" -type f 2>/dev/null
        } | sort -u
    )
    [ "$failed" = "0" ] || fail "bash -n failed"
}

require_rg_clean() {
    local pattern="$1"
    local scope="$2"
    local detail="$3"
    if search_text "$pattern" "$scope" >/tmp/qmanager_casa_rg.$$ 2>/dev/null; then
        cat /tmp/qmanager_casa_rg.$$ >&2
        rm -f /tmp/qmanager_casa_rg.$$
        fail "$detail"
    fi
    rm -f /tmp/qmanager_casa_rg.$$
}

require_rg_present() {
    local pattern="$1"
    local scope="$2"
    local detail="$3"
    if ! search_text "$pattern" "$scope" >/dev/null 2>&1; then
        fail "$detail"
    fi
}

search_text() {
    local pattern="$1"
    local scope="$2"
    if [ -n "${RG_BIN:-}" ]; then
        "$RG_BIN" -n "$pattern" "$scope"
    else
        grep -R -n -E "$pattern" "$scope"
    fi
}

find_rg() {
    if command -v rg >/dev/null 2>&1; then
        command -v rg
        return 0
    fi
    if command -v rg.exe >/dev/null 2>&1; then
        command -v rg.exe
        return 0
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
        local win_path posix_path
        win_path=$(powershell.exe -NoProfile -Command "(Get-Command rg -ErrorAction SilentlyContinue).Source" 2>/dev/null | tr -d '\r' | head -n1)
        if [ -n "$win_path" ] && command -v cygpath >/dev/null 2>&1; then
            posix_path=$(cygpath -u "$win_path")
            [ -x "$posix_path" ] && printf '%s\n' "$posix_path" && return 0
        fi
    fi
    return 1
}

safety_checks() {
    log "Running Casa safety checks"

    RG_BIN=$(find_rg || true)
    [ -n "$RG_BIN" ] || warn "rg not visible in this shell; falling back to grep -R -E"

    require_rg_present "install_cfw3212.sh" "$TARGET/build.sh" \
        "build.sh must stage install_cfw3212.sh"
    require_rg_present "uninstall_cfw3212.sh" "$TARGET/build.sh" \
        "build.sh must stage uninstall_cfw3212.sh"
    require_rg_clean "cp .*install_rm520n|install_rm520n.sh.*STAGING" "$TARGET/build.sh" \
        "build.sh still appears to stage RM520N installer"

    require_rg_present "/usrdata/bin" "$TARGET/install_cfw3212.sh" \
        "Casa installer must target /usrdata/bin"
    require_rg_present "/usrdata/qmanager/lib" "$TARGET/install_cfw3212.sh" \
        "Casa installer must target /usrdata/qmanager/lib"
    require_rg_present "/etc/systemd/system" "$TARGET/install_cfw3212.sh" \
        "Casa installer must target /etc/systemd/system"
    require_rg_present "9080" "$TARGET/install_cfw3212.sh" \
        "Casa installer must configure HTTP 9080"
    require_rg_present "9000" "$TARGET/install_cfw3212.sh" \
        "Casa installer must configure HTTPS 9000"

    require_rg_present "ip_handover" "$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh" \
        "Casa IPPT backend must use RDB ip_handover"
    require_rg_clean 'QCFG="usbnet"|QMAP="MPDN_rule"|QMAP="IPPT_NAT"|QMAP="DHCPV4DNS"|QMAPWAC|(^|[^[:alnum:]_])reboot([^[:alnum:]_]|$)' \
        "$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh" \
        "Casa IPPT backend contains upstream modem-write/reboot controls"
    require_rg_clean "ECM|MBIM|RNDIS|USB Tethering|Enter Manually|QCFG" \
        "$TARGET/components/local-network/ip-passthrough/ip-passthrough-card.tsx" \
        "Casa IPPT frontend exposes unsafe USB/MAC controls"

    require_rg_present "Joetooley28/qmanager-casa-cfw3212-package" "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh" \
        "system/update.sh must check the Casa package repo"
    require_rg_present "qmanager-cfw3212-" "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh" \
        "system/update.sh must use Casa package asset names"
    require_rg_present "language-packs" "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh" \
        "system/update.sh must document ignoring non-app releases"
    require_rg_present "sha256sum -c" "$TARGET/scripts/usr/bin/qmanager_update" \
        "qmanager_update must verify SHA-256 checksums"
    require_rg_present "qmanager_install/install_cfw3212.sh" "$TARGET/scripts/usr/bin/qmanager_update" \
        "qmanager_update must verify the Casa installer is present"
    require_rg_present "Joetooley28/qmanager-casa-cfw3212-package" "$TARGET/scripts/usr/bin/qmanager_update" \
        "qmanager_update must only allow Casa package repo releases"
    require_rg_present "auto-updates are disabled" "$TARGET/scripts/usr/bin/qmanager_auto_update" \
        "qmanager_auto_update must be disabled"
    require_rg_clean "dr-dolomite/QManager|QManager-RM520N|dr-dolomite" \
        "$TARGET/scripts/www/cgi-bin/quecmanager/system/update.sh" \
        "system/update.sh must not use upstream QManager releases directly"
    require_rg_clean "dr-dolomite/QManager|QManager-RM520N|dr-dolomite" \
        "$TARGET/scripts/usr/bin/qmanager_update" \
        "qmanager_update must not use upstream QManager releases directly"
    if [ "$CASA_PROFILE_AUTO_APPLY" = "1" ]; then
        warn "CASA_PROFILE_AUTO_APPLY=1: safety check allows boot profile auto-apply"
    else
        require_rg_present "Casa profile auto-apply disabled" "$TARGET/scripts/usr/bin/qmanager_poller" \
            "qmanager_poller must disable boot profile auto-apply"
    fi

    if [ -f "$TARGET/dependencies/atcli_smd11" ]; then
        local actual
        actual=$(sha256sum "$TARGET/dependencies/atcli_smd11" | awk '{print toupper($1)}')
        [ "$actual" = "4D2984E211BAD41EEEBDA8387B269D80F101CD0D9D98C8D55D4445A190598ACC" ] \
            || fail "atcli_smd11 SHA-256 changed: $actual"
    else
        fail "dependencies/atcli_smd11 missing"
    fi
}

build_package() {
    if [ "$SKIP_BUILD" = "1" ]; then
        warn "Skipping package build because --skip-build was supplied"
        return
    fi

    if ! command -v node >/dev/null 2>&1; then
        warn "Node is not on PATH; skipping package build"
        warn "After installing Node and Bun: cd '$TARGET' && bun install && bun run package"
        return
    fi
    if ! command -v bun >/dev/null 2>&1; then
        warn "Bun is not on PATH; skipping package build"
        warn "After installing Bun: cd '$TARGET' && bun install && bun run package"
        return
    fi

    log "Installing frontend dependencies with Bun"
    ( cd "$TARGET" && bun install )

    log "Building frontend and qmanager.tar.gz"
    ( cd "$TARGET" && bun run package )

    [ -f "$TARGET/qmanager-build/qmanager.tar.gz" ] || fail "Build did not produce qmanager.tar.gz"
    [ -f "$TARGET/qmanager-build/sha256sum.txt" ] || fail "Build did not produce sha256sum.txt"
}

prepare_target
apply_casa_overlays
write_smoke_checklist
syntax_checks
safety_checks
build_package

log "Casa port ready: $TARGET"
if [ -f "$TARGET/qmanager-build/qmanager.tar.gz" ]; then
    log "Artifact: $TARGET/qmanager-build/qmanager.tar.gz"
    log "Checksum: $TARGET/qmanager-build/sha256sum.txt"
else
    warn "Artifacts not built yet; install Node/Bun and run: cd '$TARGET' && bun install && bun run package"
fi
log "Smoke checklist: $TARGET/CFW3212_SMOKE_TEST_CHECKLIST.md"
