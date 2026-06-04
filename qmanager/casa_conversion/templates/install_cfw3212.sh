#!/bin/bash
# =============================================================================
# install_cfw3212.sh — QManager v0.1.4 installer for Casa CFW-3212
# =============================================================================
# Adapts the upstream QManager RM520N-GL installer for the CFW-3212's
# read-only squashfs rootfs.
#
# Key differences from install_rm520n.sh:
#   - /etc is writable via overlayfs (upper: /rw/local/etc/upper on UBIFS)
#   - /usr/bin, /usr/lib, /lib/systemd/system are READ-ONLY squashfs
#   - /opt does NOT exist in squashfs — Entware goes to /usrdata/opt directly
#   - Daemons       → /usrdata/bin
#   - Libraries     → /usrdata/qmanager/lib
#   - Entware       → /usrdata/opt  (/opt -> /usrdata/opt symlink for ELF paths)
#   - Systemd units → /etc/systemd/system  (writable via overlay)
#   - Wants symlinks→ /etc/systemd/system/multi-user.target.wants
#   - qmanager-lighttpd on port 9000 (HTTPS) — port 80 is Casa's turbontc
#   - /dev/smd11 exists and is free — atcli_smd11 works as-is
# =============================================================================

set -e

# --- Paths -------------------------------------------------------------------

QMANAGER_ROOT="/usrdata/qmanager"
WWW_ROOT="/usrdata/qmanager/www"
CGI_DIR="/usrdata/qmanager/www/cgi-bin/quecmanager"
LIB_DIR="/usrdata/qmanager/lib"
BIN_DIR="/usrdata/bin"
CONF_DIR="/etc/qmanager"
VERSION="v0.0.0-cfw3212.0"
CERT_DIR="/usrdata/qmanager/certs"
LIGHTTPD_CONF="/usrdata/qmanager/lighttpd.conf"
SESSION_DIR="/tmp/qmanager_sessions"

# Entware lives under /usrdata/opt; installer ensures /opt -> /usrdata/opt for sudo ELF paths
OPT_DIR="/usrdata/opt"
LIGHTTPD_MODULE_DIR="$OPT_DIR/lib/lighttpd"
LIGHTTPD_LAUNCHER="$OPT_DIR/lib/ld-linux.so.3 --library-path $OPT_DIR/lib $OPT_DIR/sbin/lighttpd -m $LIGHTTPD_MODULE_DIR"
ENTWARE_BASE="http://bin.entware.net/armv7sf-k3.2"
ENTWARE_PACKAGES_GZ="/tmp/entware-packages.gz"
ENTWARE_PACKAGES_TXT="/tmp/entware-packages.txt"
ENTWARE_STATE_DIR="$OPT_DIR/var/lib/qmanager-ipk"

# /etc is writable via overlayfs on CFW-3212
SYSTEMD_DIR="/etc/systemd/system"
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"

TARBALL="/tmp/qmanager.tar.gz"
EXTRACT_DIR="/tmp/qmanager_install"
SRC_FRONTEND="$EXTRACT_DIR/out"
SRC_SCRIPTS="$EXTRACT_DIR/scripts"
SRC_DEPS="$EXTRACT_DIR/dependencies"
FRONTEND_MANIFEST_SRC="$EXTRACT_DIR/frontend.sha256"
FRONTEND_MANIFEST_DST="$WWW_ROOT/.qmanager_frontend.sha256"

# --- Colors ------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "  ${GREEN}✓${NC}  %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${NC}  %s\n" "$1"; }
die()   { printf "  ${RED}✗${NC}  %s\n" "$1" >&2; exit 1; }
step()  { printf "\n${BLUE}${BOLD}▶ %s${NC}\n" "$1"; }

write_update_status() {
    [ -n "${QMANAGER_UPDATE_STATUS_FILE:-}" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    jq -n \
        --arg status "installing" \
        --arg message "$1" \
        --arg version "${QMANAGER_UPDATE_VERSION:-$VERSION}" \
        --arg size "" \
        '{status: $status, message: $message, version: $version, size: $size}' \
        > "$QMANAGER_UPDATE_STATUS_FILE" 2>/dev/null || true
}

copy_if_changed() {
    local src="$1"
    local dst="$2"
    local mode="${3:-}"
    local dst_dir

    dst_dir=$(dirname "$dst")
    mkdir -p "$dst_dir"

    if [ -f "$dst" ] && {
        if command -v cmp >/dev/null 2>&1; then
            cmp -s "$src" "$dst"
        else
            [ "$(sha256sum "$src" 2>/dev/null | awk '{print $1}')" = "$(sha256sum "$dst" 2>/dev/null | awk '{print $1}')" ]
        fi
    }; then
        [ -n "$mode" ] && chmod "$mode" "$dst" 2>/dev/null || true
        return 1
    fi

    cp "$src" "$dst"
    [ -n "$mode" ] && chmod "$mode" "$dst" 2>/dev/null || true
    return 0
}

sync_tree_changed() {
    local src_dir="$1"
    local dst_dir="$2"
    local preserve_prefix="${3:-}"
    local default_mode="${4:-}"
    local label="${5:-files}"
    local list="/tmp/qmanager_sync_src.$$"
    local prune_list="/tmp/qmanager_sync_dst.$$"
    local src rel dst mode total copied skipped pruned existing checked

    total=0
    copied=0
    skipped=0
    pruned=0
    checked=0

    mkdir -p "$dst_dir"
    find "$src_dir" -type f > "$list"
    total=$(wc -l < "$list" | tr -d ' ')
    printf "  ... %s: checking %s files\n" "$label" "$total"
    while IFS= read -r src; do
        rel="${src#$src_dir/}"
        dst="$dst_dir/$rel"
        mode="$default_mode"
        case "$rel" in
            *.sh) mode=755 ;;
            *.json) [ -z "$mode" ] && mode=644 ;;
        esac

        checked=$((checked + 1))
        if copy_if_changed "$src" "$dst" "$mode"; then
            copied=$((copied + 1))
            if [ $((copied % 50)) -eq 0 ]; then
                printf "  ... %s: %s/%s checked, %s changed; flushing flash\n" "$label" "$checked" "$total" "$copied"
                sync
                sleep 1
            fi
        else
            skipped=$((skipped + 1))
        fi
        if [ $((checked % 25)) -eq 0 ]; then
            printf "  ... %s: %s/%s checked, %s changed, %s unchanged\n" "$label" "$checked" "$total" "$copied" "$skipped"
        fi
    done < "$list"
    rm -f "$list"
    printf "  ... %s: pruning stale files\n" "$label"

    find "$dst_dir" -type f > "$prune_list"
    while IFS= read -r existing; do
        rel="${existing#$dst_dir/}"
        if [ -n "$preserve_prefix" ]; then
            case "$rel" in
                "$preserve_prefix"/*) continue ;;
            esac
        fi
        [ -f "$src_dir/$rel" ] && continue
        rm -f "$existing" 2>/dev/null && pruned=$((pruned + 1)) || true
    done < "$prune_list"
    rm -f "$prune_list"

    SYNC_TOTAL=$checked
    SYNC_COPIED=$copied
    SYNC_SKIPPED=$skipped
    SYNC_PRUNED=$pruned
}

disable_post_endpoint() {
    local file="$1"
    local detail="$2"
    local orig

    [ -f "$file" ] || return 0

    orig="${file}.casa_orig"
    rm -f "$orig" 2>/dev/null || true
    mv "$file" "$orig" 2>/dev/null || return 0

    cat > "$file" <<EOF
#!/bin/sh
. /usrdata/qmanager/lib/cgi_base.sh

if [ "\$REQUEST_METHOD" = "POST" ]; then
    cgi_headers
    cgi_handle_options
    cgi_error "unsupported_on_cfw3212" "$detail"
    exit 0
fi

exec /bin/sh "$orig" "\$@"
EOF
    chmod 755 "$file" 2>/dev/null || true
}

fetch_url() {
    local url="$1"
    local out="$2"
    wget -q "$url" -O "$out" \
        || curl -fsSL "$url" -o "$out" \
        || return 1
}

entware_refresh_index() {
    mkdir -p "$(dirname "$ENTWARE_PACKAGES_TXT")"
    fetch_url "$ENTWARE_BASE/Packages.gz" "$ENTWARE_PACKAGES_GZ" \
        || die "Failed to download Entware package index"
    gzip -dc "$ENTWARE_PACKAGES_GZ" > "$ENTWARE_PACKAGES_TXT" \
        || die "Failed to unpack Entware package index"
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

entware_pkg_version() {
    entware_pkg_field "$1" "Version"
}

entware_pkg_filename() {
    entware_pkg_field "$1" "Filename"
}

entware_pkg_depends() {
    entware_pkg_field "$1" "Depends"
}

entware_pkg_marker() {
    printf "%s/%s.version" "$ENTWARE_STATE_DIR" "$1"
}

entware_pkg_installed_version() {
    local marker
    marker="$(entware_pkg_marker "$1")"
    if [ -f "$marker" ]; then
        cat "$marker"
    fi
    return 0
}

extract_ipk_to_usrdata() {
    local ipk="$1"
    local tmpdir data_tar control_tar

    tmpdir="$(mktemp -d /tmp/qmipk.XXXXXX)" || return 1
    data_tar="$tmpdir/data.tar.gz"
    control_tar="$tmpdir/control.tar.gz"

    tar xzf "$ipk" -C "$tmpdir" ./data.tar.gz ./control.tar.gz >/dev/null 2>&1 \
        || { rm -rf "$tmpdir"; return 1; }
    tar xzf "$data_tar" -C /usrdata >/dev/null 2>&1 \
        || { rm -rf "$tmpdir"; return 1; }

    if [ -f "$control_tar" ]; then
        mkdir -p "$tmpdir/control"
        tar xzf "$control_tar" -C "$tmpdir/control" >/dev/null 2>&1 || true
    fi

    rm -rf "$tmpdir"
    return 0
}

entware_install_pkg() {
    local pkg="$1"
    local version filename installed marker
    local deps dep cleaned dep_filename
    local ipk tmp_ipk

    version="$(entware_pkg_version "$pkg")"
    filename="$(entware_pkg_filename "$pkg")"
    [ -n "$version" ] || die "Package not found in Entware index: $pkg"
    [ -n "$filename" ] || die "No filename found for Entware package: $pkg"

    installed="$(entware_pkg_installed_version "$pkg")"
    if [ "$installed" = "$version" ]; then
        info "$pkg already present ($version)"
        return 0
    fi

    deps="$(entware_pkg_depends "$pkg")"
    if [ -n "$deps" ]; then
        OLD_IFS="$IFS"
        IFS=','
        for dep in $deps; do
            cleaned="$(printf '%s' "$dep" | sed 's/ *(.*//; s/^ *//; s/ *$//')"
            [ -n "$cleaned" ] || continue
            dep_filename="$(entware_pkg_filename "$cleaned")"
            [ -n "$dep_filename" ] || continue
            entware_install_pkg "$cleaned"
        done
        IFS="$OLD_IFS"
    fi

    tmp_ipk="/tmp/$(basename "$filename")"
    fetch_url "$ENTWARE_BASE/$filename" "$tmp_ipk" \
        || die "Failed to download $pkg ($filename)"
    extract_ipk_to_usrdata "$tmp_ipk" \
        || die "Failed to extract $pkg from $tmp_ipk"
    rm -f "$tmp_ipk"

    mkdir -p "$ENTWARE_STATE_DIR"
    marker="$(entware_pkg_marker "$pkg")"
    printf '%s\n' "$version" > "$marker"
    info "$pkg installed ($version)"
}

