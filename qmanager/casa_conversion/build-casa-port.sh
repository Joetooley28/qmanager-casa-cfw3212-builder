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

upstream_has_v14_software_update() {
    [ -f "$TARGET/components/system-settings/software-update/derive.ts" ]
}

# Casa whole-file overrides are stored with the upstream file they were written
# against (templates/upstream-base/<tag>/<rel>). When the target still matches
# that base, the template is copied as-is; otherwise Casa's changes are
# three-way merged onto the newer upstream file, failing on real conflicts.
merge_template_cfw3212() {
    local rel="$1"
    local template="$TEMPLATE_DIR/$rel"
    local target="$TARGET/$rel"
    local base_dir base merged
    [ -f "$template" ] || fail "Template missing: $rel"
    [ -f "$target" ] || fail "Upstream target missing for template merge: $rel"
    for base_dir in "$TEMPLATE_DIR"/upstream-base/*/; do
        base="$base_dir$rel"
        [ -f "$base" ] || continue
        if cmp -s "$base" "$target"; then
            cp "$template" "$target"
            sed -i 's/\r$//' "$target" 2>/dev/null || true
            return 0
        fi
        merged="$(mktemp)"
        if git merge-file -p "$template" "$base" "$target" > "$merged" 2>/dev/null; then
            mv "$merged" "$target"
            sed -i 's/\r$//' "$target" 2>/dev/null || true
            log "Merged Casa template onto newer upstream: $rel (base $(basename "$base_dir"))"
            return 0
        fi
        rm -f "$merged"
    done
    fail "Casa template does not merge cleanly onto upstream: $rel"
}

patch_software_update_v14_cfw3212() {
    # Upstream v0.1.14+ rebuilt Software Update (components/system-settings/
    # software-update/* driven by derive.ts). Casa keeps its own update CGI and
    # installer: install restarts QManager services and then reports
    # reboot_required instead of rebooting, and the CGI serves Joetooley and
    # upstream release notes separately.
    local hook="$TARGET/hooks/use-software-update.ts"
    local dir="$TARGET/components/system-settings/software-update"
    local page="$dir/software-update.tsx"
    local notes="$dir/release-notes-card.tsx"
    local locale="$TARGET/public/locales/en/system-settings.json"
    [ -f "$hook" ] || fail "use-software-update.ts missing in target"
    [ -f "$page" ] || fail "software-update.tsx missing in target"
    [ -f "$notes" ] || fail "release-notes-card.tsx missing in target"
    [ -f "$locale" ] || fail "en/system-settings.json missing in target"

    python3 - "$hook" "$page" "$notes" "$locale" <<'PY'
from pathlib import Path
import json
import sys

hook, page, notes, locale = map(Path, sys.argv[1:5])

def sub(path, old, new, label, count=1):
    text = path.read_text()
    if new in text:
        return
    if text.count(old) < 1:
        raise SystemExit(f"software update v14: {label} anchor not found in {path.name}")
    path.write_text(text.replace(old, new, count))

# --- hook -----------------------------------------------------------------
sub(hook, "  current_changelog: string | null;\n",
    "  current_changelog: string | null;\n"
    "  /** Casa CFW-3212 package CGI: split Joetooley / upstream release notes. */\n"
    "  joetooley_changelog?: string | null;\n"
    "  upstream_changelog?: string | null;\n"
    "  current_joetooley_changelog?: string | null;\n"
    "  current_upstream_changelog?: string | null;\n"
    "  upstream_release_url?: string | null;\n",
    "UpdateInfo fields")
sub(hook, '  status: "idle" | "downloading" | "installing" | "rebooting" | "error";',
    '  status: "idle" | "downloading" | "installing" | "reboot_required" | "rebooting" | "error";',
    "UpdateStatus union")
sub(hook, "  installVersion: (version: string) => Promise<void>;\n",
    "  installVersion: (version: string) => Promise<void>;\n"
    "  /** Casa: finish a reboot_required install. */\n"
    "  rebootNow: () => Promise<void>;\n",
    "return type")
sub(hook, "  const fetchUpdateInfo = useCallback(async (silent = false) => {\n",
    "  const fetchUpdateInfo = useCallback(async (silent = false, refresh = false) => {\n",
    "fetchUpdateInfo signature")
sub(hook, "      const resp = await authFetch(CGI_ENDPOINT);\n",
    '      const resp = await authFetch(`${CGI_ENDPOINT}${refresh ? "?refresh=1" : ""}`);\n',
    "fetchUpdateInfo url")
sub(hook, "    await fetchUpdateInfo(true);\n", "    await fetchUpdateInfo(true, true);\n",
    "checkForUpdates refresh")

# Install poller: stop on reboot_required; ride out Casa's service restart.
text = hook.read_text()
start = text.index("  const startPolling = useCallback(() => {")
end = text.index("  }, [fail]);", start)
block = text[start:end]
if 'json.status === "reboot_required"' not in block:
    block = block.replace('        if (json.status === "rebooting") {\n',
        '        if (json.status === "reboot_required") {\n'
        '          if (pollRef.current) clearInterval(pollRef.current);\n'
        '          pollRef.current = null;\n'
        '          sessionStorage.removeItem("qm_update_reload_scheduled");\n'
        '          setIsUpdating(false);\n'
        '          return;\n'
        '        }\n\n'
        '        if (json.status === "rebooting") {\n', 1)
    old_catch = block[block.index("      } catch {\n"):block.index("    }, POLL_INTERVAL);")]
    block = block.replace(old_catch,
        "      } catch {\n"
        "        // Casa restarts QManager/lighttpd during install, so a failed poll is\n"
        "        // expected. Keep polling until the worker reports reboot_required or\n"
        "        // an error; reload this page as a fallback for a dropped session.\n"
        '        if (!sessionStorage.getItem("qm_update_reload_scheduled")) {\n'
        '          sessionStorage.setItem("qm_update_reload_scheduled", "1");\n'
        "          window.setTimeout(() => {\n"
        "            window.location.reload();\n"
        "          }, 30000);\n"
        "        }\n"
        "        setUpdateStatus({\n"
        '          status: "installing",\n'
        '          message: "QManager services are restarting; reconnecting.",\n'
        "        });\n"
        "      }\n", 1)
    if 'json.status === "reboot_required"' not in block or "qm_update_reload_scheduled" not in block:
        raise SystemExit("software update v14: install poller patch failed")
    text = text[:start] + block + text[end:]
    hook.write_text(text)

sub(hook, "  // Fetch on mount\n  useEffect(() => {\n    fetchUpdateInfo();\n  }, [fetchUpdateInfo]);\n",
    "  // Fetch on mount\n  useEffect(() => {\n    fetchUpdateInfo();\n  }, [fetchUpdateInfo]);\n\n"
    "  // Casa: restore a pending post-install reboot after navigation. The backend\n"
    "  // keeps reboot_required in /tmp/qmanager_update.json until the reboot.\n"
    "  useEffect(() => {\n"
    "    let cancelled = false;\n"
    "    (async () => {\n"
    "      try {\n"
    "        const resp = await authFetch(`${CGI_ENDPOINT}?action=status`);\n"
    "        if (!resp.ok) return;\n"
    "        const json: UpdateStatus = await resp.json();\n"
    "        if (cancelled || !mountedRef.current) return;\n"
    '        if (json.status === "reboot_required") setUpdateStatus(json);\n'
    "      } catch {\n"
    "        // the install poller picks it up if a job is active\n"
    "      }\n"
    "    })();\n"
    "    return () => {\n"
    "      cancelled = true;\n"
    "    };\n"
    "  }, []);\n",
    "mount effect")
sub(hook, "  const checkForUpdates = useCallback(async () => {\n",
    "  const rebootNow = useCallback(async () => {\n"
    '    setUpdateStatus({ status: "rebooting" });\n'
    '    sessionStorage.setItem("qm_rebooting", "1");\n'
    '    document.cookie = "qm_logged_in=; Path=/; Max-Age=0";\n'
    "    fetch(CGI_ENDPOINT, {\n"
    '      method: "POST",\n'
    '      headers: { "Content-Type": "application/json" },\n'
    '      body: JSON.stringify({ action: "reboot_now" }),\n'
    "      keepalive: true,\n"
    "    }).catch(() => {});\n"
    '    window.location.href = "/reboot/";\n'
    "  }, []);\n\n"
    "  const checkForUpdates = useCallback(async () => {\n",
    "rebootNow callback")
sub(hook, "    installVersion,\n    togglePrerelease,\n    saveAutoUpdate,\n  };\n",
    "    installVersion,\n    rebootNow,\n    togglePrerelease,\n    saveAutoUpdate,\n  };\n",
    "return object")

# --- page: reboot-required banner ------------------------------------------
sub(page, "    installVersion,\n    togglePrerelease,\n    saveAutoUpdate,\n  } = useSoftwareUpdate();\n",
    "    installVersion,\n    rebootNow,\n    togglePrerelease,\n    saveAutoUpdate,\n  } = useSoftwareUpdate();\n",
    "page hook destructure")
sub(page, "      <PageHeader\n",
    "      {/* Casa CFW-3212: install restarts QManager services, then waits for a\n"
    "          user-chosen reboot to finish applying the update. */}\n"
    '      {updateStatus.status === "reboot_required" && (\n'
    "        <Banner\n"
    '          role="degraded"\n'
    '          title="Reboot required"\n'
    "          description={\n"
    "            updateStatus.message ||\n"
    '            "Installation complete. Reboot when ready to finish applying the update."\n'
    "          }\n"
    "          action={\n"
    "            <button\n"
    '              type="button"\n'
    "              onClick={() => void rebootNow()}\n"
    '              className={bannerActionVariants({ tone: "on-warning" })}\n'
    "            >\n"
    "              Reboot now\n"
    "            </button>\n"
    "          }\n"
    "        />\n"
    "      )}\n\n"
    "      <PageHeader\n",
    "page banner")

# --- release notes: Joetooley / upstream tabs -------------------------------
sub(notes,
    "  const changelog =\n    (next ? info?.changelog : info?.current_changelog)?.trim() || null;\n",
    '  const [notesSource, setNotesSource] = React.useState<"joetooley" | "upstream">(\n'
    '    "joetooley",\n'
    "  );\n"
    "  // Casa CFW-3212: the package CGI serves Joetooley (Casa) and upstream notes\n"
    "  // separately; fall back to the combined changelog when neither is present.\n"
    "  const joetooleyNotes =\n"
    "    (next ? info?.joetooley_changelog : info?.current_joetooley_changelog)?.trim() || null;\n"
    "  const upstreamNotes =\n"
    "    (next ? info?.upstream_changelog : info?.current_upstream_changelog)?.trim() ||\n"
    "    (info?.upstream_release_url\n"
    "      ? `[View upstream release notes](${info.upstream_release_url})`\n"
    "      : null);\n"
    "  const hasSplitNotes = Boolean(joetooleyNotes || upstreamNotes);\n"
    "  const fallbackNotes =\n"
    "    (next ? info?.changelog : info?.current_changelog)?.trim() || null;\n"
    "  const changelog =\n"
    '    (notesSource === "upstream" ? upstreamNotes : joetooleyNotes) || fallbackNotes;\n',
    "release notes changelog")
sub(notes,
    "          {changelog ? (\n            <>\n",
    "          {changelog ? (\n            <>\n"
    "              {hasSplitNotes && (\n"
    '                <div className="inline-flex w-fit rounded-md border bg-background p-0.5">\n'
    "                  <Button\n"
    '                    type="button"\n'
    '                    variant={notesSource === "joetooley" ? "secondary" : "ghost"}\n'
    '                    size="sm"\n'
    '                    className="h-7 px-2 text-xs"\n'
    '                    onClick={() => setNotesSource("joetooley")}\n'
    "                  >\n"
    "                    Joetooley\n"
    "                  </Button>\n"
    "                  <Button\n"
    '                    type="button"\n'
    '                    variant={notesSource === "upstream" ? "secondary" : "ghost"}\n'
    '                    size="sm"\n'
    '                    className="h-7 px-2 text-xs"\n'
    '                    onClick={() => setNotesSource("upstream")}\n'
    "                  >\n"
    "                    Rus | Ame / Dr. D\n"
    "                  </Button>\n"
    "                </div>\n"
    "              )}\n",
    "release notes toggle")

# --- English wording: Casa installs restart services, then ask for a reboot --
data = json.loads(locale.read_text())
su = data["software_update"]
casa = {
    ("page", "description"): "QManager checks the Casa CFW-3212 package releases and installs them on the modem itself. Installing replaces the app and restarts QManager services; you reboot when ready to finish.",
    ("card", "available", "description"): "Downloading and installing takes a few minutes. QManager restarts its services, then asks you to reboot when ready.",
    ("card", "staged", "description"): "The package is downloaded and verified. Installing replaces QManager and restarts its services; reboot when prompted.",
    ("notice", "rest"): "Installing restarts QManager services, which briefly drops this session. A reboot is requested afterwards to finish.",
    ("notice", "staged"): "Installing replaces QManager and restarts its services. This session drops briefly, then you are asked to reboot.",
    ("notice", "versions"): "Every option here restarts QManager services and then asks for a reboot, and an older build can undo settings a newer one introduced.",
    ("preferences", "auto", "description"): "Unattended updates are disabled on Casa CFW-3212 builds.",
    ("versions", "dialog", "description_install"): "This installs {{version}} in place of {{current}}. QManager restarts its services, then asks you to reboot when ready.",
    ("versions", "dialog", "description_reinstall"): "This reinstalls {{version}} over the copy already on the modem, to repair it. QManager restarts its services, then asks you to reboot when ready.",
}
for keys, value in casa.items():
    node = su
    for k in keys[:-1]:
        node = node.get(k)
        if not isinstance(node, dict):
            raise SystemExit(f"software update v14: locale key missing {'.'.join(keys)}")
    if keys[-1] not in node:
        raise SystemExit(f"software update v14: locale key missing {'.'.join(keys)}")
    node[keys[-1]] = value
locale.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY

    grep -q 'json.status === "reboot_required"' "$hook" \
        || fail "Software Update v14: hook missing reboot_required handling"
    grep -q 'rebootNow,' "$hook" \
        || fail "Software Update v14: hook missing rebootNow"
    grep -q 'Reboot required' "$page" \
        || fail "Software Update v14: page missing reboot-required banner"
    grep -q 'joetooley_changelog' "$notes" \
        || fail "Software Update v14: release notes missing Joetooley source"
}

patch_package_script_builds_frontend_cfw3212() {
    # Upstream v0.1.14+ changed `bun run package` from "tests && next build &&
    # build.sh" to "icons:check && build.sh", so it no longer builds out/. The
    # Casa workflow and local builds call `bun run package` alone; keep that a
    # complete build by running next build first when upstream's script lacks it.
    local pkg="$TARGET/package.json"
    [ -f "$pkg" ] || fail "Target missing package.json"
    python3 - "$pkg" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
scripts = data.get("scripts", {})
package = scripts.get("package", "")
if not package:
    raise SystemExit("package.json has no package script")
if "next build" not in package:
    scripts["package"] = "bun --bun next build && " + package
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))["scripts"]["package"]; sys.exit(0 if "next build" in s else 1)' "$pkg" \
        || fail "package script does not build the frontend (out/)"
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

    # Upstream v0.1.14+ landed "ippt-strip.tsx" alongside a page-shell rewrite:
    # ip-passthrough.tsx now owns the single useIpPassthrough() read and hands
    # this card fully-controlled props (see upstream `IpPassthroughCardProps`
    # in ip-passthrough-card.tsx) instead of letting the card fetch for
    # itself. That file's existence is a stable, structure-tolerant anchor for
    # "we're on the new prop-driven layout" — the old v0.1.12 template/fallback
    # below (self-fetching via useIpPassthrough()) would build but silently
    # ignore every prop the v0.1.16 shell passes it, so it must not be used
    # once ippt-strip.tsx is present.
    if [ -f "$TARGET/components/local-network/ip-passthrough/ippt-strip.tsx" ]; then
        write_ippt_card_cfw3212_v16
        return
    fi

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

# Casa CFW-3212 IP Passthrough card for the v0.1.14+ ("ippt-strip.tsx") page
# shell. The shell owns the single useIpPassthrough() read and passes this
# card fully-controlled props (IpPassthroughCardProps upstream); Casa hardware
# only supports Disabled / Enabled Ethernet, so the extra MAC/NAT/USB/DNS-proxy
# fields upstream's card grew are dropped, same as the v0.1.12 Casa card.
write_ippt_card_cfw3212_v16() {
    cat > "$TARGET/components/local-network/ip-passthrough/ip-passthrough-card.tsx" <<'EOF'
"use client";

import { useEffect, useState, type FormEvent } from "react";
import { toast } from "sonner";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Field, FieldGroup, FieldLabel, FieldSet } from "@/components/ui/field";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { SaveButton, useSaveFlash } from "@/components/ui/save-button";
import { Skeleton } from "@/components/ui/skeleton";
import type { DnsProxy, IpptNat, PassthroughMode, UsbMode } from "@/types/ip-passthrough";
import type { IpPassthroughApplyData } from "@/hooks/use-ip-passthrough";

// Casa CFW-3212: this card is now CONTROLLED by the page shell
// (ip-passthrough.tsx), which owns the one useIpPassthrough() read and hands
// down passthroughMode/isLoading/isSaving/failed/saveSettings. It must not
// call useIpPassthrough() itself (that was the v0.1.12 shape) — doing so
// would issue a second, redundant GET and desync from the shell's state.
export interface IpPassthroughCardProps {
  passthroughMode: PassthroughMode | null;
  targetMac: string | null;
  ipptNat: IpptNat | null;
  usbMode: UsbMode | null;
  dnsProxy: DnsProxy | null;
  isLoading: boolean;
  isSaving: boolean;
  /** True when the shell's read failed and left nothing behind. */
  failed: boolean;
  saveSettings: (data: IpPassthroughApplyData) => Promise<boolean>;
}

