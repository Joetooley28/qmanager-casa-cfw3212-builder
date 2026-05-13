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
#   - Entware       → /usrdata/opt  (no bind mount to /opt needed)
#   - Systemd units → /etc/systemd/system  (writable via overlay)
#   - Wants symlinks→ /etc/systemd/system/multi-user.target.wants
#   - lighttpd on port 9000 (HTTPS) — port 80 is Casa's turbontc
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

# Entware lives entirely under /usrdata/opt — no /opt bind mount needed
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

# --- Colors ------------------------------------------------------------------

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "  ${GREEN}✓${NC}  %s\n" "$1"; }
warn()  { printf "  ${YELLOW}!${NC}  %s\n" "$1"; }
die()   { printf "  ${RED}✗${NC}  %s\n" "$1" >&2; exit 1; }
step()  { printf "\n${BLUE}${BOLD}▶ %s${NC}\n" "$1"; }

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

# --- Extract -----------------------------------------------------------------

step "Extracting tarball"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar xzf "$TARBALL" -C /tmp/
[ -d "$SRC_SCRIPTS" ] || die "Expected $SRC_SCRIPTS after extraction"
info "Extracted to $EXTRACT_DIR"

# --- Patch scripts in-place --------------------------------------------------

step "Patching path references for CFW-3212"