install_bundled_ipk() {
    local ipk="$1"
    local label="$2"

    [ -f "$ipk" ] || die "Bundled package missing: $ipk"
    extract_ipk_to_usrdata "$ipk" \
        || die "Failed to extract bundled package: $label"
    info "$label installed (bundled)"
}

create_entware_wrapper() {
    local name="$1"
    local target="$2"

    cat > "$BIN_DIR/$name" <<EOF
#!/bin/sh
exec $OPT_DIR/lib/ld-linux.so.3 --library-path $OPT_DIR/lib $target "\$@"
EOF
    chmod 755 "$BIN_DIR/$name"
}

# --- Pre-flight --------------------------------------------------------------

step "Pre-flight checks"

[ "$(id -u)" -eq 0 ] || die "Must run as root"
[ -d /usrdata ] || die "No /usrdata — wrong device?"

if ! touch /etc/.cfw3212_write_test 2>/dev/null; then
    die "/etc is not writable — is the overlay mounted?"
fi
rm -f /etc/.cfw3212_write_test
info "/etc overlay is writable"

[ -e /dev/smd11 ] || die "/dev/smd11 not found"
info "/dev/smd11 present"

[ -f "$TARBALL" ] || die "Tarball not found at $TARBALL"

available_kb=$(df /usrdata | awk 'NR==2{print $4}')
[ "$available_kb" -gt 30000 ] || die "/usrdata < 30MB free"
info "/usrdata has $((available_kb/1024))MB free"

# Optional /opt -> /usrdata/opt symlink.
#
# As of AI-56 this symlink is NOT required. The bundled Entware sudo ships
# pre-patched (ELF interpreter + RPATH repointed to /usrdata/opt at build time,
# with setuid preserved), and jq/lighttpd are launched through an explicit
# /usrdata/opt loader — so nothing on the device depends on a root-level /opt.
# On a clean stock box `/` is a read-only squashfs and /opt cannot be created;
# that is now harmless. We still create the symlink opportunistically on boxes
# that already have a writable root, since it costs nothing and keeps any stray
# /opt-relative tooling happy.
# Does not create or modify /usrdata/opt — only the root-level symlink.
if [ ! -e /opt ]; then
    opt_root_remounted_rw=0
    if mount -o remount,rw / 2>/dev/null; then
        opt_root_remounted_rw=1
    fi
    ln -sf /usrdata/opt /opt 2>/dev/null || true
    if [ "$opt_root_remounted_rw" = 1 ]; then
        mount -o remount,ro / 2>/dev/null || true
    fi
    if [ -L /opt ]; then
        info "/opt -> /usrdata/opt symlink created"
    else
        info "/opt not created (read-only root) — not required; sudo is pre-patched"
    fi
elif [ -L /opt ] && [ "$(readlink /opt 2>/dev/null || true)" = "/usrdata/opt" ]; then
    info "/opt -> /usrdata/opt symlink already present"
else
    info "/opt exists and is not our symlink — leaving unchanged (not required)"
fi

# --- Extract -----------------------------------------------------------------

step "Extracting tarball"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar xzf "$TARBALL" -C /tmp/
[ -d "$SRC_SCRIPTS" ] || die "Expected $SRC_SCRIPTS after extraction"
info "Extracted to $EXTRACT_DIR"

# --- Patch scripts in-place --------------------------------------------------

step "Patching path references for CFW-3212"

_patch_file() {
    sed -i \
        -e 's|/usr/lib/qmanager|/usrdata/qmanager/lib|g' \
        -e 's|/usr/bin/qmanager_|/usrdata/bin/qmanager_|g' \
        -e 's|/usr/bin/qcmd\b|/usrdata/bin/qcmd|g' \
        -e 's|/usr/bin/atcli_smd11|/usrdata/bin/atcli_smd11|g' \
        -e 's|/usr/bin/sms_tool|/usrdata/bin/sms_tool|g' \
        -e 's|/lib/systemd/system/multi-user\.target\.wants|/etc/systemd/system/multi-user.target.wants|g' \
        -e 's|/lib/systemd/system|/etc/systemd/system|g' \
        -e 's|/opt/bin/\([a-z]\)|/usrdata/opt/bin/\1|g' \
        -e 's|/opt/sbin/\([a-z]\)|/usrdata/opt/sbin/\1|g' \
        -e 's|/opt/etc/\([a-z]\)|/usrdata/opt/etc/\1|g' \
        -e 's|/opt/lib/\([a-z]\)|/usrdata/opt/lib/\1|g' \
        "$1" 2>/dev/null || true
}