const IPPassthroughCard = ({
  passthroughMode,
  isLoading,
  isSaving,
  failed,
  saveSettings,
}: IpPassthroughCardProps) => {
  const { saved, markSaved } = useSaveFlash();
  const [localMode, setLocalMode] = useState<PassthroughMode>("disabled");

  useEffect(() => {
    if (passthroughMode === "eth" || passthroughMode === "disabled") {
      setLocalMode(passthroughMode);
    }
  }, [passthroughMode]);

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    // Casa CFW-3212 supports Disabled or Enabled Ethernet only; the backend
    // (ip_passthrough.sh) ignores target_mac/ippt_nat/usb_mode/dns_proxy, but
    // the shared IpPassthroughApplyData shape still requires them.
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
                <Select
                  value={localMode}
                  onValueChange={(value) => setLocalMode(value as PassthroughMode)}
                  disabled={isSaving}
                >
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

          {failed ? (
            <p className="text-sm text-destructive">Could not read current IP Passthrough state.</p>
          ) : null}

          <div className="flex items-center justify-end gap-2">
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
import re
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

# Upstream v0.1.14+ splits Group B into B1-B4 baskets plus a separate
# DHCPV4DNS call. Keep the Casa mode-gated MIMO enables and RDB IPPT state.
old = '''    # --- B1: CA info + MIMO/timing enables (idempotent ",1" writes) ---
    result=$(qcmd 'AT+QCAINFO=1;+QNWCFG="lte_mimo_layers",1;+QNWCFG="nr5g_mimo_layers",1;+QNWCFG="lte_time_advance",1;+QNWCFG="nr5g_time_advance",1' 2>/dev/null)
    if [ -n "$result" ]; then
        parse_mimo "$result" "$result"
    fi
    sleep "$SIP_DELAY"

    # --- B2: mode-appropriate MIMO read (lte_mimo_layers crashes in SA,
    # nr5g_mimo_layers crashes in LTE/NSA — same gate as before) ---
    if [ "$network_type" = "5G-SA" ]; then
        result=$(qcmd 'AT+QNWCFG="nr5g_mimo_layers"' 2>/dev/null)
        [ -n "$result" ] && parse_mimo "" "$result"
    elif [ "$network_type" = "LTE" ] || [ "$network_type" = "5G-NSA" ]; then
        result=$(qcmd 'AT+QNWCFG="lte_mimo_layers"' 2>/dev/null)
        [ -n "$result" ] && parse_mimo "$result" ""
    fi'''
new = '''    # --- B1: CA info + timing enables (idempotent ",1" writes) ---
    # Casa/RG520N-NA returns ERROR for lte_mimo_layers while camped on 5G-SA,
    # so the MIMO enables move into the mode-gated B2 read below.
    result=$(qcmd 'AT+QCAINFO=1;+QNWCFG="lte_time_advance",1;+QNWCFG="nr5g_time_advance",1' 2>/dev/null)
    sleep "$SIP_DELAY"

    # --- B2: mode-appropriate MIMO enable + read ---
    if [ "$network_type" = "5G-SA" ]; then
        result=$(qcmd 'AT+QNWCFG="nr5g_mimo_layers",1;+QNWCFG="nr5g_mimo_layers"' 2>/dev/null)
        [ -n "$result" ] && parse_mimo "" "$result"
    elif [ "$network_type" = "LTE" ] || [ "$network_type" = "5G-NSA" ]; then
        result=$(qcmd 'AT+QNWCFG="lte_mimo_layers",1;+QNWCFG="lte_mimo_layers"' 2>/dev/null)
        [ -n "$result" ] && parse_mimo "$result" ""
    fi'''
text = text.replace(old, new)

casa_ippt_rdb_block = '''    # Casa CFW-3212 keeps IP Passthrough mapped to ip_handover/RDB state.
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

old = '''    # --- B3: IP Passthrough MPDN rule + NAT ---
    result=$(qcmd 'AT+QMAP="MPDN_RULE";+QMAP="IPPT_NAT"' 2>/dev/null)
    if [ -n "$result" ]; then
        parse_ippt_mpdn_rule "$result"
        parse_ippt_nat "$result"
    fi
    sleep "$SIP_DELAY"

    # --- B4: IP Passthrough usbnet mode (own AT+QCFG subsystem, own call) ---
    result=$(qcmd 'AT+QCFG="usbnet"' 2>/dev/null)
    if [ -n "$result" ]; then
        parse_ippt_usbnet "$result"
    fi'''
text = text.replace(old, casa_ippt_rdb_block)

text = re.sub(
    r'''    # =+\n    # DHCPv4 DNS mode — separate qcmd call, isolated from Group B\.\n(?:    #[^\n]*\n)*?    # =+\n    result=\$\(qcmd 'AT\+QMAP="DHCPV4DNS"' 2>/dev/null\)\n    if \[ -n "\$result" \]; then\n        parse_ippt_dhcpv4dns "\$result"\n    fi\n''',
    '''    # Casa CFW-3212: DHCPv4 DNS mode comes from the RDB IPPT block above.\n''',
    text,
    count=1,
)

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
    new = '''# Casa CFW-3212: ICCID profile auto-apply is user controlled
    # =========================================================================
    # Manual SIM profile apply is always enabled. ICCID-matched boot auto-apply
    # stays off until enabled from the SIM Profiles UI.
    # =========================================================================
    if [ -n "$boot_iccid" ] && profile_auto_apply_enabled; then
        auto_apply_profile "$boot_iccid" "boot"
    else
        qlog_info "Casa profile auto-apply disabled"
    fi'''
    text = text.replace(old, new)

    if "Casa profile auto-apply disabled" not in text:
        text = re.sub(
            r'''    # --- Auto-apply profile matching current SIM \(boot\) ---\n    if \[ -n "\$boot_iccid" \]; then\n        \( \. /usr/lib/qmanager/profile_mgr\.sh && auto_apply_profile "\$boot_iccid" "boot" \)\n    fi''',
            '''    # --- Casa CFW-3212: ICCID profile auto-apply is user controlled ---
    if [ -n "$boot_iccid" ] && profile_auto_apply_enabled; then
        auto_apply_profile "$boot_iccid" "boot"
    else
        qlog_info "Casa profile auto-apply disabled"
    fi''',
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

    # Upstream v0.1.14+ ships qmanager_ping as a POSIX shell daemon (ICMP probe
    # chain; reports last_family for "Carrying traffic on"). Its ping parsing
    # was verified against Casa's ping, so keep it instead of the Casa Rust pin.
    if head -c 2 "$target_ping" | grep -q '^#!'; then
        log "Keeping upstream shell qmanager_ping (upstream no longer ships the Rust daemon)"
        return 0
    fi

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
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    local profile_mgr="$TARGET/scripts/usr/lib/qmanager/profile_mgr.sh"
    local auto_apply_cgi="$TARGET/scripts/www/cgi-bin/quecmanager/profiles/auto_apply.sh"
    local sim_types="$TARGET/types/sim-profile.ts"
    local sim_hook="$TARGET/hooks/use-sim-profiles.ts"
    local profile_page="$TARGET/components/cellular/custom-profiles/custom-profile.tsx"

    [ -f "$settings_sh" ] || fail "Target missing cellular/settings.sh"
    [ -f "$watchcat" ] || fail "Target missing qmanager_watchcat"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"
    [ -f "$profile_mgr" ] || fail "Target missing profile_mgr.sh"
    [ -f "$sim_types" ] || fail "Target missing sim-profile.ts"
    [ -f "$sim_hook" ] || fail "Target missing use-sim-profiles.ts"
    [ -f "$profile_page" ] || fail "Target missing custom-profile.tsx"

    python3 - "$settings_sh" "$watchcat" "$poller" "$profile_mgr" "$sim_types" "$sim_hook" "$profile_page" <<'PY'
from pathlib import Path
import re
import sys

settings, watchcat, poller, profile_mgr, sim_types, sim_hook, profile_page = map(Path, sys.argv[1:8])

text = profile_mgr.read_text()
if 'PROFILE_AUTO_APPLY_CONFIG=' not in text:
    text = text.replace(
        'ACTIVE_PROFILE_FILE="/etc/qmanager/active_profile"\n',
        'ACTIVE_PROFILE_FILE="/etc/qmanager/active_profile"\nPROFILE_AUTO_APPLY_CONFIG="/etc/qmanager/profile_auto_apply.json"\n',
        1,
    )
if 'profile_auto_apply_enabled()' not in text:
    marker = '# =============================================================================\n# Profile CRUD Operations\n# =============================================================================\n'
    helper = '''# --- profile_auto_apply_enabled ------------------------------------------------
# Returns 0 when ICCID-matched profile auto-apply is enabled.
profile_auto_apply_enabled() {
    [ -f "$PROFILE_AUTO_APPLY_CONFIG" ] || return 1
    local enabled
    enabled=$(jq -r '.enabled // false' "$PROFILE_AUTO_APPLY_CONFIG" 2>/dev/null || echo false)
    [ "$enabled" = "true" ] || [ "$enabled" = "1" ]
}

# --- profile_set_auto_apply ----------------------------------------------------
# Stores ICCID auto-apply preference.
profile_set_auto_apply() {
    local enabled="$1"
    local tmp="${PROFILE_AUTO_APPLY_CONFIG}.tmp"
    mkdir -p "$(dirname "$PROFILE_AUTO_APPLY_CONFIG")" 2>/dev/null
    case "$enabled" in
        true|1|yes|on) enabled=true ;;
        *) enabled=false ;;
    esac
    jq -n --argjson enabled "$enabled" '{enabled: $enabled}' > "$tmp" 2>/dev/null || return 1
    mv "$tmp" "$PROFILE_AUTO_APPLY_CONFIG" || return 1
    chmod 640 "$PROFILE_AUTO_APPLY_CONFIG" 2>/dev/null || true
}

'''
    if marker not in text:
        raise SystemExit("profile_mgr CRUD marker not found")
    text = text.replace(marker, helper + marker, 1)
if 'auto_apply_enabled: $auto_apply' not in text:
    text = text.replace(
        '''    # Build final response
    if [ -n "$active_id" ]; then
        jq -n --argjson profiles "$profiles_json" --arg active "$active_id" \\
            '{profiles: $profiles, active_profile_id: $active}'
    else
        jq -n --argjson profiles "$profiles_json" \\
            '{profiles: $profiles, active_profile_id: null}'
    fi
''',
        '''    # Build final response
    local auto_apply_enabled=false
    profile_auto_apply_enabled && auto_apply_enabled=true
    if [ -n "$active_id" ]; then
        jq -n --argjson profiles "$profiles_json" --arg active "$active_id" --argjson auto_apply "$auto_apply_enabled" \\
            '{profiles: $profiles, active_profile_id: $active, auto_apply_enabled: $auto_apply}'
    else
        jq -n --argjson profiles "$profiles_json" --argjson auto_apply "$auto_apply_enabled" \\
            '{profiles: $profiles, active_profile_id: null, auto_apply_enabled: $auto_apply}'
    fi
''',
        1,
    )
profile_mgr.write_text(text)

text = poller.read_text()
if 'profile_auto_apply_enabled() { return 1; }' not in text:
    text = text.replace(
        '''. /usrdata/qmanager/lib/profile_mgr.sh 2>/dev/null || {
    auto_apply_profile() { :; }
}
''',
        '''. /usrdata/qmanager/lib/profile_mgr.sh 2>/dev/null || {
    auto_apply_profile() { :; }
    profile_auto_apply_enabled() { return 1; }
}
''',
        1,
    )
    text = text.replace(
        '''. /usr/lib/qmanager/profile_mgr.sh 2>/dev/null || {
    auto_apply_profile() { :; }
}
''',
        '''. /usr/lib/qmanager/profile_mgr.sh 2>/dev/null || {
    auto_apply_profile() { :; }
    profile_auto_apply_enabled() { return 1; }
}
''',
        1,
    )
poller.write_text(text)

text = settings.read_text()
old = '''                    # Auto-apply matching profile for the new SIM
                    sleep 1  # let SIM initialize after CFUN=1
                    _new_iccid=$(qcmd 'AT+QCCID' 2>/dev/null | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
                    if [ -n "$_new_iccid" ]; then
                        . /usr/lib/qmanager/profile_mgr.sh 2>/dev/null
                        auto_apply_profile "$_new_iccid" "sim_switch"
                    fi
'''
new = '''                    # Casa CFW-3212: ICCID profile auto-apply is user controlled.
                    sleep 1  # let SIM initialize after CFUN=1
                    _new_iccid=$(qcmd 'AT+QCCID' 2>/dev/null | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
                    if [ -n "$_new_iccid" ]; then
                        . /usrdata/qmanager/lib/profile_mgr.sh 2>/dev/null || . /usr/lib/qmanager/profile_mgr.sh 2>/dev/null
                        if profile_auto_apply_enabled; then
                            auto_apply_profile "$_new_iccid" "sim_switch"
                        else
                            qlog_info "Casa profile auto-apply disabled after SIM switch"
                        fi
                    fi
'''
if old in text:
    text = text.replace(old, new, 1)
elif "profile_auto_apply_enabled" not in text:
    # Upstream v0.1.14+: sim_db registration precedes the profile_mgr source.
    text = re.sub(
        r'^( +)\. /usr/lib/qmanager/profile_mgr\.sh 2>/dev/null\n\1auto_apply_profile "\$_new_iccid" "sim_switch"\n',
        lambda m: (
            f'{m.group(1)}# Casa CFW-3212: ICCID profile auto-apply is user controlled.\n'
            f'{m.group(1)}. /usrdata/qmanager/lib/profile_mgr.sh 2>/dev/null || . /usr/lib/qmanager/profile_mgr.sh 2>/dev/null\n'
            f'{m.group(1)}if profile_auto_apply_enabled; then\n'
            f'{m.group(1)}    auto_apply_profile "$_new_iccid" "sim_switch"\n'
            f'{m.group(1)}else\n'
            f'{m.group(1)}    qlog_info "Casa profile auto-apply disabled after SIM switch"\n'
            f'{m.group(1)}fi\n'
        ),
        text,
        count=1,
        flags=re.M,
    )
settings.write_text(text)

text = watchcat.read_text()
text = text.replace(
    '''    # Auto-apply matching profile for the reverted SIM
    local _revert_iccid
    _revert_iccid=$(qcmd 'AT+QCCID' 2>/dev/null | grep '+QCCID:' | sed 's/+QCCID: //g' | tr -d '\\r ')
    [ -n "$_revert_iccid" ] && auto_apply_profile "$_revert_iccid" "watchdog_revert"
''',
    '''    # Casa CFW-3212 is single-SIM hardware; Watchdog SIM recovery is disabled.
    qlog_info "Casa Watchdog SIM revert skipped on single-SIM hardware"
''',
)
text = re.sub(
    r'^( +)\[ -n "\$_revert_iccid" \] && auto_apply_profile "\$_revert_iccid" "watchdog_revert"\n',
    lambda m: (
        f"{m.group(1)}# Casa CFW-3212 is single-SIM hardware; Watchdog SIM recovery is disabled.\n"
        f'{m.group(1)}qlog_info "Casa Watchdog SIM revert skipped on single-SIM hardware"\n'
    ),
    text,
    count=1,
    flags=re.M,
)
text = text.replace(
    '''            # Auto-apply matching profile for the new SIM
            if [ -n "$curr_iccid" ]; then
                auto_apply_profile "$curr_iccid" "watchdog"
            fi
''',
    '''            # Casa CFW-3212 is single-SIM hardware; Watchdog SIM failover is disabled.
            qlog_info "Casa Watchdog SIM failover profile apply skipped on single-SIM hardware"
''',
)
watchcat.write_text(text)

text = sim_types.read_text()
if 'auto_apply_enabled' not in text:
    text = text.replace(
        '  active_profile_id: string | null;\n',
        '  active_profile_id: string | null;\n  /** Whether ICCID-matched profiles auto-apply on boot and user SIM-switch actions */\n  auto_apply_enabled?: boolean;\n',
        1,
    )
sim_types.write_text(text)

text = sim_hook.read_text()
if 'autoApplyEnabled' not in text:
    text = text.replace(
        '  activeProfileId: string | null;\n',
        '  activeProfileId: string | null;\n  /** Whether ICCID-matched profiles auto-apply automatically */\n  autoApplyEnabled: boolean;\n  /** True while saving the auto-apply setting */\n  isSavingAutoApply: boolean;\n',
        1,
    )
    if 'setAutoApplyEnabled: (enabled: boolean) => Promise<boolean>;' not in text:
        old_iface = '  deactivateProfile: () => Promise<boolean>;\n'
        if old_iface in text:
            text = text.replace(
                old_iface,
                old_iface + '  /** Enable/disable ICCID-matched profile auto-apply */\n  setAutoApplyEnabled: (enabled: boolean) => Promise<boolean>;\n',
                1,
            )
        else:
            # Upstream v0.1.14+: deactivateProfile's signature changed
            # (opts?: DeactivateOptions) => Promise<DeactivateResult>, and
            # `refresh` is now the last field before the interface closes.
            old_iface_v16 = '  /** Manually refresh the profile list */\n  refresh: () => void;\n}\n'
            if old_iface_v16 not in text:
                raise SystemExit("use-sim-profiles UseSimProfilesReturn interface anchor not found")
            text = text.replace(
                old_iface_v16,
                '  /** Manually refresh the profile list */\n  refresh: () => void;\n  /** Enable/disable ICCID-matched profile auto-apply */\n  setAutoApplyEnabled: (enabled: boolean) => Promise<boolean>;\n}\n',
                1,
            )
    text = text.replace(
        '  const [isLoading, setIsLoading] = useState(true);\n  const [error, setError] = useState<string | null>(null);\n',
        '  const [isLoading, setIsLoading] = useState(true);\n  const [error, setError] = useState<string | null>(null);\n  const [autoApplyEnabled, setAutoApplyEnabledState] = useState(false);\n  const [isSavingAutoApply, setIsSavingAutoApply] = useState(false);\n',
        1,
    )
    text = text.replace(
        '      setProfiles(data.profiles || []);\n      setActiveProfileId(data.active_profile_id || null);\n',
        '      setProfiles(data.profiles || []);\n      setActiveProfileId(data.active_profile_id || null);\n      setAutoApplyEnabledState(Boolean(data.auto_apply_enabled));\n',
        1,
    )
    marker = '  // ---------------------------------------------------------------------------\n  // Fetch a single profile\n  // ---------------------------------------------------------------------------\n'
    if marker not in text:
        marker = '  // ---------------------------------------------------------------------------\n  // Get single profile (for edit form)\n  // ---------------------------------------------------------------------------\n'
    addition = '''  // ---------------------------------------------------------------------------
  // Toggle ICCID auto-apply
  // ---------------------------------------------------------------------------
  const setAutoApplyEnabled = useCallback(
    async (enabled: boolean): Promise<boolean> => {
      setError(null);
      setIsSavingAutoApply(true);
      try {
        const resp = await authFetch(`${CGI_BASE}/auto_apply.sh`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ enabled }),
        });

        if (!resp.ok) {
          throw new Error(`HTTP ${resp.status}: ${resp.statusText}`);
        }

        const result: ProfileApiResponse & { enabled?: boolean } =
          await resp.json();

        if (!result.success) {
          setError(
            result.detail || result.error || "Failed to update auto-apply"
          );
          return false;
        }

        setAutoApplyEnabledState(Boolean(result.enabled));
        return true;
      } catch (err) {
        const msg =
          err instanceof Error ? err.message : "Failed to update auto-apply";
        setError(msg);
        return false;
      } finally {
        setIsSavingAutoApply(false);
      }
    },
    []
  );

'''
    if marker not in text:
        raise SystemExit("use-sim-profiles single-profile marker not found")
    text = text.replace(marker, addition + marker, 1)
    text = text.replace(
        '    profiles,\n    activeProfileId,\n',
        '    profiles,\n    activeProfileId,\n    autoApplyEnabled,\n    isSavingAutoApply,\n',
        1,
    )
    text = text.replace(
        '    deactivateProfile,\n    getProfile,\n',
        '    deactivateProfile,\n    setAutoApplyEnabled,\n    getProfile,\n',
        1,
    )
sim_hook.write_text(text)

text = profile_page.read_text()
if 'autoApplyEnabled' not in text:
    if 'from "sonner"' not in text:
        text = text.replace(
            'import React, { useState, useCallback } from "react";\n',
            'import React, { useState, useCallback } from "react";\nimport { toast } from "sonner";\n',
            1,
        )
    text = text.replace(
        'import type { SimProfile } from "@/types/sim-profile";\n',
        'import type { SimProfile } from "@/types/sim-profile";\nimport { Switch } from "@/components/ui/switch";\n',
        1,
    )
    text = text.replace(
        '''    deleteProfile,
    deactivateProfile,
    getProfile,
    refresh,
  } = useSimProfiles();
''',
        '''    deleteProfile,
    deactivateProfile,
    setAutoApplyEnabled,
    getProfile,
    refresh,
    autoApplyEnabled,
    isSavingAutoApply,
  } = useSimProfiles();
''',
        1,
    )
    handler = '''  const handleAutoApplyToggle = useCallback(
    async (enabled: boolean) => {
      const success = await setAutoApplyEnabled(enabled);
      if (success) {
        toast.success(
          enabled ? "ICCID auto-apply enabled." : "ICCID auto-apply disabled."
        );
      } else {
        toast.error("Failed to update ICCID auto-apply.");
      }
    },
    [setAutoApplyEnabled]
  );

'''
    marker = '''  // ---------------------------------------------------------------------------
  // Handle Edit: fetch full profile, switch form to edit mode
  // ---------------------------------------------------------------------------
'''
    if marker in text:
        text = text.replace(marker, handler + marker, 1)
    else:
        # Upstream v0.1.14+: no "Handle Edit" comment banner; anchor on the
        # standalone handleNewProfile callback instead (stable, self-contained).
        marker_v16 = '''  const handleNewProfile = useCallback(() => {
    setEditingProfile(null);
    setFormInitialTab("identity");
    setFormOpen(true);
  }, []);
'''
        if marker_v16 not in text:
            raise SystemExit("custom-profile.tsx handleNewProfile/Handle-Edit anchor not found")
        text = text.replace(marker_v16, handler + marker_v16, 1)

    old_header = '''      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">Custom SIM Profile</h1>
        <p className="text-muted-foreground">
          Bundle APN, IMEI, and TTL/HL settings into one-click profiles.
        </p>
      </div>
'''
    if old_header not in text:
        old_header = '''      <div className="mb-6">
        <h1 className="text-3xl font-bold mb-2">Custom SIM Profiles</h1>
        <p className="text-muted-foreground">
          Bundle APN, IMEI, and TTL/HL settings into one-click profiles.
        </p>
      </div>
'''
    new_header = '''      <div className="mb-6 flex flex-col gap-4 @2xl/main:flex-row @2xl/main:items-start @2xl/main:justify-between">
        <div>
          <h1 className="text-3xl font-bold mb-2">Custom SIM Profiles</h1>
          <p className="text-muted-foreground">
            Bundle APN, IMEI, and TTL/HL settings into one-click profiles.
          </p>
        </div>
        <div className="flex min-w-64 items-center justify-between gap-4 rounded-md border bg-card px-4 py-3">
          <div className="space-y-1">
            <div className="text-sm font-medium">ICCID auto-apply</div>
            <div className="text-xs text-muted-foreground">
              Apply matching profiles on boot, SIM switch, and Watchdog SIM recovery.
            </div>
          </div>
          <Switch
            checked={autoApplyEnabled}
            disabled={isSavingAutoApply}
            onCheckedChange={handleAutoApplyToggle}
            aria-label="Toggle ICCID auto-apply"
          />
        </div>
      </div>
'''
    if old_header in text:
        text = text.replace(old_header, new_header, 1)
    else:
        # Upstream v0.1.14+: the local <h1> was replaced by <CellularPageHeader>.
        # Splice the toggle in as its own card, immediately after the header,
        # rather than fighting the header's own actions layout.
        header_anchor = '''        />
      </motion.div>

      {/* --- What is in force right now'''
        if header_anchor not in text:
            raise SystemExit("custom-profile header block not found")
        toggle_card = '''        />
      </motion.div>

      {/* Casa CFW-3212: ICCID-matched profile auto-apply is user controlled. */}
      <motion.div variants={staggerItem}>
        <div className="flex min-w-64 items-center justify-between gap-4 rounded-md border bg-card px-4 py-3">
          <div className="space-y-1">
            <div className="text-sm font-medium">ICCID auto-apply</div>
            <div className="text-xs text-muted-foreground">
              Apply matching profiles on boot, SIM switch, and Watchdog SIM recovery.
            </div>
          </div>
          <Switch
            checked={autoApplyEnabled}
            disabled={isSavingAutoApply}
            onCheckedChange={handleAutoApplyToggle}
            aria-label="Toggle ICCID auto-apply"
          />
        </div>
      </motion.div>

      {/* --- What is in force right now'''
        text = text.replace(header_anchor, toggle_card, 1)
profile_page.write_text(text)
PY

    cat > "$auto_apply_cgi" <<'EOF'
#!/bin/sh
. /usrdata/qmanager/lib/cgi_base.sh 2>/dev/null || . /usr/lib/qmanager/cgi_base.sh
qlog_init "cgi_profile_auto_apply"
cgi_headers
cgi_handle_options

. /usrdata/qmanager/lib/profile_mgr.sh 2>/dev/null || . /usr/lib/qmanager/profile_mgr.sh || {
    cgi_error "profile_mgr_unavailable" "Profile manager is unavailable"
    exit 0
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    enabled=false
    profile_auto_apply_enabled && enabled=true
    jq -n --argjson success true --argjson enabled "$enabled" \
        '{success: $success, enabled: $enabled}'
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post
    input="$POST_DATA"
    enabled=$(printf '%s' "$input" | jq -r '.enabled // false' 2>/dev/null || echo false)
    case "$enabled" in
        true|1|yes|on) enabled=true ;;
        *) enabled=false ;;
    esac
    if ! profile_set_auto_apply "$enabled"; then
        cgi_error "write_failed" "Could not save ICCID auto-apply setting"
        exit 0
    fi
    jq -n --argjson success true --argjson enabled "$enabled" \
        '{success: $success, enabled: $enabled}'
    exit 0
