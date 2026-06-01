#!/bin/sh
. /usrdata/qmanager/lib/cgi_base.sh
. /usrdata/qmanager/lib/config.sh 2>/dev/null || true

# Casa CFW-3212 manual updater.
# Checks the Casa package repo, not upstream QManager, and only installs
# verified converted Casa tarballs after explicit user action.

qlog_init "cgi_system_update"
cgi_headers
cgi_handle_options

PACKAGE_REPO="${QMANAGER_CFW3212_REPO:-Joetooley28/qmanager-casa-cfw3212-package}"
VERSION_FILE="/etc/qmanager/VERSION"
UPDATES_DIR="/etc/qmanager/updates"
STATUS_FILE="/tmp/qmanager_update.json"
PID_FILE="/tmp/qmanager_update.pid"
STAGED_TARBALL="/tmp/qmanager_staged.tar.gz"
STAGED_VERSION="/tmp/qmanager_staged_version"
UPDATER="/usrdata/bin/qmanager_update"

get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        echo "0.0.0-cfw3212.0"
    fi
}

qm_update_get() {
    if command -v qm_config_get >/dev/null 2>&1; then
        qm_config_get update "$1" "$2"
    else
        echo "$2"
    fi
}

qm_update_set() {
    if command -v qm_config_set >/dev/null 2>&1; then
        qm_config_set update "$1" "$2"
    fi
}

ensure_update_config() {
    command -v qm_config_init >/dev/null 2>&1 && qm_config_init || true
}

# GitHub release list + changelog fetches are slow on-router (~30–60s cold).
# Cache API/processed lists briefly; cache per-tag changelogs longer. Pass
# ?refresh=1 (Software Update → Check for Updates) to bypass.
RELEASES_API_CACHE="/tmp/qm_cfw3212_releases_api.json"
RELEASES_API_CACHE_HDR="/tmp/qm_cfw3212_releases_api.headers"
RELEASES_API_CACHE_TTL=300
RELEASES_PROCESSED_CACHE="/tmp/qm_cfw3212_releases_processed.json"
RELEASES_PROCESSED_CACHE_TTL=300
CHANGELOG_CACHE_DIR="/tmp/qm_cfw3212_changelog_cache"
CHANGELOG_CACHE_TTL=3600

cache_mtime_age() {
    local f="$1"
    [ -f "$f" ] || return 1
    echo $(($(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0)))
}

cache_is_fresh() {
    local file="$1" ttl="$2"
    [ -f "$file" ] || return 1
    [ "$(cache_mtime_age "$file")" -lt "$ttl" ]
}

invalidate_update_release_caches() {
    rm -f "$RELEASES_API_CACHE" "$RELEASES_API_CACHE_HDR" "$RELEASES_PROCESSED_CACHE"
}

query_requests_refresh() {
    echo "$QUERY_STRING" | grep -qE '(^|&)refresh=1(&|$)'
}

http_api_fetch() {
    local url="$1" out_file="$2" header_file="$3" timeout="${4:-20}"
    if command -v curl >/dev/null 2>&1; then
        curl -sL --max-time "$timeout" -H "Accept: application/vnd.github+json" \
            -o "$out_file" -D "$header_file" "$url" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -qO "$out_file" -T "$timeout" "$url" 2>"$header_file" && return 0
    fi
    if command -v uclient-fetch >/dev/null 2>&1; then
        uclient-fetch -qO "$out_file" --timeout="$timeout" "$url" 2>"$header_file" && return 0
    fi
    return 1
}

strip_casa_suffix() {
    printf '%s' "$1" | sed 's/-cfw3212\..*$//'
}

casa_build_number() {
    case "$1" in
        *-cfw3212.*) printf '%s' "${1##*-cfw3212.}" | sed 's/\..*//' ;;
        *) printf '0' ;;
    esac
}

# 1 = release channel (vX.Y.Z-cfw3212.N), 0 = dev channel (…N.dev).
casa_channel_rank() {
    local suffix="${1##*-cfw3212.}"
    case "$suffix" in
        *.*) printf '0' ;;
        *) printf '1' ;;
    esac
}