# Walk shell scripts and service files — grep pre-filter skips files with no matches
find "$SRC_SCRIPTS" -type f | while read -r f; do
    case "$f" in
        *.sh|*.service|*.conf) ;;
        */usr/bin/*|*/usr/lib/qmanager/*) ;;
        *) continue ;;
    esac
    grep -qF '/usr/' "$f" 2>/dev/null || grep -qF '/opt/' "$f" 2>/dev/null || continue
    _patch_file "$f"
done

# Catch usr/bin, usr/lib, and www files — grep pre-filter is critical here (484 www files)
find "$SRC_SCRIPTS/usr" "$SRC_SCRIPTS/www" -type f 2>/dev/null | while read -r f; do
    grep -qF '/usr/' "$f" 2>/dev/null || grep -qF '/opt/' "$f" 2>/dev/null || continue
    _patch_file "$f"
done

info "Path references patched"

# Normalize CGI line endings so subsequent Casa-specific patching is reliable.
find "$SRC_SCRIPTS/www/cgi-bin" -type f -name "*.sh" 2>/dev/null | while read -r f; do
    sed -i 's/\r$//' "$f" 2>/dev/null || true
done
info "CGI script line endings normalized"

# qmanager_setup: remove /usr/lib/qmanager from mkdir, fix binary glob, remove
# the upstream remount-if-needed block cleanly for Casa's squashfs rootfs.
sed -i \
    -e 's|mkdir -p /var/lock /etc/qmanager /usr/lib/qmanager|mkdir -p /var/lock /etc/qmanager /usrdata/qmanager/lib|g' \
    -e 's|for f in /usr/bin/qmanager_\*|for f in /usrdata/bin/qmanager_*|g' \
    -e '/# Remount root filesystem read-write if needed (RM520N-GL boots read-only)/,/^# Ensure required directories exist$/c\\# Rootfs remount block removed for Casa CFW-3212 squashfs\\\n\\\n# Ensure required directories exist' \
    "$SRC_SCRIPTS/usr/bin/qmanager_setup" 2>/dev/null || true
info "qmanager_setup patched"

# qmanager_firewall: protect Casa's remapped QManager ports instead of upstream 80/443
sed -i \
    -e 's|PORTS="80 443"|PORTS="9080 9000"|g' \
    "$SRC_SCRIPTS/usr/bin/qmanager_firewall" 2>/dev/null || true
info "qmanager_firewall patched for ports 9080/9000"

# Casa needs Entware tools to be launched through the Entware loader, and CGI
# helpers should prefer the wrapper bin directory first.
sed -i \
    -e 's|^export PATH=.*|export PATH="/usrdata/bin:/usrdata/opt/bin:/usrdata/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"|g' \
    "$SRC_SCRIPTS/usr/lib/qmanager/cgi_base.sh" 2>/dev/null || true
if ! grep -q '^export PATH=' "$SRC_SCRIPTS/usr/lib/qmanager/cgi_base.sh" 2>/dev/null; then
    sed -i '/^_CGI_BASE_LOADED=1$/a export PATH="/usrdata/bin:/usrdata/opt/bin:/usrdata/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin:$PATH"' \
        "$SRC_SCRIPTS/usr/lib/qmanager/cgi_base.sh" 2>/dev/null || true
fi
# Keep sudo pointed at the real pre-patched setuid binary under /usrdata/opt
# Route platform.sh's privileged path at the /usrdata/bin sudo shim (Casa runs
# CGIs as root, so the shim just execs the command — see the sudo step below).
sed -i \
    -e 's|/usrdata/usrdata/opt/bin/sudo|/usrdata/bin/sudo|g' \
    -e 's|/usrdata/opt/bin/sudo|/usrdata/bin/sudo|g' \
    "$SRC_SCRIPTS/usr/lib/qmanager/platform.sh" 2>/dev/null || true
info "cgi_base.sh and platform.sh patched for Casa tool paths"

# lighttpd.conf: write a clean Casa-specific config instead of patching the
# upstream file in-place. The Entware lighttpd binary uses an /opt loader path,
# so we keep the config simple and explicit here.
mkdir -p "$SRC_SCRIPTS/usrdata/qmanager"
cat > "$SRC_SCRIPTS/usrdata/qmanager/lighttpd.conf" << 'EOF'
# =============================================================================
# QManager — lighttpd configuration for Casa CFW-3212
# =============================================================================

server.modules = (
    "mod_redirect",
    "mod_cgi",
    "mod_proxy",
    "mod_openssl",
)

server.port      = 9080

server.document-root = "/usrdata/qmanager/www"
index-file.names     = ( "index.html" )

mimetype.assign = (
    ".html"  => "text/html",
    ".css"   => "text/css",
    ".js"    => "application/javascript",
    ".json"  => "application/json",
    ".png"   => "image/png",
    ".jpg"   => "image/jpeg",
    ".svg"   => "image/svg+xml",
    ".ico"   => "image/x-icon",
    ".woff"  => "font/woff",
    ".woff2" => "font/woff2",
    ".txt"   => "text/plain",
)

$SERVER["socket"] == "0.0.0.0:9000" {
    ssl.engine  = "enable"
    ssl.privkey = "/usrdata/qmanager/certs/server.key"
    ssl.pemfile = "/usrdata/qmanager/certs/server.crt"
    ssl.openssl.ssl-conf-cmd = ("MinProtocol" => "TLSv1.2")
}

$HTTP["scheme"] == "http" {
    url.redirect = ("" => "https://${url.authority}${url.path}${qsa}")
}

$HTTP["url"] =~ "/cgi-bin/" {
    cgi.assign = ( "" => "" )
}

$HTTP["url"] =~ "(^/console)" {
    proxy.header = ("map-urlpath" => ( "/console" => "/" ), "upgrade" => "enable" )
    proxy.server = ( "" => (( "host" => "127.0.0.1", "port" => 8080 )))
}
EOF
info "lighttpd.conf rewritten for Casa (ports 9080/9000)"

# Keep the stock exported IP Passthrough route HTML. Casa-specific behavior is
# implemented in the backend CGI and the shipped client bundle so the native
# qmanager page shell remains intact without exposing usbnet control.
cat > "$SRC_SCRIPTS/www/cgi-bin/quecmanager/network/ip_passthrough.sh" << 'EOF'
#!/bin/sh
. /usrdata/qmanager/lib/cgi_base.sh

PROFILE_ID="1"
PROFILE_ENABLE_RDB="link.profile.${PROFILE_ID}.ip_handover.enable"
PROFILE_MODE_RDB="link.profile.${PROFILE_ID}.ip_handover.mode"
PROFILE_WRITEFLAG_RDB="link.profile.${PROFILE_ID}.writeflag"
PROFILE_POLICY_ENABLE_RDB="link.policy.${PROFILE_ID}.enable"
PROFILE_TRIGGER_RDB="link.policy.${PROFILE_ID}.trigger_connect"
SERVICE_ENABLE_RDB="service.ip_handover.enable"
SERVICE_LAST_IP_RDB="service.ip_handover.last_wwan_ip"
FIXED_USB_MODE="0"
FIXED_IPPT_NAT="0"
FIXED_DNS_PROXY="disabled"

read_enabled() {
    val="$(rdb get "$PROFILE_ENABLE_RDB" 2>/dev/null)"
    [ "$val" = "1" ] && echo "1" || echo "0"
}

read_service_enabled() {
    val="$(rdb get "$SERVICE_ENABLE_RDB" 2>/dev/null)"
    [ "$val" = "1" ] && echo "1" || echo "0"
}

read_mode() {
    val="$(rdb get "$PROFILE_MODE_RDB" 2>/dev/null)"
    [ -n "$val" ] && echo "$val" || echo "eth"
}

emit_state() {
    enabled="$(read_enabled)"
    if [ "$enabled" = "1" ]; then
        passthrough_mode="eth"
    else
        passthrough_mode="disabled"
    fi
    last_ip="$(rdb get "$SERVICE_LAST_IP_RDB" 2>/dev/null)"
    jq -n \
      --arg passthrough_mode "$passthrough_mode" \
      --arg mac "" \
      --arg nat "$FIXED_IPPT_NAT" \
      --arg usb "$FIXED_USB_MODE" \
      --arg dns "$FIXED_DNS_PROXY" \
      '{
          success: true,
          passthrough_mode: $passthrough_mode,
          target_mac: $mac,
          ippt_nat: $nat,
          usb_mode: $usb,
          dns_proxy: $dns
      }'
}

cgi_headers
cgi_handle_options

if [ "$REQUEST_METHOD" = "GET" ]; then
    emit_state
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    if [ "$ACTION" != "apply" ]; then
        cgi_error "invalid_action" "action must be apply"
        exit 0
    fi

    PASSTHROUGH_MODE=$(printf '%s' "$POST_DATA" | jq -r '.passthrough_mode // empty')
    case "$PASSTHROUGH_MODE" in
        disabled) ENABLED="0" ;;
        eth) ENABLED="1" ;;
        usb)
            cgi_error "unsupported_usb_mode" "USB passthrough mode is not supported on Casa CFW-3212; USB composition remains fixed"
            exit 0
            ;;
        *)
            cgi_error "invalid_passthrough_mode" "passthrough_mode must be disabled or eth"
            exit 0
            ;;
    esac

    if ! rdb set "$PROFILE_ENABLE_RDB" "$ENABLED" 2>/dev/null; then
        cgi_error "rdb_write_failed" "Failed to write Casa ip_handover flag"
        exit 0
    fi

    # Casa CFW-3212 ippt service-clear: when disabling, also clear the
    # service-level handover flag and cached last WAN IP so the data session
    # stops binding to the Casa handover placeholder across reboots.
    if [ "$ENABLED" = "0" ]; then
        rdb set "$SERVICE_ENABLE_RDB" 0 2>/dev/null || true
        rdb setflags "$SERVICE_ENABLE_RDB" p 2>/dev/null || true
        rdb set "$SERVICE_LAST_IP_RDB" "" 2>/dev/null || true
        rdb setflags "$SERVICE_LAST_IP_RDB" p 2>/dev/null || true
    fi

    rdb set "$PROFILE_WRITEFLAG_RDB" "1" 2>/dev/null || true
    policy_enable="$(rdb get "$PROFILE_POLICY_ENABLE_RDB" 2>/dev/null)"
    [ -z "$policy_enable" ] && policy_enable="1"
    rdb set "$PROFILE_TRIGGER_RDB" "$policy_enable" 2>/dev/null || true

    emit_state
    exit 0
fi

cgi_method_not_allowed
EOF
chmod 755 "$SRC_SCRIPTS/www/cgi-bin/quecmanager/network/ip_passthrough.sh" 2>/dev/null || true
info "Casa IP Passthrough mapped to ip_handover with usbnet control still blocked"

# Casa keeps the upstream SIM Profile UI/manual apply path enabled. Profiles
# can save/delete JSON state and, when manually applied by the user, can set APN,
# QManager TTL/HL firewall state, and IMEI followed by AT+CFUN=1,1. Blind
# profile auto-apply remains disabled in the Casa build patches.
info "Casa unsafe modem/network write endpoints switched to read-only mode"

# --- Users and groups --------------------------------------------------------

step "Creating users and groups"

getent group dialout >/dev/null 2>&1 || addgroup dialout 2>/dev/null || groupadd dialout 2>/dev/null || true
getent group www-data >/dev/null 2>&1 || addgroup www-data 2>/dev/null || groupadd www-data 2>/dev/null || true
id www-data >/dev/null 2>&1 || \
    adduser -S -H -D -G www-data www-data 2>/dev/null || \
    useradd -r -M -s /sbin/nologin -g www-data www-data 2>/dev/null || true
addgroup www-data dialout 2>/dev/null || usermod -aG dialout www-data 2>/dev/null || true
chown root:dialout /dev/smd11 && chmod 660 /dev/smd11
info "www-data:dialout ready, /dev/smd11 → 660"

# --- Install binaries to /usrdata/bin ----------------------------------------

step "Installing binaries to $BIN_DIR"

mkdir -p "$BIN_DIR"

for bin in atcli_smd11 sms_tool qmanager_discord; do
    if [ -f "$SRC_DEPS/$bin" ]; then
        copy_if_changed "$SRC_DEPS/$bin" "$BIN_DIR/$bin" 755 || true
        info "$bin installed"
    fi
done

if [ -d "$SRC_SCRIPTS/usr/bin" ]; then
    for f in "$SRC_SCRIPTS/usr/bin"/*; do
        [ -f "$f" ] || continue
        if head -c 2 "$f" 2>/dev/null | grep -q '^#!'; then
            sed -i 's/\r$//' "$f"
        fi
        fname=$(basename "$f")
        copy_if_changed "$f" "$BIN_DIR/$fname" 755 || true
    done
    info "$(ls "$SRC_SCRIPTS/usr/bin" | wc -l) daemons installed to $BIN_DIR"
fi

# Preserve the upstream Rust qmanager_ping as the primary implementation, but
# install a Casa shell fallback. If Rust exits nonzero during early boot, the
# wrapper falls back instead of letting systemd restart-loop the router.
step "Installing Casa ping daemon wrapper and fallback"
if [ -f "$BIN_DIR/qmanager_ping" ]; then
    mv "$BIN_DIR/qmanager_ping" "$BIN_DIR/qmanager_ping_rust"
    chmod 755 "$BIN_DIR/qmanager_ping_rust"
fi
cat > "$BIN_DIR/qmanager_ping_shell" << 'EOF'
#!/bin/sh

LIB_DIR="${QM_LIB_DIR:-/usrdata/qmanager/lib}"
. "$LIB_DIR/qlog.sh" 2>/dev/null || . /usr/lib/qmanager/qlog.sh 2>/dev/null || {
    qlog_init() { :; }
    qlog_debug() { :; }
    qlog_info() { :; }
    qlog_warn() { :; }
    qlog_error() { :; }
    qlog_state_change() { :; }
}
qlog_init "ping"

CONFIG="${PING_PROFILE_CONFIG:-/etc/qmanager/ping_profile.json}"
RELOAD_FLAG="${PING_PROFILE_RELOAD_FLAG:-/tmp/qmanager_ping_reload}"
CACHE_FILE="/tmp/qmanager_ping.json"
CACHE_TMP="/tmp/qmanager_ping.json.tmp"
HISTORY_FILE="/tmp/qmanager_ping_history"
RECOVERY_FLAG="/tmp/qmanager_recovery_active"
PID_FILE="/tmp/qmanager_ping.pid"
PING_TIMEOUT="${PING_TIMEOUT:-2}"

profile="relaxed"
target_1="http://cp.cloudflare.com/"
target_2="http://www.gstatic.com/generate_204"
interval_sec=5
fail_secs=15
recover_secs=10
intercept_secs=8
history_secs=300
fail_threshold=3
recover_threshold=2
streak_success=0
streak_fail=0
reachable="true"
connectivity="connected"
target_index=0
history_count=0
history_size=60

ceil_div() {
    a="$1"
    b="$2"
    [ "$b" -le 0 ] 2>/dev/null && b=1
    echo $(( (a + b - 1) / b ))
}

profile_defaults() {
    case "$1" in
        sensitive)
            profile="sensitive"; interval_sec=1; fail_secs=6; recover_secs=3; intercept_secs=8; history_secs=300 ;;
        regular)
            profile="regular"; interval_sec=2; fail_secs=10; recover_secs=6; intercept_secs=8; history_secs=300 ;;
        quiet)
            profile="quiet"; interval_sec=10; fail_secs=30; recover_secs=20; intercept_secs=8; history_secs=600 ;;
        *)
            profile="relaxed"; interval_sec=5; fail_secs=15; recover_secs=10; intercept_secs=8; history_secs=300 ;;
    esac
}

load_config() {
    cfg_profile="relaxed"
    if [ -f "$CONFIG" ]; then
        cfg_profile=$(jq -r '.profile // "relaxed"' "$CONFIG" 2>/dev/null || echo relaxed)
    fi
    case "$cfg_profile" in sensitive|regular|relaxed|quiet) ;; *) cfg_profile="relaxed" ;; esac
    profile_defaults "$cfg_profile"

    if [ -f "$CONFIG" ]; then
        t1=$(jq -r '.target_1 // empty' "$CONFIG" 2>/dev/null || true)
        t2=$(jq -r '.target_2 // empty' "$CONFIG" 2>/dev/null || true)
        [ -n "$t1" ] && target_1="$t1"
        [ -n "$t2" ] && target_2="$t2"
    fi

    [ -n "${PING_PROFILE:-}" ] && profile_defaults "$PING_PROFILE"
    [ -n "${PING_INTERVAL:-}" ] && interval_sec="$PING_INTERVAL" && profile="custom"
    [ -n "${FAIL_SECS:-}" ] && fail_secs="$FAIL_SECS" && profile="custom"
    [ -n "${RECOVER_SECS:-}" ] && recover_secs="$RECOVER_SECS" && profile="custom"
    [ -n "${INTERCEPT_SECS:-}" ] && intercept_secs="$INTERCEPT_SECS" && profile="custom"
    [ -n "${HISTORY_SECS:-}" ] && history_secs="$HISTORY_SECS" && profile="custom"
    [ -n "${PING_TARGET_1:-}" ] && target_1="$PING_TARGET_1"
    [ -n "${PING_TARGET_2:-}" ] && target_2="$PING_TARGET_2"

    case "$interval_sec" in *[!0-9]*|''|0) interval_sec=5 ;; esac
    case "$fail_secs" in *[!0-9]*|'') fail_secs=15 ;; esac
    case "$recover_secs" in *[!0-9]*|'') recover_secs=10 ;; esac
    case "$intercept_secs" in *[!0-9]*|'') intercept_secs=8 ;; esac
    case "$history_secs" in *[!0-9]*|'') history_secs=300 ;; esac

    fail_threshold=$(ceil_div "$fail_secs" "$interval_sec")
    recover_threshold=$(ceil_div "$recover_secs" "$interval_sec")
    history_size=$(ceil_div "$history_secs" "$interval_sec")
    [ "$fail_threshold" -lt 1 ] 2>/dev/null && fail_threshold=1
    [ "$recover_threshold" -lt 1 ] 2>/dev/null && recover_threshold=1
    [ "$history_size" -lt 1 ] 2>/dev/null && history_size=1
}

host_from_target() {
    host="$1"
    host="${host#http://}"
    host="${host#https://}"
    host="${host%%/*}"
    host="${host%%:*}"
    case "$host" in
        cp.cloudflare.com|cloudflare.com) host="1.1.1.1" ;;
    esac
    printf '%s' "$host"
}

get_target() {
    if [ "$target_index" -eq 0 ]; then
        printf '%s' "$target_1"
    else
        printf '%s' "$target_2"
    fi
    target_index=$(( (target_index + 1) % 2 ))
}

do_ping() {
    host=$(host_from_target "$1")
    [ -z "$host" ] && return 1
    result=$(ping -c1 -W"$PING_TIMEOUT" "$host" 2>/dev/null) || return 1
    rtt="${result##*time=}"
    rtt="${rtt%% *}"
    case "$rtt" in ''|*[!0-9.]*) return 1 ;; esac
    printf '%s' "$rtt"
}

write_cache() {
    rtt="$1"
    used_target="$2"
    now=$(date +%s)
    during_recovery=false
    [ -f "$RECOVERY_FLAG" ] && during_recovery=true
    if [ "$reachable" = "true" ]; then
        connectivity="connected"
        down_reason=null
    else
        connectivity="disconnected"
        down_reason="timeout"
    fi

    jq -n \
        --argjson timestamp "$now" \
        --arg target1 "$target_1" \
        --arg target2 "$target_2" \
        --argjson interval "$interval_sec" \
        --argjson last_rtt "$rtt" \
        --argjson reachable "$reachable" \
        --argjson streak_s "$streak_success" \
        --argjson streak_f "$streak_fail" \
        --argjson during_rec "$during_recovery" \
        --arg connectivity "$connectivity" \
        --arg down_reason "$down_reason" \
        --arg target_used "$used_target" \
        --argjson fail_secs "$fail_secs" \
        --argjson recover_secs "$recover_secs" \
        --argjson intercept_secs "$intercept_secs" \
        --arg profile "$profile" \
        '{
            timestamp: $timestamp,
            targets: [$target1, $target2],
            interval_sec: $interval,
            last_rtt_ms: $last_rtt,
            reachable: $reachable,
            streak_success: $streak_s,
            streak_fail: $streak_f,
            during_recovery: $during_rec,
            connectivity: $connectivity,
            limited_reason: null,
            down_reason: (if $down_reason == "null" then null else $down_reason end),
            streak_limited: 0,
            probe_target_used: $target_used,
            http_code_seen: null,
            tcp_reused: false,
            fail_secs: $fail_secs,
            recover_secs: $recover_secs,
            intercept_secs: $intercept_secs,
            profile: $profile
        }' > "$CACHE_TMP" && mv "$CACHE_TMP" "$CACHE_FILE"
}

if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        qlog_error "Another ping daemon already running (PID $old_pid), exiting"
        exit 1
    fi
    rm -f "$PID_FILE"
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE" "$CACHE_TMP"' EXIT INT TERM

load_config
qlog_info "QManager Casa shell ping daemon starting (PID $$)"
qlog_info "Profile: $profile; targets: $target_1, $target_2; interval=${interval_sec}s"
rm -f "$CACHE_TMP"
: > "$HISTORY_FILE"

while true; do
    if [ -f "$RELOAD_FLAG" ]; then
        old_profile="$profile"
        load_config
        rm -f "$RELOAD_FLAG"
        qlog_state_change "profile" "$old_profile" "$profile"
    fi

    target=$(get_target)
    rtt=$(do_ping "$target" || true)
    if [ -n "$rtt" ]; then
        streak_success=$((streak_success + 1))
        streak_fail=0
        if [ "$reachable" = "false" ] && [ "$streak_success" -ge "$recover_threshold" ]; then
            reachable="true"
            qlog_state_change "reachable" "false" "true"
        fi
        printf '%s\n' "$rtt" >> "$HISTORY_FILE"
    else
        rtt="null"
        streak_fail=$((streak_fail + 1))
        streak_success=0
        if [ "$reachable" = "true" ] && [ "$streak_fail" -ge "$fail_threshold" ]; then
            reachable="false"
            qlog_state_change "reachable" "true" "false"
            qlog_warn "Internet unreachable after $fail_threshold consecutive failures"
        fi
        printf 'null\n' >> "$HISTORY_FILE"
    fi

    history_count=$((history_count + 1))
    if [ "$history_count" -gt "$history_size" ]; then
        tail -n "$history_size" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp" && mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        history_count="$history_size"
    fi

    write_cache "$rtt" "$target" || qlog_error "Failed to write ping cache"
    sleep "$interval_sec"
done
EOF
chmod 755 "$BIN_DIR/qmanager_ping_shell"
cat > "$BIN_DIR/qmanager_ping" << 'EOF'
#!/bin/sh

RUST="/usrdata/bin/qmanager_ping_rust"
SHELL_FALLBACK="/usrdata/bin/qmanager_ping_shell"
LOG="/tmp/qmanager.log"

log_fallback() {
    ts=$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || date)
    echo "[$ts] WARN  [ping-wrapper:$$] $*" >> "$LOG" 2>/dev/null || true
}

if [ "${QM_PING_FORCE_SHELL:-0}" != "1" ] && [ -x "$RUST" ]; then
    RUST_ATTEMPTS="${QM_PING_RUST_ATTEMPTS:-4}"
    RUST_RETRY_DELAY="${QM_PING_RUST_RETRY_DELAY:-15}"
    RUST_START_DELAY="${QM_PING_RUST_START_DELAY:-20}"
    sleep "$RUST_START_DELAY"
    attempt=1
    while [ "$attempt" -le "$RUST_ATTEMPTS" ]; do
        "$RUST"
        rc=$?
        case "$rc" in
            0|143|130) exit "$rc" ;;
        esac
        if [ "$attempt" -lt "$RUST_ATTEMPTS" ]; then
            log_fallback "Rust qmanager_ping exited rc=$rc on attempt $attempt/$RUST_ATTEMPTS; retrying in ${RUST_RETRY_DELAY}s"
            sleep "$RUST_RETRY_DELAY"
        else
            log_fallback "Rust qmanager_ping exited rc=$rc on attempt $attempt/$RUST_ATTEMPTS; starting Casa shell fallback"
        fi
        attempt=$((attempt + 1))
    done
fi

exec "$SHELL_FALLBACK"
EOF
chmod 755 "$BIN_DIR/qmanager_ping"
info "Casa qmanager_ping wrapper installed (Rust primary, shell fallback)"

# --- Entware bootstrap (all under /usrdata/opt) ------------------------------

step "Entware bootstrap (→ $OPT_DIR)"

unset LD_LIBRARY_PATH LD_PRELOAD
mkdir -p "$OPT_DIR/bin" "$OPT_DIR/etc" "$OPT_DIR/lib/opkg" \
         "$OPT_DIR/tmp" "$OPT_DIR/var/lock" "$OPT_DIR/var/run" "$ENTWARE_STATE_DIR"
chmod 777 "$OPT_DIR/tmp"

# Install the core Entware runtime (libc/loader, libssl, lighttpd + modules,
# sudo). Prefer the bundled offline .ipk set staged under dependencies/entware/
# (AI-56) so a box with no WAN can still install; fall back to downloading from
# bin.entware.net only when the bundle is absent or incomplete.
ENTWARE_BUNDLE_DIR="$SRC_DEPS/entware"
entware_bundled_installed=0
if [ -d "$ENTWARE_BUNDLE_DIR" ]; then
    for ipk in "$ENTWARE_BUNDLE_DIR"/*.ipk; do
        [ -f "$ipk" ] || continue
        install_bundled_ipk "$ipk" "$(basename "$ipk" .ipk)"
        entware_bundled_installed=$((entware_bundled_installed + 1))
    done
fi
if [ "$entware_bundled_installed" -gt 0 ]; then
    info "Installed $entware_bundled_installed bundled Entware package(s) offline"
fi

# Decide whether anything still needs to come from the network. The loader
# (libc), sudo, and the lighttpd server binary are the must-haves.
entware_need_online=0
[ -e "$OPT_DIR/lib/ld-linux.so.3" ] || entware_need_online=1
[ -x "$OPT_DIR/bin/sudo" ] || entware_need_online=1
[ -x "$OPT_DIR/sbin/lighttpd" ] || entware_need_online=1

if [ "$entware_need_online" = 1 ]; then
    if [ "$entware_bundled_installed" -gt 0 ]; then
        warn "Bundled Entware set incomplete — falling back to online download"
    fi
    entware_refresh_index
    for pkg in libpcre2 libopenssl lighttpd lighttpd-mod-cgi \
               lighttpd-mod-openssl lighttpd-mod-redirect \
               lighttpd-mod-proxy sudo; do
        entware_install_pkg "$pkg"
    done
else
    info "Entware runtime satisfied from bundled packages (offline OK)"
fi

for f in passwd group shells shadow gshadow; do
    [ -f "/etc/$f" ] && ln -sf "/etc/$f" "$OPT_DIR/etc/$f" 2>/dev/null || true
done
[ -f /etc/localtime ] && ln -sf /etc/localtime "$OPT_DIR/etc/localtime" 2>/dev/null || true

if [ -x "$OPT_DIR/bin/jq" ]; then
    info "jq already present"
elif [ -f "$SRC_DEPS/jq.ipk" ]; then
    install_bundled_ipk "$SRC_DEPS/jq.ipk" "jq"
else
    warn "Bundled jq.ipk not found"
fi

if [ -x "$OPT_DIR/bin/jq" ]; then
    create_entware_wrapper "jq" "$OPT_DIR/bin/jq"
    info "jq loader wrapper installed"
fi

# sudo: do NOT create a loader wrapper. The bundled sudo is pre-patched so its
# ELF interpreter (/usrdata/opt/lib/ld-linux.so.3) and RPATH
# (/usrdata/opt/lib:/usrdata/opt/lib/sudo) resolve without /opt, and it is run
# directly as the setuid binary at $OPT_DIR/bin/sudo. A wrapper naming the
# loader explicitly would make the kernel drop the setuid bit, so `sudo -n`
# from the CGIs would silently fail. Re-assert setuid + root owner defensively
# (extraction or an older/unpatched bundle may not carry them).
# sudo shim. On Casa, lighttpd and its CGIs run as root, and QManager only ever
# uses `sudo -n <cmd>` to elevate (never `sudo -u <other-user>`). Entware's real
# setuid sudo cannot run on a clean stock box: its glibc resolves NSS modules
# (libnss_files) from the compiled-in /opt prefix, which a read-only squashfs
# root cannot provide (no pivot) — so getpwuid() fails with "you do not exist in
# the passwd database". Since the caller is already root, elevation is a no-op:
# install a tiny shim that strips sudo's own options and execs the command
# directly. If somehow not root, fall back to the bundled Entware sudo.
cat > "$BIN_DIR/sudo" <<'SUDO_EOF'
#!/bin/sh
if [ "$(id -u)" -ne 0 ]; then
    exec /usrdata/opt/bin/sudo "$@"
fi
while [ $# -gt 0 ]; do
    case "$1" in
        -n|-k|-K|-E|-H|-S|-b) shift ;;
        -u|-g|-p|-C|-r|-t|-T|-U) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec "$@"
SUDO_EOF
chmod 755 "$BIN_DIR/sudo"
info "sudo shim installed at $BIN_DIR/sudo (Casa CGIs run as root)"
# Keep the bundled Entware sudo as a setuid fallback for boxes that do have a
# writable /opt (e.g. a pivoted box); harmless and unused on a stock box.
if [ -x "$OPT_DIR/bin/sudo" ]; then
    chown 0:0 "$OPT_DIR/bin/sudo" 2>/dev/null || true
    chmod 4755 "$OPT_DIR/bin/sudo" 2>/dev/null || true
fi

# rc.unslung service → /etc/systemd/system (writable overlay)
if [ -x "$OPT_DIR/etc/init.d/rc.unslung" ]; then
    mkdir -p "$WANTS_DIR"
    cat > "$SYSTEMD_DIR/rc.unslung.service" << EOF
[Unit]
Description=Start Entware services

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 5
ExecStart=$OPT_DIR/etc/init.d/rc.unslung start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    ln -sf "$SYSTEMD_DIR/rc.unslung.service" "$WANTS_DIR/rc.unslung.service" 2>/dev/null || true
    info "rc.unslung service installed"
else
    warn "rc.unslung not present under $OPT_DIR/etc/init.d; skipping Entware init service"
fi

# dropbear is optional and direct extraction will not run postinst to create host keys.
if command -v dropbear >/dev/null 2>&1 || [ -x "$OPT_DIR/sbin/dropbear" ]; then
    info "dropbear already present"
else
    warn "Skipping bundled dropbear install during direct-IPK bootstrap (postinst would not generate host keys)"
fi

# Keep QManager quiet before the flash-heavy file sync sections. This lowers
# contention from qmanager-lighttpd/poller work while /usrdata is being checked/written.
step "Stopping existing QManager services"
for svc in qmanager-poller qmanager-ping qmanager-setup qmanager-ttl qmanager-mtu qmanager-lighttpd lighttpd; do
    systemctl stop "$svc" 2>/dev/null || true
done
pkill -f qmanager_poller 2>/dev/null || true
sleep 1

# --- Libraries ---------------------------------------------------------------

step "Installing libraries to $LIB_DIR"

mkdir -p "$LIB_DIR"
if [ -d "$SRC_SCRIPTS/usr/lib/qmanager" ]; then
    find "$SRC_SCRIPTS/usr/lib/qmanager" -name "*.sh" -exec sed -i 's/\r$//' {} \;
    sync_tree_changed "$SRC_SCRIPTS/usr/lib/qmanager" "$LIB_DIR" "" 644 "libraries"
    info "$SYNC_TOTAL library files checked ($SYNC_COPIED changed, $SYNC_SKIPPED unchanged, $SYNC_PRUNED removed)"
fi

# Stage Tailscale and console service files in LIB_DIR (for on-demand install)
for f in tailscaled.service tailscaled.defaults qmanager-console.service; do
    src="$SRC_SCRIPTS/etc/systemd/system/$f"
    [ -f "$src" ] && cp "$src" "$LIB_DIR/$f" && chmod 644 "$LIB_DIR/$f" || true
done

# --- Frontend ----------------------------------------------------------------

step "Installing frontend to $WWW_ROOT"

mkdir -p "$WWW_ROOT/cgi-bin"
if [ -f "$FRONTEND_MANIFEST_SRC" ] && [ -f "$FRONTEND_MANIFEST_DST" ] && \
    cmp -s "$FRONTEND_MANIFEST_SRC" "$FRONTEND_MANIFEST_DST"; then
    SYNC_TOTAL=0
    SYNC_COPIED=0
    SYNC_SKIPPED=$(wc -l < "$FRONTEND_MANIFEST_SRC" | tr -d ' ')
    SYNC_PRUNED=0
    info "frontend manifest unchanged; skipped frontend file sync"
else
    sync_tree_changed "$SRC_FRONTEND" "$WWW_ROOT" "cgi-bin" 644 "frontend"
    if [ -f "$FRONTEND_MANIFEST_SRC" ]; then
        cp "$FRONTEND_MANIFEST_SRC" "$FRONTEND_MANIFEST_DST"
        chmod 644 "$FRONTEND_MANIFEST_DST" 2>/dev/null || true
    fi
    info "$SYNC_TOTAL frontend files checked ($SYNC_COPIED changed, $SYNC_SKIPPED unchanged, $SYNC_PRUNED removed)"
fi

# --- CGI scripts -------------------------------------------------------------

step "Installing CGI scripts"

sync_tree_changed "$SRC_SCRIPTS/www/cgi-bin/quecmanager" "$CGI_DIR" "" 644 "CGI scripts"
info "$SYNC_TOTAL CGI files checked ($SYNC_COPIED changed, $SYNC_SKIPPED unchanged, $SYNC_PRUNED removed)"

# --- lighttpd config ---------------------------------------------------------

step "Installing lighttpd config"

mkdir -p "$QMANAGER_ROOT" "$CERT_DIR"
cp "$SRC_SCRIPTS/usrdata/qmanager/lighttpd.conf" "$LIGHTTPD_CONF"
info "lighttpd.conf installed (HTTP:9080 HTTPS:9000)"

# Proper server leaf cert with a Subject Alternative Name. Older builds made a
# CA:TRUE, SAN-less self-signed cert that modern Safari/iOS reject (no SAN => no
# "visit anyway" bypass) and Firefox blocks outright (CA:TRUE used as a leaf).
# Generate a real server cert with a SAN covering loopback + this box's LAN /
# Tailscale IPs (and the Tailscale MagicDNS name when up). Regenerate an existing
# cert if it predates this (has no SAN).
gen_cert=0
if [ ! -f "$CERT_DIR/server.key" ] || [ ! -f "$CERT_DIR/server.crt" ]; then
    gen_cert=1
elif ! openssl x509 -in "$CERT_DIR/server.crt" -noout -text 2>/dev/null | grep -q "Subject Alternative Name"; then
    gen_cert=1
    info "Existing TLS cert has no SAN — regenerating for iOS/Firefox compatibility"
fi

if [ "$gen_cert" = "1" ]; then
    cert_san="DNS:localhost,IP:127.0.0.1"
    for _ip in $(ip -4 addr 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' \
                 | grep -vE '^(127\.|169\.254\.|192\.0\.0\.)'); do
        cert_san="$cert_san,IP:$_ip"
    done
    if [ -x /usrdata/tailscale/tailscale ]; then
        _tsname="$(/usrdata/tailscale/tailscale status --json 2>/dev/null \
                   | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -1)"
        [ -n "$_tsname" ] && cert_san="$cert_san,DNS:$_tsname"
    fi
    # Build the cert from an explicit openssl config. Using -addext here is NOT
    # safe on this platform's openssl: it APPENDS extensions on top of the
    # default ones, producing a duplicate basicConstraints (CA:TRUE + CA:FALSE),
    # which is malformed (RFC 5280) and rejected by Chrome/Edge as
    # NET::ERR_CERT_INVALID with no bypass. A config with x509_extensions set
    # emits exactly one of each extension.
    cert_cfg="$(mktemp 2>/dev/null || echo "/tmp/qm_cert_$$.cnf")"
    cat > "$cert_cfg" <<CERTCFG
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = QManager-CFW3212
[v3]
subjectAltName = $cert_san
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
CERTCFG
    if openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
            -config "$cert_cfg" 2>/dev/null; then
        info "TLS cert generated (SAN: $cert_san)"
    elif openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$CERT_DIR/server.key" -out "$CERT_DIR/server.crt" \
            -subj "/CN=QManager-CFW3212" 2>/dev/null; then
        warn "openssl config-cert generation failed — generated basic TLS cert"
    else
        warn "openssl not available — TLS skipped"
    fi
    rm -f "$cert_cfg"
else
    info "TLS cert already present with SAN"
fi

# Console startup script
if [ -d "$SRC_SCRIPTS/usrdata/qmanager/console" ]; then
    mkdir -p "$QMANAGER_ROOT/console"
    cp "$SRC_SCRIPTS/usrdata/qmanager/console"/* "$QMANAGER_ROOT/console/" 2>/dev/null || true
    find "$QMANAGER_ROOT/console" -name "*.sh" -exec chmod 755 {} \;
fi

# --- Config ------------------------------------------------------------------

step "Installing config"

mkdir -p "$CONF_DIR/profiles" "$CONF_DIR/backups"
printf '%s\n' "$VERSION" > "$CONF_DIR/VERSION"
info "Version recorded: $VERSION"
if [ -d "$SRC_SCRIPTS/etc/qmanager" ]; then
    for f in "$SRC_SCRIPTS/etc/qmanager"/*; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        [ ! -f "$CONF_DIR/$fname" ] && cp "$f" "$CONF_DIR/$fname"
    done
fi

# environment: expose /usrdata/bin and /usrdata/opt/bin to all QManager processes
cat > "$CONF_DIR/environment" << EOF
QLOG_LEVEL=INFO
PATH=/usrdata/bin:/usrdata/opt/bin:/usrdata/opt/sbin:/usr/bin:/bin:/sbin
EOF
info "environment written (PATH includes /usrdata/bin and /usrdata/opt/bin)"

# Sudoers
for sudoers_path in /usrdata/opt/etc/sudoers /etc/sudoers; do
    [ -f "$sudoers_path" ] || continue
    sudoers_dir="$(dirname "$sudoers_path")/sudoers.d"
    mkdir -p "$sudoers_dir"
    grep -q "includedir.*sudoers.d" "$sudoers_path" 2>/dev/null || \
        echo "#includedir $sudoers_dir # qmanager-cfw3212" >> "$sudoers_path"
    if [ -f "$SRC_SCRIPTS/etc/sudoers.d/qmanager" ]; then
        cp "$SRC_SCRIPTS/etc/sudoers.d/qmanager" "$sudoers_dir/qmanager"
        sed -i 's/\r$//' "$sudoers_dir/qmanager"
        chmod 440 "$sudoers_dir/qmanager"
        # Normalize any sudo binary reference to the real setuid binary under
        # /usrdata/opt (not /opt, not the /usrdata/bin wrapper). Route every
        # form through a sentinel first to avoid double-prefixing.
        sed -i \
            -e "s|/usrdata/opt/bin/sudo|@QMSUDO@|g" \
            -e "s|$BIN_DIR/sudo|@QMSUDO@|g" \
            -e "s|/opt/bin/sudo|@QMSUDO@|g" \
            -e "s|@QMSUDO@|$OPT_DIR/bin/sudo|g" \
            "$sudoers_dir/qmanager"
        info "sudoers installed at $sudoers_dir"
    fi
    break
done

if [ -f "$LIB_DIR/config.sh" ]; then
    # shellcheck disable=SC1090
    . "$LIB_DIR/config.sh" 2>/dev/null && qm_config_init 2>/dev/null || true
fi

chown -R www-data:www-data "$CONF_DIR" 2>/dev/null || true
mkdir -p "$SESSION_DIR"
chown www-data:www-data "$SESSION_DIR" && chmod 700 "$SESSION_DIR"

# --- Systemd units -----------------------------------------------------------

step "Installing systemd units to $SYSTEMD_DIR"

mkdir -p "$WANTS_DIR"

rm -f "$SYSTEMD_DIR/lighttpd.service" "$WANTS_DIR/lighttpd.service"
systemctl mask lighttpd 2>/dev/null || true
info "Removed legacy QManager lighttpd.service override"

if systemctl list-unit-files turbontc.service >/dev/null 2>&1; then
    systemctl reset-failed turbontc.service 2>/dev/null || true
    systemctl start turbontc.service 2>/dev/null \
        && info "Casa stock UI turbontc.service is running" \
        || warn "Casa stock UI turbontc.service did not start — check: systemctl status turbontc"
fi

for f in "$SRC_SCRIPTS/etc/systemd/system"/qmanager*.service; do
    [ -f "$f" ] || continue
    cp "$f" "$SYSTEMD_DIR/"
    sed -i 's/\r$//' "$SYSTEMD_DIR/$(basename "$f")"
done
info "qmanager service units installed"

# Casa CFW-3212 note: keep the poller independent from qmanager-ping. The
# installer starts both explicitly, and this prevents a future ping regression
# from being pulled back in just because the poller restarts.
if [ -f "$SYSTEMD_DIR/qmanager-poller.service" ]; then
    sed -i \
        -e 's/[[:space:]]*qmanager-ping\.service//g' \
        -e '/^Wants=$/d' \
        -e '/^After=$/d' \
        "$SYSTEMD_DIR/qmanager-poller.service"
fi
if [ -f "$SYSTEMD_DIR/qmanager-ping.service" ]; then
    sed -i 's/^Description=.*/Description=QManager Ping Daemon (Rust primary, Casa shell fallback)/' "$SYSTEMD_DIR/qmanager-ping.service"