fi

cgi_error "method_not_allowed" "Unsupported request method"
EOF
    chmod 755 "$auto_apply_cgi"

    grep -q "profile_auto_apply_enabled" "$profile_mgr" \
        || fail "Could not add profile auto-apply runtime setting"
    grep -q "profile_auto_apply_enabled" "$settings_sh" \
        || fail "Could not add SIM-switch profile auto-apply toggle check"
    grep -q "Casa Watchdog SIM revert skipped on single-SIM hardware" "$watchcat" \
        || fail "Could not disable watchdog revert profile auto-apply"
    grep -q "Casa Watchdog SIM failover profile apply skipped on single-SIM hardware" "$watchcat" \
        || fail "Could not disable watchdog failover profile auto-apply"
    grep -q "autoApplyEnabled" "$sim_hook" \
        || fail "Could not add SIM profile auto-apply hook state"
    grep -q "aria-label=\"Toggle ICCID auto-apply\"" "$profile_page" \
        || fail "Could not add SIM profile auto-apply UI toggle"
}

patch_casa_iccid_and_staleness_cfw3212() {
    local profile_mgr="$TARGET/scripts/usr/lib/qmanager/profile_mgr.sh"
    local poller="$TARGET/scripts/usr/bin/qmanager_poller"
    local table="$TARGET/components/cellular/custom-profiles/custom-profile-table.tsx"
    local view="$TARGET/components/cellular/custom-profiles/custom-profile-view.tsx"
    local hero="$TARGET/components/cellular/custom-profiles/active-profile-hero.tsx"
    local modem_hook="$TARGET/hooks/use-modem-status.ts"

    [ -f "$profile_mgr" ] || fail "Target missing profile_mgr.sh"
    [ -f "$poller" ] || fail "Target missing qmanager_poller"
    [ -f "$modem_hook" ] || fail "Target missing use-modem-status.ts"
    # Upstream v0.1.14+ dropped custom-profile-table.tsx; the row-level and
    # hero-level ICCID mismatch UI moved into custom-profile-view.tsx and
    # active-profile-hero.tsx respectively. Neither canonicalizes the ICCID
    # (confirmed: custom-profile-view.tsx still does a naive string compare),
    # so the Casa normalization is still needed there.
    if [ ! -f "$table" ]; then
        table=""
        [ -f "$view" ] || fail "Target missing custom-profile-table.tsx and custom-profile-view.tsx"
        [ -f "$hero" ] || fail "Target missing active-profile-hero.tsx"
    else
        view=""
        hero=""
    fi

    python3 - "$profile_mgr" "$poller" "$table" "$view" "$hero" "$modem_hook" <<'PY'
from pathlib import Path
import sys

profile_mgr, poller, table, view, hero, modem_hook = sys.argv[1:7]
profile_mgr, poller, modem_hook = Path(profile_mgr), Path(poller), Path(modem_hook)
table = Path(table) if table else None
view = Path(view) if view else None
hero = Path(hero) if hero else None

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

if table is not None:
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

# Upstream v0.1.14+: custom-profile-table.tsx was replaced by
# custom-profile-view.tsx (row-level mismatch status via deriveStatus()) and
# active-profile-hero.tsx (hero-level mismatch banner). Neither canonicalizes
# the ICCID client-side (custom-profile-view.tsx says so explicitly in a
# comment), so both still need the Casa normalization.
if view is not None:
    text = view.read_text()
    if "function normalizeIccid" not in text:
        marker = 'type ProfileStatus = "active" | "mismatch" | "inactive";\n'
        if marker not in text:
            raise SystemExit("custom-profile-view.tsx ProfileStatus marker not found")
        text = text.replace(
            marker,
            marker + '''
function normalizeIccid(value: string | null | undefined): string {
  return (value ?? "").trim().replace(/[Ff]$/, "");
}
''',
            1,
        )
    if 'normalizedProfileIccid' not in text:
        old = '''  if (!isActive) return "inactive";
  if (profileIccid && currentIccid && profileIccid !== currentIccid) {
    return "mismatch";
  }
  return "active";
'''
        if old not in text:
            raise SystemExit("custom-profile-view.tsx deriveStatus body not found")
        text = text.replace(
            old,
            '''  if (!isActive) return "inactive";
  const normalizedProfileIccid = normalizeIccid(profileIccid);
  const normalizedCurrentIccid = normalizeIccid(currentIccid);
  if (
    normalizedProfileIccid &&
    normalizedCurrentIccid &&
    normalizedProfileIccid !== normalizedCurrentIccid
  ) {
    return "mismatch";
  }
  return "active";
''',
            1,
        )
    view.write_text(text)

if hero is not None:
    text = hero.read_text()
    if "function normalizeIccid" not in text:
        marker = 'export interface ActiveProfileHeroProps {\n'
        if marker not in text:
            raise SystemExit("active-profile-hero.tsx ActiveProfileHeroProps marker not found")
        text = text.replace(
            marker,
            '''function normalizeIccid(value: string | null | undefined): string {
  return (value ?? "").trim().replace(/[Ff]$/, "");
}

''' + marker,
            1,
        )
    if 'normalizedProfileIccid' not in text:
        old = '''  const isMismatch =
    Boolean(profile.sim_iccid) &&
    Boolean(currentIccid) &&
    profile.sim_iccid !== currentIccid;
'''
        if old not in text:
            raise SystemExit("active-profile-hero.tsx isMismatch block not found")
        text = text.replace(
            old,
            '''  const normalizedProfileIccid = normalizeIccid(profile.sim_iccid);
  const normalizedCurrentIccid = normalizeIccid(currentIccid);
  const isMismatch =
    Boolean(normalizedProfileIccid) &&
    Boolean(normalizedCurrentIccid) &&
    normalizedProfileIccid !== normalizedCurrentIccid;
''',
            1,
        )
    hero.write_text(text)

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
    old_v12 = '''      // Check staleness: compare the JSON timestamp to current time
      const now = Math.floor(Date.now() / 1000);
      const age = now - json.timestamp;
      setIsStale(age > STALE_THRESHOLD_SECONDS);
'''
    if old_v12 in text:
        text = text.replace(
            old_v12,
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
    else:
        # Upstream v0.1.14+: `nowMs` is already read once above (shared with
        # receivedAtMs) and the staleness comment/formula changed slightly.
        old_v16 = '''      const age = Math.floor(nowMs / 1000) - json.timestamp;
      setIsStale(age > STALE_THRESHOLD_SECONDS);
'''
        if old_v16 not in text:
            raise SystemExit("use-modem-status.ts staleness block not found")
        text = text.replace(
            old_v16,
            '''      // Casa CFW-3212: prefer an advancing router timestamp over raw clock
      // comparison — some Casa units boot with an incorrect wall clock until
      // time sync, which the modem-vs-browser age check above would flag as
      // permanently stale.
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
    if [ -n "$table" ]; then
        grep -q "normalizeIccid" "$table" \
            || fail "custom-profile-table.tsx missing ICCID normalization"
        grep -q "function normalizeIccid" "$table" \
            || fail "custom-profile-table.tsx missing normalizeIccid function"
    else
        grep -q "normalizeIccid" "$view" \
            || fail "custom-profile-view.tsx missing ICCID normalization"
        grep -q "function normalizeIccid" "$view" \
            || fail "custom-profile-view.tsx missing normalizeIccid function"
        grep -q "normalizeIccid" "$hero" \
            || fail "active-profile-hero.tsx missing ICCID normalization"
    fi
    grep -q "lastTimestampAdvanceMsRef" "$modem_hook" \
        || fail "use-modem-status.ts missing Casa timestamp staleness patch"
}

patch_logging_cfw3212() {
    local qlog="$TARGET/scripts/usr/lib/qmanager/qlog.sh"
    local logs_card="$TARGET/components/monitoring/logs/system-logs-card.tsx"
    local data_used="$TARGET/scripts/www/cgi-bin/quecmanager/network/data_used.sh"
    # v0.1.14+ (== v0.1.16) split the old single-file logs card apart; the
    # timestamp math that used to live in system-logs-card.tsx now lives in
    # components/system-settings/logs/derive.ts (system-logs-card.tsx is gone).
    local logs_derive="$TARGET/components/system-settings/logs/derive.ts"

    [ -f "$qlog" ] || fail "Target missing qlog.sh"
    if [ ! -f "$logs_card" ]; then
        logs_card="$TARGET/components/system-settings/logs/system-logs-card.tsx"
    fi
    if [ ! -f "$logs_card" ] && [ ! -f "$logs_derive" ]; then
        fail "Target missing system logs timestamp component (system-logs-card.tsx or system-settings/logs/derive.ts)"
    fi

    local py_bin
    py_bin="$(command -v python3 || command -v python || true)"
    [ -n "$py_bin" ] || fail "python3/python is required to patch logging safely"

    "$py_bin" - "$qlog" "$logs_card" "$logs_derive" "$data_used" <<'PY'
from pathlib import Path
import sys

qlog_path = Path(sys.argv[1])
logs_card_path = Path(sys.argv[2])
logs_derive_path = Path(sys.argv[3])
data_used_path = Path(sys.argv[4])

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

# v0.1.12 layout: system-logs-card.tsx owns both parsing and rendering.
logs_card = logs_card_path.read_text() if logs_card_path.exists() else ""
if logs_card:
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

# v0.1.14+ layout: components/system-settings/logs/derive.ts::parseLogTimestamp
# is the only place that turns a device timestamp into epoch seconds; LogRow
# no longer renders a raw "... UTC" title, so only the parser needs the same
# offset-awareness the v0.1.12 formatLogTimestamp patch gave it.
logs_derive = logs_derive_path.read_text() if logs_derive_path.exists() else ""
if logs_derive:
    logs_derive = logs_derive.replace(
        "const TIMESTAMP = /^(\\d{4})-(\\d{2})-(\\d{2})[ T](\\d{2}):(\\d{2}):(\\d{2})$/;",
        "const TIMESTAMP =\n"
        "  /^(\\d{4})-(\\d{2})-(\\d{2})[ T](\\d{2}):(\\d{2}):(\\d{2})(Z|[+-]\\d{2}:?\\d{2})?$/;",
    )
    logs_derive = logs_derive.replace(
        """export function parseLogTimestamp(raw: string): number | null {
  const m = TIMESTAMP.exec(raw.trim());
  if (!m) return null;
  const at = new Date(
    Number(m[1]),
    Number(m[2]) - 1,
    Number(m[3]),
    Number(m[4]),
    Number(m[5]),
    Number(m[6]),
  );
  return Number.isNaN(at.getTime()) ? null : Math.floor(at.getTime() / 1000);
}""",
        """export function parseLogTimestamp(raw: string): number | null {
  const m = TIMESTAMP.exec(raw.trim());
  if (!m) return null;
  if (m[7]) {
    // Casa's qlog.sh writes `%Y-%m-%dT%H:%M:%S%z` (an explicit offset) so the
    // UI never has to guess whether the router logged in UTC or local time;
    // let Date parse the offset instead of assuming the viewer's own zone.
    const at = new Date(`${m[1]}-${m[2]}-${m[3]}T${m[4]}:${m[5]}:${m[6]}${m[7]}`);
    return Number.isNaN(at.getTime()) ? null : Math.floor(at.getTime() / 1000);
  }
  const at = new Date(
    Number(m[1]),
    Number(m[2]) - 1,
    Number(m[3]),
    Number(m[4]),
    Number(m[5]),
    Number(m[6]),
  );
  return Number.isNaN(at.getTime()) ? null : Math.floor(at.getTime() / 1000);
}""",
    )
    logs_derive_path.write_text(logs_derive)

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
    if [ -f "$logs_card" ] && grep -q "formatLogTimestamp" "$logs_card"; then
        grep -q "hasTimeZone" "$logs_card" \
            || fail "Could not apply system logs timestamp patch"
    fi
    if [ -f "$logs_derive" ]; then
        grep -q "Casa's qlog.sh writes" "$logs_derive" \
            || fail "Could not apply timezone-aware system logs parser patch"
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
import re
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
poller, _n = re.subn(
    r"^du_modem_reset_count=0\n",
    "du_modem_reset_count=0\ndu_last_flush_ts=0\n",
    poller,
    count=1,
    flags=re.M,
)
if not _n:
    raise SystemExit("poller flush timestamp state marker not found")
poller = poller.replace(
    "# to DATA_USED_FILE each tick.",
    "# to a RAM-backed hot file each tick and to persistent flash on a bounded cadence.",
    1,
)
# Shape-independent: upstream changes the jq field list between releases
# (v0.1.12 orientation_history_swapped, v0.1.14+ orientation), so only the
# function header and the final tmp/mv line are rewritten.
poller = replace_once(
    poller,
    """write_data_used_state() {
    mkdir -p /usrdata/qmanager 2>/dev/null
""",
    """_write_data_used_state_file() {
    local _file="$1" _tmp _dir
    [ -n "$_file" ] || return 1
    _tmp="${_file}.tmp"
    _dir=$(dirname "$_file")
    mkdir -p "$_dir" 2>/dev/null || return 1
""",
    "poller write_data_used_state header",
)
poller = replace_once(
    poller,
    """        }' > "$DATA_USED_TMP" && mv "$DATA_USED_TMP" "$DATA_USED_FILE"
}
""",
    """        }' > "$_tmp" && mv "$_tmp" "$_file"
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
""",
    "poller write_data_used_state tail",
)
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
# Upstream v0.1.14+ already re-asserts a root-owned 0755 spool on every boot.
if "install -d -o root -g root -m 0755 /var/spool/cron/crontabs" not in setup:
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
    grep -q -e 'chmod 775 /var/spool/cron /var/spool/cron/crontabs' \
        -e 'install -d -o root -g root -m 0755 /var/spool/cron/crontabs' "$setup" \
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
import re
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
# Upstream moves comments/self-heal code around the chown between releases;
# anchor on the chown line itself and add the Casa mode tightening after it.
if "find /etc/qmanager -type d -exec chmod 750" not in setup:
    setup, _n = re.subn(
        r"^chown -R www-data:www-data /etc/qmanager\n",
        """chown -R www-data:www-data /etc/qmanager
# Casa CFW-3212: deny world access to persistent config.
find /etc/qmanager -type d -exec chmod 750 {} \\; 2>/dev/null || true
find /etc/qmanager -type f -exec chmod 640 {} \\; 2>/dev/null || true
[ -f /etc/qmanager/auth.json ] && chmod 600 /etc/qmanager/auth.json
""",
        setup,
        count=1,
        flags=re.M,
    )
    if not _n:
        raise SystemExit("qmanager_setup config permissions marker not found")
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

patch_ai62_qmanager_iptables_helper_cfw3212() {
    local platform="$TARGET/scripts/usr/lib/qmanager/platform.sh"
    local v4="$TARGET/scripts/usr/bin/qmanager_iptables"
    local v6="$TARGET/scripts/usr/bin/qmanager_ip6tables"

    [ -f "$platform" ] || fail "Target missing platform.sh for iptables helper patch"

    cat > "$v4" <<'EOF'
#!/bin/sh
# qmanager_iptables — AI-62 phase 2: narrow www-data iptables to TTL mangle rules only.
IPTABLES="/usr/sbin/iptables"

_ttl_valid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] && [ "$1" -le 255 ]
}

_allow_ttl_mangle() {
    [ "$1" = "-w" ] && [ "$2" = "5" ] && [ "$3" = "-t" ] && [ "$4" = "mangle" ] || return 1
    case "$5" in
        -vnL)
            [ "$6" = "POSTROUTING" ] && [ "$#" -eq 6 ]
            ;;
        -D|-I)
            [ "$6" = "POSTROUTING" ] && [ "$7" = "-o" ] && [ "$8" = "rmnet+" ] \
                && [ "$9" = "-j" ] && [ "${10}" = "TTL" ] && [ "${11}" = "--ttl-set" ] \
                && _ttl_valid "${12}" && [ "$#" -eq 12 ]
            ;;
        *)
            return 1
            ;;
    esac
}

if _allow_ttl_mangle "$@"; then
    exec "$IPTABLES" "$@"
fi

echo "qmanager_iptables: denied (only TTL mangle POSTROUTING on rmnet+ allowed)" >&2
exit 1
EOF

    cat > "$v6" <<'EOF'
#!/bin/sh
# qmanager_ip6tables — AI-62 phase 2: narrow www-data ip6tables to HL mangle rules only.
IP6TABLES="/usr/sbin/ip6tables"

_hl_valid() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 0 ] && [ "$1" -le 255 ]
}

_allow_hl_mangle() {
    [ "$1" = "-w" ] && [ "$2" = "5" ] && [ "$3" = "-t" ] && [ "$4" = "mangle" ] || return 1
    case "$5" in
        -vnL)
            [ "$6" = "POSTROUTING" ] && [ "$#" -eq 6 ]
            ;;
        -D|-I)
            [ "$6" = "POSTROUTING" ] && [ "$7" = "-o" ] && [ "$8" = "rmnet+" ] \
                && [ "$9" = "-j" ] && [ "${10}" = "HL" ] && [ "${11}" = "--hl-set" ] \
                && _hl_valid "${12}" && [ "$#" -eq 12 ]
            ;;
        *)
            return 1
            ;;
    esac
}

if _allow_hl_mangle "$@"; then
    exec "$IP6TABLES" "$@"
fi

echo "qmanager_ip6tables: denied (only HL mangle POSTROUTING on rmnet+ allowed)" >&2
exit 1
EOF

    chmod 755 "$v4" "$v6"

    python3 - "$platform" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old4 = 'run_iptables() {\n    $_SUDO /usr/sbin/iptables "$@"\n}'
new4 = 'run_iptables() {\n    $_SUDO /usr/bin/qmanager_iptables "$@"\n}'
old6 = 'run_ip6tables() {\n    $_SUDO /usr/sbin/ip6tables "$@"\n}'
new6 = 'run_ip6tables() {\n    $_SUDO /usr/bin/qmanager_ip6tables "$@"\n}'
if '/usr/bin/qmanager_iptables' in text:
    if old4 in text or old6 in text:
        raise SystemExit('platform.sh partially patched for qmanager_iptables?')
    raise SystemExit(0)
if old4 not in text or old6 not in text:
    raise SystemExit('platform.sh run_iptables block not found for iptables helper patch')
path.write_text(text.replace(old4, new4).replace(old6, new6))
PY

    grep -q '/usr/bin/qmanager_iptables' "$platform" \
        || fail "platform.sh missing qmanager_iptables wrapper"
    grep -q '/usr/bin/qmanager_ip6tables' "$platform" \
        || fail "platform.sh missing qmanager_ip6tables wrapper"
    if grep -q '/usr/sbin/iptables' "$platform"; then
        fail "platform.sh still calls raw /usr/sbin/iptables after helper patch"
    fi
    log "Installed qmanager_iptables/ip6tables helpers and patched platform.sh"
}

patch_ai62_qmanager_tailscale_cli_helper_cfw3212() {
    local cgi="$TARGET/scripts/www/cgi-bin/quecmanager/vpn/tailscale.sh"
    local helper="$TARGET/scripts/usr/bin/qmanager_tailscale_cli"

    [ -f "$cgi" ] || fail "Target missing tailscale.sh for Tailscale CLI helper patch"

    cat > "$helper" <<'EOF'
#!/bin/sh
# qmanager_tailscale_cli — AI-62 phase 2: narrow www-data Tailscale CLI access.
TAILSCALE="/usrdata/tailscale/tailscale"

_deny() {
    echo "qmanager_tailscale_cli: denied Tailscale command" >&2
    exit 1
}

[ -x "$TAILSCALE" ] || {
    echo "qmanager_tailscale_cli: Tailscale is not installed" >&2
    exit 1
}

case "${1:-}" in
    version)
        [ "$#" -eq 1 ] || _deny
        exec "$TAILSCALE" version
        ;;
    status)
        [ "$#" -eq 2 ] && [ "$2" = "--json" ] || _deny
        exec "$TAILSCALE" status --json
        ;;
    up)
        if [ "$#" -eq 3 ] && [ "$2" = "--reset" ] && [ "$3" = "--accept-dns=false" ]; then
            exec "$TAILSCALE" up --reset --accept-dns=false
        fi
        if [ "$#" -eq 4 ] && [ "$2" = "--reset" ] && [ "$3" = "--accept-dns=false" ] && [ "$4" = "--ssh" ]; then
            exec "$TAILSCALE" up --reset --accept-dns=false --ssh
        fi
        _deny
        ;;
    down)
        [ "$#" -eq 1 ] || _deny
        exec "$TAILSCALE" down
        ;;
    logout)
        [ "$#" -eq 1 ] || _deny
        exec "$TAILSCALE" logout
        ;;
    set)
        [ "$#" -eq 2 ] || _deny
        case "$2" in
            --ssh=true|--ssh=false)
                exec "$TAILSCALE" set "$2"
                ;;
            *)
                _deny
                ;;
        esac
        ;;
    *)
        _deny
        ;;
esac
EOF
    chmod 755 "$helper"

    python3 - "$cgi" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old_ts_cmd = 'ts_cmd() {\n    $_SUDO "$TAILSCALE_BIN" "$@"\n}'
new_ts_cmd = 'ts_cmd() {\n    $_SUDO /usrdata/bin/qmanager_tailscale_cli "$@"\n}'
old_version = 'get_ts_version() {\n    $_SUDO "$TAILSCALE_BIN" version 2>/dev/null | head -1 | awk \'{print $1}\'\n}'
new_version = 'get_ts_version() {\n    ts_cmd version 2>/dev/null | head -1 | awk \'{print $1}\'\n}'

if '/usrdata/bin/qmanager_tailscale_cli' in text:
    if old_ts_cmd in text or old_version in text:
        raise SystemExit('tailscale.sh partially patched for qmanager_tailscale_cli?')
    raise SystemExit(0)
if old_ts_cmd not in text:
    raise SystemExit('tailscale.sh ts_cmd block not found for Tailscale CLI helper patch')
if old_version not in text:
    raise SystemExit('tailscale.sh get_ts_version block not found for Tailscale CLI helper patch')
path.write_text(text.replace(old_version, new_version).replace(old_ts_cmd, new_ts_cmd))
PY

    grep -q '/usrdata/bin/qmanager_tailscale_cli' "$cgi" \
        || fail "tailscale.sh missing qmanager_tailscale_cli wrapper"
    grep -q '\$_SUDO /usrdata/bin/qmanager_tailscale_cli "\$@"' "$cgi" \
        || fail "tailscale.sh ts_cmd does not call qmanager_tailscale_cli"
    if grep -q '\$_SUDO "\$TAILSCALE_BIN"' "$cgi"; then
        fail "tailscale.sh still sudo-runs raw Tailscale binary after helper patch"
    fi
    log "Installed qmanager_tailscale_cli helper and patched tailscale.sh"
}

patch_ai62_ssh_password_sha512_cfw3212() {
    local helper="$TARGET/scripts/usr/bin/qmanager_set_ssh_password"
    [ -f "$helper" ] || fail "Target missing qmanager_set_ssh_password"

    if grep -q 'openssl passwd -6' "$helper"; then
        log "qmanager_set_ssh_password already uses SHA512-crypt"
        return 0
    fi

    grep -q 'openssl passwd -1' "$helper" \
        || fail "qmanager_set_ssh_password missing expected MD5-crypt hash line"

    sed -i 's/openssl passwd -1/openssl passwd -6/g' "$helper"
    sed -i 's/MD5-crypt/SHA512-crypt/g' "$helper"
    sed -i 's/\$1\$/\$6\$/g' "$helper"

    grep -q 'openssl passwd -6' "$helper" \
        || fail "Could not patch qmanager_set_ssh_password to SHA512-crypt"
    log "Patched qmanager_set_ssh_password to SHA512-crypt (openssl passwd -6)"
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
www-data ALL=(root) NOPASSWD: /bin/ln -sf /etc/systemd/system/qmanager*.service /etc/systemd/system/multi-user.target.wants/qmanager*.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /etc/systemd/system/multi-user.target.wants/qmanager*.service

# TTL/HL iptables — narrowed helpers only (AI-62 phase 2; qmanager_firewall runs as root via systemd)
www-data ALL=(root) NOPASSWD: /usrdata/bin/qmanager_iptables, /usrdata/bin/qmanager_ip6tables

# System reboot (used by system/reboot.sh, update installer)
www-data ALL=(root) NOPASSWD: /sbin/reboot

# SSH password management (reads password from stdin, updates /etc/shadow)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_ssh_password

# Tailscale VPN management
www-data ALL=(root) NOPASSWD: /usrdata/bin/qmanager_tailscale_mgr, /usrdata/bin/qmanager_tailscale_cli

# Tailscale boot persistence (symlink-based)
www-data ALL=(root) NOPASSWD: /bin/ln -sf /etc/systemd/system/tailscaled.service /etc/systemd/system/multi-user.target.wants/tailscaled.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /etc/systemd/system/multi-user.target.wants/tailscaled.service

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

# Upstream v0.1.14+ adds root helpers that CGIs reach through sudo (schedule
# timer arming, crash-log classification, secrets, email, timezone, SIM
# registry, language packs). Keep them allowed at their Casa install path,
# but only when the target actually ships the helper. DPI helpers are left
# out: the zapret video optimizer is not supported on Casa.
bin_dir = path.parents[2] / "usr" / "bin"
extra = [
    name for name in (
        "qmanager_crash_log_append",
        "qmanager_auto_update_arm",
        "qmanager_scenario_schedule_arm",
        "qmanager_scheduled_reboot_arm",
        "qmanager_tower_schedule_arm",
        "qmanager_secret_set",
        "qmanager_email_send",
        "qmanager_timezone_apply",
        "qmanager_language_pack_apply",
        "qmanager_sim_registry_apply",
    )
    if (bin_dir / name).is_file()
]
if extra:
    new_text += "\n# Upstream v0.1.14+ root helpers (Casa install path)\n"
    new_text += "".join(f"www-data ALL=(root) NOPASSWD: /usrdata/bin/{name}\n" for name in extra)

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
    if grep -q '/usr/sbin/iptables' "$sudoers"; then
        fail "sudoers still allows broad raw iptables after AI-62 phase 2"
    fi
    if grep -q '/usrdata/tailscale/tailscale' "$sudoers"; then
        fail "sudoers still allows broad raw tailscale after AI-62 phase 2"
    fi
    if grep -q '/usrdata/tailscale/tailscaled' "$sudoers"; then
        fail "sudoers still allows direct tailscaled after AI-62 phase 2"
    fi
    grep -q '/usrdata/bin/qmanager_iptables' "$sudoers" \
        || fail "sudoers missing qmanager_iptables helper allowance"
    grep -q '/usrdata/bin/qmanager_tailscale_cli' "$sudoers" \
        || fail "sudoers missing qmanager_tailscale_cli helper allowance"
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
    local qmanager_band="$TARGET/components/about-device/qmanager-band.tsx"
    local about_device_page="$TARGET/components/about-device/about-device.tsx"
    local about_types="$TARGET/types/about-device.ts"
    local modem_types="$TARGET/types/modem-status.ts"
    local device_status="$TARGET/components/dashboard/device-status.tsx"

    [ -f "$about_sh" ] || fail "Target missing device/about.sh"
    [ -f "$about_types" ] || fail "Target missing about-device.ts"
    [ -f "$modem_types" ] || fail "Target missing modem-status.ts"
    [ -f "$device_status" ] || fail "Target missing dashboard/device-status.tsx"

    # Upstream v0.1.14+ split the old single about-qmanager-card.tsx apart;
    # the About-page QManager version tag now lives in qmanager-band.tsx,
    # which takes no `data` prop at all (only `onSupport`) and is rendered by
    # about-device.tsx, which does hold the fetched AboutDeviceData. Presence
    # of qmanager-band.tsx (and absence of about-qmanager-card.tsx) is the
    # structure-tolerant anchor for which variant to patch.
    local new_layout=0
    if [ -f "$qmanager_band" ]; then
        new_layout=1
        [ -f "$about_device_page" ] || fail "Target missing about-device/about-device.tsx"
    else
        [ -f "$about_card" ] || fail "Target missing about-qmanager-card.tsx"
    fi

    python3 - "$about_sh" "$about_types" "$modem_types" <<'INNERPY'
from pathlib import Path
import sys

about_sh = Path(sys.argv[1])
about_types = Path(sys.argv[2])
modem_types = Path(sys.argv[3])

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

text = modem_types.read_text()
if "qmanager_version: string;" not in text:
    text = text.replace(
        '  /** Average modem temperature in °C across all available sensors (null if unavailable) */\n',
        '  /** Installed QManager package version from /etc/qmanager/VERSION */\n  qmanager_version: string;\n  /** Average modem temperature in °C across all available sensors (null if unavailable) */\n',
        1,
    )
modem_types.write_text(text)
INNERPY

    grep -q "sys_qmanager_version=" "$about_sh" \
        || fail "Could not apply Casa about-page QManager version patch"
    grep -q "qmanager_version: string;" "$modem_types" \
        || fail "Could not apply Casa dashboard QManager version type patch"

    if [ "$new_layout" = "1" ]; then
        _patch_qmanager_display_version_v16_cfw3212 "$qmanager_band" "$about_device_page" "$device_status"
    else
        _patch_qmanager_display_version_v12_cfw3212 "$about_card" "$device_status"
    fi
}

# v0.1.12 layout: single about-qmanager-card.tsx self-reads `data`, and
# device-status.tsx used a literal "QManager Version" label string.
_patch_qmanager_display_version_v12_cfw3212() {
    local about_card="$1"
    local device_status="$2"

    python3 - "$about_card" "$device_status" <<'INNERPY'
from pathlib import Path
import sys

about_card = Path(sys.argv[1])
device_status = Path(sys.argv[2])

text = about_card.read_text()
text = text.replace("{packageJson.version}", "{data?.system.qmanager_version || packageJson.version}")
about_card.write_text(text)

text = device_status.read_text()
text = text.replace(
    '{ label: "QManager Version", value: packageJson.version, mono: true },',
    '{ label: "QManager Version", value: data?.qmanager_version || packageJson.version, mono: true },',
)
device_status.write_text(text)
INNERPY

    grep -q "data?.qmanager_version" "$device_status" \
        || fail "Could not apply Casa dashboard QManager version display patch"
}

# v0.1.14+ layout: qmanager-band.tsx (About page) takes no `data` prop, so it
# needs a new prop threaded from about-device.tsx's fetched AboutDeviceData;
# device-status.tsx moved the label to i18n (`t("device_status.qmanager_version")`)
# but still reads the same `packageJson.version` fallback value.
_patch_qmanager_display_version_v16_cfw3212() {
    local qmanager_band="$1"
    local about_device_page="$2"
    local device_status="$3"

    if grep -q "qmanagerVersion" "$qmanager_band"; then
        log "QManager display-version already applied (v0.1.14+ layout)"
    else
        python3 - "$qmanager_band" "$about_device_page" <<'INNERPY'
from pathlib import Path
import sys

band_p, page_p = Path(sys.argv[1]), Path(sys.argv[2])

band = band_p.read_text()
props_old = (
    "export interface QManagerBandProps {\n"
    "  onSupport: () => void;\n"
    "}"
)
props_new = (
    "export interface QManagerBandProps {\n"
    "  onSupport: () => void;\n"
    "  /** Installed QManager package version from /etc/qmanager/VERSION (Casa CFW-3212). */\n"
    "  qmanagerVersion?: string;\n"
    "}"
)
assert band.count(props_old) == 1, "qmanager-band: QManagerBandProps anchor"
band = band.replace(props_old, props_new, 1)

sig_old = (
    "export function QManagerBand({\n"
    "  onSupport,\n"
    "}: QManagerBandProps): React.JSX.Element {"
)
sig_new = (
    "export function QManagerBand({\n"
    "  onSupport,\n"
    "  qmanagerVersion,\n"
    "}: QManagerBandProps): React.JSX.Element {"
)
assert band.count(sig_old) == 1, "qmanager-band: QManagerBand signature anchor"
band = band.replace(sig_old, sig_new, 1)

tag_old = "<Tag variant=\"neutral\">{packageJson.version}</Tag>"
assert band.count(tag_old) == 1, "qmanager-band: version Tag anchor"
band = band.replace(tag_old, "<Tag variant=\"neutral\">{qmanagerVersion || packageJson.version}</Tag>", 1)
band_p.write_text(band)

page = page_p.read_text()
call_old = '<QManagerBand onSupport={() => setDonateOpen(true)} />'
assert page.count(call_old) == 1, "about-device: QManagerBand call site anchor"
page = page.replace(
    call_old,
    '<QManagerBand\n        onSupport={() => setDonateOpen(true)}\n        qmanagerVersion={data?.system.qmanager_version}\n      />',
    1,
)
page_p.write_text(page)
INNERPY
        grep -q "qmanagerVersion" "$qmanager_band" \
            || fail "Could not apply Casa dashboard QManager version type patch"
        grep -q "qmanagerVersion" "$about_device_page" \
            || fail "Could not apply Casa dashboard QManager version type patch"
    fi

    if grep -q 'device_status.qmanager_version' "$device_status" && ! grep -q "data?.qmanager_version" "$device_status"; then
        python3 - "$device_status" <<'INNERPY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
text = p.read_text()
old = (
    "    {\n"
    "      label: t(\"device_status.qmanager_version\"),\n"
    "      value: packageJson.version,\n"
    "      mono: true,\n"
    "    },"
)
new = (
    "    {\n"
    "      label: t(\"device_status.qmanager_version\"),\n"
    "      value: data?.qmanager_version || packageJson.version,\n"
    "      mono: true,\n"
    "    },"
)
assert text.count(old) == 1, "device-status: qmanager_version row anchor"
p.write_text(text.replace(old, new, 1))
INNERPY
    fi

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
if "service.system.reset_reason" not in text and old in text:
    text = text.replace(old, new, 1)

# Upstream v0.1.14+ logs a user-initiated crash.log entry before rebooting.
old_v14 = '''        ( ( sleep 1; $_SUDO /usr/bin/qmanager_crash_log_append user 2>/dev/null; $_reboot_cmd ) </dev/null >/dev/null 2>&1 & )
        exit 0
'''
new_v14 = '''        (
            sleep 1
            $_SUDO /usr/bin/qmanager_crash_log_append user 2>/dev/null
            if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get service.system.reset >/dev/null 2>&1; then
                rdb_set service.system.reset_reason "QManager web reboot"
                rdb_set service.system.reset.delay 5
                rdb_set service.system.reset 1
            else
                $_reboot_cmd
            fi
        ) </dev/null >/dev/null 2>&1 &
        exit 0
'''
if "service.system.reset_reason" not in text and old_v14 in text:
    text = text.replace(old_v14, new_v14, 1)

if "service.system.reset_reason" not in text:
    raise SystemExit("reboot command block not found")

path.write_text(text)
PY

    grep -q 'service.system.reset_reason "QManager web reboot"' "$reboot_sh" \
        || fail "Could not apply Casa RDB reboot patch"
    grep -q 'service.system.reset.delay 5' "$reboot_sh" \
        || fail "Could not apply Casa RDB reboot delay"
    grep -q 'link.policy.1.trigger_connect' "$reboot_sh" \
        || fail "Could not apply Casa RDB reconnect patch"
}

patch_casa_scheduled_reboot_cfw3212() {
    local settings_sh="$TARGET/scripts/www/cgi-bin/quecmanager/system/settings.sh"
    local setup="$TARGET/scripts/usr/bin/qmanager_setup"
    [ -f "$settings_sh" ] || fail "Target missing system/settings.sh"
    [ -f "$setup" ] || fail "Target missing qmanager_setup"

    # Upstream v0.1.14+ replaced cron with runtime-armed systemd OnCalendar
    # timers (qmanager_scheduled_reboot_arm). Casa runs those as-is: the
    # installer rewrites /lib/systemd/system to /etc/systemd/system, and timers
    # fire in Casa local time (/etc/localtime follows RDB system.config.tz).
    # Only the BusyBox crond path for older upstreams needs the cron patches.
    local sched_uses_timers=0
    [ -f "$TARGET/scripts/usr/bin/qmanager_scheduled_reboot_arm" ] && sched_uses_timers=1

    if [ "$sched_uses_timers" = "0" ]; then
    python3 - "$settings_sh" "$setup" <<'PY'
from pathlib import Path
import re
import sys

settings_path = Path(sys.argv[1])
setup_path = Path(sys.argv[2])

settings = settings_path.read_text()
setup = setup_path.read_text()

settings = settings.replace(
    'SCHEDULE_SCRIPT="/usr/bin/qmanager_scheduled_reboot"',
    'SCHEDULE_SCRIPT="/usrdata/bin/qmanager_scheduled_reboot"',
)
settings = settings.replace(
    'CRON_FILE="/var/spool/cron/crontabs/root"',
    'CRON_FILE="/usrdata/qmanager/crontabs/root"',
)

spool_marker = '        current_cron=$(cat "$CRON_FILE" 2>/dev/null || true)\n'
spool_block = '''        mkdir -p /usrdata/qmanager/crontabs 2>/dev/null || {
            cgi_error "cron_spool_unavailable" "Could not create scheduled reboot cron directory"
            exit 0
        }
        # crond requires the crontab file root-owned; CGIs run as root on Casa
        # and the cron dir now lives on persistent /usrdata (plain ubifs, not the
        # /etc overlay), so keep both dir and file root-owned.
        chown root:root /usrdata/qmanager/crontabs 2>/dev/null || true
        chmod 755 /usrdata/qmanager/crontabs 2>/dev/null || true

        current_cron=$(cat "$CRON_FILE" 2>/dev/null || true)
'''
if 'cron_spool_unavailable' not in settings:
    if spool_marker not in settings:
        raise SystemExit("scheduled reboot spool marker not found")
    settings = settings.replace(spool_marker, spool_block, 1)

old_cleaned_cron = '''        cleaned_cron=$(printf '%s\\n' "$current_cron" | grep -v "$CRON_MARKER")
'''
new_cleaned_cron = '''        CRON_HEADER="# QManager Scheduled Reboot — DO NOT EDIT MANUALLY"
        cleaned_cron=$(printf '%s\\n' "$current_cron" \
            | grep -v "$CRON_MARKER" \
            | grep -Fvx "$CRON_HEADER" \
            | sed '/^[[:space:]]*$/d')
'''
if old_cleaned_cron not in settings:
    raise SystemExit("scheduled reboot cleaned_cron block not found")
settings = settings.replace(old_cleaned_cron, new_cleaned_cron, 1)

old_new_cron = '''            new_cron="${cleaned_cron}
# QManager Scheduled Reboot — DO NOT EDIT MANUALLY
${sched_min} ${sched_hour} * * ${DAYS_RAW} ${SCHEDULE_SCRIPT}  # ${CRON_MARKER}"
'''
new_new_cron = '''            if [ -n "$cleaned_cron" ]; then
                new_cron="${cleaned_cron}
${CRON_HEADER}
${sched_min} ${sched_hour} * * ${DAYS_RAW} ${SCHEDULE_SCRIPT}  # ${CRON_MARKER}"
            else
                new_cron="${CRON_HEADER}
${sched_min} ${sched_hour} * * ${DAYS_RAW} ${SCHEDULE_SCRIPT}  # ${CRON_MARKER}"
            fi
'''
if old_new_cron not in settings:
    raise SystemExit("scheduled reboot new_cron block not found")
settings = settings.replace(old_new_cron, new_new_cron, 1)

old_enable_write = '''            printf '%s\\n' "$new_cron" > "$CRON_FILE"
            qlog_info "Scheduled reboot cron installed: ${SCHED_TIME} days=${DAYS_RAW}"
'''
new_enable_write = '''            if ! printf '%s\\n' "$new_cron" > "$CRON_FILE"; then
                cgi_error "cron_write_failed" "Could not write scheduled reboot cron entry"
                exit 0
            fi
            # BusyBox crond (1.31.1) silently ignores crontab files not owned by
            # root. CGIs run as root here; a "> $CRON_FILE" truncate preserves an
            # existing www-data owner from older builds, so force root ownership.
            chown root:root "$CRON_FILE" 2>/dev/null || true
            qlog_info "Scheduled reboot cron installed: ${SCHED_TIME} days=${DAYS_RAW}"
'''
if 'cron_write_failed' not in settings:
    if old_enable_write not in settings:
        raise SystemExit("scheduled reboot enable write block not found")
    settings = settings.replace(old_enable_write, new_enable_write, 1)

old_disable_write = '''            if [ -n "$cleaned_cron" ]; then
                printf '%s\\n' "$cleaned_cron" > "$CRON_FILE"
            else
'''
new_disable_write = '''            if [ -n "$cleaned_cron" ]; then
                if ! printf '%s\\n' "$cleaned_cron" > "$CRON_FILE"; then
                    cgi_error "cron_write_failed" "Could not write scheduled reboot cron entry"
                    exit 0
                fi
                chown root:root "$CRON_FILE" 2>/dev/null || true
            else
'''
if old_disable_write not in settings:
    raise SystemExit("scheduled reboot disable write block not found")
settings = settings.replace(old_disable_write, new_disable_write, 1)

new_setup_dirs = '''mkdir -p /var/lock /etc/qmanager /usrdata/qmanager/crontabs /usrdata/qmanager/lib /tmp/quecmanager
# Scheduled-task state lives on persistent /usrdata (plain ubifs) instead of
# Casa's read-only /var/spool rootfs or the /etc overlay, whose writable layer
# is not reliably in place during early boot.
# Migrate any schedule from the previous /etc/qmanager/crontabs location.
if [ -f /etc/qmanager/crontabs/root ] && [ ! -f /usrdata/qmanager/crontabs/root ]; then
    cp /etc/qmanager/crontabs/root /usrdata/qmanager/crontabs/root 2>/dev/null || true
fi
# BusyBox crond silently ignores crontab files not owned by root; CGIs run as
# root on Casa, so keep both dir and file root-owned.
chown root:root /usrdata/qmanager/crontabs 2>/dev/null || true
chmod 755 /usrdata/qmanager/crontabs 2>/dev/null || true
[ -f /usrdata/qmanager/crontabs/root ] && chown root:root /usrdata/qmanager/crontabs/root 2>/dev/null || true
'''
if '/usrdata/qmanager/crontabs' not in setup:
    setup, replacements = re.subn(
        r'''mkdir -p /var/lock /etc/qmanager (?:/usr/lib/qmanager|/usrdata/qmanager/lib) /tmp/quecmanager /var/spool/cron/crontabs\n# Keep the cron spool root-owned and non-world-writable while preserving\n# current CGI schedule writers that update root's crontab directly\.\nchown root:www-data /var/spool/cron /var/spool/cron/crontabs 2>/dev/null \|\| true\nchmod 775 /var/spool/cron /var/spool/cron/crontabs\n''',
        new_setup_dirs,
        setup,
        count=1,
    )
    if replacements != 1:
        raise SystemExit("qmanager_setup cron directory block not found")

setup_marker = '# Secure auth config\n'
setup_crond_helper = '''# Casa: start BusyBox crond in the configured local timezone.
# Scheduled Reboot cron times are wall-clock HH:MM from System Settings.
_qm_crond_start() {
    _qm_tz=""
    if [ -f /etc/TZ ]; then
        _qm_tz=$(cat /etc/TZ)
    fi
    if [ -z "$_qm_tz" ]; then
        PATH="/usrdata/bin:/usrdata/opt/bin:$PATH"
        . /usrdata/qmanager/lib/config.sh 2>/dev/null || true
        . /usrdata/qmanager/lib/system_config.sh 2>/dev/null || true
        if command -v sys_get_timezone >/dev/null 2>&1; then
            _qm_tz=$(sys_get_timezone)
        fi
    fi
    [ -n "$_qm_tz" ] && export TZ="$_qm_tz"
    # BusyBox crond silently ignores crontab files not owned by root. Repair
    # ownership here — right before crond reads the file — as defensive insurance
    # so recurring Scheduled Reboots keep working across reboots.
    [ -f /usrdata/qmanager/crontabs/root ] && chown root:root /usrdata/qmanager/crontabs/root 2>/dev/null || true
    if command -v crond >/dev/null 2>&1; then
        if pidof crond >/dev/null 2>&1; then
            killall crond 2>/dev/null || true
        fi
        crond -c /usrdata/qmanager/crontabs >/dev/null 2>&1 || true
    fi
}

'''
setup_crond_call = '''
# Start crond after config exists so timezone/jq paths resolve correctly.
_qm_crond_start

'''
config_init_casa = '''if [ -f /usrdata/qmanager/lib/config.sh ]; then
    . /usrdata/qmanager/lib/config.sh
    qm_config_init
fi
'''
config_init_gl = '''if [ -f /usr/lib/qmanager/config.sh ]; then
    . /usr/lib/qmanager/config.sh
    qm_config_init
fi
'''
old_crond_inline = '''# Casa does not reliably ship a managed cron service, so ensure BusyBox crond
# runs in QManager's configured timezone (Scheduled Reboot uses wall-clock times).
. /usrdata/qmanager/lib/system_config.sh 2>/dev/null || true
if command -v sys_get_timezone >/dev/null 2>&1; then
    export TZ="$(sys_get_timezone)"
fi
if command -v crond >/dev/null 2>&1; then
    if pidof crond >/dev/null 2>&1; then
        killall crond 2>/dev/null || true
    fi
    crond -c /usrdata/qmanager/crontabs >/dev/null 2>&1 || true
fi

'''
old_crond_start = '''# Casa does not reliably ship a managed cron service, so ensure BusyBox crond
# is available to execute Scheduled Reboot entries after boot/install.
if command -v crond >/dev/null 2>&1 && ! pidof crond >/dev/null 2>&1; then
    crond -c /usrdata/qmanager/crontabs >/dev/null 2>&1 || true
fi

'''

for old in (old_crond_inline, old_crond_start):
    if old in setup:
        setup = setup.replace(old, '', 1)

if '_qm_crond_start()' not in setup:
    if config_init_casa in setup:
        setup = setup.replace(
            config_init_casa,
            setup_crond_helper + config_init_casa + setup_crond_call,
            1,
        )
    elif config_init_gl in setup:
        setup = setup.replace(
            config_init_gl,
            setup_crond_helper + config_init_gl + setup_crond_call,
            1,
        )
    else:
        raise SystemExit("qmanager_setup config init block not found")
elif setup_crond_call.strip() not in setup:
    if config_init_casa in setup:
        setup = setup.replace(config_init_casa, config_init_casa + setup_crond_call, 1)
    elif config_init_gl in setup:
        setup = setup.replace(config_init_gl, config_init_gl + setup_crond_call, 1)

old_sched_reload = '''            qlog_info "Scheduled reboot cron entries removed"
        fi

        # Build response
        DAYS_RESP=$(printf '%s' "$DAYS_RAW" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
'''
new_sched_reload = '''            qlog_info "Scheduled reboot cron entries removed"
        fi

        # Reload crond with QManager timezone so schedule times match System Settings.
        _qm_tz=""
        if [ -f /etc/TZ ]; then
            _qm_tz=$(cat /etc/TZ)
        fi
        if [ -z "$_qm_tz" ]; then
            PATH="/usrdata/bin:/usrdata/opt/bin:$PATH"
            . /usrdata/qmanager/lib/system_config.sh 2>/dev/null || true
            if command -v sys_get_timezone >/dev/null 2>&1; then
                _qm_tz=$(sys_get_timezone)
            fi
        fi
        [ -n "$_qm_tz" ] && export TZ="$_qm_tz"
        if command -v crond >/dev/null 2>&1; then
            killall crond 2>/dev/null || true
            crond -c /usrdata/qmanager/crontabs >/dev/null 2>&1 || true
        fi

        # Build response
        DAYS_RESP=$(printf '%s' "$DAYS_RAW" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
'''
old_sched_reload_mid_v1 = '''        # Reload crond with QManager timezone so schedule times match System Settings.
        . /usrdata/qmanager/lib/system_config.sh 2>/dev/null || true
        if command -v sys_get_timezone >/dev/null 2>&1; then
            export TZ="$(sys_get_timezone)"
        fi
        if command -v crond >/dev/null 2>&1; then
            killall crond 2>/dev/null || true
            crond -c /usrdata/qmanager/crontabs >/dev/null 2>&1 || true
        fi

'''
new_sched_reload_mid = '''        # Reload crond with QManager timezone so schedule times match System Settings.
        _qm_tz=""
        if [ -f /etc/TZ ]; then
            _qm_tz=$(cat /etc/TZ)
        fi
        if [ -z "$_qm_tz" ]; then
            PATH="/usrdata/bin:/usrdata/opt/bin:$PATH"
            . /usrdata/qmanager/lib/system_config.sh 2>/dev/null || true
            if command -v sys_get_timezone >/dev/null 2>&1; then
                _qm_tz=$(sys_get_timezone)
            fi
        fi
        [ -n "$_qm_tz" ] && export TZ="$_qm_tz"
        if command -v crond >/dev/null 2>&1; then
            killall crond 2>/dev/null || true
            crond -c /usrdata/qmanager/crontabs >/dev/null 2>&1 || true
        fi

'''
if '/etc/TZ' in settings and '_qm_tz=' in settings:
    pass
elif old_sched_reload_mid_v1 in settings:
    settings = settings.replace(old_sched_reload_mid_v1, new_sched_reload_mid, 1)
elif old_sched_reload in settings:
    settings = settings.replace(old_sched_reload, new_sched_reload, 1)

settings_path.write_text(settings)
setup_path.write_text(setup)
PY
    fi

    # Route the scheduled reboot through Casa's RDB managed-reset path so the
    # reboot is logged with a real reason (like the System menu Reboot button)
    # instead of a generic Warm-restart. rdb_set/rdb_get live in /usr/bin (on
    # cron's PATH); fall back to a bare reboot when RDB is unavailable.
    local sched_helper="$TARGET/scripts/usr/bin/qmanager_scheduled_reboot"
    if [ -f "$sched_helper" ]; then
        python3 - "$sched_helper" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

import re
m = re.search(r'qlog_info "Scheduled system reboot triggered"\n((?:_qm_crash_log_append[^\n]*\n)?)reboot\n', text)
old = m.group(0) if m else "\0never\0"
new = '''qlog_info "Scheduled system reboot triggered"
''' + (m.group(1) if m else "") + '''# Prefer Casa's RDB managed reset (records a real reboot reason), matching the
# System menu reboot button; fall back to a bare reboot when RDB is absent.
if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get service.system.reset >/dev/null 2>&1; then
    rdb_set service.system.reset_reason "QManager scheduled reboot"
    rdb_set service.system.reset.delay 5
    rdb_set service.system.reset 1
else
    _reboot_cmd="reboot"
    command -v run_reboot >/dev/null 2>&1 && _reboot_cmd="run_reboot"
    $_reboot_cmd
fi
'''
if 'QManager scheduled reboot' not in text:
    if old not in text:
        raise SystemExit("scheduled_reboot helper bare reboot line not found")
    text = text.replace(old, new, 1)
    path.write_text(text)
PY
        grep -q 'QManager scheduled reboot' "$sched_helper" \
            || fail "Could not apply Casa RDB reset path to scheduled reboot helper"
    fi

    [ "$sched_uses_timers" = "1" ] && return 0

    grep -q '/usrdata/bin/qmanager_scheduled_reboot' "$settings_sh" \
        || fail "Could not align Scheduled Reboot helper path to Casa /usrdata/bin"
    grep -q '/usrdata/qmanager/crontabs/root' "$settings_sh" \
        || fail "Could not move Scheduled Reboot cron file to persistent Casa storage"
    grep -q 'cron_spool_unavailable' "$settings_sh" \
        || fail "Could not add Scheduled Reboot cron directory creation guard"
    grep -q 'cron_write_failed' "$settings_sh" \
        || fail "Could not make Scheduled Reboot cron writes fail loudly"
    grep -q '/usrdata/qmanager/crontabs' "$setup" \
        || fail "Could not move Scheduled Reboot cron storage into /usrdata/qmanager"
    grep -q 'crond -c /usrdata/qmanager/crontabs' "$setup" \
        || fail "Could not add qmanager_setup crond startup"
    grep -q '_qm_crond_start' "$setup" \
        || fail "Could not add timezone-aware crond startup to qmanager_setup"
    grep -q '/etc/TZ' "$settings_sh" \
        || fail "Could not add timezone-aware crond reload to settings.sh"
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

import re
_m4 = re.search(r"    # Reboot after flushing state\n    \( sleep 1 && (?:run_)?reboot \) &\n", text)
old_tier4 = _m4.group(0) if _m4 else "\0never\0"
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

patch_casa_watchcat_single_sim_cfw3212() {
    # CFW-3212 Casa hardware has one SIM slot. Keep the upstream Watchdog Tier 3
    # symbols for config/state compatibility, but make the generated daemon
    # ignore tier3_enabled and remove every SIM-switch command path.
    local watchcat="$TARGET/scripts/usr/bin/qmanager_watchcat"
    [ -f "$watchcat" ] || return 0

    python3 - "$watchcat" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

# Structure-based edits (function names, condition lines, fi at the same
# indent) rather than exact bodies, so upstream Tier 3 rewrites (v0.1.14+
# added QUIMSLOT read-back and CPIN retries) do not break the Casa port.

def replace_function(src, name, body):
    m = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), src, flags=re.S | re.M)
    if not m:
        raise SystemExit(f"watchcat {name}() not found")
    return src[:m.start()] + body + src[m.end():]

def replace_if_blocks(src, cond_line, stub, required=True):
    lines = src.split("\n")
    out, i, hits = [], 0, 0
    while i < len(lines):
        line = lines[i]
        if line.strip() == cond_line:
            indent = line[: len(line) - len(line.lstrip())]
            j = i + 1
            while j < len(lines) and lines[j] != indent + "fi":
                j += 1
            if j == len(lines):
                raise SystemExit(f"watchcat: unterminated block for {cond_line!r}")
            out.extend(indent + s if s else s for s in stub.split("\n"))
            i = j + 1
            hits += 1
            continue
        out.append(line)
        i += 1
    if required and not hits:
        raise SystemExit(f"watchcat block not found: {cond_line!r}")
    return "\n".join(out), hits

old_config = """    val=$(qm_config_get watchcat tier3_enabled "")
    [ -n "$val" ] && CFG_TIER3_ENABLED="$val"
"""
new_config = """    val=$(qm_config_get watchcat tier3_enabled "")
    [ -n "$val" ] && CFG_TIER3_ENABLED="$val"
    # Casa CFW-3212 is single-SIM hardware; never allow Watchdog SIM failover.
    CFG_TIER3_ENABLED=0
"""
if "never allow Watchdog SIM failover" not in text:
    if old_config not in text:
        raise SystemExit("watchcat tier3 config block not found")
    text = text.replace(old_config, new_config, 1)

text = text.replace(
    "#   Tier 3: SIM failover (AT+QUIMSLOT) — Golden Rule sequence\n",
    "#   Tier 3: SIM failover — disabled on Casa CFW-3212 single-SIM hardware\n",
)

text = replace_function(text, "execute_tier3", """execute_tier3() {
    qlog_info "TIER 3: SIM failover skipped on Casa CFW-3212 single-SIM hardware"
    append_event "sim_failover" "Watchcat: SIM failover skipped on Casa single-SIM hardware" "info"
    sim_failover_active="false"
    original_sim_slot="null"
    current_sim_slot="null"
    rm -f "$SIM_FAILOVER_FILE" "$REVERT_FLAG"
    return 1
}
""")
text = replace_function(text, "sim_failover_fallback", """sim_failover_fallback() {
    qlog_info "SIM failover fallback skipped on Casa CFW-3212 single-SIM hardware"
    sim_failover_active="false"
    original_sim_slot="null"
    current_sim_slot="null"
    rm -f "$SIM_FAILOVER_FILE" "$REVERT_FLAG"
    return 1
}
""")

# Cooldown success/failure finalization for Tier 3 (success path also ran a
# Watchdog-origin SIM profile auto-apply).
text, _ = replace_if_blocks(
    text,
    'if [ "$current_tier" -eq 3 ] && [ "$current_sim_slot" != "$original_sim_slot" ] && [ "$original_sim_slot" != "null" ]; then',
    """# Casa CFW-3212 is single-SIM hardware; never finalize Watchdog SIM failover state.
if [ "$current_tier" -eq 3 ]; then
    sim_failover_active="false"
    original_sim_slot="null"
    current_sim_slot="null"
    rm -f "$SIM_FAILOVER_FILE" "$REVERT_FLAG"
fi""",
)

# Boot-time resume of saved failover state in main().
main_at = text.find("\nmain() {")
if main_at < 0:
    raise SystemExit("watchcat main() not found")
head, tail = text[:main_at], text[main_at:]
tail, _ = replace_if_blocks(
    tail,
    'if [ -f "$SIM_FAILOVER_FILE" ]; then',
    """# Casa CFW-3212 is single-SIM hardware; discard stale upstream SIM failover state.
if [ -f "$SIM_FAILOVER_FILE" ]; then
    qlog_info "Discarding stale SIM failover state on Casa single-SIM hardware"
    rm -f "$SIM_FAILOVER_FILE" "$REVERT_FLAG"
fi""",
)
text = head + tail

path.write_text(text)
PY

    grep -q 'never allow Watchdog SIM failover' "$watchcat" \
        || fail "Could not force Casa watchcat tier3 disabled"
    grep -q 'SIM failover skipped on Casa CFW-3212 single-SIM hardware' "$watchcat" \
        || fail "Could not replace Casa watchcat tier3 with single-SIM no-op"
    if grep -q 'AT+QUIMSLOT' "$watchcat"; then
        fail "Casa watchcat still contains SIM slot switching commands"
    fi
    if grep -q 'auto_apply_profile .*watchdog' "$watchcat"; then
        fail "Casa watchcat still contains Watchdog-origin SIM profile auto-apply"
    fi
}

