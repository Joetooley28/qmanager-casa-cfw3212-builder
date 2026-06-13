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

CASA_BUILD="${CASA_BUILD:-8}"
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

# Offline Entware .ipk bundle (AI-56): the full dependency closure for sudo and
# lighttpd, staged by the builder workflow into dependencies/entware/ (the sudo
# .ipk is pre-patched there so its ELF loader/RPATH point at /usrdata/opt and it
# keeps setuid). Copied verbatim so the device installer can come up with no
# WAN. Optional — a local dev build that has not fetched the set just omits it
# and the installer falls back to downloading from bin.entware.net.
if [ -d "$DEPS_DIR/entware" ]; then
    mkdir -p "$STAGING_DIR/dependencies/entware"
    cp "$DEPS_DIR/entware"/*.ipk "$STAGING_DIR/dependencies/entware/" 2>/dev/null || true
    step "Bundled $(ls "$STAGING_DIR/dependencies/entware"/*.ipk 2>/dev/null | wc -l) offline Entware package(s)"
fi

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
    if [ -x /usrdata/bin/qmanager_dns_reconcile ]; then
        /usrdata/bin/qmanager_dns_reconcile --once >/dev/null 2>&1 || true
    fi
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
        # Identity (CVERSION/CGMM/CGSN) is SIM-independent and ends in OK even
        # with no SIM inserted; accept once OK and the bare 15-digit IMEI show.
        result=$(qcmd 'AT+CVERSION;+CGMM;+CGSN' 2>/dev/null)
        if printf '%s\\n' "$result" | tr -d '\\r' | grep -q '^OK$' && printf '%s\\n' "$result" | tr -d '\\r' | grep -q -E '^[0-9]{15}$'; then
            break
        fi
        result=""
        qlog_warn "Boot identity read not ready; retry ${identity_try}/6"
        sleep 3
    done

    # SIM-dependent reads (CIMI/QCCID/CNUM) are a SEPARATE best-effort call:
    # chained into the identity compound they return ERROR on a SIM-less modem
    # and poison the whole response, blanking every device-info field. Append
    # only on success so the parser below still sees IMSI/ICCID/phone.
    if [ -n "$result" ]; then
        local sim_result
        sim_result=$(qcmd 'AT+CIMI;+QCCID;+CNUM' 2>/dev/null)
        if printf '%s\\n' "$sim_result" | tr -d '\\r' | grep -q '^OK$'; then
            result="$result
$sim_result"
        fi

        # Manufacturer (AT+CGMI) — SIM-independent; queried separately so its
        # bare "Quectel" line does not collide with the bare CGMM model line.
        local mfr_result
        mfr_result=$(qcmd 'AT+CGMI' 2>/dev/null)
        if printf '%s\\n' "$mfr_result" | tr -d '\\r' | grep -q '^OK$'; then
            boot_manufacturer=$(printf '%s\\n' "$mfr_result" | tr -d '\\r' | grep -v '^AT' | grep -v '^OK$' | grep -v '^$' | grep -v '^+' | head -1)
        fi
    fi'''
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
    local casa_ippt_enable casa_ippt_mode casa_ippt_service_enable
    casa_ippt_enable=$(rdb get link.profile.1.ip_handover.enable 2>/dev/null || true)
    casa_ippt_mode=$(rdb get link.profile.1.ip_handover.mode 2>/dev/null || true)
    casa_ippt_service_enable=$(rdb get service.ip_handover.enable 2>/dev/null || true)
    boot_ippt_mode="disabled"
    if [ "$casa_ippt_enable" = "1" ] && [ "$casa_ippt_service_enable" != "0" ]; then
        case "$casa_ippt_mode" in
            eth|enabled|1) boot_ippt_mode="eth" ;;
        esac
    fi
    boot_ippt_mac=$(rdb get service.ip_handover.mac_address 2>/dev/null || true)
    boot_ippt_nat="1"
    boot_ippt_usbnet="1"
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
    local casa_ippt_enable casa_ippt_mode casa_ippt_service_enable
    casa_ippt_enable=$(rdb get link.profile.1.ip_handover.enable 2>/dev/null || true)
    casa_ippt_mode=$(rdb get link.profile.1.ip_handover.mode 2>/dev/null || true)
    casa_ippt_service_enable=$(rdb get service.ip_handover.enable 2>/dev/null || true)
    boot_ippt_mode="disabled"
    if [ "$casa_ippt_enable" = "1" ] && [ "$casa_ippt_service_enable" != "0" ]; then
        case "$casa_ippt_mode" in
            eth|enabled|1) boot_ippt_mode="eth" ;;
        esac
    fi
    boot_ippt_mac=$(rdb get service.ip_handover.mac_address 2>/dev/null || true)
    boot_ippt_nat="1"
    boot_ippt_usbnet="1"
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

patch_qmanager_poller_lib_paths_cfw3212() {
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"

    sed -i 's#/usr/lib/qmanager/#/usrdata/qmanager/lib/#g' "$poller"

    grep -q "/usrdata/qmanager/lib/parse_at.sh" "$poller" \
        || fail "Could not patch qmanager_poller library paths for Casa"
}

# CFW-3212: the upstream System Health Check pauses the poller with
# `systemctl stop qmanager-poller` and relies on an EXIT/INT/TERM trap to
# restart it. SIGKILL is uncatchable, so if the CGI is OOM-killed or its HTTP
# request is torn down mid-run, the poller is orphaned stopped — and the unit's
# Restart=on-failure treats the clean SIGTERM as success and never resurrects
# it, leaving qmanager-poller inactive(enabled=yes) indefinitely (AI-52).
# Pause via the shared poller-pause flag instead (the same flag the speedtest
# uses): the poller keeps running and only skips AT polling while the flag
# exists, and it auto-clears a stale flag after LONG_FLAG_MAX_AGE (300s) so a
# killed health check self-recovers with no orphan-stop window.
patch_qmanager_health_check_poller_pause_cfw3212() {
    local worker="$TARGET/scripts/usr/bin/qmanager_health_check"
    [ -f "$worker" ] || fail "Target missing qmanager_health_check worker"

    python3 - "$worker" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_pause = (
    '# The poller hammers the AT lock 1-2x/sec, which makes per-test qcmd calls\n'
    "# perpetually time out. Pause it for the run's duration. The trap below\n"
    '# guarantees the poller restarts even if we crash, get killed, or hit Ctrl-C.\n'
    '\n'
    '_PAUSED_POLLER=0\n'
    '\n'
    '_pause_poller_if_running() {\n'
    '    if systemctl is-active --quiet qmanager-poller 2>/dev/null; then\n'
    '        _PAUSED_POLLER=1\n'
    '        systemctl stop qmanager-poller 2>/dev/null\n'
    '        # Give in-flight qcmd/atcli a moment to release the AT lock.\n'
    '        sleep 1\n'
    '    fi\n'
    '}\n'
    '\n'
    '_resume_poller_if_paused() {\n'
    '    if [ "$_PAUSED_POLLER" = "1" ]; then\n'
    '        systemctl start qmanager-poller 2>/dev/null\n'
    '        _PAUSED_POLLER=0\n'
    '    fi\n'
    '}\n'
)
new_pause = (
    '# The poller hammers the AT lock 1-2x/sec, which makes per-test qcmd calls\n'
    "# perpetually time out. Pause it for the run's duration via the shared\n"
    '# poller-pause flag (the same flag the speedtest uses): the poller keeps\n'
    '# running but skips AT polling while the flag exists, so there is no\n'
    '# systemctl stop and therefore no orphaned-stop window if this CGI is\n'
    '# SIGKILLed (OOM / torn-down HTTP request) before the trap can fire. The\n'
    '# poller auto-clears a stale flag after 300s as a final backstop. (AI-52)\n'
    '\n'
    'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"\n'
    '_PAUSED_POLLER=0\n'
    '\n'
    '_pause_poller_if_running() {\n'
    '    _PAUSED_POLLER=1\n'
    '    touch "$POLLER_PAUSE_FLAG" 2>/dev/null\n'
    '    # Give in-flight qcmd/atcli a moment to release the AT lock.\n'
    '    sleep 1\n'
    '}\n'
    '\n'
    '_resume_poller_if_paused() {\n'
    '    if [ "$_PAUSED_POLLER" = "1" ]; then\n'
    '        rm -f "$POLLER_PAUSE_FLAG" 2>/dev/null\n'
    '        _PAUSED_POLLER=0\n'
    '    fi\n'
    '}\n'
)

already = 'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' in text
if old_pause not in text and not already:
    raise SystemExit("health-check poller-pause block not found (upstream changed?)")
if old_pause in text:
    text = text.replace(old_pause, new_pause, 1)
    path.write_text(text)
PYEOF

    grep -q 'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' "$worker" \
        || fail "Could not apply health-check poller-pause flag to qmanager_health_check"
    grep -qF 'touch "$POLLER_PAUSE_FLAG"' "$worker" \
        || fail "health-check _pause_poller_if_running not switched to pause flag"
    ! grep -q 'systemctl stop qmanager-poller' "$worker" \
        || fail "health-check still stops qmanager-poller (orphan-stop risk remains)"
    ! grep -q 'systemctl start qmanager-poller' "$worker" \
        || fail "health-check still starts qmanager-poller via systemctl"
}

patch_qmanager_health_check_net_dns_cfw3212() {
    local worker="$TARGET/scripts/usr/bin/qmanager_health_check"
    [ -f "$worker" ] || fail "Target missing qmanager_health_check worker"

    python3 - "$worker" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

marker = "Casa CFW-3212 IP passthrough: /etc/resolv.conf often lists the handover"
if marker in text:
    sys.exit(0)

start = text.find("t_net_dns() {")
end = text.find("t_net_ping()", start)
if start < 0 or end < 0:
    raise SystemExit("t_net_dns() block not found (upstream changed?)")

new = """t_net_dns() {
    # Bound the test to 5s — nslookup against unreachable DNS can stall 30s+
    # per nameserver and timeout the CGI response. Prefer getent if available.
    #
    # Casa CFW-3212 IP passthrough: /etc/resolv.conf often lists the handover
    # placeholder 192.0.0.1 which does not answer DNS. dnsmasq on bridge0 LAN
    # still proxies correctly — query that instead when the poisoned nameserver
    # is detected.
    local out rc resolver="" poisoned=0
    if grep -qE '^nameserver[[:space:]]+192\\.0\\.0\\.[12][[:space:]]*$' \\
            /etc/resolv.conf /run/resolv.conf 2>/dev/null; then
        poisoned=1
        resolver=$(ip -o -4 addr show dev bridge0 2>/dev/null \\
            | awk '{print $4}' | cut -d/ -f1 \\
            | grep -E '^192\\.168\\.' | head -1)
        [ -z "$resolver" ] && resolver="1.1.1.1"
    fi
    if [ "$poisoned" = "0" ] && command -v getent >/dev/null 2>&1; then
        out=$(timeout 5 getent hosts install.speedtest.net 2>&1); rc=$?
    elif command -v nslookup >/dev/null 2>&1; then
        if [ -n "$resolver" ]; then
            out=$(timeout 5 nslookup install.speedtest.net "$resolver" 2>&1); rc=$?
        else
            out=$(timeout 5 nslookup install.speedtest.net 2>&1); rc=$?
        fi
    else
        echo "no resolver tool available" >> "$OUTPUT_FILE"
        echo "fail|no getent or nslookup"; return
    fi
    echo "$out" >> "$OUTPUT_FILE"
    if [ "$rc" = "124" ]; then
        echo "fail|DNS timed out (5s)"
    elif [ "$rc" -ne 0 ]; then
        echo "fail|resolution failed (rc=$rc)"
    elif echo "$out" | grep -qE '^[0-9a-fA-F:.]+[[:space:]]+install\\.speedtest\\.net|Name:[[:space:]]+install\\.speedtest\\.net'; then
        echo "pass|resolved"
    elif echo "$out" | grep -qE 'install\\.speedtest\\.net'; then
        echo "pass|resolved"
    else
        echo "fail|no answer for install.speedtest.net"
    fi
}
"""

path.write_text(text[:start] + new + text[end:])
PYEOF

    grep -q 'Casa CFW-3212 IP passthrough: /etc/resolv.conf often lists the handover' "$worker" \
        || fail "Could not apply health-check net.dns IPPT resolv bypass to qmanager_health_check"
}

patch_speedtest_poller_pause_cfw3212() {
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    local speedtest_start="$TARGET/scripts/www/cgi-bin/quecmanager/at_cmd/speedtest_start.sh"
    local speedtest_status="$TARGET/scripts/www/cgi-bin/quecmanager/at_cmd/speedtest_status.sh"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"
    [ -f "$speedtest_start" ] || fail "Target missing speedtest_start.sh"
    [ -f "$speedtest_status" ] || fail "Target missing speedtest_status.sh"

    python3 - "$poller" "$speedtest_start" "$speedtest_status" <<'PY'
from pathlib import Path
import sys

poller = Path(sys.argv[1])
start = Path(sys.argv[2])
status = Path(sys.argv[3])

text = poller.read_text()
if 'SPEEDTEST_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' not in text:
    text = text.replace(
        'LONG_FLAG="/tmp/qmanager_long_running"\n',
        'LONG_FLAG="/tmp/qmanager_long_running"\n'
        'SPEEDTEST_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"\n',
        1,
    )
text = text.replace(
    'if [ -f "$LONG_FLAG" ]; then\n'
    '        local _lf_mtime _lf_now _lf_age\n'
    '        _lf_mtime=$(stat -c %Y "$LONG_FLAG" 2>/dev/null || echo 0)',
    'if [ -f "$LONG_FLAG" ] || [ -f "$SPEEDTEST_PAUSE_FLAG" ]; then\n'
    '        local _lf_mtime _lf_now _lf_age\n'
    '        if [ -f "$LONG_FLAG" ]; then\n'
    '            _lf_mtime=$(stat -c %Y "$LONG_FLAG" 2>/dev/null || echo 0)\n'
    '        else\n'
    '            _lf_mtime=$(stat -c %Y "$SPEEDTEST_PAUSE_FLAG" 2>/dev/null || echo 0)\n'
    '        fi',
    1,
)
text = text.replace(
    'qlog_warn "LONG_FLAG stale (age=${_lf_age}s > ${LONG_FLAG_MAX_AGE}s) — removing"\n'
    '            rm -f "$LONG_FLAG"',
    'qlog_warn "poller pause flag stale (age=${_lf_age}s > ${LONG_FLAG_MAX_AGE}s) — removing"\n'
    '            rm -f "$LONG_FLAG" "$SPEEDTEST_PAUSE_FLAG"',
    1,
)
text = text.replace(
    'if [ -f "$LONG_FLAG" ]; then\n'
    '        if [ "$system_state" != "scan_in_progress" ]; then',
    'if [ -f "$LONG_FLAG" ] || [ -f "$SPEEDTEST_PAUSE_FLAG" ]; then\n'
    '        if [ "$system_state" != "scan_in_progress" ]; then',
    1,
)
poller.write_text(text)

text = start.read_text()
if 'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' not in text:
    text = text.replace(
        'WRAPPER_SCRIPT="/tmp/qmanager_speedtest_run.sh"\n',
        'WRAPPER_SCRIPT="/tmp/qmanager_speedtest_run.sh"\n'
        'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"\n',
        1,
    )
text = text.replace(
    '# Safety net: explicitly set critical vars if profile didn\'t cover them\n'
    'export HOME="${HOME:-/root}"',
    '# Safety net: explicitly set critical vars if profile didn\'t cover them.\n'
    '# Use /tmp for Ookla config; /home/root is read-only on CFW-3212.\n'
    'export HOME="/tmp/qmanager-ookla-home"\n'
    'mkdir -p "$HOME/.config/ookla"',
    1,
)
text = text.replace(
    '# Safety net: explicitly set critical vars if profile didn\'t cover them\n'
    'export HOME=/tmp/qmanager-ookla-home\n'
    'mkdir -p "$HOME"',
    '# Safety net: explicitly set critical vars if profile didn\'t cover them.\n'
    '# Use /tmp for Ookla config; /home/root is read-only on CFW-3212.\n'
    'export HOME=/tmp/qmanager-ookla-home\n'
    'mkdir -p "$HOME/.config/ookla"',
    1,
)
text = text.replace(
    '# exec replaces this shell with speedtest — PID stays the same\n'
    'exec __SPEEDTEST_BIN__',
    '# Pause the poller while Ookla saturates the link. qmanager_poller treats this\n'
    '# as a long-running operation and skips modem AT polling/event detection until\n'
    '# the flag disappears.\n'
    'touch __POLLER_PAUSE_FLAG__\n'
    "trap 'rm -f __POLLER_PAUSE_FLAG__' EXIT INT TERM\n\n"
    '__SPEEDTEST_BIN__',
    1,
)
if 's|__POLLER_PAUSE_FLAG__|' not in text:
    text = text.replace(
        'sed -i "s|__SPEEDTEST_BIN__|${SPEEDTEST_BIN}|" "$WRAPPER_SCRIPT"\n',
        'sed -i "s|__SPEEDTEST_BIN__|${SPEEDTEST_BIN}|" "$WRAPPER_SCRIPT"\n'
        'sed -i "s|__POLLER_PAUSE_FLAG__|${POLLER_PAUSE_FLAG}|" "$WRAPPER_SCRIPT"\n',
        1,
    )
start.write_text(text)

text = status.read_text()
if 'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' not in text:
    text = text.replace(
        'RESULT_FILE="/tmp/qmanager_speedtest_result.json"\n',
        'RESULT_FILE="/tmp/qmanager_speedtest_result.json"\n'
        'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"\n',
        1,
    )
if 'rm -f "$POLLER_PAUSE_FLAG"' not in text:
    text = text.replace(
        '        rm -f "$PID_FILE"\n',
        '        rm -f "$PID_FILE"\n'
        '        rm -f "$POLLER_PAUSE_FLAG"\n',
        1,
    )
status.write_text(text)
PY

    grep -q 'SPEEDTEST_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' "$poller" \
        || fail "Could not apply Speedtest poller pause flag to qmanager_poller"
    grep -q 'touch __POLLER_PAUSE_FLAG__' "$speedtest_start" \
        || fail "Could not apply Speedtest poller pause flag to speedtest_start.sh"
    grep -q '/tmp/qmanager-ookla-home' "$speedtest_start" \
        || fail "Could not apply Casa Ookla HOME path to speedtest_start.sh"
    grep -q 'rm -f "$POLLER_PAUSE_FLAG"' "$speedtest_status" \
        || fail "Could not apply Speedtest poller pause cleanup to speedtest_status.sh"
}

patch_disable_orientation_probe_cfw3212() {
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    [ -f "$poller" ] || return 0

    if ! grep -q 'start_orientation_probe' "$poller" 2>/dev/null; then
        log "No upstream orientation probe present; skipping Casa orientation gate"
        return 0
    fi

    log "Disabling upstream orientation probe for Casa CFW-3212"

    python3 - "$poller" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

start = text.find('start_orientation_probe() {')
if start >= 0:
    next_func = text.find('\n\napply_orientation_result()', start)
    if next_func > start:
        new_body = "start_orientation_probe() {\n"
        new_body += "    # Casa CFW-3212: orientation probe disabled.\n"
        new_body += "    # The CFW-3212/RG520N-NA does not exhibit flipped upload/download\n"
        new_body += "    # counters in normal use, so the live 5 MB Cloudflare probe is\n"
        new_body += "    # unnecessary and adds CPU/network contention during install/startup.\n"
        new_body += "    # Upload/download display relies on default /proc/net/dev field\n"
        new_body += "    # assignments (field 2=download, field 10=upload) — correct for\n"
        new_body += "    # CFW-3212/RG520N-NA firmware.\n"
        new_body += "    orientation_probe_attempted=true\n"
        new_body += "    printf '%s\\n' \"fallback:casa_cfw3212_disabled\" > \"${ORIENTATION_STATE_FILE}.tmp\" \\\n"
        new_body += "        && mv \"${ORIENTATION_STATE_FILE}.tmp\" \"$ORIENTATION_STATE_FILE\"\n"
        new_body += "    rm -f \"$ORIENTATION_PROBE_PIDFILE\"\n"
        new_body += "}"
        text = text[:start] + new_body + text[next_func:]
    else:
        raise SystemExit("orientation probe patching failed: apply_orientation_result not found")
else:
    raise SystemExit("orientation probe patching failed: start_orientation_probe not found")

path.write_text(text)
PY

    grep -q "Casa CFW-3212: orientation probe disabled" "$poller" \
        || fail "Could not apply Casa orientation probe disable to qmanager_poller"
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

patch_qmanager_lighttpd_unit_name_cfw3212() {
    local f

    for f in "$TARGET/scripts/etc/systemd/system"/qmanager*.service; do
        [ -f "$f" ] || continue
        sed -i 's/lighttpd\.service/qmanager-lighttpd.service/g' "$f"
    done

    log "Scoped QManager service dependencies to qmanager-lighttpd.service"
}

patch_qmanager_console_port_cfw3212() {
    local unit="$TARGET/scripts/etc/systemd/system/qmanager-console.service"
    local conf="$TARGET/scripts/usrdata/qmanager/lighttpd.conf"

    if [ -f "$unit" ]; then
        sed -i 's/-p 8080 /-p 9081 /g' "$unit"

        grep -q -- "-p 9081 " "$unit" \
            || fail "qmanager-console.service did not move ttyd to port 9081"
        ! grep -q -- "-p 8080 " "$unit" \
            || fail "qmanager-console.service still uses Casa stock UI port 8080"
    fi

    if [ -f "$conf" ]; then
        sed -i 's/"port" => 8080/"port" => 9081/g' "$conf"

        grep -q '"port" => 9081' "$conf" \
            || fail "lighttpd.conf did not move /console proxy to port 9081"
        ! grep -q '"port" => 8080' "$conf" \
            || fail "lighttpd.conf still proxies /console to Casa stock UI port 8080"
    fi

    log "Moved QManager web console backend to 127.0.0.1:9081"
}

patch_qmanager_health_check_paths_cfw3212() {
    local worker="$TARGET/scripts/usr/bin/qmanager_health_check"
    [ -f "$worker" ] || fail "Target missing qmanager_health_check worker"

    python3 - "$worker" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if 'export PATH="/usrdata/bin:/usrdata/opt/bin:' not in text:
    text = text.replace(
        'set -u\n\n',
        'set -u\n'
        'export PATH="/usrdata/bin:/usrdata/opt/bin:/usr/bin:/usr/sbin:/bin:/sbin:${PATH:-}"\n\n',
        1,
    )

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
    ('label:"lighttpd.service"',
     'label:"qmanager-lighttpd.service"'),
    ('"lighttpd.service"',
     '"qmanager-lighttpd.service"'),
    ("_svc_check lighttpd.service 1",
     "_svc_check qmanager-lighttpd.service 1"),
    ("lighttpd.service tailscaled.service",
     "qmanager-lighttpd.service tailscaled.service"),
    # Lighttpd port check — Casa exposes 9080/9000 instead of 80/443.
    (r"grep -qE '[:.](80)\b'",        r"grep -qE '[:.](9080)\b'"),
    (r"grep -qE '[:.](443)\b'",       r"grep -qE '[:.](9000)\b'"),
    # Cosmetic strings tied to the port test — labels and result messages.
    ("lighttpd listening on 80/443",  "qmanager-lighttpd listening on 9080/9000"),
    ("listening on 80 and 443",       "listening on 9080 and 9000"),
    ("listening on only one of 80/443", "listening on only one of 9080/9000"),
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
     "qmanager-lighttpd CGI PATH includes /usrdata/opt/bin"),
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

sudo_list_old = (
    '    elif [ -f /usrdata/opt/etc/sudoers.d/qmanager ] && '
    "grep -q 'qmanager' /usrdata/opt/etc/sudoers.d/qmanager 2>/dev/null; then\n"
    '        echo "warn|sudoers file present but no helpers in -l output"\n'
)
sudo_list_new = (
    '    elif [ -f /usrdata/opt/etc/sudoers.d/qmanager ] && '
    "grep -q 'qmanager' /usrdata/opt/etc/sudoers.d/qmanager 2>/dev/null; then\n"
    '        echo "pass|sudoers file present with qmanager helpers"\n'
)
if sudo_list_old in new_text:
    new_text = new_text.replace(sudo_list_old, sudo_list_new, 1)

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
    grep -q "pass|sudoers file present with qmanager helpers" "$worker" \
        || fail "Health-check worker still warns when Casa sudoers file is present"
    grep -q 'export PATH="/usrdata/bin:/usrdata/opt/bin:' "$worker" \
        || fail "Health-check worker must export Casa PATH for direct/manual runs"
    grep -q "qmanager-lighttpd listening on 9080/9000" "$worker" \
        || fail "Health-check worker still has 80/443 in lighttpd_listen label"
    grep -q "_svc_check qmanager-lighttpd.service 1" "$worker" \
        || fail "Health-check worker missing qmanager-lighttpd service check"
    ! grep -q "_svc_check lighttpd.service" "$worker" \
        || fail "Health-check worker still checks generic lighttpd.service"
    ! grep -q "listening on only one of 80/443" "$worker" \
        || fail "Health-check worker still has 80/443 in lighttpd_listen warn message"
    ! grep -q "|| echo unknown)" "$worker" \
        || fail "Health-check worker _svc_check still has || echo unknown bug"
    grep -qE '\[ -z "\$active" \] && active="unknown"' "$worker" \
        || fail "Health-check worker _svc_check fallback patch did not apply"
    # Same pattern as qmanager-traffic below: only verify the optional-mark
    # when upstream still ships the service. If upstream removes ttyd/console
    # support, the str.replace becomes a no-op and there's nothing to verify.
    if grep -q "qmanager-console.service" "$worker"; then
        grep -q "_svc_check qmanager-console.service 0" "$worker" \
            || fail "Health-check worker did not mark qmanager-console optional"
    fi
    # Upstream v0.1.12 removed qmanager-traffic.service entirely (Live Traffic
    # widget dropped because IPA hardware offload bypassed the kernel). Only
    # verify the optional-mark when the upstream worker still references it.
    if grep -q "qmanager-traffic.service" "$worker"; then
        grep -q "_svc_check qmanager-traffic.service 0" "$worker" \
            || fail "Health-check worker did not mark qmanager-traffic optional"
    fi
    grep -q "local cgi_base=/usrdata/qmanager/lib/cgi_base.sh" "$worker" \
        || fail "Health-check worker still has upstream /usr/lib/qmanager/cgi_base.sh path"
    grep -q "qmanager-lighttpd CGI PATH includes /usrdata/opt/bin" "$worker" \
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

patch_ai62_flash_and_cgi_hardening_cfw3212() {
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    local qlog="$TARGET/scripts/usr/lib/qmanager/qlog.sh"
    local setup="$TARGET/scripts/usr/bin/qmanager_setup"
    local cgi_base="$TARGET/scripts/usr/lib/qmanager/cgi_base.sh"
    local health="$TARGET/scripts/usr/bin/qmanager_health_check"

    [ -f "$poller" ] || fail "Target missing qmanager_poller"
    [ -f "$qlog" ] || fail "Target missing qlog.sh"
    [ -f "$setup" ] || fail "Target missing qmanager_setup"
    [ -f "$cgi_base" ] || fail "Target missing cgi_base.sh"
    [ -f "$health" ] || fail "Target missing qmanager_health_check"

    python3 - "$poller" "$qlog" "$setup" "$cgi_base" "$health" <<'PY'
from pathlib import Path
import sys

poller_path, qlog_path, setup_path, cgi_base_path, health_path = map(Path, sys.argv[1:])

def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} marker not found")
    return text.replace(old, new, 1)

poller = poller_path.read_text()
poller = replace_once(
    poller,
    '''# --- Persistent Data Used counter (Tier 1) -----------------------------------
DATA_USED_FILE="/usrdata/qmanager/data_used.json"
DATA_USED_TMP="/usrdata/qmanager/data_used.json.tmp"
DATA_USED_RESET_FLAG="/tmp/qmanager_data_used_reset"
''',
    '''# --- Persistent Data Used counter (Tier 1) -----------------------------------
DATA_USED_FILE="/usrdata/qmanager/data_used.json"
DATA_USED_HOT_FILE="/tmp/qmanager_data_used.json"
DATA_USED_RESET_FLAG="/tmp/qmanager_data_used_reset"
DATA_USED_FLUSH_INTERVAL="${DATA_USED_FLUSH_INTERVAL:-300}"
''',
    "poller data_used constants",
)
poller = replace_once(
    poller,
    "du_modem_reset_count=0\n\n# Orientation detection state.",
    "du_modem_reset_count=0\ndu_last_flush_ts=0\n\n# Orientation detection state.",
    "poller flush timestamp state",
)
poller = poller.replace(
    "# to DATA_USED_FILE each tick.",
    "# to a RAM-backed hot file each tick and to persistent flash on a bounded cadence.",
    1,
)
old_func = '''write_data_used_state() {
    mkdir -p /usrdata/qmanager 2>/dev/null
    local _hist_sw_json
    if [ "$orientation_history_swapped" = "true" ]; then
        _hist_sw_json=true
    else
        _hist_sw_json=false
    fi
    jq -n \\
        --argjson schema    "$DATA_USED_SCHEMA" \\
        --argjson acc_rx    "$du_accumulated_rx" \\
        --argjson acc_tx    "$du_accumulated_tx" \\
        --arg     sel       "$du_selected_counter" \\
        --argjson prev_i_rx "$du_prev_ipa_rx" \\
        --argjson prev_i_tx "$du_prev_ipa_tx" \\
        --argjson last_upd  "$du_last_update_ts" \\
        --argjson last_rst  "$du_last_reset_ts" \\
        --argjson modem_rst "$du_modem_reset_count" \\
        --argjson hist_sw   "$_hist_sw_json" \\
        '{
            schema:               $schema,
            accumulated_rx_bytes: $acc_rx,
            accumulated_tx_bytes: $acc_tx,
            selected_counter:     $sel,
            prev_ipa_rx:          $prev_i_rx,
            prev_ipa_tx:          $prev_i_tx,
            last_update_ts:       $last_upd,
            last_reset_ts:        $last_rst,
            modem_reset_count:    $modem_rst,
            orientation_history_swapped: $hist_sw
        }' > "$DATA_USED_TMP" && mv "$DATA_USED_TMP" "$DATA_USED_FILE"
}
'''
new_func = '''_write_data_used_state_file() {
    local _file="$1" _tmp _dir _hist_sw_json
    [ -n "$_file" ] || return 1
    _tmp="${_file}.tmp"
    _dir=$(dirname "$_file")
    mkdir -p "$_dir" 2>/dev/null || return 1
    if [ "$orientation_history_swapped" = "true" ]; then
        _hist_sw_json=true
    else
        _hist_sw_json=false
    fi
    jq -n \\
        --argjson schema    "$DATA_USED_SCHEMA" \\
        --argjson acc_rx    "$du_accumulated_rx" \\
        --argjson acc_tx    "$du_accumulated_tx" \\
        --arg     sel       "$du_selected_counter" \\
        --argjson prev_i_rx "$du_prev_ipa_rx" \\
        --argjson prev_i_tx "$du_prev_ipa_tx" \\
        --argjson last_upd  "$du_last_update_ts" \\
        --argjson last_rst  "$du_last_reset_ts" \\
        --argjson modem_rst "$du_modem_reset_count" \\
        --argjson hist_sw   "$_hist_sw_json" \\
        '{
            schema:               $schema,
            accumulated_rx_bytes: $acc_rx,
            accumulated_tx_bytes: $acc_tx,
            selected_counter:     $sel,
            prev_ipa_rx:          $prev_i_rx,
            prev_ipa_tx:          $prev_i_tx,
            last_update_ts:       $last_upd,
            last_reset_ts:        $last_rst,
            modem_reset_count:    $modem_rst,
            orientation_history_swapped: $hist_sw
        }' > "$_tmp" && mv "$_tmp" "$_file"
}

write_data_used_state() {
    _write_data_used_state_file "$DATA_USED_HOT_FILE"
}

flush_data_used_state() {
    local _force="${1:-0}" _now
    [ "$du_loaded" = "true" ] || return 0
    _now=$(date +%s)
    if [ "$_force" = "1" ] \\
        || [ "$du_last_flush_ts" = "0" ] \\
        || [ $((_now - du_last_flush_ts)) -ge "$DATA_USED_FLUSH_INTERVAL" ]; then
        if _write_data_used_state_file "$DATA_USED_FILE"; then
            du_last_flush_ts="$_now"
        fi
    fi
}
'''
poller = replace_once(poller, old_func, new_func, "poller write_data_used_state function")
poller = poller.replace(
    "                qlog_info \"orientation: swapped persisted accumulators (schema v4 migration)\"\n"
    "                write_data_used_state\n",
    "                qlog_info \"orientation: swapped persisted accumulators (schema v4 migration)\"\n"
    "                write_data_used_state\n"
    "                flush_data_used_state 1\n",
    1,
)
poller = poller.replace(
    "                    qlog_info \"data_used: migrated schema v${_on_disk_schema:-0} → v${DATA_USED_SCHEMA} (preserving accumulators)\"\n"
    "                    write_data_used_state\n",
    "                    qlog_info \"data_used: migrated schema v${_on_disk_schema:-0} → v${DATA_USED_SCHEMA} (preserving accumulators)\"\n"
    "                    write_data_used_state\n"
    "                    flush_data_used_state 1\n",
    1,
)
poller = poller.replace(
    "        # Persist the zeroed state now so an early return (e.g. interface\n"
    "        # absent) or a crash before Step 6 cannot resurrect the old counters.\n"
    "        write_data_used_state\n",
    "        # Persist the zeroed state now so an early return (e.g. interface\n"
    "        # absent) or a crash before Step 6 cannot resurrect the old counters.\n"
    "        write_data_used_state\n"
    "        flush_data_used_state 1\n",
    1,
)
poller = poller.replace(
    "        write_data_used_state\n        return 0\n",
    "        write_data_used_state\n        flush_data_used_state\n        return 0\n",
    1,
)
poller = poller.replace(
    "    # Step 6: persist for the next tick.\n"
    "    du_prev_ipa_rx=\"$ipa_rx\"\n"
    "    du_prev_ipa_tx=\"$ipa_tx\"\n"
    "    du_selected_counter=\"$NETWORK_IFACE\"\n"
    "    du_last_update_ts=$(date +%s)\n"
    "    write_data_used_state\n",
    "    # Step 6: keep hot state fresh every tick, but flush flash on a bounded cadence.\n"
    "    du_prev_ipa_rx=\"$ipa_rx\"\n"
    "    du_prev_ipa_tx=\"$ipa_tx\"\n"
    "    du_selected_counter=\"$NETWORK_IFACE\"\n"
    "    du_last_update_ts=$(date +%s)\n"
    "    write_data_used_state\n"
    "    flush_data_used_state\n",
    1,
)
poller = replace_once(
    poller,
    '''    collect_boot_data
''',
    '''    trap 'flush_data_used_state 1 >/dev/null 2>&1 || true' EXIT
    trap 'flush_data_used_state 1 >/dev/null 2>&1 || true; exit 0' INT TERM

    collect_boot_data
''',
    "poller shutdown flush trap",
)
poller_path.write_text(poller)

qlog = qlog_path.read_text()
qlog = qlog.replace("QLOG_TO_SYSLOG   — Also log to syslog: 1|0 (default: 1)", "QLOG_TO_SYSLOG   — Also log to syslog: 1|0 (default: 0)", 1)
qlog = qlog.replace('QLOG_TO_SYSLOG="${QLOG_TO_SYSLOG:-1}"', 'QLOG_TO_SYSLOG="${QLOG_TO_SYSLOG:-0}"', 1)
qlog_path.write_text(qlog)

setup = setup_path.read_text()
setup = replace_once(
    setup,
    '''# CGI (www-data) writes cron entries for root — needs write access to spool dir
chmod 777 /var/spool/cron/crontabs
''',
    '''# Keep the cron spool root-owned and non-world-writable while preserving
# current CGI schedule writers that update root's crontab directly.
chown root:www-data /var/spool/cron /var/spool/cron/crontabs 2>/dev/null || true
chmod 775 /var/spool/cron /var/spool/cron/crontabs
''',
    "qmanager_setup cron permissions",
)
setup_path.write_text(setup)

cgi = cgi_base_path.read_text()
cgi = cgi.replace("export PATH=\"/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH\"", "export PATH=\"/usrdata/opt/bin:/usrdata/opt/sbin:/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH\"", 1)
cgi = cgi.replace("# Authentication — source cgi_auth.sh with no-op fallbacks if missing", "# Authentication — source cgi_auth.sh with fail-closed fallbacks if missing", 1)
cgi = replace_once(
    cgi,
    '''. /usr/lib/qmanager/cgi_auth.sh 2>/dev/null || {
    require_auth()          { :; }
    is_setup_required()     { return 1; }
''',
    '''. /usr/lib/qmanager/cgi_auth.sh 2>/dev/null || {
    require_auth() {
        cgi_headers
        cgi_error "auth_unavailable" "Authentication library is unavailable"
        exit 0
    }
    is_setup_required()     { return 1; }
''',
    "cgi_base auth fallback",
)
cgi = replace_once(
    cgi,
    '''# Reads stdin into POST_DATA using CONTENT_LENGTH.
# Exits with a JSON error response if the body is missing or empty.
# ---------------------------------------------------------------------------
cgi_read_post() {
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    else
        cgi_error "no_body" "POST body is empty"
        exit 0
    fi
}
''',
    '''# Reads stdin into POST_DATA using CONTENT_LENGTH.
# Exits with a JSON error response if the body is missing, empty, or too large.
# ---------------------------------------------------------------------------
cgi_read_post() {
    : "${QM_MAX_POST_SIZE:=65536}"
    if ! [ -n "$CONTENT_LENGTH" ] || ! [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        cgi_error "no_body" "POST body is empty"
        exit 0
    fi
    if [ "$CONTENT_LENGTH" -gt "$QM_MAX_POST_SIZE" ] 2>/dev/null; then
        cgi_error "body_too_large" "POST body exceeds maximum size"
        exit 0
    fi
    POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
}
''',
    "cgi_base post size limit",
)
cgi_base_path.write_text(cgi)

health = health_path.read_text()
health = health.replace('label:"data_used.json fresh (mtime < 60s)"', 'label:"data_used hot state fresh (mtime < 60s)"', 1)
health = replace_once(
    health,
    '''t_cfg_data_used_fresh() {
    local f=/usrdata/qmanager/data_used.json
    if [ ! -f "$f" ]; then
        echo "missing $f" >> "$OUTPUT_FILE"
        echo "fail|missing (poller has never run successfully)"
        return
    fi
    local age; age=$(( $(date +%s) - $(stat -c %Y "$f") ))
    echo "path=$f age=${age}s" >> "$OUTPUT_FILE"
    if [ "$age" -lt 60 ]; then echo "pass|age ${age}s"
    else echo "warn|age ${age}s (>60s)"; fi
}
''',
    '''t_cfg_data_used_fresh() {
    local f=/tmp/qmanager_data_used.json
    if [ ! -f "$f" ]; then
        local durable=/usrdata/qmanager/data_used.json
        if [ -f "$durable" ]; then
            local d_age; d_age=$(( $(date +%s) - $(stat -c %Y "$durable") ))
            echo "hot state missing; durable path=$durable age=${d_age}s" >> "$OUTPUT_FILE"
            if [ "$d_age" -lt 600 ]; then echo "warn|hot missing; durable age ${d_age}s"
            else echo "fail|hot missing; durable age ${d_age}s"; fi
            return
        fi
        echo "missing $f" >> "$OUTPUT_FILE"
        echo "fail|missing (poller has never run successfully)"
        return
    fi
    local age; age=$(( $(date +%s) - $(stat -c %Y "$f") ))
    echo "path=$f age=${age}s" >> "$OUTPUT_FILE"
    if [ "$age" -lt 60 ]; then echo "pass|age ${age}s"
    elif [ "$age" -lt 300 ]; then echo "warn|age ${age}s (>60s)"
    else echo "fail|age ${age}s (poller may be stalled)"; fi
}
''',
    "health check data_used freshness",
)
health_path.write_text(health)
PY

    grep -q 'DATA_USED_HOT_FILE="/tmp/qmanager_data_used.json"' "$poller" \
        || fail "Could not apply data_used hot-state patch"
    grep -q 'DATA_USED_FLUSH_INTERVAL="${DATA_USED_FLUSH_INTERVAL:-300}"' "$poller" \
        || fail "Could not apply data_used flush interval patch"
    grep -q 'flush_data_used_state' "$poller" \
        || fail "Could not apply data_used durable flush function"
    grep -q 'QLOG_TO_SYSLOG="${QLOG_TO_SYSLOG:-0}"' "$qlog" \
        || fail "Could not disable Casa syslog forwarding default"
    grep -q 'chmod 775 /var/spool/cron /var/spool/cron/crontabs' "$setup" \
        || fail "Could not harden cron spool permissions"
    grep -q 'auth_unavailable' "$cgi_base" \
        || fail "Could not apply CGI auth fail-closed fallback"
    grep -q 'QM_MAX_POST_SIZE:=65536' "$cgi_base" \
        || fail "Could not apply CGI POST size limit"
    grep -q 'local f=/tmp/qmanager_data_used.json' "$health" \
        || fail "Could not move Health Check data_used freshness to hot state"
}

patch_ai62_cookie_cors_config_hardening_cfw3212() {
    local cgi_auth="$TARGET/scripts/usr/lib/qmanager/cgi_auth.sh"
    local cgi_base="$TARGET/scripts/usr/lib/qmanager/cgi_base.sh"
    local setup="$TARGET/scripts/usr/bin/qmanager_setup"

    [ -f "$cgi_auth" ] || fail "Target missing cgi_auth.sh"
    [ -f "$cgi_base" ] || fail "Target missing cgi_base.sh"
    [ -f "$setup" ] || fail "Target missing qmanager_setup"

    python3 - "$cgi_auth" "$cgi_base" "$setup" <<'PY'
from pathlib import Path
import sys

cgi_auth_path, cgi_base_path, setup_path = map(Path, sys.argv[1:])

def replace_once(text, old, new, label):
    if old not in text:
        raise SystemExit(f"{label} marker not found")
    return text.replace(old, new, 1)

cgi_auth = cgi_auth_path.read_text()
cgi_auth = replace_once(
    cgi_auth,
    '''qm_set_session_cookies() {
    echo "Set-Cookie: ${COOKIE_SESSION}=${1}; HttpOnly; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE}"
    echo "Set-Cookie: ${COOKIE_INDICATOR}=1; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE}"
}

# Emit Set-Cookie headers that clear both cookies
qm_clear_session_cookies() {
    echo "Set-Cookie: ${COOKIE_SESSION}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0"
    echo "Set-Cookie: ${COOKIE_INDICATOR}=; SameSite=Strict; Path=/; Max-Age=0"
}
''',
    '''qm_set_session_cookies() {
    echo "Set-Cookie: ${COOKIE_SESSION}=${1}; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE}"
    echo "Set-Cookie: ${COOKIE_INDICATOR}=1; Secure; SameSite=Strict; Path=/; Max-Age=${SESSION_MAX_AGE}"
}

# Emit Set-Cookie headers that clear both cookies
qm_clear_session_cookies() {
    echo "Set-Cookie: ${COOKIE_SESSION}=; HttpOnly; Secure; SameSite=Strict; Path=/; Max-Age=0"
    echo "Set-Cookie: ${COOKIE_INDICATOR}=; Secure; SameSite=Strict; Path=/; Max-Age=0"
}
''',
    "cgi_auth secure cookie headers",
)
cgi_auth_path.write_text(cgi_auth)

cgi_base = cgi_base_path.read_text()
cgi_base = cgi_base.replace(
    "# Emit full JSON + CORS headers followed by the required blank line.",
    "# Emit full JSON headers followed by the required blank line.",
    1,
)
cgi_base = replace_once(
    cgi_base,
    '''    echo "Cache-Control: no-cache, no-store, must-revalidate"
    echo "Access-Control-Allow-Origin: *"
    echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
    echo "Access-Control-Allow-Headers: Content-Type, Authorization"
    echo ""
''',
    '''    echo "Cache-Control: no-cache, no-store, must-revalidate"
    echo ""
''',
    "cgi_base wildcard CORS headers",
)
cgi_base_path.write_text(cgi_base)

setup = setup_path.read_text()
setup = replace_once(
    setup,
    '''# Config directory — www-data needs write access for auth.json, profiles
chown -R www-data:www-data /etc/qmanager

# Make all qmanager binaries executable
''',
    '''# Config directory — www-data needs write access for auth.json, profiles,
# settings, and schedule state. Deny world access to persistent config.
chown -R www-data:www-data /etc/qmanager
find /etc/qmanager -type d -exec chmod 750 {} \\; 2>/dev/null || true
find /etc/qmanager -type f -exec chmod 640 {} \\; 2>/dev/null || true
[ -f /etc/qmanager/auth.json ] && chmod 600 /etc/qmanager/auth.json

# Make all qmanager binaries executable
''',
    "qmanager_setup config permissions",
)
setup_path.write_text(setup)
PY

    grep -q 'HttpOnly; Secure; SameSite=Strict' "$cgi_auth" \
        || fail "Could not add Secure to session cookie"
    grep -q 'COOKIE_INDICATOR.*Secure; SameSite=Strict' "$cgi_auth" \
        || fail "Could not add Secure to indicator cookie"
    if grep -q 'Access-Control-Allow-Origin: \*' "$cgi_base"; then
        fail "CGI base still emits wildcard CORS"
    fi
    grep -q 'find /etc/qmanager -type d -exec chmod 750' "$setup" \
        || fail "Could not tighten /etc/qmanager directory modes"
    grep -q 'find /etc/qmanager -type f -exec chmod 640' "$setup" \
        || fail "Could not tighten /etc/qmanager file modes"
}

patch_ai62_sudoers_narrowing_cfw3212() {
    local sudoers="$TARGET/scripts/etc/sudoers.d/qmanager"

    [ -f "$sudoers" ] || fail "Target missing etc/sudoers.d/qmanager"

    python3 - "$sudoers" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

# AI-62 phase 1: align Custom DNS sudo rules with Casa /tmp staging + systemctl
# reload, drop unused crontab (Casa CGI writes /var/spool/cron/crontabs/root
# directly), and narrow systemctl to known QManager/tailscaled/dnsmasq units.
new_text = """# QManager — sudoers rules for CGI scripts (lighttpd runs as www-data)
# Install location: /usrdata/opt/etc/sudoers.d/qmanager on Casa CFW-3212

# Service control — qmanager units, tailscaled, Casa dnsmasq only (AI-62)
www-data ALL=(root) NOPASSWD: /bin/systemctl start qmanager-*, /bin/systemctl stop qmanager-*, /bin/systemctl restart qmanager-*, /bin/systemctl is-active qmanager-*
www-data ALL=(root) NOPASSWD: /bin/systemctl start tailscaled, /bin/systemctl stop tailscaled, /bin/systemctl restart tailscaled, /bin/systemctl is-active tailscaled
www-data ALL=(root) NOPASSWD: /bin/systemctl start dnsmasq_service@0.service, /bin/systemctl stop dnsmasq_service@0.service, /bin/systemctl restart dnsmasq_service@0.service, /bin/systemctl is-active dnsmasq_service@0.service

# Boot persistence (symlink-based — systemctl enable doesn't work on RM520N-GL / Casa)
www-data ALL=(root) NOPASSWD: /bin/ln -sf /lib/systemd/system/qmanager*.service /lib/systemd/system/multi-user.target.wants/qmanager*.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager*.service

# Firewall rules (used by TTL via run_iptables — phase 2 may wrap in helper)
www-data ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/iptables-restore, /usr/sbin/ip6tables, /usr/sbin/ip6tables-restore

# System reboot (used by system/reboot.sh, update installer)
www-data ALL=(root) NOPASSWD: /sbin/reboot

# SSH password management (reads password from stdin, updates /etc/shadow)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_ssh_password

# Tailscale VPN management
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_tailscale_mgr
www-data ALL=(root) NOPASSWD: /usrdata/tailscale/tailscale
www-data ALL=(root) NOPASSWD: /usrdata/tailscale/tailscaled --version

# Tailscale boot persistence (symlink-based)
www-data ALL=(root) NOPASSWD: /bin/ln -sf /lib/systemd/system/tailscaled.service /lib/systemd/system/multi-user.target.wants/tailscaled.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /lib/systemd/system/multi-user.target.wants/tailscaled.service

# Web console management
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_console_mgr

# OTA updater (download/stage/install/rollback — needs full root for install.sh)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_update

# System Health Check (privileged runner that probes binaries, AT, services, sudoers)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_health_check

# Ethernet link speed limit management
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_ethernet_apply

# Custom DNS management (Casa: tmp staging + systemctl restart dnsmasq)
# Note: chown's "radio:radio" argument has the colon backslash-escaped because
# sudoers treats ':' as the user:group separator in any token unless escaped.
www-data ALL=(root) NOPASSWD: /bin/mv /tmp/qmanager-dnsmasq.conf.new /etc/data/dnsmasq.conf
www-data ALL=(root) NOPASSWD: /bin/chown radio\\:radio /etc/data/dnsmasq.conf
"""

if text == new_text:
    raise SystemExit("sudoers already narrowed — duplicate patch?")
path.write_text(new_text)
PY

    grep -q 'systemctl start qmanager-\*' "$sudoers" \
        || fail "Could not narrow sudoers systemctl rules to qmanager-*"
    grep -q '/tmp/qmanager-dnsmasq.conf.new /etc/data/dnsmasq.conf' "$sudoers" \
        || fail "Could not align sudoers Custom DNS mv rule with /tmp staging"
    grep -q 'systemctl restart dnsmasq_service@0.service' "$sudoers" \
        || fail "Could not add sudoers dnsmasq_service restart allowance"
    if grep -q '/usr/bin/crontab' "$sudoers"; then
        fail "sudoers still allows broad crontab after AI-62 narrowing"
    fi
    if grep -q 'killall -HUP dnsmasq' "$sudoers"; then
        fail "sudoers still allows obsolete dnsmasq killall reload"
    fi
    if grep -q '/bin/systemctl start \*' "$sudoers"; then
        fail "sudoers still allows broad systemctl start *"
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

old_reconnect = '''    reconnect)
        qlog_info "Network reconnect requested (AT+COPS=2 then AT+COPS=0)"
        qcmd 'AT+COPS=2' >/dev/null 2>&1
        sleep 2
        qcmd 'AT+COPS=0' >/dev/null 2>&1
        jq -n '{"success":true,"detail":"Network reconnect initiated"}'
        ;;
'''
new_reconnect = '''    reconnect)
        qlog_info "Network reconnect requested via Casa RDB connection manager"
        if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get link.profile.1.writeflag >/dev/null 2>&1; then
            current_enable=$(rdb_get link.policy.1.enable 2>/dev/null)
            [ -z "$current_enable" ] && current_enable=1
            rdb_set link.profile.1.writeflag 1
            rdb_set link.policy.1.trigger_connect "$current_enable"
            jq -n '{"success":true,"detail":"Network reconnect requested through Casa connection manager"}'
        else
            qlog_info "Casa RDB reconnect keys unavailable; falling back to AT+COPS=2/0"
            qcmd 'AT+COPS=2' >/dev/null 2>&1
            sleep 2
            qcmd 'AT+COPS=0' >/dev/null 2>&1
            jq -n '{"success":true,"detail":"Network reconnect initiated"}'
        fi
        ;;
'''
if "Network reconnect requested via Casa RDB connection manager" not in text:
    if old_reconnect not in text:
        raise SystemExit("reconnect command block not found")
    text = text.replace(old_reconnect, new_reconnect, 1)

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
    grep -q 'link.policy.1.trigger_connect' "$reboot_sh" \
        || fail "Could not apply Casa RDB reconnect patch"
}

patch_casa_watchcat_tiers() {
    # Reroute the qmanager_watchcat recovery daemon so its automatic Tier 1
    # (reconnect) and Tier 4 (reboot) actions use the Casa RDB connection-
    # manager and service-aware reset paths, falling back to the upstream
    # AT+COPS / bare reboot behavior when those RDB keys are unavailable.
    # This matches what patch_casa_reboot does for the manual UI buttons.
    local watchcat="$TARGET/scripts/usr/bin/qmanager_watchcat"
    [ -f "$watchcat" ] || return 0

    python3 - "$watchcat" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_tier1 = '''    qcmd 'AT+COPS=2' 2>/dev/null
    sleep 2
    qcmd 'AT+COPS=0' 2>/dev/null
'''
new_tier1 = '''    if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get link.profile.1.writeflag >/dev/null 2>&1; then
        current_enable=$(rdb_get link.policy.1.enable 2>/dev/null)
        [ -z "$current_enable" ] && current_enable=1
        rdb_set link.profile.1.writeflag 1 2>/dev/null
        rdb_set link.policy.1.trigger_connect "$current_enable" 2>/dev/null
    else
        qcmd 'AT+COPS=2' 2>/dev/null
        sleep 2
        qcmd 'AT+COPS=0' 2>/dev/null
    fi
'''
if "link.policy.1.trigger_connect" not in text:
    if old_tier1 not in text:
        raise SystemExit("tier1 AT+COPS block not found")
    text = text.replace(old_tier1, new_tier1, 1)

old_tier4 = '''    # Reboot after flushing state
    ( sleep 1 && reboot ) &
'''
new_tier4 = '''    # Reboot after flushing state - Casa RDB reset path with reboot fallback
    (
        sleep 1
        if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get service.system.reset >/dev/null 2>&1; then
            rdb_set service.system.reset_reason "QManager watchcat tier4 recovery"
            rdb_set service.system.reset.delay 5
            rdb_set service.system.reset 1
        else
            _reboot_cmd="reboot"
            command -v run_reboot >/dev/null 2>&1 && _reboot_cmd="run_reboot"
            $_reboot_cmd
        fi
    ) </dev/null >/dev/null 2>&1 &
'''
if "QManager watchcat tier4 recovery" not in text:
    if old_tier4 not in text:
        raise SystemExit("tier4 reboot block not found")
    text = text.replace(old_tier4, new_tier4, 1)

path.write_text(text)
PY

    grep -q 'link.policy.1.trigger_connect' "$watchcat" \
        || fail "Could not apply Casa watchcat tier1 reconnect patch"
    grep -q 'QManager watchcat tier4 recovery' "$watchcat" \
        || fail "Could not apply Casa watchcat tier4 reboot patch"
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
    # Already patched in a previous run, or the generator now emits the clean
    # literal backslash form directly.
    if "Casa CFW-3212 boot-identity tr fix" in text or "tr -d '\\r'" in text:
        sys.exit(0)
    sys.exit("expected tr -d '\\n' literal not found in qmanager_poller")
# patch_qmanager_poller's Group A identity block emits its `tr -d '\\r'`
# guards as literal CR bytes (Python non-raw string), which read_text() above
# normalizes to \n — so each such guard shows up here and is converted to a
# clean `tr -d '\\r'`. That block currently has 5 of them; keep headroom but
# still refuse on a wildly different upstream shape.
if count > 8:
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

    if ! grep -q "Casa CFW-3212 boot-identity tr fix" "$poller"; then
        grep -Fq "tr -d '\\r'" "$poller" \
            || fail "Could not apply Casa boot-identity tr fix to qmanager_poller"
    fi
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
        + '    # Casa CFW-3212 ippt service-clear: keep the service-level handover\n'
        + '    # flag in sync with the toggle. The stock QCMAP handover engine reads\n'
        + '    # service.ip_handover.enable (factory default 1), NOT the per-profile\n'
        + '    # flag, so ENABLING must set it to 1 for handover to actually engage;\n'
        + '    # DISABLING sets 0 and clears the cached last WAN IP so the data\n'
        + '    # session stops binding to the Casa handover placeholder across\n'
        + '    # reboots. Keys are persistent (`p` flag) so we set them, not unset.\n'
        + '    if [ "$ENABLED" = "0" ]; then\n'
        + '        rdb set "$SERVICE_ENABLE_RDB" 0 2>/dev/null || true\n'
        + '        rdb setflags "$SERVICE_ENABLE_RDB" p 2>/dev/null || true\n'
        + '        rdb set "$SERVICE_LAST_IP_RDB" "" 2>/dev/null || true\n'
        + '        rdb setflags "$SERVICE_LAST_IP_RDB" p 2>/dev/null || true\n'
        + '    else\n'
        + '        rdb set "$SERVICE_ENABLE_RDB" 1 2>/dev/null || true\n'
        + '        rdb setflags "$SERVICE_ENABLE_RDB" p 2>/dev/null || true\n'
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

patch_casa_band_locking_persist_cfw3212() {
    # Make a QManager band save (including "Select all") persist across reboot on
    # Casa. The band-lock CGI keeps writing AT+QNWPREFCFG exactly as upstream --
    # that already applies the bands fine in-session; the only problem is that the
    # selection doesn't survive a reboot. Reported symptom: after "Select all" +
    # save + reboot, every band OUTSIDE Casa's hidden_bands list is still checked,
    # but the bands INSIDE it come back unchecked.
    #
    # Two wmmd mechanisms undo the save at boot, and the patch neutralizes both
    # (right after a successful lock, so it only affects boxes where a user
    # actually uses band locking -- this is NOT a blanket installer unhide):
    #   1. wmmd.config.hidden_bands FILTERS the usable set (modem base minus
    #      hidden) -- the actual cause of the reported bug. Cleared to "" so
    #      QManager owns the band set. The modem hardware base is still the hard
    #      limit, so only base-supported bands are ever exposed.
    #   2. the cdcs revert_modem_band template re-applies the carrier factory band
    #      set unless revert_selband.mode == no_change -- pinned to no_change.
    # Both keys are marked persistent (p). No RAT change, no Casa currentband
    # rewrite -- the AT QNWPREFCFG path is left exactly as upstream.
    #
    # Tradeoff: clearing hidden_bands exposes bands the carrier MBN normally hides
    # (e.g. CBRS B42/43, LAA B46) where the modem base supports them, and pinning
    # no_change disables wmmd's factory auto-revert safety. QManager Band Failover
    # remains the connectivity safety net. See private-notes
    # COMPOSER_WMMD_DEEPDIVE_2026-04-13 sec.3.3 and band root-cause note
    # 2026-04-19 sec.8 (Box 2 spike).
    local lock="$TARGET/scripts/www/cgi-bin/quecmanager/bands/lock.sh"
    [ -f "$lock" ] || fail "Target missing bands/lock.sh"
    python3 - "$lock" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

MARKER = "Casa CFW-3212 band-persist"
if MARKER in text:
    sys.exit(0)

anchor = 'qlog_info "Band lock applied: $AT_PARAM=$BANDS"'
if anchor not in text:
    sys.exit("bands/lock.sh success anchor not found (upstream changed?)")

inject = anchor + "\n\n" + (
    "# --- Casa CFW-3212 band-persist ------------------------------------------\n"
    "# Make the saved band selection survive reboot on Casa. Two wmmd mechanisms\n"
    "# otherwise undo a QManager band save at the next boot:\n"
    "#  1. wmmd.config.hidden_bands FILTERS the usable band set (modem base minus\n"
    "#     hidden). Any saved band that sits in the hidden list is dropped on\n"
    "#     reboot -- e.g. 'select all' saves fine over AT, but comes back with the\n"
    "#     hidden bands UNCHECKED. This is the actual reported bug.\n"
    "#  2. the cdcs revert_modem_band template re-applies the carrier factory band\n"
    "#     set when revert_selband.mode != no_change.\n"
    "# QManager now owns the band set: clear hidden_bands (nothing hidden -- the\n"
    "# modem hardware base is still the hard limit, so only base-supported bands\n"
    "# are ever exposed) and pin revert mode=no_change. Both keys are marked\n"
    "# persistent (p) so the change survives reboot. This is user-driven (only\n"
    "# runs when a user saves a band selection), NOT a blanket installer unhide.\n"
    'rdb_set wmmd.config.hidden_bands "" 2>/dev/null || true\n'
    'rdb_setflags wmmd.config.hidden_bands p 2>/dev/null || true\n'
    'rdb_set wwan.0.currentband.revert_selband.mode no_change 2>/dev/null || true\n'
    'rdb_setflags wwan.0.currentband.revert_selband.mode p 2>/dev/null || true'
)
text = text.replace(anchor, inject, 1)
path.write_text(text)
PY

    grep -q "Casa CFW-3212 band-persist" "$lock" \
        || fail "Could not apply Casa band-locking persist patch"
}

patch_casa_tailscale_tiny_cfw3212() {
    # Switch the on-demand Tailscale installer (driven by the UI's Tailscale
    # section, via cgi .../vpn/tailscale.sh -> qmanager_tailscale_mgr) from
    # upstream's official pkgs.tailscale.com arm build to our fork
    # Joetooley28/tiny-tailscale (forked from iamromulan/tiny-tailscale, which
    # builds via tailscale's cmd/featuretags --min). Our fork re-adds the
    # 'ipnbus' feature so the UI's interactive Connect/login flow works (the
    # stock tiny build omits ipnbus, which streams the auth URL).
    #
    # Why: on the CFW-3212 (~183 MB RAM, single armv7 core) the official
    # tailscaled is the single largest RAM consumer (~29 MB RSS, AI-47).
    # tiny-tailscale is a statically-linked, feature-reduced *combined* binary
    # (one `tailscaled`, with `tailscale` a symlink that switches to CLI mode by
    # argv[0]). Although romulan built it for the RM551E (Qualcomm OpenWRT), a
    # static Go binary has no userland dependency -- smoke-tested running on this
    # RM520N: `tailscaled --version` and `tailscale version` both return 1.98.3.
    #
    # The tarball layout matches upstream's (dir tiny-tailscale_<v>_arm/ holding
    # tailscaled + a tailscale symlink), so the existing download/extract/mv/
    # symlink/systemd logic in qmanager_tailscale_mgr works unchanged -- only the
    # version, tarball name, URL, and extract-dir need to change.
    local ts_mgr="$TARGET/scripts/usr/bin/qmanager_tailscale_mgr"
    [ -f "$ts_mgr" ] || fail "qmanager_tailscale_mgr not found at $ts_mgr (upstream layout changed?)"

    local tiny_ver="1.98.3"

    python3 - "$ts_mgr" "$tiny_ver" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
ver = sys.argv[2]
text = path.read_text()

# TAILSCALE_VERSION appears twice (outer wrapper + inner install script); both
# should move to the tiny version. ARCH stays "arm" (correct for armv7l).
repl = [
    ('TAILSCALE_VERSION="1.92.5"', f'TAILSCALE_VERSION="{ver}"'),
    ('TAILSCALE_TARBALL="tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}.tgz"',
     'TAILSCALE_TARBALL="tiny-tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}.tgz"'),
    ('TAILSCALE_URL="https://pkgs.tailscale.com/stable/${TAILSCALE_TARBALL}"',
     'TAILSCALE_URL="https://github.com/Joetooley28/tiny-tailscale/releases/download/v${TAILSCALE_VERSION}/${TAILSCALE_TARBALL}"'),
    ('TAILSCALE_EXTRACT_DIR="tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}"',
     'TAILSCALE_EXTRACT_DIR="tiny-tailscale_${TAILSCALE_VERSION}_${TAILSCALE_ARCH}"'),
    # GitHub release URLs 302-redirect to objects.githubusercontent.com; the
    # upstream helper's bare `curl -O` does NOT follow redirects (it was fine for
    # pkgs.tailscale.com which serves directly), so it saved a 0-byte file ->
    # `tar: invalid magic`. Add -fL so curl follows the redirect and fails loudly
    # on HTTP errors.
    ('if ! curl -O "$TAILSCALE_URL"; then',
     'if ! curl -fL -O "$TAILSCALE_URL"; then'),
    # tiny-tailscale (stripped build) lacks systemd sd_notify support: a
    # Type=notify unit never gets READY=1, so systemd marks the (actually
    # running) daemon as failed-to-start. Use Type=simple. Covers the mgr's
    # inline fallback unit; the staged bundled unit is patched separately below.
    ('Type=notify', 'Type=simple'),
]
for old, new in repl:
    if old not in text:
        raise SystemExit(f"tiny-tailscale: expected marker not found: {old}")
    text = text.replace(old, new)

# Neutralise the "already installed -> tailscale update" path. tiny-tailscale is
# a custom build; `tailscale update` would pull the OFFICIAL build from
# pkgs.tailscale.com and silently undo this swap. Upgrades happen by
# uninstall + reinstall (which re-fetches the tiny tarball).
old_update = 'echo y | "$TAILSCALE_DIR/tailscale" update'
if old_update not in text:
    raise SystemExit("tiny-tailscale: expected marker not found: tailscale update line")
text = text.replace(
    old_update,
    'echo "tiny-tailscale build: skipping tailscale update (reinstall to upgrade)"',
)

path.write_text(text)
PY

    grep -q 'tiny-tailscale_' "$ts_mgr" \
        || fail "Could not apply tiny-tailscale tarball/extract patch"
    grep -q 'Joetooley28/tiny-tailscale/releases/download' "$ts_mgr" \
        || fail "Could not apply tiny-tailscale URL patch"
    grep -q 'TAILSCALE_VERSION="1.98.3"' "$ts_mgr" \
        || fail "Could not apply tiny-tailscale version patch"
    grep -q 'reinstall to upgrade' "$ts_mgr" \
        || fail "Could not neutralise tailscale update path"
    grep -q 'curl -fL -O' "$ts_mgr" \
        || fail "Could not apply tiny-tailscale curl follow-redirect (-fL) patch"
    grep -q '^Type=simple' "$ts_mgr" \
        || fail "Could not set Type=simple in qmanager_tailscale_mgr inline unit"

    # Bundled unit (preferred by the mgr over its inline fallback) is staged here.
    local ts_unit="$TARGET/scripts/etc/systemd/system/tailscaled.service"
    [ -f "$ts_unit" ] || fail "staged tailscaled.service not found at $ts_unit"
    sed -i 's/^Type=notify$/Type=simple/' "$ts_unit"
    grep -q '^Type=simple' "$ts_unit" \
        || fail "Could not set Type=simple in staged tailscaled.service"

    echo "  [tailscale] on-demand installer switched to tiny-tailscale v$tiny_ver (arm), Type=simple"
}

patch_casa_tailscale_install_label_cfw3212() {
    # The on-demand installer pulls the lighter "Tiny Tailscale" build
    # (see patch_casa_tailscale_tiny_cfw3212); label the UI install button to
    # match so users know which build they're installing.
    local tscard="$TARGET/components/monitoring/tailscale/tailscale-connection-card.tsx"
    [ -f "$tscard" ] || fail "tailscale-connection-card.tsx not found at $tscard"
    python3 - "$tscard" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = "Install Tailscale"
if t.count(old) != 1:
    raise SystemExit(f"tiny-tailscale: expected exactly one 'Install Tailscale' button label, found {t.count(old)}")
t = t.replace(old, "Install Tiny Tailscale", 1)
p.write_text(t)
PY
    grep -q 'Install Tiny Tailscale' "$tscard" \
        || fail "Could not apply Tiny Tailscale install button label"
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
    # Casa CFW-3212: IP passthrough here is a ROUTED handover, NOT a DNS bypass.
    # State lives in RDB (link.profile.1.ip_handover.enable etc.), but unlike a
    # classic passthrough the handover device does NOT get carrier DNS directly:
    # bridge0 DHCP forces option 6 = 192.168.20.1 (dhcp-option-force=6) for every
    # client including the handover device, so it still routes DNS through the
    # modem's dnsmasq. Verified live (IPPT on): enabling Custom DNS changed the
    # upstream for the passthrough router's clients. So nothing bypasses dnsmasq
    # -> always false, which suppresses the upstream "IP Passthrough is bypassing
    # dnsmasq" warning that would otherwise wrongly imply Custom DNS is ignored.
    printf "false"
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
# CFW-3212: dnsmasq 2.87 SIGHUP does NOT re-read the config file, so the
# upstream `killall -HUP dnsmasq` reload never applied the custom-DNS block
# (it only took effect on the next reboot).  Restart the QCMAP dnsmasq unit
# instead: systemd (Restart=always) re-runs ExecStartPre + ExecStart with
# --conf-file=/var/run/data/dnsmasq.conf.bridge0.updated, which conf-file-
# includes /etc/data/dnsmasq.conf.  `/bin/systemctl restart *` is already
# whitelisted for www-data in /opt/etc/sudoers.d/qmanager (no sudoers change).
text = text.replace(
    "sudo /usr/bin/killall -HUP dnsmasq",
    "sudo /bin/systemctl restart dnsmasq_service@0.service",
)
text = text.replace(
    "killall -HUP dnsmasq failed",
    "dnsmasq restart failed",
)
text = text.replace(
    "jq -r '.enabled // empty'",
    "jq -r '.enabled | if . == null then \"\" else tostring end'",
)
path.write_text(text)
PY

    grep -q 'Casa CFW-3212: mobileap_cfg.xml has no <DNSMode>' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS get_dns_mode patch"
    grep -q 'link.profile.1.ip_handover.enable' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS get_passthrough_bypass patch"
    grep -q 'STAGING_FILE="/tmp/qmanager-dnsmasq.conf.new"' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS staging path patch"
    grep -q 'if . == null then "" else tostring end' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS enabled boolean fix"
    grep -q 'systemctl restart dnsmasq_service@0.service' "$dns_cgi" \
        || fail "Could not apply Casa Custom DNS reload-fix patch"
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

patch_deterministic_frontend_build_id_cfw3212() {
    local config="$TARGET/next.config.ts"
    [ -f "$config" ] || fail "next.config.ts missing in target"

    log "Patching Next build ID to be deterministic from frontend inputs"

    python3 - "$config" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "Casa CFW-3212 deterministic frontend build ID" in text:
    raise SystemExit(0)

if 'import type { NextConfig } from "next";' not in text:
    raise SystemExit("next.config.ts import marker not found")

imports = '''import type { NextConfig } from "next";
import { createHash } from "crypto";
import { existsSync, readdirSync, readFileSync, statSync } from "fs";
import path from "path";
'''
text = text.replace('import type { NextConfig } from "next";\n', imports, 1)

helper = r'''
const FRONTEND_BUILD_INPUTS = [
  "app",
  "components",
  "constants",
  "hooks",
  "lib",
  "public",
  "types",
  "middleware.ts",
  "next-env.d.ts",
  "package.json",
  "bun.lock",
  "bun.lockb",
  "postcss.config.mjs",
  "tsconfig.json",
];

const FRONTEND_BUILD_IGNORE = new Set([
  ".git",
  ".next",
  "node_modules",
  "out",
  "qmanager-build",
]);

function updateHashForPath(hash: ReturnType<typeof createHash>, root: string, filePath: string) {
  if (!existsSync(filePath)) return;

  const stat = statSync(filePath);
  if (stat.isDirectory()) {
    for (const entry of readdirSync(filePath).sort()) {
      if (FRONTEND_BUILD_IGNORE.has(entry)) continue;
      updateHashForPath(hash, root, path.join(filePath, entry));
    }
    return;
  }

  if (!stat.isFile()) return;
  const rel = path.relative(root, filePath).replaceAll(path.sep, "/");
  hash.update(rel);
  hash.update("\0");
  hash.update(readFileSync(filePath));
  hash.update("\0");
}

function casaFrontendBuildId() {
  // Casa CFW-3212 deterministic frontend build ID:
  // Next's default random build ID changes exported HTML/TXT route files even
  // when a Casa release only changes backend scripts. That made backend-only
  // package updates rewrite most of /usrdata/qmanager/www on the router. Hash
  // frontend inputs instead, so unchanged UI output keeps the same build ID.
  if (process.env.QMANAGER_FRONTEND_BUILD_ID) {
    return process.env.QMANAGER_FRONTEND_BUILD_ID;
  }

  const root = process.cwd();
  const hash = createHash("sha256");
  for (const input of FRONTEND_BUILD_INPUTS) {
    updateHashForPath(hash, root, path.join(root, input));
  }
  return `cfw3212-${hash.digest("hex").slice(0, 20)}`;
}

'''
text = text.replace('\nconst nextConfig: NextConfig = {', helper + '\nconst nextConfig: NextConfig = {', 1)

if '  trailingSlash: true,\n' not in text:
    raise SystemExit("next.config.ts trailingSlash marker not found")
text = text.replace(
    '  trailingSlash: true,\n',
    '  trailingSlash: true,\n  generateBuildId: async () => casaFrontendBuildId(),\n',
    1,
)

path.write_text(text)
PY

    grep -q 'Casa CFW-3212 deterministic frontend build ID' "$config" \
        || fail "Could not apply deterministic frontend build ID patch"
    grep -q 'generateBuildId: async () => casaFrontendBuildId()' "$config" \
        || fail "next.config.ts missing deterministic generateBuildId hook"
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

patch_speedtest_latency_iqm_guard_cfw3212() {
    local dialog="$TARGET/components/dashboard/speedtest-dialog.tsx"
    [ -f "$dialog" ] || fail "speedtest-dialog.tsx missing in target"

    python3 - "$dialog" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = [
    (
        '''            {result.download.latency.iqm.toFixed(1)} ms
''',
        '''            {result.download.latency?.iqm !== undefined
              ? `${result.download.latency.iqm.toFixed(1)} ms`
              : "-"}
''',
    ),
    (
        '''            {result.upload.latency.iqm.toFixed(1)} ms
''',
        '''            {result.upload.latency?.iqm !== undefined
              ? `${result.upload.latency.iqm.toFixed(1)} ms`
              : "-"}
''',
    ),
]

for old, new in replacements:
    if new in text:
        continue
    if old not in text:
        raise SystemExit(f"patch target not found in {path}: {old.strip()!r}")
    text = text.replace(old, new, 1)

path.write_text(text)
PY

    grep -Fq 'result.download.latency?.iqm !== undefined' "$dialog" \
        || fail "Could not apply DL latency iqm guard to speedtest-dialog.tsx"
    grep -Fq 'result.upload.latency?.iqm !== undefined' "$dialog" \
        || fail "Could not apply UL latency iqm guard to speedtest-dialog.tsx"
    ! grep -Fq '            {result.download.latency.iqm.toFixed(1)} ms' "$dialog" \
        || fail "speedtest-dialog.tsx still has unsafe DL latency iqm read"
    ! grep -Fq '            {result.upload.latency.iqm.toFixed(1)} ms' "$dialog" \
        || fail "speedtest-dialog.tsx still has unsafe UL latency iqm read"
}

patch_software_update_reboot_required_cfw3212() {
    local hook="$TARGET/hooks/use-software-update.ts"
    local page="$TARGET/components/monitoring/software-update/software-update.tsx"
    local card="$TARGET/components/monitoring/software-update/update-status-card.tsx"
    local prefs="$TARGET/components/monitoring/software-update/update-preferences-card.tsx"
    if [ ! -f "$page" ]; then
        page="$TARGET/components/system-settings/software-update/software-update.tsx"
    fi
    if [ ! -f "$card" ]; then
        card="$TARGET/components/system-settings/software-update/update-status-card.tsx"
    fi
    if [ ! -f "$prefs" ]; then
        prefs="$TARGET/components/system-settings/software-update/update-preferences-card.tsx"
    fi
    [ -f "$hook" ] || fail "use-software-update.ts missing in target"
    [ -f "$page" ] || fail "software-update.tsx missing in target"
    [ -f "$card" ] || fail "update-status-card.tsx missing in target"
    [ -f "$prefs" ] || fail "update-preferences-card.tsx missing in target"

    python3 - "$hook" "$page" "$card" "$prefs" <<'PY'
from pathlib import Path
import sys

hook, page, card, prefs = map(Path, sys.argv[1:5])

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
        // reports reboot_required or a real error. Reload the current Software
        // Update page as a fallback for users left on a dropped session, so they
        // land back on the update status instead of the home page.
        if (!sessionStorage.getItem("qm_update_reload_scheduled")) {
          sessionStorage.setItem("qm_update_reload_scheduled", "1");
          window.setTimeout(() => {
            window.location.reload();
          }, 30000);
        }
        setError(null);
        setUpdateStatus({
          status: "installing",
          message: "QManager services are restarting; reconnecting. This page will reload the Software Update page in about 30 seconds if the status does not recover.",
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

replace_once(
    prefs,
    '''                  <strong>{selectedVersion}</strong> is already downloaded and
                  verified. Installing it now will replace{" "}
                  <strong>{updateInfo?.current_version}</strong> and reboot the
                  device.
''',
    '''                  <strong>{selectedVersion}</strong> is already downloaded and
                  verified. Installing it now will replace{" "}
                  <strong>{updateInfo?.current_version}</strong>. QManager will
                  restart its services after installation and then ask you to
                  reboot when ready.
''',
)
replace_once(
    prefs,
    '''                  This will reinstall <strong>{selectedVersion}</strong> to repair the
                  current installation. The device will reboot after installation.
''',
    '''                  This will reinstall <strong>{selectedVersion}</strong> to repair the
                  current installation. QManager will restart its services after installation and then ask you to reboot when ready.
''',
)
replace_once(
    prefs,
    '''                  This will install <strong>{selectedVersion}</strong>, replacing the
                  current version (<strong>{updateInfo?.current_version}</strong>).
                  The device will reboot after installation.
''',
    '''                  This will install <strong>{selectedVersion}</strong>, replacing the
                  current version (<strong>{updateInfo?.current_version}</strong>).
                  QManager will restart its services after installation and then
                  ask you to reboot when ready.
''',
)

for path in (hook, page, card):
    if "reboot_required" not in path.read_text():
        raise SystemExit(f"reboot_required patch missing from {path}")
PY

    grep -Fq 'QManager will restart its services after installation' "$prefs" \
        || fail "update-preferences-card.tsx missing Casa install restart wording"
    count="$(grep -c 'restart its services after installation' "$prefs" || true)"
    [ "$count" -ge 3 ] \
        || fail "update-preferences-card.tsx must have Casa reboot wording in all three install dialogs (found $count)"
    ! grep -Fq 'The device will reboot after installation.' "$prefs" \
        || fail "update-preferences-card.tsx still claims auto-reboot after installation"
    ! grep -Fq 'and reboot the' "$prefs" \
        || fail "update-preferences-card.tsx staged install dialog still claims auto-reboot"
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

patch_casa_dns_status_merge_cfw3212() {
    local f="$TARGET/scripts/www/cgi-bin/quecmanager/at_cmd/fetch_data.sh"
    [ -f "$f" ] || { warn "fetch_data.sh missing; skipping dns_status merge"; return 0; }
    if grep -q "qmanager_dns_state.json" "$f"; then
        log "fetch_data.sh already merges dns_status"
        return 0
    fi
    python3 - "$f" <<'PYMERGE'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
old = '    cat "$CACHE_FILE"\n'
new = (
    '    # Casa CFW-3212 (AI-64): fold the LAN DNS reconciler state into the\n'
    '    # dashboard payload so the IPPT + DNS-source badges need no extra poll.\n'
    '    DNS_STATE="/tmp/qmanager_dns_state.json"\n'
    '    if [ -f "$DNS_STATE" ] && command -v jq >/dev/null 2>&1; then\n'
    '        jq -s \'.[0] + {dns_status: .[1]}\' "$CACHE_FILE" "$DNS_STATE" 2>/dev/null || cat "$CACHE_FILE"\n'
    '    else\n'
    '        cat "$CACHE_FILE"\n'
    '    fi\n'
)
if old not in t:
    raise SystemExit("fetch_data.sh serve line not found (upstream changed?)")
p.write_text(t.replace(old, new, 1))
PYMERGE
    grep -q "qmanager_dns_state.json" "$f" || fail "dns_status merge not applied to fetch_data.sh"
    log "fetch_data.sh now merges dns_status (AI-64)"
}

patch_casa_dns_badges_cfw3212() {
    local ns="$TARGET/components/dashboard/network-status.tsx"
    local hc="$TARGET/components/dashboard/home-component.tsx"
    local ty="$TARGET/types/modem-status.ts"
    local comp="$TARGET/components/dashboard/dns-source-badges.tsx"
    for x in "$ns" "$hc" "$ty"; do
        [ -f "$x" ] || fail "DNS badges: missing $x"
    done
    if grep -q "DnsSourceBadges" "$ns"; then
        log "DNS badges already applied"
        return 0
    fi

    cat > "$comp" << 'TSXEOF'
"use client";

// Casa CFW-3212 (AI-64): small dashboard badges shown next to the upstream
// Online/Offline badge. One reports IP Passthrough on/off; the other reports
// where the router/LAN dnsmasq resolver is getting DNS from. Scope is the
// router/LAN resolver only — it cannot represent the passthrough device's
// carrier-direct DNS. Follows the project Status Badge Pattern (outline
// variant, semantic color classes, size-3 lucide icons).

import { Badge } from "@/components/ui/badge";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  RouterIcon,
  GlobeIcon,
  ShieldCheckIcon,
  TriangleAlertIcon,
  MinusCircleIcon,
} from "lucide-react";
import type { DnsStatus } from "@/types/modem-status";

export function DnsSourceBadges({ dnsStatus }: { dnsStatus: DnsStatus | null }) {
  if (!dnsStatus) return null;

  const ipptOn = dnsStatus.ippt_on === true;
  const ipptBadge = (
    <Badge
      variant="outline"
      className={
        ipptOn
          ? "bg-info/15 text-info hover:bg-info/20 border-info/30"
          : "bg-muted/50 text-muted-foreground border-muted-foreground/30"
      }
    >
      <RouterIcon className="size-3" />
      IPPT {ipptOn ? "On" : "Off"}
    </Badge>
  );

  let cls = "bg-muted/50 text-muted-foreground border-muted-foreground/30";
  let label = "Unknown";
  let Icon = MinusCircleIcon;
  let tip = "Router/LAN DNS source unknown";

  switch (dnsStatus.dns_source) {
    case "carrier":
      cls = "bg-success/15 text-success hover:bg-success/20 border-success/30";
      label = "Carrier";
      Icon = ShieldCheckIcon;
      tip = "Router/LAN DNS: carrier resolvers";
      break;
    case "custom":
      cls = "bg-info/15 text-info hover:bg-info/20 border-info/30";
      label = "Custom";
      Icon = GlobeIcon;
      tip = "Router/LAN DNS: QManager Custom DNS";
      break;
    case "public_fallback":
      cls = "bg-warning/15 text-warning hover:bg-warning/20 border-warning/30";
      label = "Public";
      Icon = TriangleAlertIcon;
      tip = "Router/LAN DNS: public fallback (carrier DNS unreachable)";
      break;
    case "poisoned":
      cls =
        "bg-destructive/15 text-destructive hover:bg-destructive/20 border-destructive/30";
      label = "Poisoned";
      Icon = TriangleAlertIcon;
      tip = "Router/LAN DNS: handover placeholder, no working resolver";
      break;
    default:
      break;
  }

  const dnsBadge = (
    <Badge variant="outline" className={cls}>
      <Icon className="size-3" />
      DNS: {label}
    </Badge>
  );

  return (
    <>
      {ipptBadge}
      <Tooltip>
        <TooltipTrigger asChild>{dnsBadge}</TooltipTrigger>
        <TooltipContent>{tip}</TooltipContent>
      </Tooltip>
    </>
  );
}
TSXEOF

    python3 - "$ns" "$hc" "$ty" << 'PYBADGE'
import sys, re
from pathlib import Path
ns_p, hc_p, ty_p = (Path(p) for p in sys.argv[1:4])

# --- types/modem-status.ts ---
ty = ty_p.read_text()
dns_iface = (
    "/** Casa CFW-3212 LAN DNS reconciler state (AI-64). Router/LAN scope. */\n"
    "export interface DnsStatus {\n"
    "  ippt_on: boolean;\n"
    "  dns_source: \"carrier\" | \"custom\" | \"public_fallback\" | \"poisoned\" | \"unknown\";\n"
    "  carrier_reachable: boolean;\n"
    "  scope: string;\n"
    "  checked_at: number;\n"
    "}\n\n"
)
anchor_ms = "export interface ModemStatus {"
assert ty.count(anchor_ms) == 1, "ModemStatus interface anchor"
ty = ty.replace(anchor_ms, dns_iface + anchor_ms, 1)
conn_field = "  /** Internet connectivity and latency (from ping daemon) */\n  connectivity: ConnectivityStatus;\n"
assert ty.count(conn_field) == 1, "connectivity field anchor"
ty = ty.replace(
    conn_field,
    conn_field + "  /** LAN DNS reconciler state (AI-64) */\n  dns_status?: DnsStatus;\n",
    1,
)
ty_p.write_text(ty)

