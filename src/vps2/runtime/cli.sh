#!/usr/bin/env bash
# rp (VPS-2) — минимальное управление. Обновление параметров: вставить новый блок из VPS-1.
set -uo pipefail
ETC=/etc/rp; STATE=/var/lib/rp
# shellcheck disable=SC1091
. "$ETC/rp2.conf"
mkdir -p "$STATE"
VPS1_WG=10.77.0.1
N=204800
rp_plain_console() {
  case "${RP_ASCII:-auto}" in
    1|yes|true) return 0 ;;
    0|no|false) return 1 ;;
  esac
  case "${TERM:-}" in linux|dumb|vt100|vt102|cons25|ansi) return 0 ;; esac
  [[ -t 1 && -z "${SSH_TTY:-}${SSH_CONNECTION:-}" ]]
}
rp_transliterate() {
  LC_ALL=C sed \
    -e 's/Ё/Yo/g' \
    -e 's/Ж/Zh/g' \
    -e 's/Х/Kh/g' \
    -e 's/Ц/Ts/g' \
    -e 's/Ч/Ch/g' \
    -e 's/Ш/Sh/g' \
    -e 's/Щ/Shch/g' \
    -e 's/Ю/Yu/g' \
    -e 's/Я/Ya/g' \
    -e 's/А/A/g' \
    -e 's/Б/B/g' \
    -e 's/В/V/g' \
    -e 's/Г/G/g' \
    -e 's/Д/D/g' \
    -e 's/Е/E/g' \
    -e 's/З/Z/g' \
    -e 's/И/I/g' \
    -e 's/Й/Y/g' \
    -e 's/К/K/g' \
    -e 's/Л/L/g' \
    -e 's/М/M/g' \
    -e 's/Н/N/g' \
    -e 's/О/O/g' \
    -e 's/П/P/g' \
    -e 's/Р/R/g' \
    -e 's/С/S/g' \
    -e 's/Т/T/g' \
    -e 's/У/U/g' \
    -e 's/Ф/F/g' \
    -e 's/Ъ//g' \
    -e 's/Ы/Y/g' \
    -e 's/Ь//g' \
    -e 's/Э/E/g' \
    -e 's/ё/yo/g' \
    -e 's/ж/zh/g' \
    -e 's/х/kh/g' \
    -e 's/ц/ts/g' \
    -e 's/ч/ch/g' \
    -e 's/ш/sh/g' \
    -e 's/щ/shch/g' \
    -e 's/ю/yu/g' \
    -e 's/я/ya/g' \
    -e 's/а/a/g' \
    -e 's/б/b/g' \
    -e 's/в/v/g' \
    -e 's/г/g/g' \
    -e 's/д/d/g' \
    -e 's/е/e/g' \
    -e 's/з/z/g' \
    -e 's/и/i/g' \
    -e 's/й/y/g' \
    -e 's/к/k/g' \
    -e 's/л/l/g' \
    -e 's/м/m/g' \
    -e 's/н/n/g' \
    -e 's/о/o/g' \
    -e 's/п/p/g' \
    -e 's/р/r/g' \
    -e 's/с/s/g' \
    -e 's/т/t/g' \
    -e 's/у/u/g' \
    -e 's/ф/f/g' \
    -e 's/ъ//g' \
    -e 's/ы/y/g' \
    -e 's/ь//g' \
    -e 's/э/e/g' \
    -e 's/✓/OK/g' \
    -e 's/✗/ERROR/g' \
    -e 's/●/*/g' \
    -e 's/◆/==/g' \
    -e 's/›/>/g' \
    -e 's/—/-/g' \
    -e 's/–/-/g' \
    -e 's/→/->/g' \
    -e 's/≥/>=/g' \
    -e 's/≤/<=/g' \
    -e 's/┌/+/g' \
    -e 's/└/+/g' \
    -e 's/─/-/g' \
    -e 's/│/|/g' \
    -e 's/·/-/g' \
    -e 's/⠋/-/g' \
    -e 's/⠙/-/g' \
    -e 's/⠹/-/g' \
    -e 's/⠸/-/g' \
    -e 's/⠼/-/g' \
    -e 's/⠴/-/g' \
    -e 's/⠦/-/g' \
    -e 's/⠧/-/g' \
    -e 's/⠇/-/g' \
    -e 's/⠏/-/g'
}
say() {
  if rp_plain_console; then
    if command -v iconv >/dev/null 2>&1; then
      printf '%s\n' "$*" | rp_transliterate | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null
    else
      printf '%s\n' "$*" | rp_transliterate
    fi
  else
    printf '%s\n' "$*"
  fi
}
tr_all() { echo "$TRANSPORT_ORDER"; }
# By default prefer availability over preemptive failback. A candidate T2/T3
# requires tr_start -> tr_stop_all and would interrupt a healthy tunnel.
failback_policy() {
  local p
  p=$(cat "$STATE/failback-policy" 2>/dev/null || true)
  case "$p" in active) echo active ;; *) echo passive ;; esac
}
cmd_failback() {
  local target=${1:-status} tmp
  case "$target" in
    status) say "Failback: $(failback_policy) (passive = no interruption of healthy tunnel)" ;;
    passive|active)
      if [[ $target == active ]]; then
        say "WARNING: active failback may briefly stop the healthy tunnel every 30 minutes." >&2
      fi
      tmp=$(mktemp "$STATE/.failback.XXXXXXXX") || return 1
      printf '%s\n' "$target" >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$STATE/failback-policy" || { rm -f "$tmp"; return 1; }
      say "Failback policy: $target"
      ;;
    *) say "Usage: rp failback [status|passive|active]" >&2; return 2 ;;
  esac
}
# Persistent on VPS-2; deliberately NOT stored in rp2.conf so 'rp push' preserves it.
# A pinned transport never falls back to a different protocol. In case of failure,
# the watchdog retries that same protocol and preserves fail-closed routing.
mode_get() {
  local m
  m=$(cat "$STATE/mode" 2>/dev/null) || m=auto
  [[ -n $m ]] || m=auto
  case "$m" in
    auto|manual:reality-xhttp|manual:reality-xhttp2|manual:hy2-wg|manual:hy2o-wg) printf '%s\n' "$m" ;;
    *) printf 'invalid\n'; return 1 ;;
  esac
}
manual_target() { local m; m=$(mode_get) || return 1; [[ $m == manual:* ]] || return 1; printf '%s\n' "${m#manual:}"; }
mode_allowed() {
  local t
  for t in $TRANSPORT_ORDER; do [[ $t == "$1" ]] && return 0; done
  return 1
}
# usable/results — последний снимок диагностики, а не постоянный запрет транспорта.
# Иначе временная потеря UDP исключает HY2 навсегда до ручного rp select.
tr_order() {
  local m t
  m=$(mode_get) || return 1
  if [[ $m == manual:* ]]; then
    t=${m#manual:}
    # Never silently choose a different transport if a pinned one was removed
    # from the allowed transports by a future configuration update.
    mode_allowed "$t" || return 1
    printf '%s\n' "$t"
  elif [[ -n ${TRANSPORT_FORCE:-} ]]; then
    printf '%s\n' "$TRANSPORT_FORCE"
  else
    tr_all
  fi
}
active() { cat "$STATE/active" 2>/dev/null; }
unit_of() { case $1 in hy2-wg) echo rp-hy2 ;; hy2o-wg) echo rp-hy2o ;; reality-xhttp) echo rp-xray@xhttp ;; reality-xhttp2) echo rp-xray@xhttp2 ;; esac; }
tr_stop_all() { systemctl stop rp-xray@xhttp rp-xray@xhttp2 rp-xray@tcp wg-quick@rp-wg rp-hy2 rp-hy2o 2>/dev/null; return 0; }
wait_udp_fwd() { local i; for ((i = 0; i < ${1:-20}; i++)); do ss -lunH sport = :51820 2>/dev/null | grep -q . && return 0; sleep 1; done; return 1; }
tr_start() {
  tr_stop_all
  case $1 in
    hy2-wg|hy2o-wg) systemctl start "$(unit_of "$1")" || return 1; wait_udp_fwd 30 || return 1; systemctl start wg-quick@rp-wg || return 1; wg_kick || true ;;
    reality-xhttp|reality-xhttp2) systemctl start "$(unit_of "$1")" ;;
    *) return 1 ;;
  esac
}
tr_probe_addr() { case $1 in hy2*) echo "$VPS1_WG $ECHO_PORT" ;; *) echo "127.0.0.1 7777" ;; esac; }
# Для коротких проб 15 c, для T3 — до 50 c; не теряем частичный объём при timeout.
xfer_down() {
  local got
  # exec head: timeout убивает именно head, а wc выводит фактически полученный объём
  got=$(timeout "${4:-15}" bash -c 'exec 3<>/dev/tcp/$0/$1 || exit 1; printf "DN %d\n" "$2" >&3; exec head -c "$2" <&3' "$1" "$2" "$3" 2>/dev/null | wc -c) || true
  [[ ${got:-} =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || got=0
  printf '%d\n' "$got"
}
xfer_up() {
  timeout "${4:-20}" bash -c 'exec 3<>/dev/tcp/$0/$1 || exit 1; printf "UP %d\n" "$2" >&3; head -c "$2" /dev/zero >&3; read -r -t "$3" l <&3; [[ $l == "OK $2" ]]' "$1" "$2" "$3" "${5:-15}" 2>/dev/null
}
# WireGuard is quiet until the first packet. Without PersistentKeepalive, merely
# starting the interface and waiting for a handshake (old T2 logic) is a deadlock.
# Generate local WG traffic; it is carried by Hysteria2 UDP forwarding (127.0.0.1:51820).
# This is not an external UDP connection and opens no public listening port.
wg_kick() {
  ip link show rp-wg >/dev/null 2>&1 || return 1
  # Fail closed if the WG route is missing (avoid sending the probe via VPS-2 public NIC).
  ip -4 route get 10.77.0.1 2>/dev/null | grep -Eq '(^|[[:space:]])dev rp-wg([[:space:]]|$)' || return 1
  ( printf 'rp\n' > /dev/udp/10.77.0.1/9 ) 2>/dev/null
}
wg_handshake_fresh() {
  local hs now
  hs=$(wg show rp-wg latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  [[ ${hs:-} =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  ((hs > 0 && hs <= now && now - hs < 150))
}
# Lightweight end-to-end health checks for both Hysteria2+WG and VLESS+XHTTP.
# Vary payload sizes independently: every probe must carry actual reverse-tunnel data.
probe_size() {
  local raw
  raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null) || raw=""
  [[ $raw =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || raw=$RANDOM
  printf '%d\n' "$((640 + raw % 1409))"
}
func_ok() {
  local t=$1 h p dn up
  if [[ $t == hy2* ]]; then
    # Active liveness probe supplies real traffic at the watchdog's randomized cadence.
    local attempt
    for ((attempt=0; attempt<5; attempt++)); do
      wg_kick || return 1
      wg_handshake_fresh && break
      sleep 1
    done
    wg_handshake_fresh || return 1
  fi
  read -r h p < <(tr_probe_addr "$t")
  dn=$(probe_size); up=$(probe_size)
  [[ $(xfer_down "$h" "$p" "$dn") -eq "$dn" ]] && xfer_up "$h" "$p" "$up"
}
t1_check() { # T1: доступность порта / UDP-сессии
  local t=$1 port
  case $t in
    hy2-wg|hy2o-wg) wait_udp_fwd 40; return ;;
    reality-xhttp) port=$RXH_PORT ;;
    reality-xhttp2) port=$RXH2_PORT ;;
    *) return 1 ;;
  esac
  timeout 8 bash -c '</dev/tcp/$0/$1' "$PUBLIC_IP" "$port" 2>/dev/null
}
t2_check() { # T2: initiate WG handshake (hy2) or verify Reality path
  local t=$1 i
  for ((i=1; i<=20; i++)); do
    if [[ $t == hy2* ]]; then
      # Explicitly initiate handshake rather than relying solely on 28s keepalive.
      wg_kick && wg_handshake_fresh && return 0
    else
      func_ok "$t" && return 0
    fi
    sleep 2
  done
  return 1
}
t3_check() { # Двусторонние 200 КБ; один кратковременный сбой не означает блокировку.
  local t=$1 h p got attempt last="нет ответа" up_rc
  read -r h p < <(tr_probe_addr "$t")
  for attempt in 1 2; do
    got=$(xfer_down "$h" "$p" "$N" 50)
    if ((got == N)); then
      if xfer_up "$h" "$p" "$N" 50 40; then
        ((attempt > 1)) && logger -t rp "T3: $t succeeded on retry (transient transfer issue)" || true
        return 0
      else
        up_rc=$?
        last="приём $N/$N байт, передача не подтверждена (код $up_rc)"
      fi
    else
      last="приём ${got:-0}/$N байт"
    fi
    ((attempt == 1)) && sleep 3
  done
  say "$last после 2 попыток; проверьте журнал Xray и ограничения транспорта"
  return 1
}
unit_failed() { systemctl is-failed --quiet "$(unit_of "$1")"; }
# Диагностика различает: нет ответа, обрыв после N КБ, сброс, ошибка конфигурации
diag() {
  local t=$1 stage=$2 detail=${3:-}
  case $stage in
    cfg) say "    ошибка конфигурации: смотрите «rp logs» (параметры не подошли версии Xray/Hysteria2)" ;;
    t1)
      if [[ $t == hy2* ]]; then say "    нет ответа по UDP: QUIC режется или порт фильтруется → смените порт, SNI или транспорт"
      elif timeout 5 bash -c '</dev/tcp/$0/$1' "$PUBLIC_IP" "$([[ $t == reality-xhttp ]] && echo "$RXH_PORT" || echo "$RXH2_PORT")" 2>&1 | grep -qi refused; then
        say "    сброс: порт закрыт или сервис VPS-1 не запущен → проверьте «rp status» на VPS-1"
      else say "    нет ответа: пакеты теряются (фильтрация по IP/порту) → смените порт или транспорт"; fi ;;
    t2)
      if [[ $t == hy2* ]]; then
        say "    QUIC мог успешно подключиться, но WG handshake через UDP forwarding не состоялся."
        say "    Проверьте: wg show rp-wg; ip route get 10.77.0.1; ss -lunp; rp logs."
      else say "    Reality/XHTTP: нет ответа через обратный канал; проверьте SNI, порт и журнал Xray"; fi ;;
    t3) say "    ${detail:-ошибка передачи}; причины: таймаут, XHTTP-режим, сеть или фильтрация. Логи: rp logs" ;;
  esac
}
# Прерывание (Ctrl-C / SIGTERM) не должно оставлять VPS-2 без сторожа
cmd_select() {
  local rc
  trap 'systemctl enable --now rp-watch >/dev/null 2>&1; exit 130' INT TERM
  cmd_select_body; rc=$?
  trap - INT TERM
  return $rc
}
cmd_select_body() {
  # Проверяются ВСЕ транспорты; рабочие попадают в usable, неработающие исключаются (VPS-1 уберёт их командой rp prune)
  local t first="" res tmpu=() ok_n=0 bad="" target="" last_checked="" current_mode="" pinned=""
  local -a scan_order=()
  current_mode=$(mode_get) || current_mode=invalid
  [[ $current_mode == manual:* ]] && pinned=${current_mode#manual:}
  target=${pinned:-${TRANSPORT_ORDER%% *}}
  # Scan the intended final channel LAST, so it can remain running without
  # a redundant 200 KB probe + restart after the scan.
  for t in ${TRANSPORT_FORCE:-$TRANSPORT_ORDER}; do
    [[ $t == "$target" ]] || scan_order+=("$t")
  done
  for t in ${TRANSPORT_FORCE:-$TRANSPORT_ORDER}; do
    [[ $t == "$target" ]] && { scan_order+=("$t"); break; }
  done
  systemctl stop rp-watch >/dev/null 2>&1 || true
  : >"$STATE/results"
  say "Проверка транспортов (T1–T3): ${scan_order[*]}"
  for t in "${scan_order[@]}"; do
    last_checked=$t
    say "── $t"
    if ! tr_start "$t" || unit_failed "$t"; then
      say "  ✗ транспорт не запустился"; diag "$t" cfg
      echo "$t=fail:cfg" >>"$STATE/results"; bad+=" $t"; continue
    fi
    sleep 2
    t1_check "$t" || { say "  ✗ T1 доступность"; diag "$t" t1; echo "$t=fail:t1" >>"$STATE/results"; bad+=" $t"; continue; }; say "  ✓ T1"
    t2_check "$t" || { say "  ✗ T2 рукопожатие"; diag "$t" t2; echo "$t=fail:t2" >>"$STATE/results"; bad+=" $t"; continue; }; say "  ✓ T2"
    res=$(t3_check "$t") || { say "  ✗ T3: двусторонняя передача ≥200 КБ не прошла после полного повтора"; diag "$t" t3 "$res"; echo "$t=fail:t3" >>"$STATE/results"; bad+=" $t"; continue; }; say "  ✓ T3"
    echo "$t=ok" >>"$STATE/results"; tmpu+=("$t"); ok_n=$((ok_n + 1))
  done
  # Do not stop the successfully scanned final transport here.
  say ""
  if ((ok_n > 0)); then
    printf '%s\n' "${tmpu[@]}" >"$STATE/usable"
  else
    : >"$STATE/usable"
  fi
  # Результат предварительного сканирования может устареть. Ещё раз проверяем
  # окончательно выбранный канал после его повторного запуска.
  first=""
  # A configured manual pin survives reinstall/update and the full 'rp select'.
  # A failed pinned transport must NOT be silently replaced by a fallback.
  local -a final_candidates=()
  # Scan order differs from priority order; selection must honor priority.
  for t in ${TRANSPORT_FORCE:-$TRANSPORT_ORDER}; do
    [[ " ${tmpu[*]} " == *" $t "* ]] && final_candidates+=("$t")
  done
  [[ $current_mode != invalid ]] || final_candidates=()
  if [[ -n $pinned ]]; then
    final_candidates=()
    for t in "${tmpu[@]}"; do
      [[ $t == "$pinned" ]] && final_candidates+=("$t")
    done
  fi
  # Highest-priority healthy transport, or the pinned one in manual mode.
  for t in "${final_candidates[@]}"; do
    if [[ $t == "$last_checked" && $t == "${tmpu[-1]:-}" ]] && func_ok "$t"; then
      first=$t; break
    fi
    if tr_start "$t" && t1_check "$t" && t2_check "$t" && t3_check "$t"; then
      first=$t; break
    fi
    say "  ! $t не прошёл контроль готовности, пробую следующий"
  done
  if [[ -n $first ]]; then
    printf '%s\n' "$first" >"$STATE/active"; date +%s >"$STATE/since"
  else
    # Нет выхода — активный маршрут не назначается (Xray: fallback=block).
    tr_stop_all; rm -f "$STATE/active" "$STATE/since"
  fi
  # Сторож обязан запускаться даже при нуле пригодных транспортов: он сам
  # будет периодически перепроверять ВСЕ настроенные, не отключая их навсегда.
  systemctl enable --now rp-watch >/dev/null 2>&1 || {
    say "Не удалось включить rp-watch: проверьте systemctl status rp-watch" >&2
    return 1
  }
  say "Прошли T1–T3: ${tmpu[*]:-ни один}"
  [[ -n $bad ]] && say "Не прошли при первом сканировании:$bad (сохранены для повторных проверок)"
  if [[ -z $first ]]; then
    say "Нет активного выхода: действует fail-closed; сторож продолжит восстановление"
    return 1
  fi
  say "Активен транспорт: $first (режим: $(mode_get))"
}
# VPS-2 control plane: requests are accepted BEFORE any network interruption;
# rp-watch executes them and records the result. A retry of the same request id
# never creates a second switching operation.
cmd_mode() {
  local sub=${1:-status} id=${2:-} choice=${3:-} old oldid oldchoice f tmp
  case $sub in
    auto|reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg)
      # Local emergency control from VPS-2 console if the reverse SSH path is down.
      cmd_mode request "$(cat /proc/sys/kernel/random/uuid)" "$sub"
      ;;
    status)
      say "mode=$(mode_get)"
      say "active=$(active)"
      if [[ -s $STATE/mode-request ]]; then
        read -r oldid oldchoice <"$STATE/mode-request" || true
        say "pending=$oldchoice"
      fi
      ;;
    result)
      [[ $id =~ ^[0-9a-f-]{8,64}$ ]] || return 2
      if [[ -s $STATE/mode-result ]]; then
        read -r oldid old <"$STATE/mode-result" || true
        if [[ $id == "$oldid" ]]; then printf '%s\n' "$old"; return 0; fi
      fi
      if [[ -s $STATE/mode-request ]]; then
        read -r oldid oldchoice <"$STATE/mode-request" || true
        [[ $id == "$oldid" ]] && { printf 'pending\n'; return 0; }
      fi
      printf 'unknown\n'; return 1
      ;;
    request)
      [[ $id =~ ^[0-9a-f-]{8,64}$ ]] || { say 'Invalid request ID' >&2; return 2; }
      case $choice in
        auto) : ;;
        reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg)
          mode_allowed "$choice" || { say "Transport is not configured: $choice" >&2; return 2; }
          ;;
        *) say "Invalid transport: $choice" >&2; return 2 ;;
      esac
      exec 8>"$STATE/mode-request.lock"
      flock -x 8 || return 1
      if [[ -s $STATE/mode-request ]]; then
        read -r oldid oldchoice <"$STATE/mode-request" || true
        [[ $oldid == "$id" && $oldchoice == "$choice" ]] && return 0
        say 'A transport switch is already in progress' >&2; return 1
      fi
      # Repeated request after dropped SSH acknowledgment is idempotent.
      if [[ -s $STATE/mode-result ]]; then
        read -r oldid old <"$STATE/mode-result" || true
        [[ $oldid == "$id" ]] && return 0
      fi
      tmp=$(mktemp "$STATE/.mode-request.XXXXXX") || return 1
      printf '%s %s\n' "$id" "$choice" >"$tmp" && chmod 600 "$tmp" &&
        mv -f "$tmp" "$STATE/mode-request" || { rm -f "$tmp"; return 1; }
      say "accepted=$id"
      ;;
    *) say 'rp mode status | request ID auto|TRANSPORT | result ID' >&2; return 2 ;;
  esac
}
cmd_results() { cat "$STATE/results" 2>/dev/null; }
cmd_setorder() { # rp _setorder список — оставить только перечисленные транспорты
  local l="$*" t
  [[ $l =~ ^[a-z0-9\ -]+$ ]] || { say "неверный список"; return 1; }
  sed -i "s|^TRANSPORT_ORDER=.*|TRANSPORT_ORDER=\"$l\"|" "$ETC/rp2.conf"
  for t in $l; do echo "$t"; done >"$STATE/usable"
  systemctl is-active --quiet rp-watch && systemctl restart rp-watch
  say "Приоритеты: $l (остальные намеренно исключены администратором)"
}
# egress — отчёт «ключ=значение» о том, может ли VPS-2 пропускать трафик VPS-1 в интернет
fw_egress_state() {
  local zone=$1 external=$2 info rc
  [[ -n $zone && -n $external ]] || { echo unknown; return; }
  [[ $zone == rp-tunnel && $external != rp-tunnel ]] || { echo no; return; }
  # --query-forward describes INTRA-zone forwarding. Our managed path uses
  # an active INTER-zone policy; inspect runtime state, not permanent XML.
  info=$(LC_ALL=C firewall-cmd --info-policy=rp-tunnel-egress 2>/dev/null) || { echo unknown; return; }
  if ! grep -Eq '^rp-tunnel-egress[[:space:]]+\(active\)$' <<<"$info" ||
     ! grep -Eq '^[[:space:]]+target:[[:space:]]+ACCEPT$' <<<"$info"; then
    echo no; return
  fi
  local query
  for query in "--query-ingress-zone=$zone" "--query-egress-zone=$external"; do
    if firewall-cmd --policy=rp-tunnel-egress "$query" >/dev/null 2>&1; then :
    else
      rc=$?; if ((rc == 1)); then echo no; else echo unknown; fi
      return
    fi
  done
  echo yes
}
cmd_egress() {
  local z ez external
  say "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  say "rp_filter_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
  say "nat=$(nft list table ip rp_nat >/dev/null 2>&1 && echo yes || echo NO)"
  say "nat_packets=$(nft list table ip rp_nat 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\).*/\1/p' | head -1)"
  say "default_if=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  if systemctl is-active --quiet firewalld; then
    ez=$(ip -4 route show default | awk '{print $5; exit}')
    z=$(firewall-cmd --get-zone-of-interface=rp-wg 2>/dev/null) || z=""
    external=$(firewall-cmd --get-zone-of-interface="$ez" 2>/dev/null) || external=""
    [[ -n $external ]] || external=$(firewall-cmd --get-default-zone 2>/dev/null) || external=""
    say "fw_zone_wg=${z:-—}"
    say "fw_zone_ext=${external:-—}"
    say "fw_forward=$(fw_egress_state "$z" "$external")"
  else say "fw_zone_wg=нет-firewalld"; say "fw_forward=not-applicable"; fi
  say "internet=$(curl -4 -fsS -m 8 -o /dev/null https://1.1.1.1/cdn-cgi/trace && echo ok || echo FAIL)"
}
# fixnet — привести пересылку и NAT в рабочее состояние (идемпотентно)
cmd_fixnet() {
  local ez z
  sysctl -q -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || return 1
  if [[ -d /proc/sys/net/ipv4/conf/rp-wg ]]; then
    sysctl -q -w net.ipv4.conf.rp-wg.rp_filter=2 >/dev/null 2>&1 || return 1
  fi
  systemctl enable --now rp-nat >/dev/null 2>&1 || { say "Ошибка включения rp-nat" >&2; return 1; }
  systemctl restart rp-nat >/dev/null 2>&1 || { say "Ошибка загрузки NAT" >&2; return 1; }
  if systemctl is-active --quiet firewalld; then
    # Separate rp-wg from the host's public zone. Do NOT add --add-forward to
    # that zone (it would also affect unrelated 3x-ui / hosting workloads).
    local wg_zone=rp-tunnel policy=rp-tunnel-egress old_zone
    ez=$(ip -4 route show default | awk '{print $5; exit}')
    [[ -n $ez ]] || { say 'firewalld: default IPv4 interface not found' >&2; return 1; }
    z=$(firewall-cmd --get-zone-of-interface="$ez" 2>/dev/null) || z=""
    [[ -n $z ]] || z=$(firewall-cmd --get-default-zone) || return 1
    [[ $z != "$wg_zone" ]] || { say 'firewalld: egress zone equals rp-tunnel' >&2; return 1; }
    if ! firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx "$wg_zone"; then
      firewall-cmd --permanent --new-zone="$wg_zone" >/dev/null || return 1
    fi
    if ! firewall-cmd --permanent --get-policies | tr ' ' '\n' | grep -qx "$policy"; then
      firewall-cmd --permanent --new-policy="$policy" >/dev/null || return 1
    fi
    old_zone=$(firewall-cmd --permanent --get-zone-of-interface=rp-wg 2>/dev/null || true)
    if [[ -n $old_zone && $old_zone != "$wg_zone" ]]; then
      firewall-cmd --permanent --zone="$old_zone" --remove-interface=rp-wg >/dev/null || return 1
    fi
    firewall-cmd --permanent --zone="$wg_zone" --query-interface=rp-wg >/dev/null 2>&1 ||
      firewall-cmd --permanent --zone="$wg_zone" --add-interface=rp-wg >/dev/null || return 1
    firewall-cmd --permanent --zone="$wg_zone" --query-service=ssh >/dev/null 2>&1 ||
      firewall-cmd --permanent --zone="$wg_zone" --add-service=ssh >/dev/null || return 1
    firewall-cmd --permanent --policy="$policy" --query-ingress-zone="$wg_zone" >/dev/null 2>&1 ||
      firewall-cmd --permanent --policy="$policy" --add-ingress-zone="$wg_zone" >/dev/null || return 1
    # The public zone may change if the VPS moves networks; replace outdated
    # egress zones, but only within our own policy.
    local old_eg
    for old_eg in $(firewall-cmd --permanent --policy="$policy" --list-egress-zones 2>/dev/null); do
      [[ $old_eg == "$z" ]] || firewall-cmd --permanent --policy="$policy" --remove-egress-zone="$old_eg" >/dev/null || return 1
    done
    firewall-cmd --permanent --policy="$policy" --query-egress-zone="$z" >/dev/null 2>&1 ||
      firewall-cmd --permanent --policy="$policy" --add-egress-zone="$z" >/dev/null || return 1
    firewall-cmd --permanent --policy="$policy" --set-target=ACCEPT >/dev/null || return 1
    firewall-cmd --reload >/dev/null || return 1
    ip link show rp-wg >/dev/null 2>&1 &&
      firewall-cmd --zone="$wg_zone" --change-interface=rp-wg >/dev/null 2>&1
    if firewall-cmd --zone="$z" --query-forward >/dev/null 2>&1; then
      say "! firewalld: в общей зоне $z уже включён forward (возможно, старой версией rp); автоматически не отключаю, чтобы не сломать другие сервисы"
    fi
    say "firewalld: rp-wg в отдельной зоне $wg_zone; policy $policy -> $z"
  fi
  [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]] &&
    nft list table ip rp_nat >/dev/null 2>&1 || {
      say "Ошибка: forwarding или rp_nat отсутствуют" >&2; return 1;
    }
  say "fixnet: готово"
}
cmd_status() {
  local t; t=$(active)
  say "Режим: $(mode_get); транспорт: ${t:-нет — fail-closed}"
  say "Приоритеты: $(tr_order); прошли первичный тест: $(tr '\n' ' ' <"$STATE/usable" 2>/dev/null)"
  say "Failback: $(failback_policy) (passive не прерывает рабочее соединение)"
  say "Сквозная проба (HY2 и XHTTP): случайный интервал ${WATCH_MIN:-10}–${WATCH_MAX:-15} с; штатные QUIC/TCP keepalive не меняются"
  say "hy2: $(systemctl is-active rp-hy2)  hy2o: $(systemctl is-active rp-hy2o)  wg: $(systemctl is-active wg-quick@rp-wg)  xhttp: $(systemctl is-active rp-xray@xhttp)  xhttp2: $(systemctl is-active rp-xray@xhttp2)  сторож: $(systemctl is-active rp-watch)"
  [[ -n $t ]] && { func_ok "$t" && say "Проверка: туннель работает" || say "Проверка: туннель НЕ отвечает"; }
  [[ $t == hy2* ]] && wg show rp-wg latest-handshakes 2>/dev/null | awk '{print "Рукопожатие WG: " (($2>0)? systime()-$2 " с назад" : "не было")}'
  say "NAT: $(nft list table ip rp_nat >/dev/null 2>&1 && echo есть || echo ОТСУТСТВУЕТ)  пересылка: $(sysctl -n net.ipv4.ip_forward)"
  say "Версии: $(cmd_version)"
}
cmd_version() { echo "xray $(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}') hysteria $(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/{print $2}')"; }
cmd_logs() { journalctl -u rp-watch -u rp-hy2 -u rp-hy2o -u 'rp-xray@*' -u wg-quick@rp-wg -n "${1:-80}" --no-pager; }
restart_ready() {
  # Type=simple can report a successful start before the process immediately
  # exits. Verify the reverse tunnel, with a bounded lightweight probe; full
  # selection/update T1-T3 are unchanged. _fn does not acquire the mutation lock.
  local t=$1 attempt
  for attempt in 1 2 3 4 5; do
    unit_failed "$t" && return 1
    timeout -k 2 8 /bin/bash "$0" _fn func_ok "$t" && return 0
    ((attempt == 5)) || sleep 2
  done
  return 1
}
cmd_restart() {
  local t; t=$(active)
  [[ -n $t ]] || { say "Транспорт не выбран: rp select"; return 1; }
  tr_start "$t" || { say "Ошибка перезапуска: $t" >&2; return 1; }
  restart_ready "$t" || { say "Туннель не восстановился после перезапуска: $t" >&2; return 1; }
  say "Перезапущено: $t"
}
cmd_remove() {
  read -rp "Удалить rp с VPS-2 (туннель, конфиги, ключ SSH)? [y/N] " a; [[ ${a,,} == y ]] || return 0
  # Exact owned units only: another application may also use the rp- prefix.
  # Stop timers before removing the runner and handle absent legacy units singly.
  local u
  for u in rp-transaction-rollback.timer rp-rollback-run.timer rp-rollback.timer \
    rp-transaction-recover.service rp-transaction-rollback.service rp-rollback-run.service \
    rp-rollback.service rp-watch.service rp-nat.service rp-hy2.service rp-hy2o.service \
    rp-xray@xhttp.service rp-xray@xhttp2.service rp-xray@tcp.service wg-quick@rp-wg.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  tr_stop_all
  for u in rp-watch.service rp-nat.service rp-hy2.service rp-hy2o.service rp-xray@.service \
    rp-rollback.service rp-rollback.timer rp-rollback-run.service rp-rollback-run.timer \
    rp-transaction-recover.service rp-transaction-rollback.service rp-transaction-rollback.timer; do
    rm -f "/etc/systemd/system/$u"
  done
  rm -f /root/.rp-push.sh /etc/wireguard/rp-wg.conf
  rm -rf /usr/local/lib/rp /usr/local/share/rp "$ETC" "$STATE"
  [[ -f /root/.ssh/authorized_keys ]] && sed -i '/ rp@vps1$/d' /root/.ssh/authorized_keys
  nft delete table ip rp_nat 2>/dev/null; rm -f /etc/sysctl.d/99-rp.conf
  if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --delete-policy=rp-tunnel-egress >/dev/null 2>&1 || true
    firewall-cmd --permanent --delete-zone=rp-tunnel >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload; say "Удалено. Бинарники /usr/local/bin/{xray,hysteria,rp} оставлены; rm — вручную."
}
cmd_confirm() {
  if [[ -f $STATE/transaction/state.json ]]; then
    python3 "$STATE/transaction/runner.py" confirm
    return $?
  fi
  say "Нет проверяемой транзакции: подтверждение запрещено" >&2
  return 1
}
cmd_rollback() {
  if [[ -f $STATE/transaction/state.json ]]; then
    python3 "$STATE/transaction/runner.py" rollback
    return $?
  fi
  [[ -f $STATE/backup.tgz ]] || { say "Резервной копии нет"; return 1; }
  tar -xzf "$STATE/backup.tgz" -C / || { say "Не удалось восстановить резервную копию" >&2; return 1; }
  local f
  for f in mode active since; do
    if [[ -f $STATE/$f.before-identity ]]; then
      mv -f "$STATE/$f.before-identity" "$STATE/$f" || return 1
    fi
  done
  systemctl daemon-reload && cmd_restart || return 1
  systemctl stop rp-rollback-run.timer rp-rollback.timer >/dev/null 2>&1 || true
  rm -f /root/.rp-push.sh
  say "Возврат к прежним параметрам выполнен"
}
menu() {
  while :; do
    if rp_plain_console; then
      say ""
      say "== rp VPS-2 | transport: $(active) =="
      say "1 Status | 2 Restart | 3 Logs | 4 Retest | 5 Repair NAT | 6 Remove | 0 Exit"
      printf '> '
    else
      printf '\n◆ rp · VPS-2   транспорт: %s\n  1 Статус\n  2 Перезапуск\n  3 Журнал\n  4 Проверить все транспорты заново\n  5 Починить NAT и пересылку\n  6 Удалить\n  0 Выход\n› ' "$(active)"
    fi
    read -r c || exit 0
    case $c in 1) cmd_status ;; 2) /usr/local/bin/rp restart ;; 3) cmd_logs 60 ;; 4) /usr/local/bin/rp select ;; 5) /usr/local/bin/rp fixnet ;; 6) /usr/local/bin/rp remove ;; 0) exit 0 ;; *) say "Введите число от 0 до 6" ;; esac
  done
}
if [[ ${1:-} == --ascii ]]; then RP_ASCII=1; export RP_ASCII; shift; fi
case "${1:-menu}:${2:-}" in
  mode:status|mode:result|mode:) : ;;
  select:*|restart:*|remove:*|fixnet:*|mode:*|failback:*|_setorder:*)
    if [[ ${RP_TX_INTERNAL:-0} != 1 ]]; then
      exec 8>/run/rp-vps2-mutation.lock
      flock -n 8 || { say "Другая операция VPS-2 выполняется" >&2; exit 1; }
      if [[ -f $STATE/transaction/pending ]]; then
        say "Обновление не завершено; требуется rollback" >&2; exit 1
      fi
    fi ;;
esac
case ${1:-menu} in
  menu) menu ;; status) cmd_status ;; restart) cmd_restart ;; logs) cmd_logs "${2:-80}" ;; select) cmd_select ;;
  test) t=$(active); t1_check "$t" && t2_check "$t" && t3_check "$t" && say "T1–T3: ок" ;;
  remove) cmd_remove ;; version) cmd_version ;; confirm) cmd_confirm ;; rollback) cmd_rollback ;;
  results) cmd_results ;; egress) cmd_egress ;; fixnet) cmd_fixnet ;; mode) shift; cmd_mode "$@" ;; failback) shift; cmd_failback "$@" ;; _setorder) shift; cmd_setorder "$@" ;;
  _func) func_ok "$(active)" ;;
  _fn) shift; "$@" ;;
  *) say "rp: status | restart | logs [N] | select | test | results | egress | fixnet | version | remove (без аргументов — меню)"; say "Заменить параметры: вставьте новый блок из VPS-1." ;;
esac