patch_casa_watchdog_ui_single_sim_cfw3212() {
    # Match the Watchdog UI/API to Casa single-SIM behavior. The backend daemon
    # already ignores Tier 3; this prevents a saved-looking control from
    # implying that backup-SIM recovery exists on CFW-3212.
    local watchdog_cgi="$TARGET/scripts/www/cgi-bin/quecmanager/monitoring/watchdog.sh"
    local watchdog_card="$TARGET/components/monitoring/watchdog/watchdog-settings-card.tsx"
    local ladder_card="$TARGET/components/monitoring/watchdog/ladder-card.tsx"
    local profile_page="$TARGET/components/cellular/custom-profiles/custom-profile.tsx"

    [ -f "$watchdog_cgi" ] || fail "Target missing monitoring/watchdog.sh"
    [ -f "$profile_page" ] || fail "Target missing custom-profile.tsx"
    # Upstream v0.1.14+ replaced the settings-card Recovery tab with the
    # "ladder" — one Rung per tier, tier 3 being the backup-SIM rung — under
    # components/monitoring/watchdog/. watchdog-settings-card.tsx is gone.
    if [ ! -f "$watchdog_card" ]; then
        watchdog_card=""
        [ -f "$ladder_card" ] || fail "Target missing watchdog-settings-card.tsx and ladder-card.tsx"
    else
        ladder_card=""
    fi

    python3 - "$watchdog_cgi" "$watchdog_card" "$ladder_card" "$profile_page" <<'PY'
from pathlib import Path
import re
import sys

watchdog_cgi, watchdog_card, ladder_card, profile_page = sys.argv[1:5]
watchdog_cgi, profile_page = Path(watchdog_cgi), Path(profile_page)
watchdog_card = Path(watchdog_card) if watchdog_card else None
ladder_card = Path(ladder_card) if ladder_card else None

text = watchdog_cgi.read_text()
text = text.replace(
    '''    tier3=$(qm_config_get watchcat tier3_enabled 0)
    tier4=$(qm_config_get watchcat tier4_enabled 1)
    backup_sim=$(qm_config_get watchcat backup_sim_slot "")
''',
    '''    tier3=0  # Casa CFW-3212 single-SIM hardware: Watchdog SIM failover unavailable.
    tier4=$(qm_config_get watchcat tier4_enabled 1)
    backup_sim=""
''',
    1,
)
text = text.replace(
    '''    # Read SIM failover state
    sim_failover_json='{"active":false}'
    if [ -f "$SIM_FAILOVER_FILE" ]; then
        sim_failover_json=$(cat "$SIM_FAILOVER_FILE" 2>/dev/null)
    fi
''',
    '''    # Casa CFW-3212 single-SIM hardware: ignore stale upstream SIM failover state.
    sim_failover_json='{"active":false}'
    rm -f "$SIM_FAILOVER_FILE" "$REVERT_FLAG" 2>/dev/null || true
''',
    1,
)
text = text.replace(
    '''        val=$(printf '%s' "$POST_DATA" | jq -r '.tier3_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) qm_config_set watchcat tier3_enabled 1 ;; false) qm_config_set watchcat tier3_enabled 0 ;; esac
        fi
''',
    '''        # Casa CFW-3212 single-SIM hardware: never persist Watchdog SIM failover enabled.
        qm_config_set watchcat tier3_enabled 0
''',
    1,
)
text = text.replace(
    '''        val=$(printf '%s' "$POST_DATA" | jq -r '.backup_sim_slot // empty')
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            qm_config_set watchcat backup_sim_slot "$val"
        else
            qm_config_set watchcat backup_sim_slot ""
        fi
''',
    '''        # Casa CFW-3212 single-SIM hardware: no backup SIM slot exists.
        qm_config_set watchcat backup_sim_slot ""
''',
    1,
)
# Upstream v0.1.14+ parses POST fields into f_* variables before saving.
text = text.replace(
    '''        if [ -n "$f_tier3" ]; then
            case "$f_tier3" in true) qm_config_set watchcat tier3_enabled 1 ;; false) qm_config_set watchcat tier3_enabled 0 ;; esac
        fi
''',
    '''        # Casa CFW-3212 single-SIM hardware: never persist Watchdog SIM failover enabled.
        qm_config_set watchcat tier3_enabled 0
''',
    1,
)
text = text.replace(
    '''        if [ -n "$f_backup_sim_slot" ] && [ "$f_backup_sim_slot" != "null" ]; then
            qm_config_set watchcat backup_sim_slot "$f_backup_sim_slot"
        else
            qm_config_set watchcat backup_sim_slot ""
        fi
''',
    '''        # Casa CFW-3212 single-SIM hardware: no backup SIM slot exists.
        qm_config_set watchcat backup_sim_slot ""
''',
    1,
)
watchdog_cgi.write_text(text)

if watchdog_card is not None:
    text = watchdog_card.read_text()
    text = text.replace(
        '''  const [tier3Enabled, setTier3Enabled] = useState(
    settings?.tier3_enabled ?? false,
  );
''',
        '''  const tier3Enabled = false;
''',
        1,
    )
    text = text.replace(
        '''  const [backupSimSlot, setBackupSimSlot] = useState<string>(
    settings?.backup_sim_slot != null ? String(settings.backup_sim_slot) : "",
  );
''',
        '''  const backupSimSlot = "";
''',
        1,
    )
    text, backup_count = re.subn(
        r'\n                <div aria-live="polite">\n                  \{tier3Enabled && \(\n                    <Field>\n                      <FieldLabel htmlFor="backup-sim-slot">.*?\n                </div>\n',
        '\n',
        text,
        count=1,
        flags=re.S,
    )
    if backup_count != 1:
        raise SystemExit("Watchdog backup SIM slot block not found")
    text = text.replace(
        '''                <Field orientation="horizontal" className="w-fit">
                  <FieldLabel htmlFor="tier3-enabled">
                    Switch to Backup SIM
                  </FieldLabel>
                  <Switch
                    id="tier3-enabled"
                    checked={tier3Enabled}
                    onCheckedChange={setTier3Enabled}
                    disabled={!isEnabled}
                  />
                </Field>

''',
        '''                <Field>
                  <FieldLabel>Backup SIM Recovery</FieldLabel>
                  <FieldDescription>
                    Disabled on Casa CFW-3212 single-SIM hardware.
                  </FieldDescription>
                </Field>

''',
        1,
    )
    watchdog_card.write_text(text)

# Upstream v0.1.14+: the Recovery tab's per-tier toggle became the ladder's
# Rung component, one per tier, shared across all four tiers. Tier 3's own
# field slot (previously the sole child of the removed Field above) is now
# the backup-SIM Select; force the tier off and swap its field slot for a
# static notice so Casa single-SIM hardware never shows it as available.
if ladder_card is not None:
    text = ladder_card.read_text()
    if 'Disabled on Casa CFW-3212 single-SIM hardware' not in text:
        old_switch = '''        <Switch
          checked={rung.enabled}
          onCheckedChange={onToggle}
          disabled={masterOff}
          aria-label={t("watchdog.ladder.tierAria", { name })}
          className={SWITCH_TARGET}
        />
'''
        if old_switch not in text:
            raise SystemExit("ladder-card.tsx tier enable Switch not found")
        text = text.replace(
            old_switch,
            '''        <Switch
          checked={rung.tier === 3 ? false : rung.enabled}
          onCheckedChange={onToggle}
          disabled={masterOff || rung.tier === 3}
          aria-label={t("watchdog.ladder.tierAria", { name })}
          className={SWITCH_TARGET}
        />
''',
            1,
        )

        old_field = '''        {rung.tier === 3 && rung.enabled ? (
          <div className={cn(RUNG.FIELD_SLOT, FIELD.ROW)}>
            <label className={FIELD.LABEL} htmlFor={FIELD_ID.backupSim}>
              {t("watchdog.ladder.tier3.slotLabel")}
            </label>
            <Select
              value={form.backupSimSlot}
              onValueChange={form.setBackupSimSlot}
            >
              <SelectTrigger
                id={FIELD_ID.backupSim}
                ref={registerField(FIELD_ID.backupSim)}
                aria-invalid={form.errors.backupSim !== null}
                aria-describedby={
                  form.errors.backupSim
                    ? `${FIELD_ID.backupSim}-hint ${FIELD_ID.backupSim}-error`
                    : `${FIELD_ID.backupSim}-hint`
                }
                className={cn(
                  FIELD.SHELL_ON_CONTAINER,
                  FIELD.INVALID,
                  FIELD.NARROW,
                )}
              >
                <SelectValue
                  placeholder={t("watchdog.ladder.tier3.slotPlaceholder")}
                />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="1">
                  {t("watchdog.ladder.tier3.slot", { slot: 1 })}
                </SelectItem>
                <SelectItem value="2">
                  {t("watchdog.ladder.tier3.slot", { slot: 2 })}
                </SelectItem>
              </SelectContent>
            </Select>
            <p id={`${FIELD_ID.backupSim}-hint`} className={RUNG.FIELD_HINT}>
              {t("watchdog.ladder.tier3.slotHint")}
            </p>
            {form.errors.backupSim ? (
              <p id={`${FIELD_ID.backupSim}-error`} className={FIELD.ERROR}>
                {t(form.errors.backupSim)}
              </p>
            ) : null}
          </div>
        ) : null}
'''
        if old_field not in text:
            raise SystemExit("ladder-card.tsx tier3 backup SIM field block not found")
        text = text.replace(
            old_field,
            '''        {rung.tier === 3 ? (
          <div className={cn(RUNG.FIELD_SLOT, FIELD.ROW)}>
            {/* Casa CFW-3212 is single-SIM hardware: Watchdog SIM failover
                never exists as an option here, regardless of saved state. */}
            <p className={RUNG.FIELD_HINT}>
              Disabled on Casa CFW-3212 single-SIM hardware.
            </p>
          </div>
        ) : null}
''',
            1,
        )
    ladder_card.write_text(text)

text = profile_page.read_text()
text = text.replace(
    "Apply matching profiles on boot, SIM switch, and Watchdog SIM recovery.",
    "Apply matching profiles on boot and user SIM-switch actions.",
)
profile_page.write_text(text)
PY

    grep -q 'tier3=0  # Casa CFW-3212 single-SIM hardware' "$watchdog_cgi" \
        || fail "Could not force Watchdog CGI tier3 unavailable"
    grep -q 'never persist Watchdog SIM failover enabled' "$watchdog_cgi" \
        || fail "Could not force Watchdog CGI tier3 saves off"
    if [ -n "$watchdog_card" ]; then
        grep -q 'Disabled on Casa CFW-3212 single-SIM hardware' "$watchdog_card" \
            || fail "Could not replace Watchdog backup SIM UI"
        if grep -q 'onCheckedChange={setTier3Enabled}' "$watchdog_card"; then
            fail "Watchdog backup SIM toggle still present"
        fi
    else
        grep -q 'Disabled on Casa CFW-3212 single-SIM hardware' "$ladder_card" \
            || fail "Could not replace Watchdog backup SIM UI"
        grep -q 'rung.tier === 3 ? false : rung.enabled' "$ladder_card" \
            || fail "Watchdog backup SIM toggle still present"
    fi
    grep -q 'Apply matching profiles on boot and user SIM-switch actions' "$profile_page" \
        || fail "Could not update ICCID auto-apply UI copy"
}