fi

# Older Casa systemd ignores StartLimitIntervalSec= and falls back to a very
# short default. Use the older key so any future crashing daemon rate-limits
# over an hour instead of respawning forever every few seconds.
for f in "$SYSTEMD_DIR"/qmanager*.service; do
    [ -f "$f" ] || continue
    sed -i 's/^StartLimitIntervalSec=/StartLimitInterval=/' "$f"
done

# Treat "no IMEI check is pending" as a clean skipped oneshot, not a failed
# boot service. The jq-enabled check remains for the rare case where both
# marker files exist but the saved setting is disabled.
if [ -f "$SYSTEMD_DIR/qmanager-imei-check.service" ]; then
    cat > "$SYSTEMD_DIR/qmanager-imei-check.service" << 'EOF'
# /etc/systemd/system/qmanager-imei-check.service
[Unit]
Description=QManager IMEI Rejection Check (One-Shot)
After=qmanager-setup.service
ConditionPathExists=/etc/qmanager/imei_check_pending
ConditionPathExists=/etc/qmanager/imei_backup.json

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'enabled=$(jq -r "(.enabled) | if . == null then \"false\" else tostring end" /etc/qmanager/imei_backup.json 2>/dev/null); [ "$enabled" = "true" ]'
ExecStart=/usrdata/bin/qmanager_imei_check
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF
fi

