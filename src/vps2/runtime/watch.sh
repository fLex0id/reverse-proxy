#!/usr/bin/env bash
# rp: VPS-2 supervisor. One active transport; all configured candidates retained.
# Conservative failover (3 failures), two-way T2+T3 validation, circuit breaker.
# Hysteria2 owns QUIC keepalive; inner WG remains at PersistentKeepalive=28.
set -u
ST=/var/lib/rp
# shellcheck disable=SC1091
. /etc/rp/rp2.conf
WATCH_MIN=${WATCH_MIN:-10}; WATCH_MAX=${WATCH_MAX:-15}
if [[ ! $WATCH_MIN =~ ^[0-9]+$ || ! $WATCH_MAX =~ ^[0-9]+$ ]] ||
   ((WATCH_MIN < 5 || WATCH_MAX > 120 || WATCH_MAX < WATCH_MIN)); then
  logger -t rp-watch 'invalid WATCH_MIN/WATCH_MAX, using 10..15'
  WATCH_MIN=10; WATCH_MAX=15
fi
fn() { /usr/local/bin/rp _fn "$@"; }
rand_between() {
  local lo=$1 hi=$2 raw
  raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null) || raw=""
  [[ $raw =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || raw=$(( (RANDOM << 16) | RANDOM ))
  printf '%d\n' "$((lo + raw % (hi - lo + 1)))"
}
activity_sleep() { sleep "$(rand_between "$WATCH_MIN" "$WATCH_MAX")"; }
# 'passive' (default) never tears down a good connection just to re-test a
# preferred candidate. Priority order still applies after the CURRENT path fails.
failback_policy_now() {
  [[ $(cat "$ST/failback-policy" 2>/dev/null || true) == active ]] && echo active || echo passive
}
error_sleep() { sleep "$(rand_between 1 2)"; }
# A bounded lightweight health sample, not a replacement for full T1/T2/T3.
# Three consecutive failures are required before any automatic failover.
health_probe() { timeout --kill-after=2 6 /usr/local/bin/rp _fn func_ok "$1"; }
log() { logger -t rp-watch -- "$*"; }
active() { cat "$ST/active" 2>/dev/null || true; }
set_active() {
  printf '%s\n' "$1" >"$ST/active.new" && mv -f "$ST/active.new" "$ST/active"
  date +%s >"$ST/since"
}
clear_active() { rm -f "$ST/active" "$ST/since"; }
order_now() { fn tr_order; }
# Cooldown per transport after failures; memory is intentionally reset on service restart.
declare -A blocked_until=() strike=()
penalize() {
  local t=$1 now n=${strike[$1]:-0} seconds
  now=$(date +%s) || return 1
  n=$((n + 1)); ((n > 4)) && n=4
  strike[$t]=$n
  seconds=$((300 * (1 << (n - 1))))  # 5, 10, 20, 40 minutes
  blocked_until[$t]=$((now + seconds))
  log "$t unavailable; quarantine for ${seconds}s (attempt $n)"
}
allowed() { (( $(date +%s) >= ${blocked_until[$1]:-0} )); }
# A transport is eligible only if it really carries data through both directions.
# A successful process start / TCP or QUIC handshake alone is NOT enough.
try_transport() {
  local t=$1
  fn tr_start "$t" || return 1
  fn t2_check "$t" || return 1
  if ! fn t3_check "$t" >/dev/null; then
    # Short reverse-bridge warmup often affects only the first 200 KB probe.
    sleep 5
    fn t3_check "$t" >/dev/null || return 1
  fi
  fn func_ok "$t" || return 1
  return 0
}
choose_candidate() {
  local skip=${1:-} t
  for t in "${order[@]}"; do
    [[ $t == "$skip" ]] && continue
    allowed "$t" || continue
    if try_transport "$t"; then
      set_active "$t"; strike[$t]=0; blocked_until[$t]=0
      log "active transport: $t"
      return 0
    fi
    penalize "$t"
  done
  return 1
}
# Execute a requested manual switch in the supervisor, not inside the SSH
# session used to submit it. Commit only after bidirectional T2/T3 checks.
mode_result() {
  local tmp
  tmp=$(mktemp "$ST/.mode-result.XXXXXXXX") || return 1
  printf '%s %s\n' "$1" "$2" >"$tmp" && chmod 600 "$tmp" &&
    mv -f "$tmp" "$ST/mode-result"
}
mode_commit() {
  local tmp
  tmp=$(mktemp "$ST/.mode.XXXXXXXX") || return 1
  printf '%s\n' "$1" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$ST/mode"
}
process_mode_request() {
  [[ -s $ST/mode-request ]] || return 1
  local id desired previous status=fail t
  read -r id desired <"$ST/mode-request" || true
  [[ $id =~ ^[0-9a-f-]{8,64}$ ]] || { rm -f "$ST/mode-request"; return 0; }
  case $desired in auto|reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg) :;;
    *) mode_result "$id" fail; rm -f "$ST/mode-request"; return 0;; esac
  previous=$(active)
  if [[ $desired == auto ]]; then
    if mode_commit auto; then
      status=ok
      # Re-enable priority failback without forcing an unnecessary disconnect.
      last_switch=$(( $(date +%s) - 1800 ))
      last_failback=0
      errors=0
      log 'automatic failover enabled'
    fi
  elif [[ " $(fn tr_all) " != *" $desired "* ]]; then
    log "manual transport not configured: $desired"
  elif [[ $previous == "$desired" ]] && fn func_ok "$desired"; then
    if mode_commit "manual:$desired"; then status=ok; errors=0; fi
  elif try_transport "$desired"; then
    if mode_commit "manual:$desired"; then
      set_active "$desired"
      strike[$desired]=0; blocked_until[$desired]=0
      last_switch=$(date +%s); errors=0
      next_deep=$((last_switch + $(rand_between 480 900)))
      status=ok
      log "manual transport selected: $desired"
    else
      log 'could not save manual mode; restoring previous transport'
      if [[ -n $previous ]] && try_transport "$previous"; then
        set_active "$previous"
      else
        clear_active; fn tr_stop_all >/dev/null 2>&1 || true
      fi
    fi
  else
    log "manual candidate $desired failed T2/T3; restoring $previous"
    # Do not change the mode on failure. Validate the previous connection again.
    if [[ -n $previous && " $(fn tr_all) " == *" $previous "* ]] && try_transport "$previous"; then
      set_active "$previous"
      errors=0; last_switch=$(date +%s)
      next_deep=$((last_switch + $(rand_between 480 900)))
      log "restored previous transport $previous"
    else
      clear_active
      fn tr_stop_all >/dev/null 2>&1 || true
      # The old AUTO policy may recover through any configured candidate.
      # The old MANUAL policy only retries its original transport.
      log 'previous transport could not be restored; fail-closed recovery'
    fi
  fi
  mode_result "$id" "$status" || log "could not record mode result $id"
  rm -f "$ST/mode-request"
  return 0
}
# On reboot services might not be enabled individually: bring back the stored active.
order=()
read -ra order <<<"$(order_now)"
if ((${#order[@]})) && [[ -n $(active) ]]; then
  current=$(active)
  if [[ " ${order[*]} " == *" $current "* ]]; then
    # rp select may have just started a healthy transport. Do not tear it down
    # merely because the watchdog service was (re)started.
    fn func_ok "$current" || fn tr_start "$current" || log "startup recovery failed for $current"
  else
    clear_active
  fi
fi
errors=0; last_switch=$(date +%s)
next_deep=$((last_switch + $(rand_between 480 900)))
last_failback=0
while :; do
  if [[ -f $ST/transaction/installing ]]; then sleep 2; continue; fi
  if process_mode_request; then activity_sleep; continue; fi
  read -ra order <<<"$(order_now)"
  if ((${#order[@]} == 0)); then
    # Misconfigured or empty policy: no permission to use an unlisted channel.
    fn tr_stop_all >/dev/null 2>&1 || true
    clear_active
    log 'empty TRANSPORT_ORDER; fail-closed'
    sleep 30; continue
  fi
  t=$(active)
  if [[ -n $t && " ${order[*]} " != *" $t "* ]]; then
    clear_active; t=""
  fi
  if [[ -z $t ]]; then
    # No active transport. Retry failed ones after their cooldown expires.
    if choose_candidate ""; then
      errors=0; last_switch=$(date +%s)
      next_deep=$((last_switch + $(rand_between 480 900)))
      activity_sleep
    else
      fn tr_stop_all >/dev/null 2>&1 || true
      clear_active
      error_sleep
    fi
    continue
  fi
  now=$(date +%s)
  good=0
  if health_probe "$t"; then good=1; fi
  if ((good && now >= next_deep)); then
    next_deep=$((now + $(rand_between 480 900)))
    fn t3_check "$t" >/dev/null || good=0
  fi
  if ((good)); then
    errors=0
    # On fallback: wait for 30 min of uninterrupted operation before failback.
    # Failed failback must not cause immediate repeated attempts or lose the old path.
    if [[ $(failback_policy_now) == active && $t != "${order[0]}" ]] &&
       ((now - last_switch >= 1800)) && ((now - last_failback >= 1800)); then
      last_failback=$now
      attempted=0; upgraded=""
      # Try ALL higher-priority candidates in rank order, not just position 1.
      # Example: if packet-up stays blocked but auto recovers, leave Hysteria2 for auto.
      for preferred in "${order[@]}"; do
        [[ $preferred == "$t" ]] && break
        allowed "$preferred" || continue
        attempted=1
        log "probing higher-priority $preferred (current $t)"
        if try_transport "$preferred"; then upgraded=$preferred; break; fi
        penalize "$preferred"
      done
      if [[ -n $upgraded ]]; then
        set_active "$upgraded"; strike[$upgraded]=0; blocked_until[$upgraded]=0
        log "failback $t -> $upgraded (T2+T3 passed)"
        last_switch=$(date +%s); errors=0
        next_deep=$((last_switch + $(rand_between 480 900)))
        activity_sleep; continue
      fi
      if ((attempted)); then
        # Restore the previously healthy transport. Verify it before marking active.
        if try_transport "$t"; then
          set_active "$t"
          log "failed failback, restored $t"
          last_switch=$(date +%s); errors=0
          next_deep=$((last_switch + $(rand_between 480 900)))
          activity_sleep; continue
        fi
        penalize "$t"
        clear_active
        log 'failed to restore previous transport; fail-closed'
        if choose_candidate ""; then
          last_switch=$(date +%s); errors=0
        else
          fn tr_stop_all >/dev/null 2>&1 || true
        fi
        error_sleep; continue
      fi
    fi
    activity_sleep; continue
  fi
  errors=$((errors + 1))
  # Failback requires 30 minutes of clean health checks, not just uptime.
  last_switch=$(date +%s)
  log "$t end-to-end probe failed ($errors/3)"
  if ((errors < 3)); then error_sleep; continue; fi
  errors=0
  # In auto, validate a different eligible channel before retrying a known
  # broken one. Retrying its full T2/T3 first can strand clients for minutes.
  # Manual mode still retries only the pinned channel and stays fail-closed.
  if [[ $(fn mode_get) == auto && ${#order[@]} -gt 1 ]]; then
    penalize "$t"
    clear_active
    if choose_candidate "$t"; then
      last_switch=$(date +%s)
      next_deep=$((last_switch + $(rand_between 480 900)))
      activity_sleep
    else
      fn tr_stop_all >/dev/null 2>&1 || true
      log 'all eligible backup transports unavailable: fail-closed'
      error_sleep
    fi
    continue
  fi
  log "restarting unhealthy $t"
  if try_transport "$t"; then
    set_active "$t"; strike[$t]=0; blocked_until[$t]=0
    log "recovered $t after restart"
    last_switch=$(date +%s)
    next_deep=$((last_switch + $(rand_between 480 900)))
    activity_sleep; continue
  fi
  penalize "$t"
  clear_active
  if choose_candidate "$t"; then
    last_switch=$(date +%s)
    next_deep=$((last_switch + $(rand_between 480 900)))
  else
    fn tr_stop_all >/dev/null 2>&1 || true
    log 'all eligible transports unavailable: fail-closed'
  fi
  error_sleep
done