# Walk all shell scripts and service files in the extracted tree
find "$SRC_SCRIPTS" -type f | while read -r f; do
    case "$f" in
        *.sh|*.service|*.conf)
            ;;
        */usr/bin/*|*/usr/lib/qmanager/*)
            ;;
        *)
            continue
            ;;
    esac
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
        "$f" 2>/dev/null || true
done

# Catch the usr/bin and usr/lib files (excluded from the case above)
find "$SRC_SCRIPTS/usr" "$SRC_SCRIPTS/www" -type f 2>/dev/null | while read -r f; do
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
        "$f" 2>/dev/null || true
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
sed -i \
    -e 's|/usrdata/usrdata/opt/bin/sudo|/usrdata/bin/sudo|g' \
    -e 's|/usrdata/opt/bin/sudo|/usrdata/bin/sudo|g' \
    "$SRC_SCRIPTS/usr/lib/qmanager/platform.sh" 2>/dev/null || true
info "cgi_base.sh and platform.sh patched for Casa tool paths"

# lighttpd.conf: write a clean Casa-specific config instead of patching the
# upstream file in-place. The Entware lighttpd binary uses an /opt loader path,
# so we keep the config simple and explicit here.
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

# Casa already has a working QMI/rmnet data path with its own APN/profile state.
# The remaining hard safety line is upstream IP Passthrough / usbnet control.
# Profile-engine writes stay blocked for now because they are a separate layer
# above direct AT handlers and need more Casa-specific review.
disable_post_endpoint \
    "$SRC_SCRIPTS/www/cgi-bin/quecmanager/profiles/apply.sh" \
    "Profile apply is disabled on Casa CFW-3212"
disable_post_endpoint \
    "$SRC_SCRIPTS/www/cgi-bin/quecmanager/profiles/save.sh" \
    "Profile save is disabled on Casa CFW-3212"
disable_post_endpoint \
    "$SRC_SCRIPTS/www/cgi-bin/quecmanager/profiles/delete.sh" \
    "Profile deletion is disabled on Casa CFW-3212"
disable_post_endpoint \
    "$SRC_SCRIPTS/www/cgi-bin/quecmanager/profiles/deactivate.sh" \
    "Profile deactivation is disabled on Casa CFW-3212"
info "Casa modem/network write endpoints switched to read-only mode"

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

for bin in atcli_smd11 sms_tool; do
    if [ -f "$SRC_DEPS/$bin" ]; then
        cp "$SRC_DEPS/$bin" "$BIN_DIR/$bin"
        chmod 755 "$BIN_DIR/$bin"
        info "$bin installed"
    fi
done

if [ -d "$SRC_SCRIPTS/usr/bin" ]; then
    for f in "$SRC_SCRIPTS/usr/bin"/*; do
        [ -f "$f" ] || continue
        fname=$(basename "$f")
        cp "$f" "$BIN_DIR/$fname"
        sed -i 's/\r$//' "$BIN_DIR/$fname"
        chmod 755 "$BIN_DIR/$fname"
    done
    info "$(ls "$SRC_SCRIPTS/usr/bin" | wc -l) daemons installed to $BIN_DIR"
fi

# --- Entware bootstrap (all under /usrdata/opt) ------------------------------

step "Entware bootstrap (→ $OPT_DIR)"

unset LD_LIBRARY_PATH LD_PRELOAD
mkdir -p "$OPT_DIR/bin" "$OPT_DIR/etc" "$OPT_DIR/lib/opkg" \
         "$OPT_DIR/tmp" "$OPT_DIR/var/lock" "$OPT_DIR/var/run" "$ENTWARE_STATE_DIR"
chmod 777 "$OPT_DIR/tmp"

entware_refresh_index

for pkg in libpcre2 libopenssl lighttpd lighttpd-mod-cgi \
           lighttpd-mod-openssl lighttpd-mod-redirect \
           lighttpd-mod-proxy sudo; do
    entware_install_pkg "$pkg"
done

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

if [ -x "$OPT_DIR/bin/sudo" ]; then
    create_entware_wrapper "sudo" "$OPT_DIR/bin/sudo"
    info "sudo loader wrapper installed"
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

# --- Libraries ---------------------------------------------------------------

step "Installing libraries to $LIB_DIR"

mkdir -p "$LIB_DIR"
if [ -d "$SRC_SCRIPTS/usr/lib/qmanager" ]; then
    cp "$SRC_SCRIPTS/usr/lib/qmanager"/* "$LIB_DIR/"
    find "$LIB_DIR" -name "*.sh" -exec sed -i 's/\r$//' {} \;
    find "$LIB_DIR" -name "*.sh" -exec chmod 644 {} \;
    info "$(ls "$LIB_DIR" | wc -l) library files installed"
fi

# Stage Tailscale and console service files in LIB_DIR (for on-demand install)
for f in tailscaled.service tailscaled.defaults qmanager-console.service; do
    src="$SRC_SCRIPTS/etc/systemd/system/$f"
    [ -f "$src" ] && cp "$src" "$LIB_DIR/$f" && chmod 644 "$LIB_DIR/$f" || true
done

# --- Frontend ----------------------------------------------------------------

step "Installing frontend to $WWW_ROOT"

mkdir -p "$WWW_ROOT/cgi-bin"
for item in "$WWW_ROOT"/*; do
    [ "$(basename "$item")" = "cgi-bin" ] && continue
    rm -rf "$item"
done
cp -r "$SRC_FRONTEND"/* "$WWW_ROOT/"
info "$(find "$SRC_FRONTEND" -type f | wc -l) frontend files installed"

# --- CGI scripts -------------------------------------------------------------

step "Installing CGI scripts"

rm -rf "$CGI_DIR"
mkdir -p "$CGI_DIR"
cp -r "$SRC_SCRIPTS/www/cgi-bin/quecmanager"/. "$CGI_DIR/"
find "$CGI_DIR" -name "*.sh" -exec sed -i 's/\r$//' {} \;
find "$CGI_DIR" -name "*.sh" -exec chmod 755 {} \;
find "$CGI_DIR" -name "*.json" -exec chmod 644 {} \;
info "$(find "$CGI_DIR" -name "*.sh" | wc -l) CGI scripts installed"

# --- lighttpd config ---------------------------------------------------------

step "Installing lighttpd config"

mkdir -p "$QMANAGER_ROOT" "$CERT_DIR"
cp "$SRC_SCRIPTS/usrdata/qmanager/lighttpd.conf" "$LIGHTTPD_CONF"
info "lighttpd.conf installed (HTTP:9080 HTTPS:9000)"

if [ ! -f "$CERT_DIR/server.key" ]; then
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/server.key" \
        -out "$CERT_DIR/server.crt" -days 3650 -nodes \
        -subj "/CN=QManager-CFW3212" 2>/dev/null \
        && info "TLS cert generated" || warn "openssl not available — TLS skipped"
else
    info "TLS cert already exists"
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
        echo "#includedir $sudoers_dir" >> "$sudoers_path"
    if [ -f "$SRC_SCRIPTS/etc/sudoers.d/qmanager" ]; then
        cp "$SRC_SCRIPTS/etc/sudoers.d/qmanager" "$sudoers_dir/qmanager"
        sed -i 's/\r$//' "$sudoers_dir/qmanager"
        chmod 440 "$sudoers_dir/qmanager"
        # Replace sudo binary path references in case they point to /opt
        sed -i "s|/opt/bin/sudo|$OPT_DIR/bin/sudo|g" "$sudoers_dir/qmanager"
        sed -i "s|$OPT_DIR/bin/sudo|$BIN_DIR/sudo|g" "$sudoers_dir/qmanager"
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

for f in "$SRC_SCRIPTS/etc/systemd/system"/qmanager*.service; do
    [ -f "$f" ] || continue
    cp "$f" "$SYSTEMD_DIR/"
    sed -i 's/\r$//' "$SYSTEMD_DIR/$(basename "$f")"
done
info "qmanager service units installed"

# lighttpd.service — overrides the null-mask in squashfs.
# Write a clean Casa-specific unit instead of trying to rewrite the upstream
# one again after the earlier generic /opt -> /usrdata/opt patching pass.
cat > "$SYSTEMD_DIR/lighttpd.service" << EOF
[Unit]
Description=Lighttpd Daemon
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
sed -i 's/\r$//' "$SYSTEMD_DIR/lighttpd.service"
info "lighttpd.service installed (overrides squashfs null-mask)"

systemctl daemon-reload

# Enable services
for svc in lighttpd qmanager-firewall qmanager-setup qmanager-ping \
           qmanager-poller qmanager-ttl qmanager-mtu qmanager-imei-check; do
    f="$SYSTEMD_DIR/${svc}.service"
    if [ -f "$f" ]; then
        ln -sf "$f" "$WANTS_DIR/${svc}.service"
        info "Enabled $svc"
    fi
done

systemctl daemon-reload

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

systemctl start qmanager-setup 2>/dev/null \
    && info "qmanager-setup done" \
    || warn "qmanager-setup had issues — check: systemctl status qmanager-setup"

sleep 1

# Verify lighttpd config before starting
if $LIGHTTPD_LAUNCHER -tt -f "$LIGHTTPD_CONF" >/dev/null 2>&1; then
    systemctl start lighttpd 2>/dev/null \
        && info "lighttpd started" \
        || warn "lighttpd failed — check: systemctl status lighttpd"
else
    warn "lighttpd config check failed — not starting"
    warn "Debug: $LIGHTTPD_LAUNCHER -tt -f $LIGHTTPD_CONF"
fi

systemctl start qmanager-ping 2>/dev/null && info "qmanager-ping started" || true
systemctl start qmanager-poller 2>/dev/null \
    && info "qmanager-poller started" \
    || warn "qmanager-poller failed — check: systemctl status qmanager-poller"

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
    OOKLA_TMP=$(mktemp /tmp/ookla_speedtest_XXXXXX.tgz)
    if command -v curl >/dev/null 2>&1; then
        curl -sL --max-time 60 "$OOKLA_URL" -o "$OOKLA_TMP" 2>/dev/null
    else
        wget -qO "$OOKLA_TMP" -T 60 "$OOKLA_URL" 2>/dev/null
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
echo "  Web UI:   https://<router-lan-ip>:9000/"
echo "  Setup:    create the QManager password on first login"
echo ""
echo "  Check status:"
echo "    systemctl status lighttpd"
echo "    systemctl status qmanager-poller"
echo ""
echo "  lighttpd config test:"
echo "    $LIGHTTPD_LAUNCHER -tt -f $LIGHTTPD_CONF"
echo ""