# --- network-status.tsx ---
ns = ns_p.read_text()
ns = ns.replace(
    "  NetworkStatus,\n  ConnectivityStatus,\n  ServiceStatus,\n  PingTriState,\n} from \"@/types/modem-status\";",
    "  NetworkStatus,\n  ConnectivityStatus,\n  ServiceStatus,\n  PingTriState,\n  DnsStatus,\n} from \"@/types/modem-status\";",
    1,
)
ns = ns.replace(
    "} from \"@/components/ui/tooltip\";\n",
    "} from \"@/components/ui/tooltip\";\nimport { DnsSourceBadges } from \"./dns-source-badges\";\n",
    1,
)
ns = ns.replace(
    "  connectivity: ConnectivityStatus | null;\n",
    "  connectivity: ConnectivityStatus | null;\n  dnsStatus: DnsStatus | null;\n",
    1,
)
ns = ns.replace(
    "const NetworkStatusComponent = ({\n  data,\n  connectivity,\n",
    "const NetworkStatusComponent = ({\n  data,\n  connectivity,\n  dnsStatus,\n",
    1,
)
render_anchor = "              })()}\n            </div>\n          )}\n        </div>"
assert ns.count(render_anchor) == 1, "render anchor"
ns = ns.replace(
    render_anchor,
    "              })()}\n              {/* Casa CFW-3212 (AI-64): IPPT + LAN DNS source badges */}\n              <DnsSourceBadges dnsStatus={dnsStatus} />\n            </div>\n          )}\n        </div>",
    1,
)
# AI-64: let the header badge row wrap so the added IPPT/DNS badges plus
# transient badges (e.g. "Data Delayed") do not overflow the card.
ns = ns.replace(
    '<div className="flex md:flex-row flex-col xl:items-center justify-center xl:justify-between gap-2">',
    '<div className="flex flex-wrap md:flex-row flex-col xl:items-center justify-center xl:justify-between gap-2">',
    1,
)
ns = ns.replace(
    '<div className="flex items-center gap-x-1.5">\n              {/* Stale indicator */}',
    '<div className="flex flex-wrap items-center gap-1.5">\n              {/* Stale indicator */}',
    1,
)
assert "flex flex-wrap items-center gap-1.5" in ns, "badge-row wrap not applied"
ns_p.write_text(ns)