# qmanager-lighttpd.service — keep QManager's Entware web server separate from
# Casa's stock web stack. Stock Casa masks lighttpd.service and serves the
# browser UI through turbontc.service on port 80; QManager stays on 9080/9000.
rm -f "$SYSTEMD_DIR/qmanager-lighttpd.service"
cat > "$SYSTEMD_DIR/qmanager-lighttpd.service" << EOF
[Unit]
Description=QManager Lighttpd Daemon
After=network.target

[Service]
Type=simple
PIDFile=$OPT_DIR/var/run/lighttpd.pid
ExecStartPre=$LIGHTTPD_LAUNCHER -tt -f $LIGHTTPD_CONF
ExecStart=$LIGHTTPD_LAUNCHER -D -f $LIGHTTPD_CONF
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sed -i 's/\r$//' "$SYSTEMD_DIR/qmanager-lighttpd.service"
info "qmanager-lighttpd.service installed (QManager web UI only)"

# Enable services
for svc in qmanager-lighttpd qmanager-firewall qmanager-setup qmanager-ping \
           qmanager-poller qmanager-ttl qmanager-mtu qmanager-imei-check; do
    f="$SYSTEMD_DIR/${svc}.service"
    if [ -f "$f" ]; then
        ln -sf "$f" "$WANTS_DIR/${svc}.service"
        systemctl enable "$svc" >/dev/null 2>&1 || true
        info "Enabled $svc"
    fi
