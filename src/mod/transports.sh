#!/usr/bin/env bash
transport_label() {
  case $1 in
    hy2-wg) echo "Hysteria2 · QUIC/UDP · без обфускации · несёт WG" ;;
    hy2o-wg) echo "Hysteria2 · QUIC/UDP · обфускация Salamander · несёт WG" ;;
    reality-xhttp) echo "VLESS Reverse · Reality · XHTTP (stream-up) · TCP" ;;
    reality-xhttp2) echo "VLESS Reverse · Reality · XHTTP (packet-up) · TCP" ;;
    *) echo "$1" ;;
  esac
}
ord_has() { [[ " $1 " == *" $2 "* ]]; }   # ord_has "список" имя
tr_sort() { # tr_sort "список" → тот же набор в порядке TR_RANK (неизвестные имена отбрасываются)
  local t out=""; for t in "${TR_RANK[@]}"; do [[ " $* " == *" $t "* ]] && out+="${out:+ }$t"; done
  printf '%s\n' "$out"
}
tr_port() { case $1 in hy2-wg) echo "UDP/$(cf HY2_PORT)" ;; hy2o-wg) echo "UDP/$(cf HY2O_PORT)" ;; reality-xhttp) echo "TCP/$(cf RXH_PORT)" ;; reality-xhttp2) echo "TCP/$(cf RXH2_PORT)" ;; esac; }

# ── Транспорты: результаты проверки на VPS-2, исключение неработающих ────
tr_results() { vps2_run '/usr/local/bin/rp results' 2>/dev/null; }
cmd_transports() {
  need_vps1; local res t r st
  res=$(tr_results || true)
  card "Транспорты"
  for t in $(cf TRANSPORT_ORDER); do
    r=$(printf '%s\n' "$res" | awk -F= -v t="$t" '$1==t {print $2}')
    case $r in ok) st="${C_OK}работает${R}" ;; fail*) st="${C_ERR}не прошёл (${r#fail:})${R}" ;; *) st="${C_DIM}нет данных${R}" ;; esac
    kv "$t" "$(tr_port "$t") · $st"
    card_line "  ${C_DIM}$(transport_label "$t")${R}"
  done
  card_end
}
prune_apply() { # prune_apply «список-неработающих» → новый порядок на VPS-1 и VPS-2
  local bad=$1 t new=""
  for t in $(cf TRANSPORT_ORDER); do [[ " $bad " == *" $t "* ]] || new+="${new:+ }$t"; done
  new=$(tr_sort "$new")   # единая политика приоритетов
  [[ -n $new ]] || { err "Исключить все транспорты нельзя: сначала смените порты/SNI (rp.conf) и повторите rp select на VPS-2"; return 1; }
  vps1_set TRANSPORT_ORDER "$new" || return 1
  vps2_run "/usr/local/bin/rp _setorder $new" >/dev/null 2>&1 || warn "Порядок на VPS-2 не обновлён: на VPS-2 выполните  rp _setorder $new"
  ok "Остались: $new; порты исключённых закрыты, службы остановлены"
}
cmd_prune() {
  need_vps1; local res bad="" line t r
  res=$(tr_results) || die "Нет связи с VPS-2 — результаты проверки недоступны (выполните rp select на VPS-2)"
  [[ -n $res ]] || die "На VPS-2 нет результатов: выполните там  rp select"
  while IFS='=' read -r t r; do [[ -n $t && $r == fail* ]] && [[ " $(cf TRANSPORT_ORDER) " == *" $t "* ]] && bad+="${bad:+ }$t"; done <<<"$res"
  cmd_transports
  [[ -n $bad ]] || { ok "Все транспорты из конфигурации прошли проверку на VPS-2"; return 0; }
  warn "Не прошли проверку: $bad"
  yesno "Исключить их НАВСЕГДА из резервов (закрыть порты и остановить службы)? Обычно лучше оставить для авто-восстановления" n || return 0
  prune_apply "$bad"
}
prune_offer() { # Никакого автоматического удаления резервов: временная блокировка может исчезнуть.
  local res bad="" t r
  res=$(tr_results) || return 0
  while IFS='=' read -r t r; do [[ -n $t && $r == fail* ]] && [[ " $(cf TRANSPORT_ORDER) " == *" $t "* ]] && bad+="${bad:+ }$t"; done <<<"$res"
  [[ -n $bad ]] || return 0
  warn "Первичную проверку не прошли: $bad; остаются в списке резервов с повторными попытками"
  note "Для намеренного исключения из конфигурации: rp prune (по умолчанию отказ)"
  return 0
}

# ── Ручной выбор транспорта VPS-2 ──────────────────────────────────────
cmd_tunnel() {
  need_vps1
  local desired=${1:-status} req reply attempt old="" t cur old_state=""
  local -a options=("auto|Автоматически|приоритеты и резервирование включены")
  case $desired in
    select)
      for t in $(cf TRANSPORT_ORDER); do
        case $t in
          reality-xhttp2) options+=("$t|VLESS + REALITY + XHTTP packet-up|TCP, основной") ;;
          reality-xhttp) options+=("$t|VLESS + REALITY + XHTTP stream-up|TCP, резерв") ;;
          hy2-wg) options+=("$t|Hysteria2|UDP, внутренний WG") ;;
          hy2o-wg) options+=("$t|Hysteria2 + Salamander|UDP, внутренний WG") ;;
        esac
      done
      note "Режим и текущий транспорт на VPS-2:"
      old_state=$(vps2_read '/usr/local/bin/rp mode status') || { err "Нет управляющего SSH к VPS-2; выбор невозможен"; return 1; }
      printf '%s
