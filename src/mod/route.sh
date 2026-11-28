#!/usr/bin/env bash
# ── Согласование маршрута Xray с выбранным транспортом VPS-2 ────────────
# Xray's leastPing has its OWN opinion of the best transport. Without a live
# override it can keep sending SOCKS, DNS and wg0 flows to the WRONG bridge.
route_target_for() {
  case $1 in
    hy2-wg|hy2o-wg) echo to-exit ;;
    reality-xhttp) echo r-xhttp ;;
    reality-xhttp2) echo r-xhttp2 ;;
    *) return 1 ;;
  esac
}
route_api_override() { # apply and verify the actual in-memory RoutingService state
  local bal=$1 target=$2 response
  [[ $bal == exit || $bal == rev ]] || return 2
  case $target in
    to-exit|r-xhttp|r-xhttp2)
      "$XRAY_BIN" api bo --server=127.0.0.1:10085 -b "$bal" "$target" >/dev/null 2>&1 || return 1 ;;
    clear)
      "$XRAY_BIN" api bo --server=127.0.0.1:10085 -b "$bal" -r >/dev/null 2>&1 || return 1 ;;
    *) return 2 ;;
  esac
  # Xray 26.4.25 exposes structured output with --json (verified on the lab).
  response=$("$XRAY_BIN" api bi --server=127.0.0.1:10085 --json "$bal" 2>/dev/null) || return 1
  printf '%s\n' "$response" | python3 -I -c '