done

systemctl daemon-reload || true

# --- Fix permissions ---------------------------------------------------------

step "Fixing permissions"

find "$BIN_DIR" -name "qmanager_*" -exec chmod 755 {} \; 2>/dev/null || true
for b in qcmd qcmd_test atcli_smd11 sms_tool jq; do
    [ -f "$BIN_DIR/$b" ] && chmod 755 "$BIN_DIR/$b" || true
done
find "$CGI_DIR" -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
find "$LIB_DIR" -name "*.sh" -exec chmod 644 {} \; 2>/dev/null || true

# --- Start services ----------------------------------------------------------

step "Starting QManager services"
write_update_status "Restarting QManager services..."

systemctl start qmanager-firewall 2>/dev/null \
    && info "qmanager-firewall started" \
    || warn "qmanager-firewall had issues — check: systemctl status qmanager-firewall"

systemctl start qmanager-setup 2>/dev/null \
    && info "qmanager-setup done" \
    || warn "qmanager-setup had issues — check: systemctl status qmanager-setup"

sleep 1

# Verify lighttpd config before starting
if $LIGHTTPD_LAUNCHER -tt -f "$LIGHTTPD_CONF" >/dev/null 2>&1; then
    systemctl start qmanager-lighttpd 2>/dev/null \
        && info "qmanager-lighttpd started" \
        || warn "qmanager-lighttpd failed — check: systemctl status qmanager-lighttpd"