patch_casa_watchcat_ping_health_cfw3212() {
    # Keep the watchdog honest when the ping daemon is missing/stale. Recovery
    # tiers act on modem connectivity, so a dead ping daemon should not trigger
    # CFUN/SIM/reboot recovery. Instead, expose a degraded state and make a
    # bounded attempt to restart qmanager-ping.
    local watchcat="$TARGET/scripts/usr/bin/qmanager_watchcat"
    [ -f "$watchcat" ] || return 0

    python3 - "$watchcat" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if (
    "PING_STALE_RESTART_CYCLES" in text
    and "write_disabled_state()" in text
    and "restart_ping_service_if_needed()" in text
    and 'state="ping_${ping_status}"' in text
):
    path.write_text(text)
    sys.exit(0)

text = text.replace(
'''PING_STALE_THRESHOLD=15
MODEM_WAIT_TIMEOUT=60
''',
'''PING_STALE_THRESHOLD=15
PING_STALE_RESTART_CYCLES=6
PING_STALE_RESTART_MAX=3
MODEM_WAIT_TIMEOUT=60
''')

text = text.replace(
'''reboots_this_hour=0
''',
'''reboots_this_hour=0
ping_status="unknown"
ping_age="null"
stale_ping_cycles=0
ping_service_restarts=0
''')

text = text.replace(
'''write_state() {
    local ts
    ts=$(date +%s)
''',
'''write_state() {
    if [ "$CFG_ENABLED" != "1" ]; then
        state="disabled"
        failure_counter=0
        current_tier=0
        cooldown_remaining=0
        ping_status="disabled"
        ping_age="null"
        stale_ping_cycles=0
    fi

    local ts
    ts=$(date +%s)
''')

text = text.replace(
'''        --argjson reboots "$reboots_this_hour" \\
        '{
''',
'''        --argjson reboots "$reboots_this_hour" \\
        --arg ping_status "$ping_status" \\
        --argjson ping_age "${ping_age:-null}" \\
        --argjson stale_cycles "$stale_ping_cycles" \\
        --argjson ping_restarts "$ping_service_restarts" \\
        '{
''')

text = text.replace(
'''            current_sim_slot: $sf_curr,
            reboots_this_hour: $reboots
        }' > "$STATE_TMP"
''',
'''            current_sim_slot: $sf_curr,
            reboots_this_hour: $reboots,
            ping_status: $ping_status,
            ping_age: $ping_age,
            stale_ping_cycles: $stale_cycles,
            ping_service_restarts: $ping_restarts
        }' > "$STATE_TMP"
''')

text = text.replace(
'''# Check if tower lock is active (Tier 2 must be skipped)
''',
'''write_disabled_state() {
    read_config 2>/dev/null || true
    CFG_ENABLED=0
    state="disabled"
    failure_counter=0
    current_tier=0
    cooldown_remaining=0
    ping_status="disabled"
    ping_age="null"
    stale_ping_cycles=0
    rm -f "$RECOVERY_FLAG"
    write_state
}

restart_ping_service_if_needed() {
    [ "$stale_ping_cycles" -lt "$PING_STALE_RESTART_CYCLES" ] && return 0
    [ "$ping_service_restarts" -ge "$PING_STALE_RESTART_MAX" ] && return 0
    if [ $((stale_ping_cycles % PING_STALE_RESTART_CYCLES)) -ne 0 ]; then
        return 0
    fi

    ping_service_restarts=$((ping_service_restarts + 1))
    qlog_warn "Ping cache ${ping_status} for ${stale_ping_cycles} watchdog cycles; restarting qmanager-ping (${ping_service_restarts}/${PING_STALE_RESTART_MAX})"
    append_event "watchcat_degraded" "Watchcat: ping daemon cache ${ping_status}; restarting qmanager-ping" "warning"
    if command -v svc_restart >/dev/null 2>&1; then
        svc_restart qmanager_ping 2>/dev/null || true
    else
        systemctl restart qmanager-ping 2>/dev/null || true
    fi
}

# Check if tower lock is active (Tier 2 must be skipped)
''')

text = text.replace(
'''read_ping() {
    if [ ! -f "$PING_CACHE" ]; then
        qlog_warn "Ping cache missing"
        return 1
    fi
''',
'''read_ping() {
    ping_status="ok"
    ping_age="null"
    if [ ! -f "$PING_CACHE" ]; then
        ping_status="missing"
        qlog_warn "Ping cache missing"
        return 1
    fi
''')

text = text.replace(
'''    [ -z "$_pdata" ] && return 1
''',
'''    if [ -z "$_pdata" ]; then
        ping_status="invalid"
        return 1
    fi
''')

text = text.replace(
'''    age=$((now - ping_ts))
    if [ "$age" -gt "$PING_STALE_THRESHOLD" ]; then
        qlog_warn "Ping data stale (age=${age}s), skipping cycle"
        return 1
    fi

    return 0
}
''',
'''    age=$((now - ping_ts))
    ping_age="$age"
    if [ "$age" -gt "$PING_STALE_THRESHOLD" ]; then
        ping_status="stale"
        qlog_warn "Ping data stale (age=${age}s), skipping cycle"
        return 1
    fi

    ping_status="ok"
    return 0
}
''')

text = text.replace(
'''    # Cleanup on exit
    trap 'rm -f "$PID_FILE" "$STATE_TMP" "$RECOVERY_FLAG"; write_state' EXIT INT TERM
''',
'''    # Cleanup on exit. Re-read config so a UI disable leaves a disabled state
    # file instead of the daemon's previous in-memory enabled/monitor snapshot.
    trap 'rm -f "$PID_FILE" "$STATE_TMP" "$RECOVERY_FLAG"; read_config 2>/dev/null || true; [ "$CFG_ENABLED" != "1" ] && state="disabled" && ping_status="disabled"; write_state' EXIT INT TERM
''')

text = text.replace(
'''    if [ "$CFG_ENABLED" != "1" ]; then
        qlog_info "Watchcat disabled in config, exiting"
        exit 0
    fi
''',
'''    if [ "$CFG_ENABLED" != "1" ]; then
        qlog_info "Watchcat disabled in config, exiting"
        write_disabled_state
        exit 0
    fi
''')

text = text.replace(
'''                state="disabled"
                write_state
                exit 0
''',
'''                write_disabled_state
                exit 0
''')

text = text.replace(
'''        if ! read_ping; then
            # Stale or missing data — don't make recovery decisions
            write_state
            sleep "$CFG_CHECK_INTERVAL"
            continue
        fi
''',
'''        if ! read_ping; then
            # Stale or missing ping data means the watchdog is blind, not that
            # the modem is down. Do not escalate modem recovery from this path.
            stale_ping_cycles=$((stale_ping_cycles + 1))
            state="ping_${ping_status}"
            failure_counter=0
            current_tier=0
            rm -f "$RECOVERY_FLAG"
            restart_ping_service_if_needed
            write_state
            sleep "$CFG_CHECK_INTERVAL"
            continue
        fi
        if [ "$state" = "ping_missing" ] || [ "$state" = "ping_stale" ] || [ "$state" = "ping_invalid" ]; then
            qlog_info "Ping data recovered after ${stale_ping_cycles} degraded cycles"
            state="monitor"
            failure_counter=0
            current_tier=0
        fi
        stale_ping_cycles=0
''')

if "PING_STALE_RESTART_CYCLES" not in text:
    raise SystemExit("watchcat ping stale restart constants missing")
if "write_disabled_state()" not in text:
    raise SystemExit("watchcat disabled-state helper missing")
if "restart_ping_service_if_needed()" not in text:
    raise SystemExit("watchcat ping restart helper missing")
if "state=\"ping_${ping_status}\"" not in text:
    raise SystemExit("watchcat ping degraded state path missing")

path.write_text(text)
PY

    grep -q 'PING_STALE_RESTART_CYCLES' "$watchcat" \
        || fail "Could not add watchcat stale ping restart threshold"
    grep -q 'write_disabled_state' "$watchcat" \
        || fail "Could not add watchcat disabled-state writer"
    grep -q 'state="ping_${ping_status}"' "$watchcat" \
        || fail "Could not add watchcat ping degraded state"
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
    # v0.1.14+ split this card apart (components/monitoring/tailscale/tailscale.tsx
    # + install-card.tsx etc.) and moved the button label to i18n
    # (public/locales/en/common.json: tailscale.install.install), so there is no
    # longer a literal "Install Tailscale" string in a component file.
    local locale="$TARGET/public/locales/en/common.json"

    if [ -f "$tscard" ]; then
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
        return
    fi

    [ -f "$locale" ] || fail "tailscale-connection-card.tsx not found at $tscard and en/common.json missing"

    python3 - "$locale" <<'PY'
import json
from pathlib import Path
import sys

p = Path(sys.argv[1])
data = json.loads(p.read_text())
install = data["tailscale"]["install"]
if install.get("install") == "Install Tailscale":
    install["install"] = "Install Tiny Tailscale"
elif install.get("install") != "Install Tiny Tailscale":
    raise SystemExit(f"tiny-tailscale: unexpected tailscale.install.install value: {install.get('install')!r}")
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
PY
    grep -q '"install": "Install Tiny Tailscale"' "$locale" \
        || fail "Could not apply Tiny Tailscale install button label"
}

