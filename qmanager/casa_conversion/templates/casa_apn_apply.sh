
# =============================================================================
# Casa CFW-3212: apn_apply_write through Casa's connection manager
# =============================================================================
# Casa owns the data context (CID 1 = link.profile.1, module_profile_idx=1).
# Upstream's bracket writes AT+CGDCONT and does a raw AT+COPS=2/0 re-attach
# behind Casa's back, which leaves link.profile.1.apn and the modem disagreeing
# and can strand the session. On Casa, CID 1 instead goes through the RDB
# profile plus writeflag/trigger_connect (the same path as Reconnect Network),
# which Casa uses to push the profile APN to the modem and re-attach itself.
# A blank-APN revert restores the APN Casa had before QManager changed it,
# rather than writing an empty APN. Other CIDs keep the upstream bracket.
# Same return-code contract, status names and hooks as upstream.
CASA_APN_ORIGINAL_FILE="/etc/qmanager/casa_apn_original.json"
CASA_APN_VERIFY_TIMEOUT="${CASA_APN_VERIFY_TIMEOUT:-120}"
CASA_APN_VERIFY_INTERVAL="${CASA_APN_VERIFY_INTERVAL:-3}"

_casa_apn_pdp_to_rdb() {
    case "$1" in
        IP|ip|IPV4|ipv4) printf 'ipv4' ;;
        IPV6|ipv6) printf 'ipv6' ;;
        *) printf 'ipv4v6' ;;
    esac
}

_casa_apn_fold() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