else
    warn "qmanager-lighttpd config check failed — not starting"
    warn "Debug: $LIGHTTPD_LAUNCHER -tt -f $LIGHTTPD_CONF"
fi

systemctl start qmanager-ping 2>/dev/null \
    && info "qmanager-ping started" \
    || warn "qmanager-ping failed — check: systemctl status qmanager-ping"
pkill -f qmanager_poller 2>/dev/null || true
sleep 1
systemctl start qmanager-poller 2>/dev/null \
    && info "qmanager-poller started" \
    || warn "qmanager-poller failed — check: systemctl status qmanager-poller"

# --- Web Console (ttyd) ------------------------------------------------------
# Upstream ships qmanager_console_mgr as an optional downloader for ttyd. The
# Casa installer already stages the console script and qmanager-console unit;
# run the helper best-effort so /console works on internet-connected installs.
TTYD_BIN="$QMANAGER_ROOT/console/ttyd"

step "Installing web console (ttyd)"
if [ -x "$TTYD_BIN" ]; then
    systemctl start qmanager-console 2>/dev/null \
        && info "web console already installed and started" \
        || warn "ttyd exists, but qmanager-console failed — check: systemctl status qmanager-console"
elif [ -x "$BIN_DIR/qmanager_console_mgr" ]; then
    if "$BIN_DIR/qmanager_console_mgr" install >/tmp/qmanager_console_install.log 2>&1; then
        info "web console installed and started"
    else
        warn "ttyd download/install failed — web console page will show unavailable"
        warn "Details: /tmp/qmanager_console_install.log"
    fi
