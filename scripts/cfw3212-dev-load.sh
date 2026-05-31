#!/usr/bin/env bash
#
# cfw3212-dev-load.sh — load dev/working-branch QManager Casa builds (or
# individual converted files) onto a LIVE CFW-3212 router for pre-release
# testing, without cutting a public package release.
#
# The builder workflow forces dry_run on any non-main branch, so a `dev` build
# never publishes — it only uploads a `casa-cfw3212-publish-<tag>` artifact.
# This script pulls that artifact (the fully-converted package) and either does
# a full offline install or hot-patches individual files onto a running install.
#
# IMPORTANT: hot-patch sources files from the CONVERTED package (the artifact /
# tarball), never from the raw repo templates — the converter transforms them
# (PACKAGE_REPO substitution, poller AT-command patches, CR fixes), so raw
# templates would NOT match what runs on device. Use --file for a verbatim push
# only when you have already converted the file yourself.
#
# Usage:
#   cfw3212-dev-load.sh fetch    [--run RUN_ID] [--branch dev]
#   cfw3212-dev-load.sh install  [--run RUN_ID | --tarball PATH] [--yes]
#   cfw3212-dev-load.sh hotpatch [--run RUN_ID | --tarball PATH] [--yes] COMPONENT...
#
#   COMPONENT (hotpatch): cgi-update | updater | poller | platform | all
#                         --file LOCAL:REMOTE   (push an arbitrary local file verbatim)
#
# Environment:
#   CFW3212_BOX   ssh target for the router (default: cfw3212-router) — set this to your box
#   BUILDER_REPO  GitHub repo for artifacts (default: Joetooley28/qmanager-casa-cfw3212-builder)
#   BUILD_BRANCH  branch to pull the latest run from when --run is omitted (default: dev)
#
# Notes:
#   - scp to the modem MUST use -O (the modem has no sftp subsystem).
#   - Writes to a live router; prompts for confirmation unless --yes is given.
#
set -euo pipefail

BOX="${CFW3212_BOX:-cfw3212-router}"   # override with CFW3212_BOX to match your ssh config
REPO="${BUILDER_REPO:-Joetooley28/qmanager-casa-cfw3212-builder}"
BRANCH="${BUILD_BRANCH:-dev}"
WORKFLOW="build-casa-package.yml"

RUN_ID=""
TARBALL=""
ASSUME_YES=0
declare -a EXTRA_FILES=()
declare -a COMPONENTS=()

die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo ">> $*" >&2; }

# component -> "tarball-relative-path|on-device-path|service-to-restart-or-empty"
component_spec() {
  case "$1" in
    cgi-update) echo "qmanager_install/scripts/www/cgi-bin/quecmanager/system/update.sh|/usrdata/qmanager/www/cgi-bin/quecmanager/system/update.sh|lighttpd" ;;
    updater)    echo "qmanager_install/scripts/usr/bin/qmanager_update|/usrdata/bin/qmanager_update|" ;;
    poller)     echo "qmanager_install/scripts/usr/bin/qmanager_poller|/usrdata/bin/qmanager_poller|qmanager-poller" ;;
    platform)   echo "qmanager_install/scripts/usr/lib/qmanager/platform.sh|/usrdata/qmanager/lib/platform.sh|" ;;
    *) return 1 ;;
  esac
}

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '%s [y/N] ' "$1" >&2
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) die "aborted by user" ;; esac
}

# Resolve the latest run id on $BRANCH if none was given.
resolve_run() {
  [ -n "$RUN_ID" ] && return 0
  note "Finding latest '$WORKFLOW' run on branch '$BRANCH' in $REPO ..."
  RUN_ID="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" \
            --limit 1 --json databaseId,status,conclusion,headSha \
            --jq '.[0].databaseId' 2>/dev/null || true)"
  [ -n "$RUN_ID" ] || die "no runs found on branch '$BRANCH'; dispatch a dry-run build there first"
  note "Using run $RUN_ID"
}

# Download + extract the publish bundle; sets TARBALL to the converted .tar.gz.
fetch_tarball() {
  [ -n "$TARBALL" ] && { [ -f "$TARBALL" ] || die "tarball not found: $TARBALL"; return 0; }
  resolve_run
  local dl; dl="$(mktemp -d /tmp/cfw3212-dl.XXXXXX)"
  note "Downloading publish bundle from run $RUN_ID ..."
  gh run download "$RUN_ID" --repo "$REPO" --pattern 'casa-cfw3212-publish-*' --dir "$dl" \
    || die "could not download a 'casa-cfw3212-publish-*' artifact from run $RUN_ID"
  TARBALL="$(find "$dl" -name 'qmanager-cfw3212-*.tar.gz' | head -1)"
  [ -n "$TARBALL" ] || die "no qmanager-cfw3212-*.tar.gz inside the artifact"
  note "Package: $TARBALL"
}