patch_casa_single_sim_slot_cfw3212() {
    # Casa CFW-3212 has one SIM slot. Cellular Settings' SIM Slot control would
    # switch the modem to an empty slot 2 (AT+QUIMSLOT) and drop the data
    # connection. The CGI ignores slot changes, and the v0.1.14+ settings card
    # no longer offers the control.
    local cgi="$TARGET/scripts/www/cgi-bin/quecmanager/cellular/settings.sh"
    local card="$TARGET/components/cellular/settings/cellular-settings-card.tsx"
    [ -f "$cgi" ] || fail "Target missing cellular/settings.sh"
    python3 - "$cgi" "$card" <<'PY'
from pathlib import Path
import re
import sys

cgi, card = Path(sys.argv[1]), Path(sys.argv[2])

text = cgi.read_text()
marker = "Casa CFW-3212: single SIM slot; never switch slots"
if marker not in text:
    anchor = """    SIM_SLOT=$(printf '%s' "$POST_DATA" | jq -r 'if has("sim_slot") then (.sim_slot | tostring) else "unset" end')\n"""
    if text.count(anchor) != 1:
        raise SystemExit("settings.sh SIM_SLOT extraction anchor not found")
    text = text.replace(anchor, anchor + f"""    # {marker}.
    if [ "$SIM_SLOT" != "unset" ]; then
        qlog_info "Casa: ignoring sim_slot=$SIM_SLOT (single-SIM hardware)"
        SIM_SLOT="unset"
    fi
""", 1)
    cgi.write_text(text)

# v0.1.14+ card only (declarative simRows); older layouts rely on the CGI guard.
if card.exists() and "const simRows: RowDef[] = [" in card.read_text():
    text = card.read_text()
    if "Casa CFW-3212: no SIM Slot row" not in text:
        text, n = re.subn(
            r'(  const simRows: RowDef\[\] = \[\n)    \{\n      key: "sim_slot",\n.*?\n    \},\n',
            r'\1    // Casa CFW-3212: no SIM Slot row (single-SIM hardware).\n',
            text,
            count=1,
            flags=re.S,
        )
        if n != 1:
            raise SystemExit("cellular-settings-card.tsx sim_slot row not found")
        card.write_text(text)
PY
    grep -q 'Casa CFW-3212: single SIM slot; never switch slots' "$cgi" \
        || fail "Could not apply Casa single-SIM slot guard to settings.sh"
    if [ -f "$card" ] && grep -q 'const simRows: RowDef\[\] = \[' "$card"; then
        grep -q 'Casa CFW-3212: no SIM Slot row' "$card" \
            || fail "Could not remove SIM Slot row from cellular settings card"
    fi
}

patch_radio_info_row_wrap_cfw3212() {
    # Cosmetic, upstream v0.1.14+ layout bug: Cellular Information rows keep the
    # label unshrinkable and the value group unwrappable, so a wide value (a
    # 24-bit 5G TAC plus its hex pill) spills left over the label. Let the value
    # group wrap instead. Warn-only if upstream changes the markup.
    local card="$TARGET/components/cellular/radio/cellular-information-card.tsx"
    [ -f "$card" ] || return 0
    local old='<div className="flex min-w-0 items-center justify-end gap-2">'
    local new='<div className="flex min-w-0 flex-wrap items-center justify-end gap-x-2 gap-y-1">'
    if grep -qF "$new" "$card"; then
        return 0
    fi
    if grep -qF "$old" "$card"; then
        sed -i "s|$old|$new|" "$card"
        log "Cellular Information rows: value group may wrap (TAC overlap fix)"
    else
        warn "Cellular Information Row markup changed upstream; TAC overlap fix not applied"
    fi
}