else
    warn "qmanager_console_mgr missing — web console page will show unavailable"
fi

# --- Ookla Speedtest CLI -----------------------------------------------------
# The QManager speedtest CGIs (speedtest_start.sh / speedtest_status.sh etc.)
# use `command -v speedtest` to locate the binary. /usrdata/bin is first in
# the CGI PATH, so the binary just needs to live there.
#
# Download is best-effort: a failed download is warned but does not abort the
# install. The speedtest_check.sh CGI returns {"available":false} until the
# binary is present, disabling the speedtest button gracefully.
OOKLA_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-armhf.tgz"
OOKLA_BIN="$BIN_DIR/speedtest"

step "Installing Ookla Speedtest CLI"
if [ -x "$OOKLA_BIN" ]; then
    info "Ookla speedtest binary already present — skipping download"
elif command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    # busybox mktemp rejects a template with a suffix after the X's
    # ("Invalid argument"); since set -e is on, that would abort the whole
    # install. Use an X-terminated template (tar -xzf ignores the extension)
    # with a fallback so this step can never kill the install.
    OOKLA_TMP=$(mktemp /tmp/ookla_speedtest_XXXXXX 2>/dev/null || echo "/tmp/ookla_speedtest_$$")
    if command -v curl >/dev/null 2>&1; then
        curl -sL --max-time 60 "$OOKLA_URL" -o "$OOKLA_TMP" 2>/dev/null || true
    else
        wget -qO "$OOKLA_TMP" -T 60 "$OOKLA_URL" 2>/dev/null || true
    fi
    if [ -s "$OOKLA_TMP" ]; then
        tar -xzf "$OOKLA_TMP" -C /tmp speedtest 2>/dev/null \
            && mv /tmp/speedtest "$OOKLA_BIN" \
            && chmod 755 "$OOKLA_BIN" \
            && info "Ookla speedtest installed to $OOKLA_BIN" \
            || warn "Ookla tarball extraction failed — speedtest page will show 'not available'"
    else
        warn "Ookla download failed (network unreachable?) — speedtest page will show 'not available'"
        warn "To install later: curl -sL '$OOKLA_URL' | tar -xzC $BIN_DIR speedtest && chmod 755 $OOKLA_BIN"
    fi
    rm -f "$OOKLA_TMP"
else
    warn "No curl or wget found — skipping Ookla download"
fi

# --- Summary -----------------------------------------------------------------

echo ""
printf "${GREEN}${BOLD}QManager install complete.${NC}\n"
echo ""
printf "${YELLOW}  Note: qmanager-lighttpd was restarted. If the web UI appears blank,${NC}\n"
printf "${YELLOW}  do a hard refresh (Ctrl+F5 / Cmd+Shift+R) — do not wait.${NC}\n"
printf "${YELLOW}  Your login session is preserved across updates.${NC}\n"
printf "${YELLOW}  A reboot is recommended when convenient, but this installer does not reboot automatically.${NC}\n"
echo ""
echo "  Web UI:   https://<router-lan-ip>:9000/"
echo "  Setup:    create the QManager password on first login"
echo ""
echo "  Check status:"
echo "    systemctl status qmanager-lighttpd"
echo "    systemctl status qmanager-poller"
echo ""
echo "  lighttpd config test:"
echo "    $LIGHTTPD_LAUNCHER -tt -f $LIGHTTPD_CONF"
echo ""