check_box() {
  note "Checking router '$BOX' is reachable ..."
  ssh -o ConnectTimeout=15 -o BatchMode=yes "$BOX" 'echo ok; cat /etc/qmanager/VERSION 2>/dev/null || echo "(no VERSION yet)"' \
    || die "cannot reach router '$BOX' (set CFW3212_BOX to your router's ssh target and check connectivity)"
}

cmd_fetch() { fetch_tarball; echo "$TARBALL"; }

cmd_install() {
  fetch_tarball
  check_box
  confirm "Full offline install of $(basename "$TARBALL") onto '$BOX' (overwrites the current install)?"
  note "Copying package to $BOX:/tmp/qmanager.tar.gz ..."
  scp -O "$TARBALL" "$BOX:/tmp/qmanager.tar.gz"
  note "Running offline installer on $BOX ..."
  ssh "$BOX" 'set -e; cd /tmp; rm -rf qmanager_install; tar xzf qmanager.tar.gz; sh /tmp/qmanager_install/install_cfw3212.sh'
  note "Install finished. Check the UI / About Device."
}

cmd_hotpatch() {
  [ "${#COMPONENTS[@]}" -gt 0 ] || [ "${#EXTRA_FILES[@]}" -gt 0 ] || die "hotpatch: name at least one component or --file LOCAL:REMOTE"

  # Expand 'all'
  local -a comps=()
  for c in "${COMPONENTS[@]}"; do
    if [ "$c" = "all" ]; then comps=(cgi-update updater poller platform); else comps+=("$c"); fi
  done

  local need_tarball=0
  [ "${#comps[@]}" -gt 0 ] && need_tarball=1
  [ "$need_tarball" = "1" ] && fetch_tarball
  check_box

  local work; work="$(mktemp -d /tmp/cfw3212-hp.XXXXXX)"
  [ "$need_tarball" = "1" ] && tar xzf "$TARBALL" -C "$work"

  declare -a plan_local=() plan_remote=() plan_svc=()

  for c in "${comps[@]}"; do
    local spec; spec="$(component_spec "$c")" || die "unknown component: $c"
    local rel="${spec%%|*}"; local rest="${spec#*|}"
    local dev="${rest%%|*}"; local svc="${rest#*|}"
    local src="$work/$rel"
    [ -f "$src" ] || die "component '$c' not found in package: $rel"
    # Match installer behavior: strip CR from shebang scripts.
    if head -c2 "$src" 2>/dev/null | grep -q '#!'; then sed -i 's/\r$//' "$src"; fi
    plan_local+=("$src"); plan_remote+=("$dev"); plan_svc+=("$svc")
  done

  for pair in "${EXTRA_FILES[@]}"; do
    local lf="${pair%%:*}"; local rf="${pair#*:}"
    [ -f "$lf" ] || die "--file local path not found: $lf"
    [ "$rf" != "$pair" ] && [ -n "$rf" ] || die "--file expects LOCAL:REMOTE (got '$pair')"
    plan_local+=("$lf"); plan_remote+=("$rf"); plan_svc+=("")
  done

  note "Hot-patch plan for '$BOX':"
  local i
  for i in "${!plan_local[@]}"; do
    printf '   %s  ->  %s%s\n' "$(basename "${plan_local[$i]}")" "${plan_remote[$i]}" \
      "$([ -n "${plan_svc[$i]}" ] && echo "   (restart ${plan_svc[$i]})")" >&2
  done
  confirm "Push these file(s) to the running install on '$BOX'?"

  declare -A restart_set=()
  for i in "${!plan_local[@]}"; do
    note "scp ${plan_remote[$i]}"
    scp -O "${plan_local[$i]}" "$BOX:${plan_remote[$i]}"
    ssh "$BOX" "chmod 755 '${plan_remote[$i]}'"
    [ -n "${plan_svc[$i]}" ] && restart_set["${plan_svc[$i]}"]=1
  done

  for svc in "${!restart_set[@]}"; do
    note "systemctl restart $svc"
    ssh "$BOX" "systemctl restart $svc"
  done
  note "Hot-patch complete."
}

# ---- arg parsing ----
[ "$#" -ge 1 ] || die "usage: $0 {fetch|install|hotpatch} [options]"
SUB="$1"; shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --run) RUN_ID="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --box) BOX="$2"; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --file) EXTRA_FILES+=("$2"); shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) COMPONENTS+=("$1"); shift ;;
  esac
done

case "$SUB" in
  fetch) cmd_fetch ;;
  install) cmd_install ;;
  hotpatch) cmd_hotpatch ;;
  *) die "unknown subcommand: $SUB (use fetch|install|hotpatch)" ;;
esac