# Exit codes: 0 = $1 newer, 1 = same, 2 = $1 older.
casa_version_compare() {
    local a="$1" b="$2" a_base b_base a_build b_build
    a_base="$(strip_casa_suffix "$a")"
    b_base="$(strip_casa_suffix "$b")"
    a_base="${a_base#v}"
    b_base="${b_base#v}"
    a_build="$(casa_build_number "$a")"
    b_build="$(casa_build_number "$b")"

    local a1 a2 a3 b1 b2 b3
    IFS='.' read a1 a2 a3 <<EOF
$a_base
EOF
    IFS='.' read b1 b2 b3 <<EOF
$b_base
EOF
    a1=${a1:-0}; a2=${a2:-0}; a3=${a3:-0}
    b1=${b1:-0}; b2=${b2:-0}; b3=${b3:-0}
    [ "$a1" -gt "$b1" ] 2>/dev/null && return 0
    [ "$a1" -lt "$b1" ] 2>/dev/null && return 2
    [ "$a2" -gt "$b2" ] 2>/dev/null && return 0
    [ "$a2" -lt "$b2" ] 2>/dev/null && return 2
    [ "$a3" -gt "$b3" ] 2>/dev/null && return 0
    [ "$a3" -lt "$b3" ] 2>/dev/null && return 2
    [ "$a_build" -gt "$b_build" ] 2>/dev/null && return 0
    [ "$a_build" -lt "$b_build" ] 2>/dev/null && return 2
    local a_rank b_rank
    a_rank="$(casa_channel_rank "$a")"
    b_rank="$(casa_channel_rank "$b")"
    [ "$a_rank" -gt "$b_rank" ] && return 0
    [ "$a_rank" -lt "$b_rank" ] && return 2
    return 1
}

check_lock() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if pid_alive "$pid"; then
            cgi_error "update_in_progress" "An update is already in progress"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi
}

asset_name_for_tag() {
    # Asset name carries the full Casa tag (e.g. v0.1.12-cfw3212.15) so every
    # build is uniquely named and manual downloads never collide (AI-56 follow-up).
    printf 'qmanager-cfw3212-%s.tar.gz' "$1"
}

checksum_name_for_tag() {
    printf 'qmanager-cfw3212-%s.sha256' "$1"
}

# Pre-99c5c47 releases named assets after the upstream version only
# (e.g. qmanager-cfw3212-v0.1.12.tar.gz, shared across every build of that
# upstream). Accept these too so older releases stay installable for rollback.
asset_name_old_for_tag() {
    printf 'qmanager-cfw3212-%s.tar.gz' "$(strip_casa_suffix "$1")"
}

checksum_name_old_for_tag() {
    printf 'qmanager-cfw3212-%s.sha256' "$(strip_casa_suffix "$1")"
}

changelog_name_for_tag() {
    local tag="$1"
    printf 'qmanager-cfw3212-%s-changelog.json' "$tag"
}

download_url_for_tag() {
    local tag="$1"
    printf 'https://github.com/%s/releases/download/%s/%s' \
        "$PACKAGE_REPO" "$tag" "$(asset_name_for_tag "$tag")"
}

checksum_url_for_tag() {
    local tag="$1"
    printf 'https://github.com/%s/releases/download/%s/%s' \
        "$PACKAGE_REPO" "$tag" "$(checksum_name_for_tag "$tag")"
}

changelog_url_for_tag() {
    local tag="$1"
    printf 'https://github.com/%s/releases/download/%s/%s' \
        "$PACKAGE_REPO" "$tag" "$(changelog_name_for_tag "$tag")"
}