@PY:route_api_override@
' "$target"
}
route_rev_has() { # Detect whether this outbound is valid for the separate management balancer.
  local tag=$1
  python3 -I - "$ETC/xray.json" "$tag" <<'PY_REV_HAS'
@PY:route_rev_has@
PY_REV_HAS
}
route_has_rev() { # rev exists whenever SSH doors use reverse XHTTP bridges.
  grep -Eq '"tag"[[:space:]]*:[[:space:]]*"rev"' "$ETC/xray.json" 2>/dev/null
}
route_prepare() { # Pre-arm ONLY the management reverse bridge, never customer traffic.
  local target=$1
  [[ $target == to-exit || $target == r-xhttp || $target == r-xhttp2 ]] || return 2
  route_has_rev || return 0
  if [[ $target == to-exit ]]; then
    route_api_override rev clear
  else
    route_rev_has "$target" || return 1
    route_api_override rev "$target"
  fi
}
route_pin() {
  local target=$1 policy=${2:-manual} tmp ptmp old old_policy rev_target old_rev
  [[ $policy == auto || $policy == manual ]] || return 2
  [[ $target == to-exit || $target == r-xhttp || $target == r-xhttp2 ]] || return 2
  old=$(cat "$STATE/route-target" 2>/dev/null || true)
  old_policy=$(cat "$STATE/route-policy" 2>/dev/null || echo manual)
  if ! { tr_has reality-xhttp || tr_has reality-xhttp2; }; then
    [[ $target == to-exit ]] || return 1
    rm -f "$STATE/route-target" "$STATE/route-policy"
    return 0
  fi
  # CRITICAL: exit serves customer traffic, rev serves the reverse-SSH door.
  # Updating exit alone loses SSH when VPS-2 switches between XHTTP bridges.
  # Apply rev FIRST for XHTTP, then exit; for Hysteria use WG control and
  # clear the stale rev override (its selector contains only XHTTP bridges).
  if route_has_rev; then
    # Automatic failover needs an unpinned management balancer, otherwise a
    # switch XHTTP2 -> XHTTP permanently strands control on the old bridge.
    if [[ $target == to-exit || $policy == auto ]]; then rev_target=clear
    elif route_rev_has "$target"; then rev_target=$target
    else err "SSH-балансировщик rev не содержит $target"; return 1
    fi
    if ! route_api_override rev "$rev_target"; then
      err "Xray не смог согласовать управляющий балансировщик rev"; return 1
    fi
  fi
  if ! route_api_override exit "$target"; then
    if [[ -n $old && $old != "$target" ]]; then
      [[ $old == to-exit || $old_policy == auto ]] && old_rev=clear || old_rev=$old
      route_has_rev && route_api_override rev "$old_rev" || true
    fi
    err "Xray отказался установить исходящий маршрут $target"; return 1
  fi
  tmp=$(mktemp "$STATE/.route-target.XXXXXXXX") || return 1
  ptmp=$(mktemp "$STATE/.route-policy.XXXXXXXX") || { rm -f "$tmp"; return 1; }
  if ! printf '%s\n' "$target" >"$tmp" || ! printf '%s\n' "$policy" >"$ptmp" ||
     ! chmod 644 "$tmp" "$ptmp" || ! mv -f "$ptmp" "$STATE/route-policy" ||
     ! mv -f "$tmp" "$STATE/route-target"; then
    rm -f "$tmp" "$ptmp"
    if [[ -n $old ]]; then
      printf '%s\n' "$old_policy" >"$STATE/route-policy"
      [[ $old == to-exit || $old_policy == auto ]] && old_rev=clear || old_rev=$old
      route_has_rev && route_api_override rev "$old_rev" || true
      route_api_override exit "$old" || true
    fi
    err "Не удалось сохранить исходящий маршрут/режим $target/$policy"
    return 1
  fi
}
# Journal: this local record documents an in-flight operation, not an assertion
# about VPS-2. VPS-2's /var/lib/rp/mode and /var/lib/rp/active are authoritative.
transition_start() { # uuid desired previous-target
  local id=$1 desired=$2 previous=$3 tmp
  [[ $id =~ ^[0-9a-f-]{8,64}$ ]] || return 2
  case $desired in auto|reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg) :;; *) return 2;; esac
  tmp=$(mktemp "$STATE/.route-transition.XXXXXXXX") || return 1
  printf 'id=%s\ndesired=%s\nprevious=%s\nstarted=%s\n' \
    "$id" "$desired" "$previous" "$(date +%s)" >"$tmp" &&
    chmod 600 "$tmp" && mv -f "$tmp" "$STATE/route-transition"
}
transition_clear() { rm -f "$STATE/route-transition"; }
transition_show() {
  [[ -s $STATE/route-transition ]] || return 0
  local id desired started elapsed
  id=$(sed -n 's/^id=//p' "$STATE/route-transition" | head -1)
  desired=$(sed -n 's/^desired=//p' "$STATE/route-transition" | head -1)
  started=$(sed -n 's/^started=//p' "$STATE/route-transition" | head -1)
  if [[ $started =~ ^[0-9]+$ ]]; then elapsed=$(( $(date +%s) - started )); else elapsed='?'; fi
  printf 'Ожидает подтверждения: %s (операция %s, прошло %s с)\n' "$desired" "$id" "$elapsed"
}
remote_mode_parse() { # validate one coherent response: mode=... active=...
  local snapshot=$1 mode act
  mode=$(sed -n 's/^mode=//p' <<<"$snapshot" | head -1)
  act=$(sed -n 's/^active=//p' <<<"$snapshot" | head -1)
  case $mode in auto|manual:reality-xhttp|manual:reality-xhttp2|manual:hy2-wg|manual:hy2o-wg) :;; *) return 1;; esac
  case $act in reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg) :;; *) return 1;; esac
  [[ $mode == auto || $mode == "manual:$act" ]] || return 1
  printf '%s %s\n' "$mode" "$act"
}
route_reconcile_snapshot() { # snapshot returned by VPS-2; can be called with rp.lock held
  local snapshot=$1 parsed mode act target old
  parsed=$(remote_mode_parse "$snapshot") || return 1
  read -r mode act <<<"$parsed"
  target=$(route_target_for "$act") || return 1
  old=$(cat "$STATE/route-target" 2>/dev/null || true)
  # An accepted request is async: do not re-pin the OLD bridge before the
  # watchdog has committed the new one. Only a definite failure permits undo.
  if [[ -s $STATE/route-transition ]]; then
    local expected id result
    expected=$(sed -n 's/^desired=//p' "$STATE/route-transition" | head -1)
    if [[ $expected != auto && $act != "$expected" ]]; then
      id=$(sed -n 's/^id=//p' "$STATE/route-transition" | head -1)
      result=$(RP_READ_RETRIES=1 vps2_read "/usr/local/bin/rp mode result $id" 2>/dev/null || true)
      if [[ $result != fail ]]; then
        warn "Переход $expected ещё не завершён (result=${result:-unavailable}); прежний пользовательский маршрут сохраняю"
        return 1
      fi
    fi
  fi
  # Apply every time, even if the FILE matches: a restarted Xray has no in-memory override.
  if [[ $mode == auto ]]; then
    route_pin "$target" auto || return 1
  else
    route_pin "$target" manual || return 1
  fi
  cache_vps2_state "$snapshot"
  if [[ -s $STATE/route-transition ]]; then
    local desired id result
    desired=$(sed -n 's/^desired=//p' "$STATE/route-transition" | head -1)
    id=$(sed -n 's/^id=//p' "$STATE/route-transition" | head -1)
    if [[ $desired == auto && $mode == auto || $desired == "$act" && $mode == "manual:$act" ]]; then
      transition_clear
    else
      result=$(RP_READ_RETRIES=1 vps2_read "/usr/local/bin/rp mode result $id" 2>/dev/null || true)
      if [[ $result == fail ]]; then
        warn "VPS-2 отклонил переключение $desired; восстанавливаю $mode/$act"
        transition_clear
      else
        warn "Переход $desired ожидает результата (result=${result:-unavailable})"
        return 1
      fi
    fi
  fi
  [[ $old == "$target" ]] || note "Синхронизирован маршрут VPS-1: $act → $target (exit и rev)"
  return 0
}
route_sync() {
  [[ $(cf ROLE) == vps1 ]] || return 1
  exec 7>/run/rp.lock
  flock -n 7 || return 0
  if [[ -f $STATE/migration/state.json ]]; then
    (exec 9>&7; python3 "$STATE/migration/runner.py" guard) >/dev/null 2>&1 || return 0
  fi
  local snapshot
  snapshot=$(RP_READ_RETRIES=1 vps2_read '/usr/local/bin/rp mode status' 2>/dev/null) || return 0
  route_reconcile_snapshot "$snapshot"
}
route_sync_locked() {
  local snapshot
  snapshot=$(vps2_read '/usr/local/bin/rp mode status' 2>/dev/null) || return 1
  route_reconcile_snapshot "$snapshot"
}
# Repair a split-brain installation without modifying VPS-2 or needing an SSH
# path that is currently routed to the WRONG reverse bridge. The requested
# transport MUST be independently confirmed on VPS-2 after local API repair.
route_recover() { # named transport confirmed by administrator on VPS-2 console
  local desired=$1 target old snapshot mode act i
  [[ $desired == reality-xhttp || $desired == reality-xhttp2 || $desired == hy2-wg || $desired == hy2o-wg ]] || return 2
  tr_has "$desired" || { err "Транспорт $desired отсутствует в конфигурации"; return 1; }
  target=$(route_target_for "$desired") || return 1
  old=$(cat "$STATE/route-target" 2>/dev/null || true)
  note "Восстанавливаю локальные балансировщики Xray под $desired, VPS-2 не изменяю"
  route_pin "$target" || return 1
  for ((i=1; i<=12; i++)); do
    snapshot=$(RP_READ_RETRIES=1 vps2_read '/usr/local/bin/rp mode status' 2>/dev/null || true)
    if [[ -n $snapshot ]]; then
      read -r mode act < <(remote_mode_parse "$snapshot" 2>/dev/null || echo invalid invalid)
      if [[ $act == "$desired" ]] && { [[ $mode == auto ]] || [[ $mode == "manual:$desired" ]]; }; then
        # Explicit recovery cancels a stale pending request on VPS-1.
        transition_clear
        route_reconcile_snapshot "$snapshot" || return 1
        ok "Подтверждено VPS-2: $mode, $act; оба балансировщика согласованы"
        return 0
      fi
      warn "VPS-2 сообщает $mode/$act; ожидалось $desired; восстанавливаю локальный маршрут по фактическому состоянию"
      transition_clear
      route_reconcile_snapshot "$snapshot" || true
      return 1
    fi
    sleep 3
  done
  warn "Маршрут локально переключён, но VPS-2 не отвечает через обратный SSH; результат НЕ подтверждён"
  warn "Проверьте на VPS-2: rp mode status; затем rp tunnel sync (или rp tunnel recover ТРАНСПОРТ)"
  return 1
}