' "$old_state"
      note "Фиксированный транспорт: при отказе другой не включается (fail-closed)."
      old=$(sed -n 's/^mode=//p' <<<"$old_state" | head -1)
      [[ $old == manual:* ]] && old=${old#manual:}
      [[ -n $old ]] || old=auto
      desired=""
      choose desired "Режим обратного туннеля" "$old" "${options[@]}"
      if [[ $desired == "$old" ]]; then
        note "Режим уже выбран; проверяю согласованность маршрута"
        if route_sync_locked; then
          ok "Маршрут Xray согласован"
          return 0
        fi
        err "Не удалось подтвердить маршрут: rp tunnel sync"
        return 1
      fi
      ;;
    status)
      if ! vps2_read '/usr/local/bin/rp mode status'; then
        warn "Нет подтверждения VPS-2 по обратному SSH; используйте rp tunnel recover ТРАНСПОРТ, если VPS-2 уже переключён"
      fi
      note "Маршрут Xray VPS-1: $(cat "$STATE/route-target" 2>/dev/null || echo не синхронизирован)"
      [[ ! -s $STATE/route-transition ]] || transition_show
      return 0 ;;
    recover)
      [[ $# -ge 2 ]] || { err "Использование: rp tunnel recover reality-xhttp"; return 2; }
      route_recover "$2"
      return $? ;;
    sync)
      if route_sync_locked; then
        ok "Маршрут VPS-1 согласован с активным транспортом VPS-2"
        return 0
      fi
      err "Состояние VPS-2 не подтверждено, маршрут VPS-1 оставлен без изменений"
      return 1 ;;
    auto|reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg) : ;;
    *) die "rp tunnel [status|select|sync|recover TRANSPORT|auto|reality-xhttp2|reality-xhttp|hy2-wg|hy2o-wg]" ;;
  esac
  [[ $desired == auto ]] || tr_has "$desired" || { err "Транспорт $desired не включён в настройках VPS-1"; return 1; }
  if [[ $desired == auto ]]; then
    note "Включаю автоматическое переключение и возврат по приоритетам"
  else
    warn "Ручная фиксация $desired отключает failover на другие протоколы; при сбое — fail-closed"
  fi
  if [[ -s $STATE/route-transition ]]; then
    err "Предыдущее переключение ещё не подтверждено. Сначала: rp tunnel status; rp tunnel sync"
    return 1
  fi
  req=$(uuid) || return 1
  local before
  before=$(cat "$STATE/route-target" 2>/dev/null || true)
  transition_start "$req" "$desired" "$before" || return 1
  if ! push_ssh "/usr/local/bin/rp mode request $req $desired" /dev/null; then
    transition_clear
    err "Не удалось передать команду выбора на VPS-2"
    return 1
  fi
  # VPS-2 has accepted, but the asynchronous watcher may not have switched.
  # Pre-arm ONLY the management 'rev' balancer; leave customer 'exit' on the
  # old working transport until VPS-2 confirms the new active channel.
  if [[ $desired != auto ]]; then
    local prepared
    prepared=$(route_target_for "$desired") || return 1
    if ! route_prepare "$prepared"; then
      err "Запрос принят VPS-2, но подготовка управляющего пути не прошла. Операция ожидает восстановления"
      warn "Проверьте: rp tunnel status; rp tunnel recover $desired"
      return 1
    fi
  fi
  note "VPS-2 принял запрос. Управляющий путь подготовлен; пользовательский выход остаётся прежним до подтверждения."
  local deadline=$((SECONDS + 300))
  while ((SECONDS < deadline)); do
    reply=$(RP_READ_RETRIES=1 vps2_read "/usr/local/bin/rp mode result $req" 2>/dev/null | tail -1 | tr -d '\r' || true)
    case $reply in
      ok)
        local state now_mode now_active ready=0
        state=$(vps2_read '/usr/local/bin/rp mode status' 2>/dev/null || true)
        now_mode=$(sed -n 's/^mode=//p' <<<"$state" | head -1)
        now_active=$(sed -n 's/^active=//p' <<<"$state" | head -1)
        if [[ $desired == auto ]]; then
          [[ $now_mode == auto ]] || { warn "VPS-2 ещё не подтвердил автоматический режим"; sleep 3; continue; }
        else
          [[ $now_mode == "manual:$desired" && $now_active == "$desired" ]] || { warn "VPS-2 ещё переключается"; sleep 3; continue; }
        fi
        if ! route_sync_locked; then
          warn "VPS-2 подтвердил режим, но маршрут ещё согласуется; повторяю"
          sleep 3
          continue
        fi
        # The outbound route is now pinned to the confirmed VPS-2 transport.
        # Give existing TCP connections time to drain before testing a fresh one.
        for ((ready=1; ready<=12; ready++)); do
          wait_exit_once && break
          sleep 3
        done
        if ((ready>12)); then
          warn "Режим согласован, но сквозной выход не подтвердился. Проверьте rp test / rp diag"
          return 1
        fi
        ok "Обе VPS используют один транспорт: ${now_active:-не подтверждён}. Выход проверен."
        printf '%s\n' "$state"
        return 0 ;;
      fail)
        if ! route_sync_locked >/dev/null 2>&1; then
          [[ -z $before ]] || route_pin "$before" || true
        fi
        transition_clear
        err "VPS-2 не смог проверить $desired; выполнен откат к прежнему маршруту, если он доступен"
        return 1 ;;
    esac
    sleep 3
  done
  warn "За 300 с нет подтверждения VPS-2. Запрос сохранён в $STATE/route-transition."
  warn "Не повторяйте переключение: rp tunnel sync; при необходимости rp tunnel recover ТРАНСПОРТ"
  return 1
}