patch_casa_apn_apply_cfw3212() {
    # Upstream v0.1.14+ applies/reverts profile and APN-page APNs with a raw
    # AT+CGDCONT write plus AT+COPS=2/0 re-attach (apn_apply.sh). On Casa that
    # bypasses the connection manager: deactivating a profile wrote an empty
    # APN, left link.profile.1.apn and the modem disagreeing, and took ~6 min
    # to recover on Box 2. Route CID 1 through Casa's RDB profile instead
    # (templates/casa_apn_apply.sh); other CIDs keep upstream's bracket.
    local lib="$TARGET/scripts/usr/lib/qmanager/apn_apply.sh"
    local casa="$TEMPLATE_DIR/casa_apn_apply.sh"
    if [ ! -f "$lib" ]; then
        log "apn_apply.sh not present (pre-v0.1.14 upstream); skipping Casa APN path"
        return 0
    fi
    [ -f "$casa" ] || fail "Template missing: casa_apn_apply.sh"
    if ! grep -q '^_upstream_apn_apply_write() {' "$lib"; then
        [ "$(grep -c '^apn_apply_write() {' "$lib")" = "1" ] \
            || fail "apn_apply.sh apn_apply_write() definition not found"
        sed -i 's/^apn_apply_write() {/_upstream_apn_apply_write() {/' "$lib"
        cat "$casa" >> "$lib"
    fi
    grep -q '^_upstream_apn_apply_write() {' "$lib" && grep -q '^apn_apply_write() {' "$lib" \
        && grep -q 'Casa CFW-3212: apn_apply_write through Casa' "$lib" \
        || fail "Could not install Casa apn_apply_write"

    # The APN page writes APN + credentials with AT+QICSGP before calling
    # apn_apply_write. Casa's reconnect pushes link.profile.1 (auth included)
    # to the modem, so for CID 1 the credentials must land in the Casa profile
    # too, or Casa would overwrite them with its stored auth.
    local apn_cgi="$TARGET/scripts/www/cgi-bin/quecmanager/cellular/apn.sh"
    [ -f "$apn_cgi" ] || return 0
    python3 - "$apn_cgi" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
marker = "Casa CFW-3212: mirror CID 1 credentials into link.profile.1"
if marker in text:
    sys.exit(0)
anchor = """        if ! run_at "$qicsgp_cmd" >/dev/null; then
            die "qicsgp_failed" "AT+QICSGP failed for CID $IDX"
        fi
"""
if text.count(anchor) != 1:
    raise SystemExit("apn.sh QICSGP write anchor not found")
text = text.replace(anchor, anchor + f"""
        # {marker} (Casa pushes that
        # profile to the modem on reconnect). Auth codes follow AT+QICSGP.
        if [ "$IDX" = "1" ] && command -v rdb >/dev/null 2>&1 \\
            && [ -n "$(rdb get link.profile.1.module_profile_idx 2>/dev/null)" ]; then
            case "$AUTH_AT" in
                1) _casa_auth="pap" ;;
                2) _casa_auth="chap" ;;
                3) _casa_auth="pap|chap" ;;
                *) _casa_auth="none" ;;
            esac
            rdb set link.profile.1.auth_type "$_casa_auth" 2>/dev/null
            if [ "$_casa_auth" = "none" ]; then
                rdb set link.profile.1.user "" 2>/dev/null
                rdb set link.profile.1.pass "" 2>/dev/null
            else
                rdb set link.profile.1.user "$USERNAME" 2>/dev/null
                rdb set link.profile.1.pass "$eff_pass" 2>/dev/null
            fi
        fi
""", 1)
path.write_text(text)
PY
    grep -q 'Casa CFW-3212: mirror CID 1 credentials into link.profile.1' "$apn_cgi" \
        || fail "Could not mirror APN page credentials into the Casa profile"
}

patch_casa_managed_reboot_cfw3212() {
    # Every QManager reboot on Casa should go through Casa's RDB managed reset
    # (records a reason, same path as the stock UI) rather than /sbin/reboot.
    # run_reboot() is the funnel for cgi_reboot_response (IMEI and MBN changes)
    # and the fallbacks in reboot.sh/update.sh/watchcat/scheduled reboot;
    # qmanager_imei_check calls a bare `reboot` after restoring a backup IMEI.
    local platform="$TARGET/scripts/usr/lib/qmanager/platform.sh"
    local imei_check="$TARGET/scripts/usr/bin/qmanager_imei_check"
    [ -f "$platform" ] || fail "Target missing platform.sh"
    python3 - "$platform" "$imei_check" <<'PY'
from pathlib import Path
import sys

platform, imei_check = Path(sys.argv[1]), Path(sys.argv[2])
rdb_reset = """if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get service.system.reset >/dev/null 2>&1; then
        rdb_set service.system.reset_reason "{reason}"
        rdb_set service.system.reset.delay 5
        rdb_set service.system.reset 1
"""

text = platform.read_text()
if "Casa CFW-3212: managed reset" not in text:
    old = "run_reboot() {\n    $_SUDO /sbin/reboot \"$@\"\n}\n"
    if text.count(old) != 1:
        raise SystemExit("platform.sh run_reboot() not found")
    new = ("run_reboot() {\n"
           "    # Casa CFW-3212: managed reset through RDB, /sbin/reboot only as fallback.\n"
           "    " + rdb_reset.format(reason="${QM_REBOOT_REASON:-QManager reboot}") +
           "        return 0\n"
           "    fi\n"
           "    $_SUDO /sbin/reboot \"$@\"\n"
           "}\n")
    platform.write_text(text.replace(old, new, 1))

if imei_check.exists():
    text = imei_check.read_text()
    if "QManager backup IMEI restore" not in text:
        old = "    qlog_info \"Backup IMEI written — rebooting device\"\n    sleep 1\n    reboot\n"
        if text.count(old) != 1:
            raise SystemExit("qmanager_imei_check reboot block not found")
        new = ("    qlog_info \"Backup IMEI written — rebooting device\"\n"
               "    sleep 1\n"
               "    # Casa CFW-3212: managed reset through RDB, bare reboot only as fallback.\n"
               "    " + rdb_reset.format(reason="QManager backup IMEI restore") +
               "    else\n"
               "        reboot\n"
               "    fi\n")
        imei_check.write_text(text.replace(old, new, 1))
PY
    grep -q 'Casa CFW-3212: managed reset' "$platform" \
        || fail "Could not route run_reboot through Casa RDB managed reset"
    if [ -f "$imei_check" ]; then
        grep -q 'QManager backup IMEI restore' "$imei_check" \
            || fail "Could not route qmanager_imei_check reboot through Casa RDB managed reset"
    fi
}

