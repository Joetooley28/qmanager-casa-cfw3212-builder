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

for svc in lighttpd \
    qmanager-poller qmanager-ping qmanager-firewall qmanager-setup \
    qmanager-ttl qmanager-mtu qmanager-imei-check qmanager-watchcat \
    qmanager-tower-failover qmanager-traffic qmanager-console \
    qmanager-discord qmanager-ethernet qmanager-cfun-fix \
    qmanager_tailscale_install; do
    systemctl disable --now "$svc.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$svc.service"
    rm -f "/etc/systemd/system/multi-user.target.wants/$svc.service"
done
find /etc/systemd/system /etc/systemd/system/multi-user.target.wants \
    -maxdepth 1 \( -name 'qmanager*.service' -o -name 'qmanager_*.service' \) \
    -exec rm -f {} \; 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

rm -rf /usrdata/qmanager
rm -f /usrdata/bin/qmanager_* /usrdata/bin/qcmd /usrdata/bin/atcli_smd11 /usrdata/bin/sms_tool
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

if [ "$PURGE" = "1" ]; then
    rm -rf /etc/qmanager /usrdata/opt
    rm -f /etc/sudoers.d/qmanager /usrdata/opt/etc/sudoers.d/qmanager 2>/dev/null || true
fi

systemctl reset-failed lighttpd \
    qmanager-poller qmanager-ping qmanager-firewall qmanager-setup \
    qmanager-ttl qmanager-mtu qmanager-imei-check qmanager-watchcat \
    qmanager-tower-failover qmanager-traffic qmanager-console \
    qmanager-discord qmanager-ethernet qmanager-cfun-fix \
    qmanager_tailscale_install 2>/dev/null || true

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
from pathlib import Path
import sys
import re

path = Path(sys.argv[1])
text = path.read_text()

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
    # =========================================================================
    result=$(qcmd 'AT+CVERSION;+CGMM;+CGSN;+CIMI;+QCCID;+CNUM' 2>/dev/null)'''
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
    # QManager SIM profiles can change APN/TTL/IMEI state. The Casa public build
    # keeps those write paths disabled until they are mapped and validated for
    # this platform.
    # =========================================================================
    qlog_info "Casa profile auto-apply disabled"'''
text = text.replace(old, new)

if "Casa profile auto-apply disabled" not in text:
    text = re.sub(
        r'''    # --- Auto-apply profile matching current SIM \(boot\) ---\n    if \[ -n "\$boot_iccid" \]; then\n        \( \. /usr/lib/qmanager/profile_mgr\.sh && auto_apply_profile "\$boot_iccid" "boot" \)\n    fi''',
        '''    # --- Casa CFW-3212 safety: profile auto-apply disabled ---
    # QManager SIM profiles can change APN/TTL/IMEI state. The Casa public build
    # keeps those write paths disabled until they are mapped and validated for
    # this platform.
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
    grep -q "Casa profile auto-apply disabled" "$poller" \
        || fail "Could not apply Casa profile auto-apply poller patch"
    grep -q "qmanager_version: \$qmanager_version" "$poller" \
        || fail "Could not apply Casa QManager version poller patch"
}

patch_disable_profile_auto_apply() {
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

patch_update_defaults_cfw3212() {
    local config="$TARGET/scripts/usr/lib/qmanager/config.sh"
    [ -f "$config" ] || fail "config.sh missing in target"

    if command -v perl >/dev/null 2>&1; then
        perl -0pi -e 's/"include_prerelease":\s*1/"include_prerelease": 0/g' "$config"
    else
        sed -i.bak 's/"include_prerelease":[[:space:]]*1/"include_prerelease": 0/g' "$config"
        rm -f "$config.bak"
    fi

    grep -q '"include_prerelease": 0' "$config" \
        || fail "Could not set Casa prerelease default to disabled"
}

patch_software_update_reboot_required_cfw3212() {
    local hook="$TARGET/hooks/use-software-update.ts"
    local page="$TARGET/components/monitoring/software-update/software-update.tsx"
    local card="$TARGET/components/monitoring/software-update/update-status-card.tsx"
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
    '  status: "idle" | "downloading" | "installing" | "rebooting" | "error";',
    '  status: "idle" | "downloading" | "installing" | "reboot_required" | "rebooting" | "error";',
)
replace_once(
    hook,
    '  installUpdate: () => Promise<void>;\n  togglePrerelease:',
    '  installUpdate: () => Promise<void>;\n  rebootNow: () => Promise<void>;\n  togglePrerelease:',
)
replace_once(
    hook,
    '''        if (json.status === "rebooting") {
          // Navigate to /reboot/ immediately so the static page loads from
          // lighttpd before the OTA worker fires the reboot syscall. The
          // worker waits for the page's reboot_ack before issuing reboot,
          // so any delay here only widens the race.
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          sessionStorage.setItem("qm_rebooting", "1");
          document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
          window.location.href = "/reboot/";
        }
''',
    '''        if (json.status === "reboot_required") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          setIsUpdating(false);
          return;
        }

        if (json.status === "rebooting") {
          if (pollRef.current) clearInterval(pollRef.current);
          pollRef.current = null;
          sessionStorage.setItem("qm_rebooting", "1");
          document.cookie = "qm_logged_in=; Path=/; Max-Age=0";
          window.location.href = "/reboot/";
        }