apn_apply_write() {
    local _cid="$1" _pdp="$2" _apn="$3" _allow_empty="${4:-0}"

    if [ "$_cid" != "1" ] || ! command -v rdb >/dev/null 2>&1 \
        || [ -z "$(rdb get link.profile.1.module_profile_idx 2>/dev/null)" ]; then
        _upstream_apn_apply_write "$@"
        return $?
    fi

    APN_APPLY_STATUS=""
    APN_APPLY_DETAIL=""
    APN_APPLY_NEGOTIATED_APN=""
    APN_APPLY_RC=0

    if [ -z "$_apn" ] && [ "$_allow_empty" != "1" ]; then
        APN_APPLY_STATUS="skipped_empty_apn"
        APN_APPLY_DETAIL="No APN configured; skipped (no modem write, no detach)"
        APN_APPLY_RC=6
        return 6
    fi

    if [ "$APN_APPLY_LOCK_EXTERNAL" != "1" ] && ! _apn_apply_lock_acquire; then
        _apn_apply_lock_release
        APN_APPLY_STATUS="apn_busy"
        APN_APPLY_DETAIL="Another APN apply is already in progress; try again shortly"
        APN_APPLY_RC=7
        return 7
    fi
    _apn_apply_detached=0
    command -v apn_apply_on_bracket_start >/dev/null 2>&1 && apn_apply_on_bracket_start

    local _cur_apn _cur_pdp _want_apn _want_pdp _revert=0
    _cur_apn=$(rdb get link.profile.1.apn 2>/dev/null)
    _cur_pdp=$(rdb get link.profile.1.pdp_type 2>/dev/null)

    if [ -z "$_apn" ]; then
        # Revert: restore what Casa had before QManager changed it. With no
        # saved original, keep Casa's current APN (never write an empty one).
        _revert=1
        _want_apn="$_cur_apn"
        _want_pdp="$_cur_pdp"
        if [ -f "$CASA_APN_ORIGINAL_FILE" ]; then
            _want_apn=$(jq -r '.apn // empty' "$CASA_APN_ORIGINAL_FILE" 2>/dev/null)
            _want_pdp=$(jq -r '.pdp_type // empty' "$CASA_APN_ORIGINAL_FILE" 2>/dev/null)
            [ -n "$_want_apn" ] || _want_apn="$_cur_apn"
            [ -n "$_want_pdp" ] || _want_pdp="$_cur_pdp"
        fi
    else
        _want_apn="$_apn"
        _want_pdp=$(_casa_apn_pdp_to_rdb "$_pdp")
        # Remember Casa's own APN once, before QManager first changes it.
        if [ ! -f "$CASA_APN_ORIGINAL_FILE" ] && [ -n "$_cur_apn" ] \
            && [ "$(_casa_apn_fold "$_cur_apn")" != "$(_casa_apn_fold "$_want_apn")" ]; then
            jq -n --arg apn "$_cur_apn" --arg pdp "$_cur_pdp" \
                '{apn:$apn, pdp_type:$pdp}' > "$CASA_APN_ORIGINAL_FILE" 2>/dev/null || true
        fi
    fi

    # Already in place on Casa and on the network: no reconnect needed.
    local _rdp _negotiated
    _rdp=$(run_at "AT+CGCONTRDP=${_cid}")
    [ -n "$_rdp" ] && _negotiated=$(parse_cgcontrdp_apn "$_rdp")
    if [ "$(_casa_apn_fold "$_cur_apn")" = "$(_casa_apn_fold "$_want_apn")" ] \
        && [ "$_cur_pdp" = "$_want_pdp" ] && [ -n "$_negotiated" ] \
        && [ "$(_casa_apn_fold "$_negotiated")" = "$(_casa_apn_fold "$_want_apn")" ]; then
        _apn_apply_finish
        [ "$_revert" = "1" ] && rm -f "$CASA_APN_ORIGINAL_FILE" 2>/dev/null
        APN_APPLY_NEGOTIATED_APN="$_negotiated"
        if [ "$_revert" = "1" ]; then
            APN_APPLY_STATUS="done_carrier_default"
            APN_APPLY_DETAIL="Casa APN ${_negotiated} already active (CID ${_cid})"
        else
            APN_APPLY_STATUS="done"
            APN_APPLY_DETAIL="APN ${_negotiated} already active (CID ${_cid})"
        fi
        APN_APPLY_RC=0
        return 0
    fi

    append_event "apn_apply_started" "Applying APN change via Casa connection manager (CID ${_cid})" "info"
    if ! rdb set link.profile.1.apn "$_want_apn" 2>/dev/null \
        || ! rdb set link.profile.1.pdp_type "$_want_pdp" 2>/dev/null; then
        _apn_apply_finish
        APN_APPLY_STATUS="failed_cgdcont"
        APN_APPLY_DETAIL="Could not write the Casa APN profile (link.profile.1) — connection unchanged"
        APN_APPLY_RC=1
        return 1
    fi
    local _policy_enable
    _policy_enable=$(rdb get link.policy.1.enable 2>/dev/null)
    [ -n "$_policy_enable" ] || _policy_enable=1
    rdb set link.profile.1.writeflag 1 2>/dev/null
    rdb set link.policy.1.trigger_connect "$_policy_enable" 2>/dev/null

    # Casa pushes the profile to the modem and re-attaches (~60s measured).
    local _waited=0
    _negotiated=""
    while [ "$_waited" -lt "$CASA_APN_VERIFY_TIMEOUT" ]; do
        sleep "$CASA_APN_VERIFY_INTERVAL"
        _waited=$((_waited + CASA_APN_VERIFY_INTERVAL))
        [ "$(rdb get link.profile.1.status 2>/dev/null)" = "up" ] || continue
        _rdp=$(run_at "AT+CGCONTRDP=${_cid}")
        [ -n "$_rdp" ] && _negotiated=$(parse_cgcontrdp_apn "$_rdp")
        [ -n "$_negotiated" ] && break
    done
    _apn_apply_finish
    APN_APPLY_NEGOTIATED_APN="$_negotiated"

    if [ -z "$_negotiated" ]; then
        APN_APPLY_STATUS="timeout_verify"
        APN_APPLY_DETAIL="Casa reconnect requested but no APN data after ${_waited}s"
        APN_APPLY_RC=5
        return 5
    fi
    if [ "$_revert" = "1" ]; then
        rm -f "$CASA_APN_ORIGINAL_FILE" 2>/dev/null
        APN_APPLY_STATUS="done_carrier_default"
        APN_APPLY_DETAIL="Restored Casa APN ${_want_apn}; network negotiated ${_negotiated} (CID ${_cid})"
        APN_APPLY_RC=0
        append_event "apn_apply_done" "CID ${_cid} restored to Casa APN ${_want_apn}" "info"
        return 0
    fi
    if [ "$(_casa_apn_fold "$_negotiated")" = "$(_casa_apn_fold "$_want_apn")" ]; then
        APN_APPLY_STATUS="done"
        APN_APPLY_DETAIL="APN negotiated: ${_negotiated} (CID ${_cid})"
        APN_APPLY_RC=0
        append_event "apn_apply_done" "APN ${_negotiated} confirmed on CID ${_cid}" "info"
        return 0
    fi
    APN_APPLY_STATUS="mismatch"
    APN_APPLY_DETAIL="Requested ${_want_apn}, network negotiated ${_negotiated} — apply did not take"
    APN_APPLY_RC=4
    append_event "apn_apply_mismatch" "CID ${_cid} requested ${_want_apn}, negotiated ${_negotiated}" "warning"
    return 4
}