patch_casa_cgcontrdp_dualstack_cfw3212() {
    # Casa CFW-3212 (RG520N-NA) answers AT+CGCONTRDP for a dual-stack context
    # on ONE line, not the 3GPP layout upstream parses:
    #   1,0,"apn","<v4>","<v6>","<gw fe80::>","<dns1 v4>" "<dns1 v6>","<dns2 v4>" "<dns2 v6>"
    # Upstream reads fixed comma positions (addr+mask, gw, dns1, dns2), so it
    # showed the IPv6 gateway as Primary DNS and a glued v4+v6 pair as
    # Secondary DNS. Detect this layout and take the IPv4 token of each pair.
    local lib="$TARGET/scripts/usr/lib/qmanager/cgi_at.sh"
    [ -f "$lib" ] || fail "Target missing cgi_at.sh"
    if ! grep -q '^parse_cgcontrdp()' "$lib"; then
        log "parse_cgcontrdp not in cgi_at.sh (older upstream layout); skipping Casa dual-stack patch"
        return 0
    fi
    python3 - "$lib" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "casa_pick_dns" in text:
    sys.exit(0)

anchor = "            gw = f[5]; d1 = f[6]; d2 = f[7]\n"
if text.count(anchor) != 1:
    raise SystemExit("parse_cgcontrdp field-position anchor not found in cgi_at.sh")
text = text.replace(anchor, anchor + """            # Casa CFW-3212 (RG520N-NA) dual-stack layout: IPv6 address as its
            # own field after the IPv4 address, then the (IPv6) gateway, then
            # each DNS field is a space-separated "v4 v6" pair.
            m = split(f[5], _f5, " ")
            k = split(_f5[1], _o5, "[.]")
            if (n >= 8 && f[4] !~ / / && addr !~ /:/ && (k == 16 || _f5[1] ~ /:/) && _f5[1] !~ /^(254[.]128[.]|fe80)/) {
                if (v6 == "") v6 = _f5[1]
                gw = f[6]; d1 = f[7]; d2 = f[8]
                if (split(gw, _g, "[.]") != 4) gw = ""
            }
            d1 = casa_pick_dns(d1); d2 = casa_pick_dns(d2)
""", 1)

end_anchor = """        END { printf "%s\\t%s\\t%s\\t%s\\t%s\\n", v4, v4gw, dns1, dns2, v6 }'"""
if text.count(end_anchor) != 1:
    raise SystemExit("parse_cgcontrdp END anchor not found in cgi_at.sh")
text = text.replace(end_anchor, """        END { printf "%s\\t%s\\t%s\\t%s\\t%s\\n", v4, v4gw, dns1, dns2, v6 }
        function casa_pick_dns(s,    t, c, j, o) {
            # Casa "v4 v6" DNS pair: prefer the IPv4 token.
            c = split(s, t, " ")
            for (j = 1; j <= c; j++) if (split(t[j], o, "[.]") == 4) return t[j]
            return t[1]
        }'""", 1)
path.write_text(text)
PY
    grep -q 'casa_pick_dns' "$lib" \
        || fail "Could not apply Casa CGCONTRDP dual-stack parser patch"

    # The poller has its own copy in parse_at.sh that cuts fields 6/7 and
    # deletes spaces, gluing each "v4 v6" pair. Same layout handling there.
    local plib="$TARGET/scripts/usr/lib/qmanager/parse_at.sh"
    [ -f "$plib" ] || return 0
    python3 - "$plib" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
if "Casa CFW-3212 (RG520N-NA) dual-stack CGCONTRDP" in text:
    sys.exit(0)
old = """    t2_primary_dns=$(printf '%s' "$csv" | cut -d',' -f6 | tr -d '"' | tr -d ' ')
"""
old2 = """    t2_secondary_dns=$(printf '%s' "$csv" | cut -d',' -f7 | tr -d '"' | tr -d ' ')
"""
if text.count(old) != 1 or text.count(old2) != 1:
    raise SystemExit("parse_at.sh parse_cgcontrdp DNS cut lines not found")
new = """    # Casa CFW-3212 (RG520N-NA) dual-stack CGCONTRDP: v4 and v6 addresses as
    # separate fields, then the gateway, then each DNS field is a space-
    # separated "v4 v6" pair. Spec layout: addr+mask, gw, dns1, dns2.
    local _casa_dns
    _casa_dns=$(printf '%s\\n' "$csv" | awk '
        {
            n = split($0, f, ",")
            for (i = 1; i <= n; i++) {
                gsub(/"/, "", f[i])
                gsub(/^[ \\t]+|[ \\t]+$/, "", f[i])
            }
            d1 = f[6]; d2 = f[7]
            split(f[5], a5, " ")
            k = split(a5[1], o5, "[.]")
            if (n >= 8 && f[4] !~ / / && f[4] !~ /:/ && (k == 16 || a5[1] ~ /:/) && a5[1] !~ /^(254[.]128[.]|fe80)/) {
                d1 = f[7]; d2 = f[8]
            }
            printf "%s\\t%s\\n", pick(d1), pick(d2)
        }
        function pick(s,    t, c, j, o) {
            c = split(s, t, " ")
            for (j = 1; j <= c; j++) if (split(t[j], o, "[.]") == 4) return t[j]
            return t[1]
        }')
    t2_primary_dns=$(printf '%s' "$_casa_dns" | cut -f1)
"""
text = text.replace(old, new, 1)
text = text.replace(old2, """    t2_secondary_dns=$(printf '%s' "$_casa_dns" | cut -f2)
""", 1)
path.write_text(text)
PY
    grep -q 'Casa CFW-3212 (RG520N-NA) dual-stack CGCONTRDP' "$plib" \
        || fail "Could not apply Casa CGCONTRDP dual-stack patch to parse_at.sh"
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
# The Casa LAN DNS reconciler owns the public-fallback block in the same
# dnsmasq.conf. Re-run it right after a Custom DNS save so turning Custom DNS
# off while carrier DNS is down restores the fallback immediately (and turning
# it on drops the fallback servers) instead of waiting for the 30s timer.
reconcile_marker = "Casa: re-run LAN DNS reconciler after Custom DNS change"
if reconcile_marker not in text:
    anchor = '        qlog_info "custom DNS applied successfully"\n'
    if anchor not in text:
        raise SystemExit("custom DNS applied-successfully anchor not found in custom_dns.sh")
    text = text.replace(
        anchor,
        f"        # {reconcile_marker}\n"
        "        if [ -x /usrdata/bin/qmanager_dns_reconcile ]; then\n"
        "            /usrdata/bin/qmanager_dns_reconcile --once >/dev/null 2>&1 || true\n"
        "        fi\n"
        + anchor,
        1,
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
    grep -q 'Casa: re-run LAN DNS reconciler after Custom DNS change' "$dns_cgi" \
        || fail "Could not add LAN DNS reconcile after Custom DNS save"
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
        if pgrep -f "/usrdata/bin/qmanager_ping_rust" >/dev/null 2>&1; then runtime="rust"; elif pgrep -f "/usrdata/bin/qmanager_ping_shell" >/dev/null 2>&1; then runtime="shell"; elif pgrep -f "/usrdata/bin/qmanager_ping" >/dev/null 2>&1; then runtime="shell"; elif [ "$service_active" = "false" ]; then runtime="stopped"; fi
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

# v0.1.14+ rewrote this dialog and already derives dlLatency/ulLatency with
# `result.download.latency?.iqm !== undefined ? ... : <absent>` before calling
# .toFixed() — the exact Casa intent (never crash on missing iqm). No-op here.
if (
    "result.download.latency?.iqm !== undefined" in text
    and "result.upload.latency?.iqm !== undefined" in text
):
    pass
else:
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

patch_casa_hide_video_optimizer_cfw3212() {
    # Upstream v0.1.14+ added a Traffic Engine / DPI page (components/local-
    # network/traffic-engine) with three selectable modes: "none", "full_bypass"
    # and "video_optimizer" -- the latter installs/runs a DPI binary driven by
    # scripts/www/cgi-bin/quecmanager/network/video_optimizer.sh. Casa wants to
    # keep shipping the backend (to try later) but not expose it as choosable
    # yet, pending Casa-specific validation. Remove just the "video_optimizer"
    # entry from the mode selector's MODES array so the UI can never select or
    # enable it; leave the hook/CGI/backend files untouched. Absent entirely on
    # v0.1.12 (Traffic Engine is a v0.1.14+ feature), so this is a no-op there.
    local mode_card="$TARGET/components/local-network/traffic-engine/mode-card.tsx"
    if [ ! -f "$mode_card" ]; then
        log "Video Optimizer hide: no-op (Traffic Engine not present, pre-v0.1.14 layout)"
        return 0
    fi

    if grep -q "Casa CFW-3212: Video Optimizer mode hidden pending validation" "$mode_card"; then
        log "Video Optimizer hide patch already applied"
        return 0
    fi

    python3 - "$mode_card" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

entry = '''  {
    mode: "video_optimizer",
    nameKey: "trafficEngine.mode.video_optimizer",
    hintKey: "trafficEngine.mode.video_optimizer_hint",
    glyph: VideoIcon,
  },
'''
if entry not in text:
    raise SystemExit("mode-card: video_optimizer MODES entry not found (upstream may have changed)")
text = text.replace(
    entry,
    "  // Casa CFW-3212: Video Optimizer mode hidden pending validation (backend\n"
    "  // kept for a later try; see patch_casa_hide_video_optimizer_cfw3212).\n",
    1,
)

# VideoIcon import is now unused; drop it so lint/tsc stay clean.
unused_import = "  VideoIcon,\n"
if unused_import in text and "VideoIcon" not in text.replace(unused_import, "", 1):
    text = text.replace(unused_import, "", 1)

path.write_text(text)
PY

    grep -q "Casa CFW-3212: Video Optimizer mode hidden pending validation" "$mode_card" \
        || fail "Could not hide Video Optimizer mode from Traffic Engine selector"
    ! grep -q 'mode: "video_optimizer"' "$mode_card" \
        || fail "Video Optimizer mode entry still selectable in Traffic Engine"
    log "Video Optimizer mode hidden from Traffic Engine selector (backend kept)"
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
    local rail="$TARGET/components/dashboard/status-rail.tsx"
    for x in "$ns" "$hc" "$ty"; do
        [ -f "$x" ] || fail "DNS badges: missing $x"
    done

    # Shared by both layouts: the DnsStatus type + ModemStatus.dns_status field.
    # Anchors (ModemStatus interface open brace, connectivity field) are
    # unchanged between v0.1.12 and v0.1.14+/v0.1.16.
    if ! grep -q "export interface DnsStatus" "$ty"; then
        python3 - "$ty" <<'PYTYPES'
import sys
from pathlib import Path
ty_p = Path(sys.argv[1])
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
PYTYPES
        grep -q "export interface DnsStatus" "$ty" || fail "DNS badges: DnsStatus type missing"
    fi

    # Upstream v0.1.14+ moved the dashboard's Online/Offline + Radio/Internet
    # chips out of network-status.tsx into a dedicated page-header rail
    # component, "status-rail.tsx" (DashboardStatusRail). Its presence is a
    # stable, structure-tolerant anchor for which layout we're on: on that
    # layout the IPPT/DNS chips belong beside the other rail chips, not inside
    # the (now badge-less) network-status.tsx card.
    if [ -f "$rail" ]; then
        _patch_casa_dns_badges_rail_cfw3212 "$rail" "$hc"
        return
    fi

    # --- v0.1.12 layout: badges render inside network-status.tsx ---
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

    python3 - "$ns" "$hc" << 'PYBADGE'
import sys, re
from pathlib import Path
ns_p, hc_p = (Path(p) for p in sys.argv[1:3])

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
print(f"DNS badges patched: ns+hc ({n[0]} home-component usages threaded)")
PYBADGE
    grep -q "DnsSourceBadges" "$ns" || fail "DNS badges: network-status insertion failed"
    grep -q "dns_status" "$hc" || fail "DNS badges: home-component threading failed"
    grep -q "export interface DnsStatus" "$ty" || fail "DNS badges: DnsStatus type missing"
    log "Casa IPPT + DNS-source dashboard badges applied (AI-64)"
}

# Upstream v0.1.14+ layout: thread dns_status into the page-header status
# rail (status-rail.tsx / DashboardStatusRail) instead of network-status.tsx,
# which no longer renders any badges (they moved to the rail — see the file's
# own header comment). Reuses the rail's own Chip component/tone system
# rather than the shadcn Badge/Tooltip pair dns-source-badges.tsx uses, so the
# two new chips read as part of the same family as Radio/Internet/Stale
# instead of as a bolted-on card.
_patch_casa_dns_badges_rail_cfw3212() {
    local rail="$1"
    local hc="$2"

    if grep -q "dnsStatus" "$rail"; then
        log "DNS badges already applied (status-rail layout)"
        return 0
    fi

    python3 - "$rail" "$hc" <<'PYRAIL'
import sys
from pathlib import Path
rail_p, hc_p = (Path(p) for p in sys.argv[1:3])

# --- status-rail.tsx ---
rail = rail_p.read_text()

import_old = (
    "import type {\n"
    "  NetworkStatus,\n"
    "  ConnectivityStatus,\n"
    "  ConnectivityState,\n"
    "} from \"@/types/modem-status\";"
)
import_new = (
    "import type {\n"
    "  NetworkStatus,\n"
    "  ConnectivityStatus,\n"
    "  ConnectivityState,\n"
    "  DnsStatus,\n"
    "} from \"@/types/modem-status\";"
)
assert rail.count(import_old) == 1, "status-rail: modem-status type import anchor"
rail = rail.replace(import_old, import_new, 1)

props_old = (
    "interface DashboardStatusRailProps {\n"
    "  data: NetworkStatus | null;\n"
    "  connectivity: ConnectivityStatus | null;\n"
    "  modemReachable: boolean;\n"
    "  isLoading: boolean;\n"
    "  isStale: boolean;\n"
    "}"
)
props_new = (
    "interface DashboardStatusRailProps {\n"
    "  data: NetworkStatus | null;\n"
    "  connectivity: ConnectivityStatus | null;\n"
    "  modemReachable: boolean;\n"
    "  isLoading: boolean;\n"
    "  isStale: boolean;\n"
    "  /** Casa CFW-3212 LAN DNS reconciler state (AI-64). */\n"
    "  dnsStatus: DnsStatus | null;\n"
    "}"
)
assert rail.count(props_old) == 1, "status-rail: DashboardStatusRailProps anchor"
rail = rail.replace(props_old, props_new, 1)

tone_old = (
    "const CHIP_TONE: Record<ChipTone, string> = {\n"
    "  success: \"bg-success-container text-on-success-container\",\n"
    "  warning: \"bg-warning-container text-on-warning-container\",\n"
    "  destructive: \"bg-destructive-container text-on-destructive-container\",\n"
    "  muted: \"bg-surface-container-high text-on-surface-variant\",\n"
    "};"
)
tone_new = tone_old + (
    "\n\n"
    "// Casa CFW-3212 (AI-64): tone + label maps for the LAN DNS-source chip.\n"
    "const DNS_SOURCE_TONE: Record<DnsStatus[\"dns_source\"], ChipTone> = {\n"
    "  carrier: \"success\",\n"
    "  custom: \"success\",\n"
    "  public_fallback: \"warning\",\n"
    "  poisoned: \"destructive\",\n"
    "  unknown: \"muted\",\n"
    "};\n\n"
    "const DNS_SOURCE_LABEL: Record<DnsStatus[\"dns_source\"], string> = {\n"
    "  carrier: \"Carrier\",\n"
    "  custom: \"Custom\",\n"
    "  public_fallback: \"Public\",\n"
    "  poisoned: \"Poisoned\",\n"
    "  unknown: \"Unknown\",\n"
    "};"
)
assert rail.count(tone_old) == 1, "status-rail: CHIP_TONE anchor"
rail = rail.replace(tone_old, tone_new, 1)

sig_old = (
    "export function DashboardStatusRail({\n"
    "  data,\n"
    "  connectivity,\n"
    "  modemReachable,\n"
    "  isLoading,\n"
    "  isStale,\n"
    "}: DashboardStatusRailProps) {"
)
sig_new = (
    "export function DashboardStatusRail({\n"
    "  data,\n"
    "  connectivity,\n"
    "  modemReachable,\n"
    "  isLoading,\n"
    "  isStale,\n"
    "  dnsStatus,\n"
    "}: DashboardStatusRailProps) {"
)
assert rail.count(sig_old) == 1, "status-rail: DashboardStatusRail signature anchor"
rail = rail.replace(sig_old, sig_new, 1)

tail_old = (
    "          </Chip>\n"
    "        )}\n"
    "      </motion.span>\n"
    "    </motion.div>\n"
    "  );\n"
    "}\n"
)
tail_new = (
    "          </Chip>\n"
    "        )}\n"
    "      </motion.span>\n"
    "\n"
    "      {/* Casa CFW-3212 (AI-64): IPPT + LAN DNS source chips */}\n"
    "      {dnsStatus && (\n"
    "        <>\n"
    "          <motion.span variants={staggerRowItem} className=\"inline-flex\">\n"
    "            <Chip\n"
    "              tone={dnsStatus.ippt_on ? \"success\" : \"muted\"}\n"
    "              swapKey={dnsStatus.ippt_on ? \"ippt-on\" : \"ippt-off\"}\n"
    "            >\n"
    "              <MaterialSymbol name=\"swap_horiz\" size={15} filled className=\"shrink-0\" />\n"
    "              {dnsStatus.ippt_on ? \"IPPT On\" : \"IPPT Off\"}\n"
    "            </Chip>\n"
    "          </motion.span>\n"
    "          <motion.span variants={staggerRowItem} className=\"inline-flex\">\n"
    "            <Chip\n"
    "              tone={DNS_SOURCE_TONE[dnsStatus.dns_source]}\n"
    "              swapKey={dnsStatus.dns_source}\n"
    "            >\n"
    "              <MaterialSymbol name=\"dns\" size={15} filled className=\"shrink-0\" />\n"
    "              {`DNS: ${DNS_SOURCE_LABEL[dnsStatus.dns_source]}`}\n"
    "            </Chip>\n"
    "          </motion.span>\n"
    "        </>\n"
    "      )}\n"
    "    </motion.div>\n"
    "  );\n"
    "}\n"
)
assert rail.count(tail_old) == 1, "status-rail: rail tail (Internet chip close + motion.div close) anchor"
rail = rail.replace(tail_old, tail_new, 1)

rail_p.write_text(rail)

# --- home-component.tsx: thread dnsStatus into the single <DashboardStatusRail> call ---
hc = hc_p.read_text()
call_old = (
    "            <DashboardStatusRail\n"
    "              data={data?.network ?? null}\n"
    "              connectivity={data?.connectivity ?? null}\n"
    "              modemReachable={data?.modem_reachable ?? false}\n"
    "              isLoading={isLoading}\n"
    "              isStale={isStale}\n"
    "            />"
)
call_new = (
    "            <DashboardStatusRail\n"
    "              data={data?.network ?? null}\n"
    "              connectivity={data?.connectivity ?? null}\n"
    "              modemReachable={data?.modem_reachable ?? false}\n"
    "              isLoading={isLoading}\n"
    "              isStale={isStale}\n"
    "              dnsStatus={data?.dns_status ?? null}\n"
    "            />"
)
assert hc.count(call_old) == 1, "home-component: DashboardStatusRail call site anchor"
hc = hc.replace(call_old, call_new, 1)
hc_p.write_text(hc)
print("DNS badges patched (status-rail layout): rail+hc")
PYRAIL
    grep -q "dnsStatus" "$rail" || fail "DNS badges: status-rail insertion failed"
    grep -q "dns_status" "$hc" || fail "DNS badges: home-component threading failed"
    log "Casa IPPT + DNS-source status-rail chips applied (AI-64)"
}

patch_active_bands_multi_expand_cfw3212() {
    local active_bands="$TARGET/components/cellular/active-bands.tsx"
    # v0.1.14+ moved/renamed this to components/cellular/radio/active-bands-card.tsx
    # and, per its own top-of-file comment, deliberately DELETED the Radix
    # Accordion this Casa patch used to force open ("This replaced a Radix
    # Accordion (`type="single" collapsible`, PCC open by default) ... Deleting
    # it retires that exception"). Every carrier's metrics now render at once,
    # unconditionally -- a stronger form of Casa's "let the user see every band
    # panel expanded" intent than the accordion tweak ever was. Nothing to patch.
    local active_bands_card="$TARGET/components/cellular/radio/active-bands-card.tsx"
    if [ ! -f "$active_bands" ] && [ -f "$active_bands_card" ]; then
        if grep -Eq '<Accordion[ />]' "$active_bands_card"; then
            fail "Active bands multi-expand: active-bands-card.tsx reintroduced an Accordion; Casa multi-expand intent needs re-evaluating"
        fi
        log "Active bands multi-expand: no-op on v0.1.14+ (accordion removed upstream, all bands always shown)"
        return 0
    fi
    [ -f "$active_bands" ] || fail "Active bands multi-expand: missing $active_bands"

    if grep -q 'type="multiple"' "$active_bands" && \
       grep -q 'defaultValue={\["item-0"\]}' "$active_bands"; then
        log "Active bands multi-expand patch already applied"
        return 0
    fi

    python3 - "$active_bands" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''        <Accordion
          type="single"
          collapsible
          className="w-full"
          defaultValue="item-0"
        >'''
new = '''        <Accordion
          type="multiple"
          className="w-full"
          defaultValue={["item-0"]}
        >'''

if old not in text:
    raise SystemExit("active-bands: single-open accordion block not found (upstream may have changed)")

path.write_text(text.replace(old, new, 1))
PY

    grep -q 'type="multiple"' "$active_bands" \
        || fail "Active bands multi-expand: Accordion type was not updated"
    grep -q 'defaultValue={\["item-0"\]}' "$active_bands" \
        || fail "Active bands multi-expand: defaultValue was not updated"
    ! grep -q 'type="single"' "$active_bands" \
        || fail "Active bands multi-expand: single-open accordion still present"

    log "Active bands multi-expand patch applied"
}

patch_terminal_sidebar_children_cfw3212() {
    local sidebar="$TARGET/components/app-sidebar.tsx"
    # v0.1.14+ rewrote app-sidebar.tsx: nav-main/nav-cellular etc. (with
    # per-item `title` strings) were replaced by module-level arrays whose
    # items carry `t_key` and are resolved through i18n (public/locales/en/
    # sidebar.json's "items" map, which already ships an "at_terminal": "AT
    # Terminal" entry upstream never wires into a nav item -- see below).
    local locale="$TARGET/public/locales/en/sidebar.json"
    [ -f "$sidebar" ] || fail "Terminal sidebar patch: missing $sidebar"

    if grep -q '{ title: "AT Terminal", url: "/system-settings/at-terminal" }' "$sidebar" && \
       grep -q '{ title: "Web Console", url: "/system-settings/web-console" }' "$sidebar"; then
        log "Terminal sidebar children patch already applied"
        return 0
    fi
    if grep -q '{ t_key: "at_terminal", url: "/system-settings/at-terminal" }' "$sidebar" && \
       grep -q '{ t_key: "web_console", url: "/system-settings/web-console" }' "$sidebar"; then
        log "Terminal sidebar children patch already applied (t_key layout)"
        return 0
    fi

    if grep -q 't_key: "terminals"' "$sidebar"; then
        [ -f "$locale" ] || fail "Terminal sidebar patch: missing $locale (t_key layout needs sidebar.json)"
        python3 - "$sidebar" "$locale" <<'PY'
import json
from pathlib import Path
import sys

sidebar_path, locale_path = map(Path, sys.argv[1:3])
text = sidebar_path.read_text()

old = '''  {
    t_key: "terminals",
    url: "/system-settings/at-terminal",
    icon: "terminal",
    items: [{ t_key: "web_console", url: "/system-settings/web-console" }],
  },'''
new = '''  {
    t_key: "terminals",
    url: "/system-settings/at-terminal",
    icon: "terminal",
    items: [
      { t_key: "at_terminal", url: "/system-settings/at-terminal" },
      { t_key: "web_console", url: "/system-settings/web-console" },
    ],
  },'''
if old not in text:
    raise SystemExit("app-sidebar: Terminals block not found (upstream may have changed)")
sidebar_path.write_text(text.replace(old, new, 1))

data = json.loads(locale_path.read_text())
items = data["items"]
if items.get("at_terminal") != "AT Terminal":
    raise SystemExit(f"sidebar.json: unexpected items.at_terminal value: {items.get('at_terminal')!r}")
if items.get("web_console") is None:
    raise SystemExit("sidebar.json: items.web_console missing")
PY

        grep -q '{ t_key: "at_terminal", url: "/system-settings/at-terminal" }' "$sidebar" \
            || fail "Terminal sidebar patch did not add AT Terminal child"
        grep -q '{ t_key: "web_console", url: "/system-settings/web-console" }' "$sidebar" \
            || fail "Terminal sidebar patch lost Web Console child"
        log "Terminal sidebar now shows AT Terminal and Web Console children (t_key layout)"
        return 0
    fi

    python3 - "$sidebar" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''    {
      title: "Terminals",
      url: "/system-settings/at-terminal",
      icon: TerminalIcon,
      items: [
        { title: "Web Console", url: "/system-settings/web-console" },
      ],
    },'''

new = '''    {
      title: "Terminals",
      url: "/system-settings/at-terminal",
      icon: TerminalIcon,
      items: [
        { title: "AT Terminal", url: "/system-settings/at-terminal" },
        { title: "Web Console", url: "/system-settings/web-console" },
      ],
    },'''

if old not in text:
    raise SystemExit("app-sidebar: Terminals block not found (upstream may have changed)")
path.write_text(text.replace(old, new, 1))
PY

    grep -q '{ title: "AT Terminal", url: "/system-settings/at-terminal" }' "$sidebar" \
        || fail "Terminal sidebar patch did not add AT Terminal child"
    grep -q '{ title: "Web Console", url: "/system-settings/web-console" }' "$sidebar" \
        || fail "Terminal sidebar patch lost Web Console child"
    log "Terminal sidebar now shows AT Terminal and Web Console children"
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

# v0.1.12: submit()'s useCallback dependency array is a single line.
dep_needle = (
    '  }, [ltePreset, nr5gPreset, lteCustom, nr5gCustom, ltePresets, '
    'nr5gPresets, onLoadingChange, onSuccess]);\n'
)
dep_replacement = (
    '  }, [ltePreset, nr5gPreset, lteCustom, nr5gCustom, ltePresets, '
    'nr5gPresets, supportedLte, supportedNr5g, onLoadingChange, onSuccess]);\n'
)
# v0.1.14+: the array was reformatted multi-line and gained `outcome` (partial
# apply/retry state) as a dependency; insert supportedLte/supportedNr5g the
# same way, ahead of the newer deps rather than replacing the whole block.
dep_needle_v14 = (
    '  }, [\n'
    '    ltePreset,\n'
    '    nr5gPreset,\n'
    '    lteCustom,\n'
    '    nr5gCustom,\n'
    '    ltePresets,\n'
    '    nr5gPresets,\n'
    '    outcome,\n'
    '    onLoadingChange,\n'
    '    onSuccess,\n'
    '  ]);\n'
)
dep_replacement_v14 = (
    '  }, [\n'
    '    ltePreset,\n'
    '    nr5gPreset,\n'
    '    lteCustom,\n'
    '    nr5gCustom,\n'
    '    ltePresets,\n'
    '    nr5gPresets,\n'
    '    supportedLte,\n'
    '    supportedNr5g,\n'
    '    outcome,\n'
    '    onLoadingChange,\n'
    '    onSuccess,\n'
    '  ]);\n'
)
if dep_needle in text:
    text = text.replace(dep_needle, dep_replacement, 1)
elif dep_needle_v14 in text:
    text = text.replace(dep_needle_v14, dep_replacement_v14, 1)
else:
    raise SystemExit("band-locking: submit() dependency array not found (upstream may have changed)")

path.write_text(text)
PY
    grep -q "onboarding band normalize" "$bl" \
        || fail "Onboarding normalize: band-locking patch did not apply"
    # v0.1.12's dependency array is single-line; v0.1.14+'s is multi-line
    # (see the two dep_needle variants above), so check membership rather than
    # one exact joined substring.
    grep -q "supportedLte" "$bl" && grep -q "supportedNr5g" "$bl" \
        || fail "Onboarding normalize: band-locking dependency array not updated"

    log "Onboarding default-normalize patches applied (RAT + band lock)"
}

apply_casa_overlays() {
    log "Applying Casa CFW-3212 overlays from $REF_DIR"

    patch_build_script
    patch_package_script_builds_frontend_cfw3212

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
    patch_casa_cgcontrdp_dualstack_cfw3212
    patch_casa_single_sim_slot_cfw3212
    patch_casa_managed_reboot_cfw3212
    patch_casa_apn_apply_cfw3212
    patch_radio_info_row_wrap_cfw3212
    patch_casa_dns_status_merge_cfw3212
    patch_casa_dns_badges_cfw3212
    patch_active_bands_multi_expand_cfw3212
    patch_terminal_sidebar_children_cfw3212
    patch_onboarding_normalize_defaults_cfw3212
    patch_ai62_qmanager_iptables_helper_cfw3212
    patch_ai62_qmanager_tailscale_cli_helper_cfw3212
    patch_ai62_ssh_password_sha512_cfw3212
    patch_ai62_sudoers_narrowing_cfw3212
    patch_qmanager_display_version
    patch_casa_display_name
    patch_casa_reboot
    patch_casa_scheduled_reboot_cfw3212
    patch_casa_watchcat_tiers
    patch_casa_watchcat_single_sim_cfw3212
    patch_casa_watchdog_ui_single_sim_cfw3212
    patch_casa_watchcat_ping_health_cfw3212
    merge_template_cfw3212 "components/nav-user.tsx"
    merge_template_cfw3212 "components/reboot/reboot-countdown.tsx"
    if ! upstream_has_v14_software_update; then
        copy_template_or_fallback "components/monitoring/software-update/update-preferences-card.tsx" "$TEMPLATE_DIR/components/monitoring/software-update/update-preferences-card.tsx"
        copy_template_or_fallback "components/monitoring/software-update/software-update.tsx" "$TEMPLATE_DIR/components/monitoring/software-update/software-update.tsx"
        copy_template_or_fallback "hooks/use-software-update.ts" "$TEMPLATE_DIR/hooks/use-software-update.ts"
    fi
    patch_casa_tailscale_tiny_cfw3212
    patch_casa_tailscale_install_label_cfw3212
    patch_casa_poller_boot_identity_cfw3212
    patch_casa_ippt_disable_clears_service_cfw3212
    patch_casa_band_locking_persist_cfw3212
    patch_email_alerts_casa_msmtp
    patch_ping_profile_service_toggle_cfw3212
    patch_casa_hide_video_optimizer_cfw3212
    patch_speedtest_latency_iqm_guard_cfw3212
    if upstream_has_v14_software_update; then
        patch_software_update_v14_cfw3212
    else
        patch_software_update_reboot_required_cfw3212
    fi
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
    if [ -f "$TARGET/scripts/usr/bin/qmanager_scheduled_reboot_arm" ]; then
        require_rg_present 'QManager scheduled reboot' "$TARGET/scripts/usr/bin/qmanager_scheduled_reboot" \
            "Scheduled Reboot timer worker must use Casa RDB managed reset"
    else
        require_rg_present "/usrdata/qmanager/crontabs" "$TARGET/scripts/usr/bin/qmanager_setup" \
            "qmanager_setup must store Scheduled Reboot cron data in writable persistent QManager storage"
        require_rg_present "crond -c /usrdata/qmanager/crontabs" "$TARGET/scripts/usr/bin/qmanager_setup" \
            "qmanager_setup must ensure BusyBox crond is running for Scheduled Reboot"
    fi
    require_rg_present "find /etc/qmanager -type d -exec chmod 750" "$TARGET/scripts/usr/bin/qmanager_setup" \
        "qmanager_setup must restrict /etc/qmanager directory permissions"
    require_rg_present "find /etc/qmanager -type f -exec chmod 640" "$TARGET/scripts/usr/bin/qmanager_setup" \
        "qmanager_setup must restrict /etc/qmanager file permissions"
    if [ ! -f "$TARGET/scripts/usr/bin/qmanager_scheduled_reboot_arm" ]; then
        require_rg_present '/usrdata/bin/qmanager_scheduled_reboot' "$TARGET/scripts/www/cgi-bin/quecmanager/system/settings.sh" \
            "Scheduled Reboot must target the Casa-installed helper path"
        require_rg_present '/usrdata/qmanager/crontabs/root' "$TARGET/scripts/www/cgi-bin/quecmanager/system/settings.sh" \
            "Scheduled Reboot must write cron entries to persistent writable Casa storage"
        require_rg_present 'cron_spool_unavailable' "$TARGET/scripts/www/cgi-bin/quecmanager/system/settings.sh" \
            "Scheduled Reboot must fail if the cron spool cannot be prepared"
        require_rg_present 'cron_write_failed' "$TARGET/scripts/www/cgi-bin/quecmanager/system/settings.sh" \
            "Scheduled Reboot must fail if writing the cron file fails"
    fi
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
    require_rg_present "/etc/systemd/system/qmanager\\*.service /etc/systemd/system/multi-user.target.wants/qmanager\\*.service" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers qmanager boot persistence must match Casa /etc systemd path"
    require_rg_clean "/lib/systemd/system/qmanager\\*.service" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not use stale /lib systemd path for qmanager boot persistence"
    require_rg_present "/tmp/qmanager-dnsmasq.conf.new /etc/data/dnsmasq.conf" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers Custom DNS mv rule must match Casa /tmp staging path (AI-62)"
    require_rg_clean "/bin/systemctl start \\*" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow broad systemctl start * (AI-62)"
    require_rg_clean "/usr/bin/crontab" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow crontab on Casa (AI-62)"
    require_rg_clean "killall -HUP dnsmasq" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not use obsolete dnsmasq killall reload (AI-62)"
    require_rg_present "/usrdata/bin/qmanager_iptables" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must allow qmanager_iptables helper only (AI-62 phase 2)"
    require_rg_clean "/usr/sbin/iptables" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow broad raw iptables (AI-62 phase 2)"
    require_rg_present "/usrdata/bin/qmanager_tailscale_cli" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must allow qmanager_tailscale_cli helper only (AI-62 phase 2)"
    require_rg_clean "/usrdata/tailscale/tailscale" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow broad raw Tailscale CLI (AI-62 phase 2)"
    require_rg_clean "/usrdata/tailscale/tailscaled" "$TARGET/scripts/etc/sudoers.d/qmanager" \
        "sudoers must not allow direct tailscaled commands (AI-62 phase 2)"
    require_rg_present "PING_STALE_RESTART_CYCLES" "$TARGET/scripts/usr/bin/qmanager_watchcat" \
        "watchcat must expose stale ping cache and restart qmanager-ping"
    require_rg_present "write_disabled_state" "$TARGET/scripts/usr/bin/qmanager_watchcat" \
        "watchcat must write disabled state on UI/service disable"
    require_rg_present "state=\"ping_\\$\\{ping_status\\}\"" "$TARGET/scripts/usr/bin/qmanager_watchcat" \
        "watchcat must report ping_missing/stale/invalid degraded states"
    require_rg_present "qmanager_iptables" "$TARGET/scripts/usr/lib/qmanager/platform.sh" \
        "platform.sh must call qmanager_iptables helper (AI-62 phase 2)"
    [ -x "$TARGET/scripts/usr/bin/qmanager_iptables" ] \
        || fail "Packaged qmanager_iptables helper must be executable"
    [ -x "$TARGET/scripts/usr/bin/qmanager_ip6tables" ] \
        || fail "Packaged qmanager_ip6tables helper must be executable"
    require_rg_present "qmanager_tailscale_cli" "$TARGET/scripts/www/cgi-bin/quecmanager/vpn/tailscale.sh" \
        "Tailscale CGI must call qmanager_tailscale_cli helper (AI-62 phase 2)"
    require_rg_clean '\\$_SUDO "\\$TAILSCALE_BIN"' "$TARGET/scripts/www/cgi-bin/quecmanager/vpn/tailscale.sh" \
        "Tailscale CGI must not sudo-run raw Tailscale binary (AI-62 phase 2)"
    [ -x "$TARGET/scripts/usr/bin/qmanager_tailscale_cli" ] \
        || fail "Packaged qmanager_tailscale_cli helper must be executable"
    # v0.1.12 sidebar items use `title: "..."`; v0.1.14+ resolves labels from
    # locale JSON via `t_key: "..."` instead (see patch_terminal_sidebar_children_cfw3212).
    require_rg_present '(title: "AT Terminal"|t_key: "at_terminal")' "$TARGET/components/app-sidebar.tsx" \
        "Terminals sidebar dropdown must show AT Terminal"
    require_rg_present '(title: "Web Console"|t_key: "web_console")' "$TARGET/components/app-sidebar.tsx" \
        "Terminals sidebar dropdown must show Web Console"

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