# --- home-component.tsx (thread to all usages, preserve indent) ---
hc = hc_p.read_text()
n = [0]
def add_dns(m):
    # Insert dnsStatus as the first prop of <NetworkStatusComponent> only.
    # Other components (e.g. LiveLatency) also take connectivity but NOT dnsStatus,
    # so anchor on the component tag, not on the connectivity line.
    n[0] += 1
    return m.group(1) + m.group(2) + "dnsStatus={data?.dns_status ?? null}\n" + m.group(2)
hc2 = re.sub(r'(<NetworkStatusComponent\n)([ \t]*)', add_dns, hc)
assert n[0] >= 1, "no <NetworkStatusComponent> usage found"
hc_p.write_text(hc2)
print(f"DNS badges patched: ns+ty+hc ({n[0]} home-component usages threaded)")
PYBADGE
    grep -q "DnsSourceBadges" "$ns" || fail "DNS badges: network-status insertion failed"
    grep -q "dns_status" "$hc" || fail "DNS badges: home-component threading failed"
    grep -q "export interface DnsStatus" "$ty" || fail "DNS badges: DnsStatus type missing"
    log "Casa IPPT + DNS-source dashboard badges applied (AI-64)"
}

patch_onboarding_normalize_defaults_cfw3212() {
    # First-run onboarding's "default" choices for Network Mode (RAT) and Band
    # Locking were implemented upstream as no-ops: selecting the pre-checked
    # "Automatic" / "All bands" simply advanced the wizard without sending any
    # AT command. That assumes the modem is already in that default state.
    # RAT (mode_pref/nr5g_disable_mode) and band-lock settings live in the
    # *modem's* NVM, not qmanager config, so they survive a qmanager reinstall.
    # On a previously-configured modem (e.g. one used for field testing) the
    # wizard's "Automatic" silently left a stale RAT/band lock in place. These
    # patches make the default choices actively normalize the modem.
    local nm="$TARGET/components/onboarding/steps/step-network-mode.tsx"
    local bl="$TARGET/components/onboarding/steps/step-band-locking.tsx"
    [ -f "$nm" ] || fail "Onboarding normalize: missing $nm"
    [ -f "$bl" ] || fail "Onboarding normalize: missing $bl"

    if grep -q "onboarding RAT normalize" "$nm" && \
       grep -q "onboarding band normalize" "$bl"; then
        log "Onboarding default-normalize patches already applied"
        return 0
    fi

    # --- Step 3: Network Mode — always apply, even AUTO/0 ---
    python3 - "$nm" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

needle = (
    '    if (selectedMode === "AUTO" && nr5gMode === 0) {\n'
    '      onSuccess();\n'
    '      return;\n'
    '    }\n'
    '\n'
    '    onLoadingChange(true);\n'
)
replacement = (
    '    // Casa CFW-3212 (onboarding RAT normalize): always apply the selected\n'
    '    // network mode, even the "Automatic" default (mode_pref=AUTO /\n'
    '    // nr5g_disable_mode=0). The upstream skip-when-default optimization\n'
    '    // assumed the modem was already in AUTO, but RAT/NR preferences live in\n'
    '    // modem NVM and survive qmanager reinstalls. On a previously-configured\n'
    '    // modem, skipping left a stale RAT lock in place, so onboarding\'s\n'
    '    // "Automatic" silently did nothing.\n'
    '    onLoadingChange(true);\n'
)
if needle not in text:
    raise SystemExit("network-mode: AUTO skip block not found (upstream may have changed)")
text = text.replace(needle, replacement, 1)
path.write_text(text)
PY
    grep -q "onboarding RAT normalize" "$nm" \
        || fail "Onboarding normalize: network-mode patch did not apply"

    # --- Step 5: Band Locking — "All bands" unlocks to full supported list ---
    python3 - "$bl" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

needle = (
    '    const lteBands = getBandString(ltePreset, ltePresets, lteCustom);\n'
    '    const nr5gBands = getBandString(nr5gPreset, nr5gPresets, nr5gCustom);\n'
)
replacement = (
    '    // Casa CFW-3212 (onboarding band normalize): "All bands (default)" now\n'
    '    // performs an explicit unlock — lock to the full modem-supported list —\n'
    '    // instead of a no-op. Band locks live in modem NVM and survive qmanager\n'
    '    // reinstalls, so the upstream skip left any stale band lock from prior\n'
    '    // use in place. Only unlock when the supported-band list is known; if\n'
    '    // poller data has not loaded we fall back to skip so we never POST an\n'
    '    // empty (invalid) band list.\n'
    '    const lteSupportedStr = supportedLte.length\n'
    '      ? [...supportedLte].sort((a, b) => a - b).join(":")\n'
    '      : null;\n'
    '    const nr5gSupportedStr = supportedNr5g.length\n'
    '      ? [...supportedNr5g].sort((a, b) => a - b).join(":")\n'
    '      : null;\n'
    '    const lteBands =\n'
    '      ltePreset === "all"\n'
    '        ? lteSupportedStr\n'
    '        : getBandString(ltePreset, ltePresets, lteCustom);\n'
    '    const nr5gBands =\n'
    '      nr5gPreset === "all"\n'
    '        ? nr5gSupportedStr\n'
    '        : getBandString(nr5gPreset, nr5gPresets, nr5gCustom);\n'
)
if needle not in text:
    raise SystemExit("band-locking: getBandString call block not found (upstream may have changed)")
text = text.replace(needle, replacement, 1)

dep_needle = (
    '  }, [ltePreset, nr5gPreset, lteCustom, nr5gCustom, ltePresets, '
    'nr5gPresets, onLoadingChange, onSuccess]);\n'
)
dep_replacement = (
    '  }, [ltePreset, nr5gPreset, lteCustom, nr5gCustom, ltePresets, '
    'nr5gPresets, supportedLte, supportedNr5g, onLoadingChange, onSuccess]);\n'
)
if dep_needle not in text:
    raise SystemExit("band-locking: submit() dependency array not found (upstream may have changed)")
text = text.replace(dep_needle, dep_replacement, 1)

path.write_text(text)
PY
    grep -q "onboarding band normalize" "$bl" \
        || fail "Onboarding normalize: band-locking patch did not apply"
    grep -q "supportedLte, supportedNr5g, onLoadingChange" "$bl" \
        || fail "Onboarding normalize: band-locking dependency array not updated"

    log "Onboarding default-normalize patches applied (RAT + band lock)"
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
    patch_qmanager_lighttpd_unit_name_cfw3212
    patch_qmanager_console_port_cfw3212
    patch_qmanager_health_check_paths_cfw3212
    patch_qmanager_health_check_poller_pause_cfw3212
    patch_qmanager_health_check_net_dns_cfw3212
    patch_qmanager_poller
    patch_qmanager_poller_lib_paths_cfw3212
    patch_speedtest_poller_pause_cfw3212
    patch_disable_orientation_probe_cfw3212
    patch_disable_profile_auto_apply
    patch_casa_iccid_and_staleness_cfw3212
    patch_logging_cfw3212
    patch_ai62_flash_and_cgi_hardening_cfw3212
    patch_ai62_cookie_cors_config_hardening_cfw3212
    patch_casa_custom_dns_cfw3212
    patch_casa_dns_status_merge_cfw3212
    patch_casa_dns_badges_cfw3212
    patch_onboarding_normalize_defaults_cfw3212
    patch_ai62_sudoers_narrowing_cfw3212
    patch_qmanager_display_version
    patch_casa_display_name
    patch_casa_reboot
    patch_casa_watchcat_tiers
    copy_template_or_fallback "components/nav-user.tsx" "$TEMPLATE_DIR/components/nav-user.tsx"
    copy_template_or_fallback "components/monitoring/software-update/update-preferences-card.tsx" "$TEMPLATE_DIR/components/monitoring/software-update/update-preferences-card.tsx"
    copy_template_or_fallback "components/monitoring/software-update/software-update.tsx" "$TEMPLATE_DIR/components/monitoring/software-update/software-update.tsx"
    copy_template_or_fallback "hooks/use-software-update.ts" "$TEMPLATE_DIR/hooks/use-software-update.ts"
    copy_template_or_fallback "components/reboot/reboot-countdown.tsx" "$TEMPLATE_DIR/components/reboot/reboot-countdown.tsx"
    patch_casa_tailscale_tiny_cfw3212
    patch_casa_tailscale_install_label_cfw3212
    patch_casa_poller_boot_identity_cfw3212
    patch_casa_ippt_disable_clears_service_cfw3212
    patch_casa_band_locking_persist_cfw3212
    patch_email_alerts_casa_msmtp
    patch_ping_profile_service_toggle_cfw3212
    patch_speedtest_latency_iqm_guard_cfw3212
    patch_software_update_reboot_required_cfw3212
    patch_deterministic_frontend_build_id_cfw3212

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

- `systemctl status qmanager-lighttpd`
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
    require_rg_present '"port" => 9081' "$TARGET/install_cfw3212.sh" \
        "Casa installer must proxy /console to QManager ttyd on 9081"
    require_rg_clean '"port" => 8080|-p 8080 ' "$TARGET/install_cfw3212.sh" \
        "Casa installer must not reserve Casa stock UI port 8080 for QManager console"

    local health_check="$TARGET/scripts/usr/bin/qmanager_health_check"
    [ -f "$health_check" ] || fail "Converted tree missing qmanager_health_check worker"
    require_rg_present "/usrdata/opt/bin/jq" "$health_check" \
        "Health-check worker must use Casa /usrdata/opt/bin helpers"
    require_rg_present "qmanager-lighttpd listening on 9080/9000" "$health_check" \
        "Health-check worker must use Casa lighttpd ports 9080/9000"
    require_rg_present "_svc_check qmanager-lighttpd.service 1" "$health_check" \
        "Health-check worker must check qmanager-lighttpd.service"
    require_rg_clean "_svc_check lighttpd.service|/usr/bin/atcli_smd11|listening on only one of 80/443|_check_bin jq          /opt/bin/jq|_check_bin curl        /opt/bin/curl|_check_bin openssl     /opt/bin/openssl" \
        "$health_check" \
        "Health-check worker still contains upstream RM520N paths or port labels"
    require_rg_present 'POLLER_PAUSE_FLAG="/tmp/qmanager_speedtest_polling_pause"' "$health_check" \
        "Health-check worker must pause the poller via the shared pause flag, not systemctl stop (AI-52)"
    require_rg_clean "systemctl stop qmanager-poller|systemctl start qmanager-poller" \
        "$health_check" \
        "Health-check worker must not stop/start the poller — orphan-stop risk (AI-52)"

    require_rg_present "ip_handover" "$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh" \
        "Casa IPPT backend must use RDB ip_handover"
    require_rg_present "qmanager_dns_reconcile" "$TARGET/install_cfw3212.sh" \
        "Casa installer missing LAN DNS reconciler (AI-64)"
    require_rg_present "qmanager-dns-reconcile.timer" "$TARGET/install_cfw3212.sh" \
        "Casa installer missing LAN DNS reconciler systemd timer (AI-64)"
    require_rg_present "qmanager_dns_state.json" "$TARGET/scripts/www/cgi-bin/quecmanager/at_cmd/fetch_data.sh" \
        "fetch_data.sh must merge LAN DNS reconciler state into dashboard payload (AI-64)"
    require_rg_clean 'QCFG="usbnet"|QMAP="MPDN_rule"|QMAP="IPPT_NAT"|QMAP="DHCPV4DNS"|QMAPWAC|(^|[^[:alnum:]_])reboot([^[:alnum:]_]|$)' \
        "$TARGET/scripts/www/cgi-bin/quecmanager/network/ip_passthrough.sh" \
        "Casa IPPT backend contains upstream modem-write/reboot controls"
    require_rg_clean "ECM|MBIM|RNDIS|USB Tethering|Enter Manually|QCFG" \
        "$TARGET/components/local-network/ip-passthrough/ip-passthrough-card.tsx" \
        "Casa IPPT frontend exposes unsafe USB/MAC controls"
    if [ -f "$TARGET/scripts/etc/systemd/system/qmanager-console.service" ]; then
        require_rg_present "[-]p 9081 " "$TARGET/scripts/etc/systemd/system/qmanager-console.service" \
            "QManager console service must use 9081, not Casa stock UI port 8080"
        require_rg_clean "[-]p 8080 " "$TARGET/scripts/etc/systemd/system/qmanager-console.service" \
            "QManager console service still uses Casa stock UI port 8080"
    fi
    if [ -f "$TARGET/scripts/usrdata/qmanager/lighttpd.conf" ]; then
        require_rg_present '"port" => 9081' "$TARGET/scripts/usrdata/qmanager/lighttpd.conf" \
            "Packaged QManager lighttpd.conf must proxy /console to 9081"
        require_rg_clean '"port" => 8080' "$TARGET/scripts/usrdata/qmanager/lighttpd.conf" \
            "Packaged QManager lighttpd.conf still proxies /console to Casa stock UI port 8080"
    fi
    require_rg_present "link.profile.1.ip_handover.enable" "$TARGET/scripts/usr/bin/qmanager_poller" \
        "Casa poller must report IPPT status from RDB ip_handover state"
    require_rg_present "service.ip_handover.mac_address" "$TARGET/scripts/usr/bin/qmanager_poller" \
        "Casa poller must report IPPT MAC from RDB ip_handover state"
    require_rg_present "/usrdata/qmanager/lib/parse_at.sh" "$TARGET/scripts/usr/bin/qmanager_poller" \
        "Casa poller must source libraries from /usrdata/qmanager/lib"
    require_rg_present 'DATA_USED_HOT_FILE="/tmp/qmanager_data_used.json"' "$TARGET/scripts/usr/bin/qmanager_poller" \
        "Casa poller must keep hot data_used state in /tmp"
    require_rg_present 'DATA_USED_FLUSH_INTERVAL="\$\{DATA_USED_FLUSH_INTERVAL:-300\}"' "$TARGET/scripts/usr/bin/qmanager_poller" \
        "Casa poller must throttle durable data_used flushes"
    require_rg_clean "/usr/lib/qmanager/(parse_at|events|qlog|profile_mgr|email_alerts|sms_alerts)\\.sh" \
        "$TARGET/scripts/usr/bin/qmanager_poller" \
        "Casa poller still sources upstream /usr/lib/qmanager library paths"
    require_rg_present 'QLOG_TO_SYSLOG="\$\{QLOG_TO_SYSLOG:-0\}"' "$TARGET/scripts/usr/lib/qmanager/qlog.sh" \
        "Casa qlog must default syslog forwarding off"
    require_rg_present "auth_unavailable" "$TARGET/scripts/usr/lib/qmanager/cgi_base.sh" \
        "CGI auth library fallback must fail closed"
    require_rg_present "QM_MAX_POST_SIZE:=65536" "$TARGET/scripts/usr/lib/qmanager/cgi_base.sh" \
        "CGI POST body reader must enforce default size limit"
    require_rg_present "chmod 775 /var/spool/cron /var/spool/cron/crontabs" "$TARGET/scripts/usr/bin/qmanager_setup" \
        "qmanager_setup must not leave cron spool world-writable"
    require_rg_present "find /etc/qmanager -type d -exec chmod 750" "$TARGET/scripts/usr/bin/qmanager_setup" \
        "qmanager_setup must restrict /etc/qmanager directory permissions"
    require_rg_present "find /etc/qmanager -type f -exec chmod 640" "$TARGET/scripts/usr/bin/qmanager_setup" \
        "qmanager_setup must restrict /etc/qmanager file permissions"
    require_rg_present "HttpOnly; Secure; SameSite=Strict" "$TARGET/scripts/usr/lib/qmanager/cgi_auth.sh" \
        "QManager session cookie must include Secure"
    require_rg_present "COOKIE_INDICATOR.*Secure; SameSite=Strict" "$TARGET/scripts/usr/lib/qmanager/cgi_auth.sh" \
        "QManager login indicator cookie must include Secure"
    require_rg_clean "Access-Control-Allow-Origin: \\*" "$TARGET/scripts/usr/lib/qmanager/cgi_base.sh" \
        "CGI base must not emit wildcard CORS by default"
    require_rg_present "local f=/tmp/qmanager_data_used.json" "$TARGET/scripts/usr/bin/qmanager_health_check" \
        "Health Check must use data_used hot-state freshness, not durable flash mtime"
    require_rg_present "Casa CFW-3212 IP passthrough: /etc/resolv.conf often lists the handover" \
        "$TARGET/scripts/usr/bin/qmanager_health_check" \
        "Health Check net.dns must bypass IPPT poisoned 192.0.0.1 resolv.conf"
    require_rg_present "systemctl start qmanager-*" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must narrow systemctl to qmanager-* units (AI-62)"
    require_rg_present "/tmp/qmanager-dnsmasq.conf.new /etc/data/dnsmasq.conf" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers Custom DNS mv rule must match Casa /tmp staging path (AI-62)"
    require_rg_clean "/bin/systemctl start \\*" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow broad systemctl start * (AI-62)"
    require_rg_clean "/usr/bin/crontab" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow crontab on Casa (AI-62)"
    require_rg_clean "killall -HUP dnsmasq" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not use obsolete dnsmasq killall reload (AI-62)"

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
