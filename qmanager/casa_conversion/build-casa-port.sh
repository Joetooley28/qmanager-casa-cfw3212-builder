#!/usr/bin/env bash
set -euo pipefail

# Convert an upstream dr-dolomite/QManager tag/release into a Casa
# CFW-3212 work tree and, when Bun/Node are available, build release artifacts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QMANAGER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_REF_DIR="$QMANAGER_DIR/qmanager_work_v0.1.9_casa"
TEMPLATE_DIR="$SCRIPT_DIR/templates"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/dr-dolomite/QManager.git}"
UPSTREAM_API="${UPSTREAM_API:-https://api.github.com/repos/dr-dolomite/QManager/releases}"
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
  UPSTREAM_REPO         Git repo URL. Default: dr-dolomite/QManager.
  UPSTREAM_API          GitHub releases API. Default: dr-dolomite/QManager.
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
            "QManager OTA updates are disabled in this Casa CFW-3212 build."
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

    if [ -f "$REF_DIR/build.sh" ] \
        && grep -q "install_cfw3212.sh" "$REF_DIR/build.sh" \
        && ! grep -q "install_rm520n.sh.*STAGING\\|STAGING.*install_rm520n.sh" "$REF_DIR/build.sh"; then
        copy_file "build.sh"
    else
        patch_build_script
    fi

    copy_file_or_fallback "install_cfw3212.sh" "$TEMPLATE_DIR/install_cfw3212.sh"
    patch_installer_version_cfw3212

    if [ -f "$REF_DIR/uninstall_cfw3212.sh" ]; then
        copy_file "uninstall_cfw3212.sh"
    elif [ -f "$TEMPLATE_DIR/uninstall_cfw3212.sh" ]; then
        copy_file_or_fallback "uninstall_cfw3212.sh" "$TEMPLATE_DIR/uninstall_cfw3212.sh"
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
    patch_logging_cfw3212

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
- Confirm Software Update checks Casa package releases only.
- Confirm auto-update remains disabled and no qmanager_auto_update cron entry exists.
- Confirm GUI download verifies SHA-256 before the Install button is useful.
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