''',
)
replace_once(
    hook,
    '''      } catch {
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
''',
    '''      } catch {
        // Casa does not reboot automatically after package install. A brief
        // lighttpd restart during install can make one poll fail, so leave the
        // user on the update page instead of assuming the router is rebooting.
        if (pollRef.current) clearInterval(pollRef.current);
        pollRef.current = null;
        setIsUpdating(false);
        setError("Lost connection while checking install status. Refresh QManager and reboot when ready if the update completed.");
      }
''',
)
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
replace_once(
    hook,
    '    installStaged,\n    installUpdate,\n    togglePrerelease,\n',
    '    installStaged,\n    installUpdate,\n    rebootNow,\n    togglePrerelease,\n',
)

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
replace_once(
    page,
    '''  if (isUpdating && updateStatus.status !== "error") {
    return (
      <Badge variant="outline" className="bg-info/15 text-info hover:bg-info/20 border-info/30">
        <DownloadIcon className="h-3 w-3" />
        Updating
      </Badge>
    );
  }
''',
    '''  if (updateStatus.status === "reboot_required") {
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
''',
)

replace_once(card, '  RefreshCwIcon,\n', '  RefreshCwIcon,\n  RotateCwIcon,\n')
replace_once(card, '  installStaged: () => Promise<void>;\n', '  installStaged: () => Promise<void>;\n  rebootNow: () => Promise<void>;\n')
replace_once(card, '  installStaged,\n}: UpdateStatusCardProps) {\n', '  installStaged,\n  rebootNow,\n}: UpdateStatusCardProps) {\n')
replace_once(card, '  const displayError = updateInfo?.check_error || error;\n', '  const displayError = updateInfo?.check_error || error;\n  const rebootRequired = updateStatus.status === "reboot_required";\n')
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
replace_once(
    card,
    '''              The device will reboot automatically after installation. Do not
              power off the device during the update.
''',
    '''              QManager will restart its services after installation and then
              ask you to reboot when ready. Do not power off the device during
              the update.
''',
)

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

    patch_qmanager_poller
    patch_disable_profile_auto_apply
    patch_logging_cfw3212
    patch_qmanager_display_version
    patch_casa_display_name
    patch_casa_reboot
    patch_software_update_reboot_required_cfw3212

    write_qmanager_update_cfw3212
    write_qmanager_auto_update_cfw3212

    patch_package_version
    patch_update_defaults_cfw3212
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
- Confirm profile apply/save/delete endpoints report unsupported for POST.

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
    require_rg_present "Casa profile auto-apply disabled" "$TARGET/scripts/usr/bin/qmanager_poller" \
        "qmanager_poller must disable boot profile auto-apply"

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