# Dev sideload tags (v0.1.12-cfw3212.N.dev) are not published on the package repo.
# Try the exact tag, the stripped tag, then the newest official Casa build that is
# still on the same upstream base (so release notes stay populated on .dev installs).
changelog_candidates() {
    local want="$1" releases="$2" stripped
    [ -n "$want" ] || return 0
    printf '%s\n' "$want"
    case "$want" in
        *.dev)
            stripped="${want%.dev}"
            [ "$stripped" != "$want" ] && printf '%s\n' "$stripped"
            printf '%s' "$releases" | jq -r --arg want "$want" '
              def build_num(t):
                (t | split("-cfw3212.")[1] // "" | split(".")[0] | tonumber? // 0);
              def is_official(t):
                (t | test("-cfw3212\\.[0-9]+$"));
              (build_num($want)) as $wb
              | [
                  ([.[] | select(.tag_name | is_official) | select(build_num(.tag_name) <= $wb) | .tag_name] | last),
                  (.[0].tag_name // empty)
                ]
              | map(select(length > 0))
              | unique
              | .[]
            ' 2>/dev/null
            ;;
    esac
}

changelog_json_has_notes() {
    local file="$1"
    jq -e '((.joetooley_notes // "") != "") or ((.upstream_notes // "") != "")' "$file" >/dev/null 2>&1
}

fetch_changelog_for_tag() {
    local tag="$1" out_file="$2" releases="${3:-}" try_tag tmp_body tmp_headers url cache_file
    [ -n "$tag" ] || { printf '{}\n' > "$out_file"; return 0; }

    mkdir -p "$CHANGELOG_CACHE_DIR" 2>/dev/null || true

    for try_tag in $(changelog_candidates "$tag" "$releases"); do
        [ -n "$try_tag" ] || continue
        cache_file="$CHANGELOG_CACHE_DIR/${try_tag}.json"
        if [ "${QM_UPDATE_FORCE_REFRESH:-0}" = "0" ] \
            && cache_is_fresh "$cache_file" "$CHANGELOG_CACHE_TTL" \
            && changelog_json_has_notes "$cache_file"; then
            cp "$cache_file" "$out_file" 2>/dev/null || printf '{}\n' > "$out_file"
            return 0
        fi

        tmp_body="/tmp/qm_cfw3212_changelog_${try_tag}.json"
        tmp_headers="/tmp/qm_cfw3212_changelog_${try_tag}.headers"
        url="$(changelog_url_for_tag "$try_tag")"
        rm -f "$tmp_body" "$tmp_headers"

        if http_api_fetch "$url" "$tmp_body" "$tmp_headers" 15 \
            && changelog_json_has_notes "$tmp_body"; then
            cp "$tmp_body" "$out_file" 2>/dev/null || printf '{}\n' > "$out_file"
            cp "$tmp_body" "$cache_file" 2>/dev/null || true
            rm -f "$tmp_body" "$tmp_headers"
            return 0
        fi
        rm -f "$tmp_body" "$tmp_headers"
    done

    printf '{}\n' > "$out_file"
}

start_update_worker() {
    local unit="$1"
    shift

    if command -v systemd-run >/dev/null 2>&1; then
        systemd-run --unit="$unit" --collect \
            /bin/sh -c 'exec "$@" </dev/null >>/tmp/qmanager_update.log 2>&1' \
            qmanager-update-worker "$@" >/dev/null 2>&1 && return 0
    fi

    ( "$@" </dev/null >>/tmp/qmanager_update.log 2>&1 & )
    return 0
}

if [ "$REQUEST_METHOD" = "GET" ]; then
    action=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')

    if [ "$action" = "status" ]; then
        if [ -f "$STATUS_FILE" ]; then
            cat "$STATUS_FILE"
        else
            jq -n '{"status":"idle"}'
        fi
        exit 0
    fi

    ensure_update_config
    current_version=$(get_current_version)
    include_prerelease=$(qm_update_get include_prerelease 1)
    auto_time=$(qm_update_get auto_update_time "03:00")
    include_prerelease_json="$( [ "$include_prerelease" = "1" ] && echo true || echo false )"
    # check = latest-version probe (auto on page load). versions = dropdown list (cached).
    [ -z "$action" ] && action=check
    UPDATE_SKIP_CHANGELOGS=0
    UPDATE_SKIP_VERSION_LIST=0
    UPDATE_VERSIONS_CACHE_ONLY=0
    case "$action" in
        check)
            UPDATE_SKIP_VERSION_LIST=1
            ;;
        versions)
            UPDATE_SKIP_CHANGELOGS=1
            UPDATE_VERSIONS_CACHE_ONLY=1
            ;;
        *)
            action=check
            UPDATE_SKIP_VERSION_LIST=1
            ;;
    esac
    if query_requests_refresh; then
        QM_UPDATE_FORCE_REFRESH=1
        invalidate_update_release_caches
        UPDATE_VERSIONS_CACHE_ONLY=0
    else
        QM_UPDATE_FORCE_REFRESH=0
    fi

    api_url="https://api.github.com/repos/$PACKAGE_REPO/releases"
    tmp_body="/tmp/qm_cfw3212_update_api_body.json"
    tmp_headers="/tmp/qm_cfw3212_update_api_headers.txt"
    releases=""
    releases_from_cache=0

    if [ "$QM_UPDATE_FORCE_REFRESH" = "0" ] \
        && cache_is_fresh "$RELEASES_PROCESSED_CACHE" "$RELEASES_PROCESSED_CACHE_TTL" \
        && jq -e --argjson ip "$include_prerelease_json" \
            '.include_prerelease == $ip and (.releases | type) == "array"' \
            "$RELEASES_PROCESSED_CACHE" >/dev/null 2>&1; then
        releases=$(jq -c '.releases' "$RELEASES_PROCESSED_CACHE" 2>/dev/null)
        [ -n "$releases" ] || releases="[]"
        releases_from_cache=1
    fi

    if [ "$releases_from_cache" = "0" ]; then
        api_fetch_ok=0
        if [ "$QM_UPDATE_FORCE_REFRESH" = "0" ] \
            && cache_is_fresh "$RELEASES_API_CACHE" "$RELEASES_API_CACHE_TTL"; then
            cp "$RELEASES_API_CACHE" "$tmp_body" 2>/dev/null \
                && cp "$RELEASES_API_CACHE_HDR" "$tmp_headers" 2>/dev/null \
                && api_fetch_ok=1
        fi
        if [ "$api_fetch_ok" = "0" ]; then
            rm -f "$tmp_body" "$tmp_headers"
            if ! http_api_fetch "$api_url" "$tmp_body" "$tmp_headers"; then
                rm -f "$tmp_body" "$tmp_headers"
                invalidate_update_release_caches
                jq -n \
                    --arg cv "$current_version" \
                    --argjson include_prerelease_bool "$include_prerelease_json" \
                    --arg auto_time "$auto_time" \
                    '{
                        success: true, current_version: $cv,
                        latest_version: null, update_available: false,
                        changelog: null, current_changelog: null,
                        download_url: null, download_size: null,
                        available_versions: [], download_state: null,
                        include_prerelease: $include_prerelease_bool,
                        auto_update_enabled: false,
                        auto_update_time: $auto_time,
                        check_error: "Unable to check Casa package releases. Confirm the package repo is public and the router has internet."
                    }'
                exit 0
            fi
            cp "$tmp_body" "$RELEASES_API_CACHE" 2>/dev/null || true
            cp "$tmp_headers" "$RELEASES_API_CACHE_HDR" 2>/dev/null || true
        fi

        if grep -qi "403 Forbidden\|HTTP/[0-9.]* 403" "$tmp_headers" 2>/dev/null; then
            rm -f "$tmp_body" "$tmp_headers"
            invalidate_update_release_caches
            jq -n \
                --arg cv "$current_version" \
                --argjson include_prerelease_bool "$include_prerelease_json" \
                --arg auto_time "$auto_time" \
                '{
                    success: true, current_version: $cv,
                    latest_version: null, update_available: false,
                    changelog: null, current_changelog: null,
                    download_url: null, download_size: null,
                    available_versions: [], download_state: null,
                    include_prerelease: $include_prerelease_bool,
                    auto_update_enabled: false,
                    auto_update_time: $auto_time,
                    check_error: "GitHub rate limit or access error while checking Casa package releases."
                }'
            exit 0
        fi

        api_response=$(cat "$tmp_body" 2>/dev/null)
        rm -f "$tmp_body" "$tmp_headers"

        # Only Casa package releases are considered installable.
        # language-packs and upstream QManager assets are intentionally ignored.
        casa_filter='[
          .[]
          | select(.draft == false)
          | select(.tag_name | startswith("v"))
          | select(.tag_name | contains("-cfw3212."))
          | . as $rel
          | ($rel.tag_name | split("-cfw3212.")[0]) as $up
          | ("qmanager-cfw3212-" + $rel.tag_name + ".tar.gz") as $tar_new
          | ("qmanager-cfw3212-" + $rel.tag_name + ".sha256") as $sha_new
          | ("qmanager-cfw3212-" + $up + ".tar.gz") as $tar_old
          | ("qmanager-cfw3212-" + $up + ".sha256") as $sha_old
          | select(any($rel.assets[]?; .name == $tar_new) or any($rel.assets[]?; .name == $tar_old))
          | select(any($rel.assets[]?; .name == $sha_new) or any($rel.assets[]?; .name == $sha_old))
        ]'

        releases=$(printf '%s' "$api_response" | jq "$casa_filter" 2>/dev/null)
        [ -n "$releases" ] || releases="[]"
        if [ "$include_prerelease" != "1" ]; then
            releases=$(printf '%s' "$releases" | jq '[ .[] | select(.prerelease == false) ]' 2>/dev/null)
            [ -n "$releases" ] || releases="[]"
        fi

        releases=$(printf '%s' "$releases" | jq 'sort_by([
            (.tag_name | ltrimstr("v") | split("-cfw3212.")[0] | split(".") | map(tonumber? // 0)),
            (.tag_name | split("-cfw3212.")[1] | split(".")[0] | tonumber? // 0),
            (if (.tag_name | split("-cfw3212.")[1] | contains(".")) then 0 else 1 end)
          ]) | reverse' 2>/dev/null)
        [ -n "$releases" ] || releases="[]"

        jq -n \
            --argjson releases "$releases" \
            --argjson include_prerelease_bool "$include_prerelease_json" \
            '{include_prerelease: $include_prerelease_bool, releases: $releases}' \
            > "$RELEASES_PROCESSED_CACHE" 2>/dev/null || true
    fi

    if [ "$UPDATE_VERSIONS_CACHE_ONLY" = "1" ] && [ "$releases_from_cache" = "0" ]; then
        jq -n \
            --argjson include_prerelease_bool "$include_prerelease_json" \
            '{
                success: true,
                available_versions: [],
                versions_from_cache: false,
                versions_cache_miss: true,
                include_prerelease: $include_prerelease_bool
            }'
        exit 0
    fi

    latest_tag=$(printf '%s' "$releases" | jq -r '.[0].tag_name // empty')
    changelog=""
    current_changelog=""
    joetooley_changelog=""
    upstream_changelog=""
    upstream_release_url=""
    current_joetooley_changelog=""
    current_upstream_changelog=""
    if [ "$UPDATE_SKIP_CHANGELOGS" != "1" ]; then
        changelog=$(printf '%s' "$releases" | jq -r '.[0].body // empty')
        current_changelog=$(printf '%s' "$releases" | jq -r --arg cv "$current_version" '[ .[] | select(.tag_name == $cv) ][0].body // empty')

        latest_changelog_json="/tmp/qm_cfw3212_latest_changelog.json"
        current_changelog_json="/tmp/qm_cfw3212_current_changelog.json"
        fetch_changelog_for_tag "$latest_tag" "$latest_changelog_json" "$releases"
        if [ "$current_version" = "$latest_tag" ]; then
            cp "$latest_changelog_json" "$current_changelog_json" 2>/dev/null || printf '{}\n' > "$current_changelog_json"
        else
            fetch_changelog_for_tag "$current_version" "$current_changelog_json" "$releases"
        fi
        joetooley_changelog=$(jq -r '.joetooley_notes // empty' "$latest_changelog_json" 2>/dev/null)
        upstream_changelog=$(jq -r '.upstream_notes // empty' "$latest_changelog_json" 2>/dev/null)
        upstream_release_url=$(jq -r '.upstream_release_url // empty' "$latest_changelog_json" 2>/dev/null)
        current_joetooley_changelog=$(jq -r '.joetooley_notes // empty' "$current_changelog_json" 2>/dev/null)
        current_upstream_changelog=$(jq -r '.upstream_notes // empty' "$current_changelog_json" 2>/dev/null)
        rm -f "$latest_changelog_json" "$current_changelog_json"
    fi

    download_state="null"
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if pid_alive "$pid" && [ -f "$STATUS_FILE" ]; then
            download_state=$(cat "$STATUS_FILE" 2>/dev/null)
        fi
    elif [ -f "$STAGED_TARBALL" ] && [ -f "$STAGED_VERSION" ]; then
        staged_ver=$(cat "$STAGED_VERSION" 2>/dev/null)
        staged_size=$(du -k "$STAGED_TARBALL" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
        download_state=$(jq -n \
            --arg status "ready" \
            --arg version "$staged_ver" \
            --arg message "Download verified ($staged_size)" \
            --arg size "$staged_size" \
            '{status: $status, version: $version, message: $message, size: $size}')
    fi

    if [ "$UPDATE_SKIP_VERSION_LIST" = "1" ]; then
        available_versions='[]'
    else
        available_versions=$(printf '%s' "$releases" | jq \
            --arg cv "$current_version" \
            '[ .[] | .tag_name as $t | {
                tag: .tag_name,
                has_assets: true,
                asset_size: (((([ .assets[] | select(.name == ("qmanager-cfw3212-" + $t + ".tar.gz")) ][0].size) // ([ .assets[] | select(.name == ("qmanager-cfw3212-" + ($t | split("-cfw3212.")[0]) + ".tar.gz")) ][0].size) // 0) / 1048576 * 10 | floor / 10 | tostring + " MB")),
                is_current: (.tag_name == $cv)
            }]')
    fi

    if [ "$action" = "versions" ]; then
        versions_from_cache_json=false
        [ "$releases_from_cache" = "1" ] && versions_from_cache_json=true
        jq -n \
            --argjson av "$available_versions" \
            --argjson include_prerelease_bool "$include_prerelease_json" \
            --argjson versions_from_cache "$versions_from_cache_json" \
            '{
                success: true,
                available_versions: $av,
                versions_from_cache: $versions_from_cache,
                versions_cache_miss: false,
                include_prerelease: $include_prerelease_bool
            }'
        exit 0
    fi

    download_url=""
    download_size=""
    if [ -n "$latest_tag" ]; then
        download_url="$(download_url_for_tag "$latest_tag")"
        download_size=$(printf '%s' "$releases" | jq -r --arg t "$latest_tag" '(([ .[0].assets[] | select(.name == ("qmanager-cfw3212-" + $t + ".tar.gz")) ][0].size) // ([ .[0].assets[] | select(.name == ("qmanager-cfw3212-" + ($t | split("-cfw3212.")[0]) + ".tar.gz")) ][0].size)) as $sz | if $sz then ($sz / 1048576 * 10 | floor / 10 | tostring + " MB") else "" end' 2>/dev/null | head -n1)
    fi

    update_available="false"
    if [ -n "$latest_tag" ]; then
        casa_version_compare "$latest_tag" "$current_version"
        [ "$?" = "0" ] && update_available="true"
    fi

    jq -n \
        --arg cv "$current_version" \
        --arg lv "$latest_tag" \
        --argjson ua "$update_available" \
        --arg cl "$changelog" \
        --arg ccl "$current_changelog" \
        --arg jcl "$joetooley_changelog" \
        --arg ucl "$upstream_changelog" \
        --arg cjcl "$current_joetooley_changelog" \
        --arg cucl "$current_upstream_changelog" \
        --arg uurl "$upstream_release_url" \
        --arg dl "$download_url" \
        --arg ds "$download_size" \
        --argjson av "$available_versions" \
        --argjson ds_obj "$download_state" \
        --argjson include_prerelease_bool "$include_prerelease_json" \
        --arg auto_time "$auto_time" \
        '{
            success: true,
            current_version: $cv,
            latest_version: (if $lv == "" then null else $lv end),
            update_available: $ua,
            changelog: (if $cl == "" then null else $cl end),
            current_changelog: (if $ccl == "" then null else $ccl end),
            joetooley_changelog: (if $jcl == "" then null else $jcl end),
            upstream_changelog: (if $ucl == "" then null else $ucl end),
            current_joetooley_changelog: (if $cjcl == "" then null else $cjcl end),
            current_upstream_changelog: (if $cucl == "" then null else $cucl end),
            upstream_release_url: (if $uurl == "" then null else $uurl end),
            download_url: (if $dl == "" then null else $dl end),
            download_size: (if $ds == "" then null else $ds end),
            available_versions: $av,
            download_state: $ds_obj,
            include_prerelease: $include_prerelease_bool,
            auto_update_enabled: false,
            auto_update_time: $auto_time,
            check_error: null
        }'
    exit 0
fi

if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post
    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')
    [ -n "$ACTION" ] || { cgi_error "missing_action" "action field is required"; exit 0; }

    if [ "$ACTION" = "save_prerelease" ]; then
        enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled // false')
        if [ "$enabled" = "true" ] || [ "$enabled" = "1" ]; then
            qm_update_set include_prerelease 1
        else
            qm_update_set include_prerelease 0
        fi
        invalidate_update_release_caches
        cgi_success
        exit 0
    fi

    if [ "$ACTION" = "save_auto_update" ]; then
        cgi_error "auto_update_disabled_on_cfw3212" "Automatic updates are disabled in the Casa CFW-3212 build."
        exit 0
    fi

    if [ "$ACTION" = "download" ]; then
        check_lock
        version=$(printf '%s' "$POST_DATA" | jq -r '.version // empty')
        if ! printf '%s' "$version" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+-cfw3212\.[0-9]+$'; then
            cgi_error "invalid_version" "Version must be a Casa CFW-3212 release tag."
            exit 0
        fi
        download_url="$(download_url_for_tag "$version")"
        checksum_url="$(checksum_url_for_tag "$version")"
        if ! start_update_worker "qmanager-update-download" "$UPDATER" download "$download_url" "$checksum_url" "$version"; then
            cgi_error "update_start_failed" "Could not start the Casa update download worker."
            exit 0
        fi
        jq -n '{"success":true,"status":"starting"}'
        exit 0
    fi

    if [ "$ACTION" = "install_staged" ]; then
        check_lock
        [ -f "$STAGED_TARBALL" ] || { cgi_error "no_staged" "No staged download found. Download first."; exit 0; }
        if ! start_update_worker "qmanager-update-install" "$UPDATER" install_staged; then
            cgi_error "update_start_failed" "Could not start the Casa update install worker."
            exit 0
        fi
        jq -n '{"success":true,"status":"starting"}'
        exit 0
    fi

    if [ "$ACTION" = "clear_staged" ]; then
        check_lock
        rm -f "$STAGED_TARBALL" "$STAGED_VERSION" "$STATUS_FILE"
        jq -n '{"success":true,"status":"cleared"}'
        exit 0
    fi

    if [ "$ACTION" = "reboot_now" ]; then
        jq -n '{"success":true,"status":"rebooting"}'
        jq -n \
            --arg status "rebooting" \
            --arg message "Rebooting device..." \
            '{status: $status, message: $message}' > "$STATUS_FILE"
        (
            sleep 1
            if command -v rdb_set >/dev/null 2>&1 && command -v rdb_get >/dev/null 2>&1 && rdb_get service.system.reset >/dev/null 2>&1; then
                rdb_set service.system.reset_reason "QManager GUI update reboot"
                rdb_set service.system.reset.delay 5
                rdb_set service.system.reset 1
            else
                _reboot_cmd="reboot"
                command -v run_reboot >/dev/null 2>&1 && _reboot_cmd="run_reboot"
                $_reboot_cmd
            fi
        ) </dev/null >/dev/null 2>&1 &
        exit 0
    fi

    if [ "$ACTION" = "install" ]; then
        cgi_error "unsupported_on_cfw3212" "Use the Casa two-step download and install flow."
        exit 0
    fi

    if [ "$ACTION" = "rollback" ]; then
        cgi_error "unsupported_on_cfw3212" "Select an older Casa release from Version Management instead."
        exit 0
    fi

    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

cgi_method_not_allowed
