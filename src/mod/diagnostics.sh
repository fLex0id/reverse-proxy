#!/usr/bin/env bash
wait_exit_once() { local ip; ip=$(sx -m 6 https://api.ipify.org 2>/dev/null) && [[ -n $ip ]] && { [[ -z $(cf VPS2_IPH) || $(ip_hash "$ip") == "$(cf VPS2_IPH)" ]]; }; }
wait_exit() { local t=0; while ((t < 90)); do wait_exit_once && return 0; sleep 3; t=$((t + 3)); done; return 1; }
failclosed_static() {
  local rules
  nft list table inet rp_guard >/dev/null 2>&1 || return 1
  nft list table ip rp_tp >/dev/null 2>&1 || return 1
  nft list table ip6 rp_block6 >/dev/null 2>&1 || return 1
  rules=$(nft list chain inet rp_guard forward 2>/dev/null) || return 1
  grep -Eq 'iifname "wg0".*drop' <<<"$rules" || return 1
  grep -Eq 'oifname "wg0".*drop' <<<"$rules" || return 1
  rules=$(nft list chain inet rp_guard output 2>/dev/null) || return 1
  grep -Eq 'ip saddr 10\.77\.0\.1 oifname != "wg-exit" oifname != "lo".*drop' <<<"$rules" || return 1
  ip -4 rule show | grep -Eq 'from 10\.77\.0\.1(/32)? lookup 200' || return 1
  ip -4 rule show | grep -Eq 'fwmark 0xff.*lookup 200' || return 1
  ip -4 route show table 200 | grep -Eq '(^|[[:space:]])prohibit[[:space:]]+default|^prohibit default' || return 1
  python3 -I - "$ETC/xray.json" <<'PY_VERIFY_XRAY'
@PY:failclosed_static@
PY_VERIFY_XRAY
}
# rp diag [--fix]: каждый участок пути проверяется отдельно, чтобы причина была названа, а не угадана
cmd_diag() {
  need_vps1
  local fix=0 failed=0 u active="" mark="" rf rfi eff pr="" code probe_ok=0 eg k v
  local -A E=()
  if (($#)); then
    [[ $# == 1 && $1 == --fix ]] || { err "rp diag [--fix]"; return 2; }
    fix=1
  fi
  banner "Диагностика выхода в интернет" "$( ((fix)) && echo 'с исправлением' || echo 'только проверка')"
  for u in rp-net rp-xray; do
    systemctl is-active -q "$u" && ok "$u работает" || { err "$u не работает (journalctl -u $u)"; failed=1; }
  done
  active=$(vps2_read 'cat /var/lib/rp/active' 2>/dev/null | tr -d '\r\n' || true)
  mark=$(control_method "$active" 2>/dev/null || true)
  if [[ -n $mark ]]; then
    ok "VPS-2 сообщает активный транспорт: $active"
  elif sx -m 10 https://api.ipify.org >/dev/null 2>&1; then
    warn "Выход через SOCKS есть, но активный транспорт не удалось получить по SSH; вероятно, переходное состояние"
    note "Для уточнения: повторите rp diag после стабилизации сторожа VPS-2"
    failed=1
  else
    err "Нет подтверждённой связи с VPS-2 ни по SSH, ни через SOCKS"
    return 1
  fi
  # The inactive WG interface may still have a recent handshake for up to 180s.
  # Never interpret that alone as evidence of a live HY2 transport.
  if [[ $mark == hy2 ]]; then
    if hy2_live; then
      ok "Внутренний WG активного Hysteria2: свежий handshake"
    else
      warn "VPS-2 выбрал Hysteria2, но WG handshake отсутствует или устарел"
      failed=1
    fi
  elif [[ -n $active ]]; then
    note "Проба wg-exit не требуется: активный маршрут — XHTTP Reverse"
  fi
  rf=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0)
  rfi=$(sysctl -n net.ipv4.conf.wg-exit.rp_filter 2>/dev/null || echo 0)
  eff=$((rf > rfi ? rf : rfi))
  if [[ $mark == hy2 ]] && ((eff == 1)); then
    err "Строгий rp_filter мешает wg-exit (all=$rf, wg-exit=$rfi)"
    failed=1
    if ((fix)); then
      sysctl -q -w net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 net.ipv4.conf.wg-exit.rp_filter=2 >/dev/null 2>&1 && ok "rp_filter переведён в loose"
    fi
  else
    ok "rp_filter: all=$rf wg-exit=$rfi (актуально при Hysteria2)"
  fi
  if [[ $mark == hy2 ]] && hy2_live; then
    ip -4 route get 1.1.1.1 mark 255 2>/dev/null | grep -q 'wg-exit' && ok "Маршрут mark 255 ведёт в wg-exit" || { err "Нет маршрута с mark 255 через wg-exit"; failed=1; }
    pr=$(py probe 1.1.1.1 443)
    case $pr in
      ok*) probe_ok=1; ok "Прямая проба через внутренний WG: ${pr#ok } мс" ;;
      *) warn "Внутренний WG не прошёл пробу: $pr (маршрут/переключение/NAT; не доказательство блокировки)"; failed=1 ;;
    esac
  fi
  # VPS-2 egress reports routing/NAT for the inner WG transport; only relevant when HY2 is active.
  if [[ $mark == hy2 ]]; then
    if eg=$(vps2_read '/usr/local/bin/rp egress' 2>/dev/null) && [[ -n $eg ]]; then
      while IFS='=' read -r k v; do [[ -n $k ]] && E[$k]=$v; done <<<"$eg"
      local fixv2=0
      [[ ${E[ip_forward]:-} == 1 ]] && ok "VPS-2: пересылка IPv4 включена" || { err "VPS-2: IPv4 forwarding выключен"; fixv2=1; }
      [[ ${E[nat]:-} == yes ]] && ok "VPS-2: NAT для WG присутствует" || { err "VPS-2: NAT для WG отсутствует"; fixv2=1; }
      case ${E[fw_forward]:-} in
        yes|not-applicable) : ;;
        *) err "VPS-2: политика firewalld для WG не подтверждена"; fixv2=1 ;;
      esac
      if ((fixv2)); then
        failed=1
        if ((fix)); then vps2_run '/usr/local/bin/rp fixnet' && ok "Команда восстановления NAT на VPS-2 выполнена" || err "Не удалось исправить NAT на VPS-2"
        else warn "Для исправления NAT: rp diag --fix"; fi
      fi
    else warn "SSH к VPS-2 временно недоступен, сведения о NAT не получены"; failed=1; fi
  fi
  if [[ $mark == hy2 && $fix == 1 && $probe_ok == 0 ]]; then
    sleep 2
    pr=$(py probe 1.1.1.1 443)
    [[ $pr == ok* ]] && ok "Повторная проба внутреннего WG: ${pr#ok } мс" || warn "Проба после исправления не прошла: $pr"
  fi
  if code=$(sx -m 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null) && [[ $code == 204 ]]; then
    ok "Через Xray (SOCKS) интернет доступен"
  else err "Проба выхода через SOCKS не прошла (HTTP ${code:-нет ответа})"; failed=1; fi
  cmd_dns test || failed=1
  if ((fix)); then
    note "Повторная диагностика после исправлений; итог определяется фактическими проверками"
    cmd_diag
    return $?
  fi
  return "$failed"
}

# ── Тесты T1–T8 ──────────────────────────────────────────────────────────
t_res() { TR+=("$1|$2|$3"); case $2 in ok) ok "$1 $3" ;; fail) err "$1 $3" ;; *) note "– $1 $3" ;; esac; }
cmd_test() {
  need_vps1; TR=()
  local long=0 restart=0 opt n=204800 act="" method="" ip="" want="" known="" code="" d1="" port=""
  local t miss="" t0=0 up=0 r bad=0
  for opt in "$@"; do
    case $opt in
      --long) long=1 ;;
      --restart) restart=1 ;;
      *) err "Неверный параметр $opt: rp test [--long] [--restart]"; return 2 ;;
    esac
  done
  banner "Проверка туннеля" "T1–T8 (без разрыва активных соединений$( ((restart)) && echo '; явный перезапуск T8' ))"
  for t in $(cf TRANSPORT_ORDER); do
    case $t in
      hy2-wg) systemctl is-active -q rp-hy2 || miss+=" hy2" ;;
      hy2o-wg) systemctl is-active -q rp-hy2o || miss+=" hy2+obfs" ;;
      reality-xhttp) ss -lnt | grep -q ":$(cf RXH_PORT) " || miss+=" xhttp" ;;
      reality-xhttp2) ss -lnt | grep -q ":$(cf RXH2_PORT) " || miss+=" xhttp2" ;;
    esac
  done
  [[ -z $miss ]] && t_res T1 ok "локальные слушатели транспортов работают" || t_res T1 fail "не слушают:$miss"
  # Query active from VPS-2; a past WG handshake is NOT a current transport indicator.
  # Three read retries tolerate switching during a watchdog's check.
  act=$(vps2_read 'cat /var/lib/rp/active' 2>/dev/null | tr -d '\r\n' || true)
  # Test the route that VPS-2 actually selected; no service restart.
  # This path runs under rp.lock, so use the non-locking reconciler.
  if [[ -n $act ]] && { tr_has reality-xhttp || tr_has reality-xhttp2; }; then
    route_sync_locked >/dev/null 2>&1 || warn "Не удалось синхронизировать Xray с VPS-2; T5/T6 могут быть переходными"
  fi
  method=$(control_method "$act" 2>/dev/null || true)
  if [[ -n $method ]] && ! ssh_method_ready "$method"; then
    note "Жду открытия управляющего SSH через $method (до 60 с)…"
    wait_ssh_method "$method" 60 || true
  fi
  if [[ -n $method ]] && ssh_method_ready "$method"; then
    t_res T2 ok "активный на VPS-2: $act (SSH через $method подтверждён)"
  elif [[ -n $method ]]; then
    t_res T2 skip "VPS-2 сообщает $act, но управляющий SSH сейчас переключается; тест не равен отказу транспорта"
    method=""
  elif sx -m 10 https://api.ipify.org >/dev/null 2>&1; then
    t_res T2 skip "выход через VPS-2 есть; SSH-данные о текущем транспорте пока недоступны"
  else
    t_res T2 fail "нет подтверждённого выхода и ответа SSH от VPS-2; проверьте rp status / rp diag"
  fi
  # T3/T4 use an explicitly selected path; no more switching implicitly from
  # XHTTP to an inactive WG tunnel just because an earlier handshake is fresh.
  if [[ -n $method ]]; then
    wait_ssh_method "$method" 30 || true
    if t3_ssh_method "$method" "$n"; then
      t_res T3 ok "200 КБ в обе стороны по SSH через $method"
    else
      local act_now
      act_now=$(vps2_read 'cat /var/lib/rp/active' 2>/dev/null | tr -d '\r\n' || true)
      if [[ -n $act_now && $act_now != "$act" ]]; then
        t_res T3 skip "во время передачи активный транспорт изменился: $act → $act_now; повторите rp test"
      else
        t_res T3 fail "SSH-передача 200 КБ через $method не прошла; причина требует логов, это не доказательство воздействия ТСПУ"
      fi
    fi
    if ssh_method_banner "$method"; then
      t_res T4 ok "SSH-баннер VPS-2 через $method получен"
    else
      t_res T4 skip "SSH-дверь через $method временно не отвечает; возможна смена активного транспорта"
    fi
  else
    t_res T3 skip "нет стабильного управляющего SSH; объёмный тест будет повторён при следующем запуске"
    t_res T4 skip "нет стабильного SSH-пути для проверки баннера"
  fi
  if ((long)) && [[ -n $method ]]; then
    local w
    for w in 60 240 600; do
      note "Повтор T3 через $((w / 60)) мин…"; sleep "$w"
      t3_ssh_method "$method" "$n" && t_res T3+ ok "повторная передача в обе стороны" || { t_res T3+ fail "повторная SSH-передача не прошла"; break; }
    done
  fi
  # T5: prefer a persisted fingerprint when the SSH control path is flaky.
  # Do not report 'expected —' as an exit-IP mismatch.
  ip=$(sx -m 12 https://api.ipify.org 2>/dev/null || true)
  want=$(vps2_read 'curl -4 -fsS -m 8 https://api.ipify.org' 2>/dev/null | tr -d '[:space:]' || true)
  known=$(cf VPS2_IPH)
  if [[ $want =~ ^[0-9.]+$ && -n $ip && $ip == "$want" ]]; then
    [[ -z $known ]] && conf_set VPS2_IPH "$(ip_hash "$want")"
    if [[ -n $known && $(ip_hash "$want") != "$known" ]]; then
      t_res T5 fail "контрольный IP VPS-2 изменился (проверить вручную перед обновлением отпечатка)"
    else
      touch "$STATE/linked"
      t_res T5 ok "выход через VPS-2 ($(mask_ip "$ip")) подтверждён сравнением IP"
    fi
  elif [[ -n $ip && -n $known && $(ip_hash "$ip") == "$known" ]]; then
    t_res T5 ok "выход $(mask_ip "$ip") совпадает с сохранённым отпечатком VPS-2$( [[ -z $want ]] && echo '; контрольный SSH недоступен' )"
  elif [[ -z $ip ]]; then
    t_res T5 fail "SOCKS не смог получить IP выхода; проверьте rp diag"
  elif [[ -z $want && -z $known ]]; then
    t_res T5 skip "IP выхода известен, но нет контрольного IP или сохранённого отпечатка VPS-2"
  elif [[ -z $want ]]; then
    t_res T5 fail "IP выхода не соответствует сохранённому отпечатку VPS-2"
  else
    t_res T5 fail "IP выхода отличается от IP VPS-2 (выход $(mask_ip "$ip"), VPS-2 $(mask_ip "$want"))"
  fi
  d1=$(py dns | head -1)
  doh_test "$d1" && t_res T6 ok "DoH через туннель ($d1)" || t_res T6 fail "DoH не прошёл проверку ($d1); подробности: $STATE/doh-last-failure.json"
  code=$(sx -m 12 -o /dev/null -I -w '%{http_code}' https://www.instagram.com/ 2>/dev/null || true)
  [[ -n $code && $code != 000 ]] && t_res T6b ok "тестовый HTTPS-ресурс ответил (HTTP $code)" || t_res T6b fail "тестовый HTTPS-ресурс не ответил"
  note "UDP/DNS клиентов wg0 проверьте с клиента: nslookup example.com"
  # A healthy alternate transport MUST NOT be called an IP leak. Test structural
  # protection only; never stop wg-exit nor restart Xray during normal rp test.
  if failclosed_static; then
    t_res T7 ok "kill switch, nftables и fallbackTag=block проверены (статически, без остановки туннеля)"
  else
    t_res T7 fail "неполная конфигурация fail-closed; проверьте rp-net, nftables и маршруты"
  fi
  if ((restart)); then
    warn "T8 --restart: по явному запросу перезапускаются rp-xray, rp-hy2 и rp-hy2o"
    if systemctl restart rp-xray && { ! tr_has hy2-wg || systemctl restart rp-hy2; } && { ! tr_has hy2o-wg || systemctl restart rp-hy2o; }; then
      while ((t0 < 120)); do
        wait_exit_once && { up=1; break; }
        sleep 3; t0=$((t0+3))
      done
      ((up)) && t_res T8 ok "выход восстановился после перезапуска за $t0 с" || t_res T8 fail "нет выхода после перезапуска за 120 с"
    else
      t_res T8 fail "не удалось перезапустить одну из служб"
    fi
  else
    t_res T8 skip "перезапуск служб намеренно не выполнялся; для отдельного испытания используйте rp test --restart"
  fi
  for r in "${TR[@]}"; do [[ $r == *"|fail|"* ]] && bad=1; done
  prune_offer
  return "$bad"
}

cmd_doctor() {
  need_vps1; banner "Сводка" "rp doctor"
  local v2 ip
  card "VPS-1"; kv "rp" "$SELF_VERSION"; kv "Xray" "$($XRAY_BIN version 2>/dev/null | awk 'NR==1{print $2}')"
  [[ -x $HY2_BIN ]] && kv "Hysteria2" "$($HY2_BIN version 2>/dev/null | awk '/^Version:/{print $2}')"
  kv "Транспорты" "$(cf TRANSPORT_ORDER)"
  ip=$(sx -m 8 https://api.ipify.org 2>/dev/null)
  kv "Выход (факт)" "$(mask_ip "${ip:-}")"
  [[ -n $ip && -n $(cf VPS2_IPH) ]] && { [[ $(ip_hash "$ip") == "$(cf VPS2_IPH)" ]] && kv "Выход = VPS-2" "да" || kv "Выход = VPS-2" "${C_ERR}нет${R}"; }
  card_end
  if v2=$(vps2_run '/usr/local/bin/rp version' 2>/dev/null); then
    card "VPS-2"; kv "Версии" "$v2"; card_end
    local mine; mine="xray $(cf XRAY_VER) hysteria $(cf HY2_VER)"
    local a b; a=$(sed -E 's/(^| )v([0-9])/\1\2/g' <<<"$v2"); b=$(sed -E 's/(^| )v([0-9])/\1\2/g' <<<"$mine")   # префикс «v» не различие
    [[ $a == "$b" ]] && ok "Версии на обоих концах согласованы" || warn "Версии различаются (VPS-1: $mine) — rp push"
  else warn "VPS-2 недоступен по SSH"; fi
  return 0
}

# ── Статус, журнал, удаление ─────────────────────────────────────────────
cmd_status() {
  need_vps1; banner "rp · VPS-1" "$(cf PUBLIC_IP)"
  card "Службы"
  kv "Xray (TPROXY, маршруты)" "$(dot_state rp-xray)"; kv "WG клиентов (wg0)" "$(dot_state wg-quick@wg0)"
  tr_has hy2-wg && kv "Hysteria2 (сервер)" "$(dot_state rp-hy2)"
  tr_has hy2o-wg && kv "Hysteria2 + obfs" "$(dot_state rp-hy2o)"
  [[ $(cf TRANSPORT_ORDER) == *hy2* ]] && kv "WG к VPS-2 (wg-exit)" "$(dot_state wg-quick@wg-exit)"
  kv "Правила сети" "$(dot_state rp-net)"; card_end
  card "Туннель"
  kv "Порядок транспортов" "$(cf TRANSPORT_ORDER)"
  local snapshot policy act local_target expected
  snapshot=$(vps2_read '/usr/local/bin/rp mode status' 2>/dev/null || true)
  policy=$(sed -n 's/^mode=//p' <<<"$snapshot" | head -1)
  act=$(sed -n 's/^active=//p' <<<"$snapshot" | head -1)
  kv "Режим VPS-2" "${policy:-не подтверждён (обратный SSH недоступен)}"
  case "$act" in
    reality-xhttp|reality-xhttp2|hy2-wg|hy2o-wg) kv "Живой транспорт" "$act" ;;
    *) kv "Живой транспорт" "не подтверждён (handshake не показатель)" ;;
  esac
  local_target=$(cat "$STATE/route-target" 2>/dev/null || true)
  expected=$(route_target_for "$act" 2>/dev/null || true)
  kv "Маршрут VPS-1 (пользовательский)" "${local_target:-балансировщик/ещё не синхронизирован}"
  kv "Политика управления VPS-1" "$(cat "$STATE/route-policy" 2>/dev/null || echo не подтверждена)"
  if [[ -s $STATE/route-transition ]]; then
    kv "Переключение" "$(transition_show)"
  fi
  if [[ -n $expected && -n $local_target && $expected != "$local_target" ]]; then
    warn "Маршруты VPS-1 и VPS-2 расходятся: выполните rp tunnel sync"
  fi
  kv "Клиентов WG" "$(client_names | wc -l)"; kv "Выход VPS-2" "$([[ -n $(cf VPS2_IPH) ]] && echo "проверен (адрес не хранится)" || echo "ещё не проверялся: rp test")"; card_end
}
cmd_logs() { journalctl -u rp-xray -u rp-hy2 -u rp-hy2o -u rp-net -u wg-quick@wg0 -u wg-quick@wg-exit -n "${1:-80}" --no-pager; }
cmd_restart() {
  need_vps1
  local rc=0
  # Restart explicitly includes inactive client WG and the functional probe
  # service. Requires= alone does not start an already inactive dependent.
  systemctl restart rp-net rp-xray rp-echo wg-quick@wg0 || rc=1
  if tr_has hy2-wg; then systemctl restart rp-hy2 || rc=1; fi
  if tr_has hy2o-wg; then systemctl restart rp-hy2o || rc=1; fi
  if [[ $(cf TRANSPORT_ORDER) == *hy2* ]]; then systemctl restart wg-quick@wg-exit || rc=1; fi
  if ((rc)); then err "Не все службы перезапущены; проверьте rp diag и rp logs"; return 1; fi
  vps1_check || { err "Службы не прошли проверку после перезапуска"; return 1; }
  if [[ $(cf TRANSPORT_ORDER) == *hy2* ]]; then
    unit_up wg-quick@wg-exit || { err "Внутренний WireGuard не поднялся после перезапуска"; return 1; }
  fi
  ok "Службы перезапущены"
}
cmd_uninstall() {
  need_vps1; yesno "Удалить rp с VPS-1 (клиенты потеряют выход)?" n || return 0
  # по одной: общий «disable --now» со списком обрывается на первой несуществующей службе (rp-hy2o нет в установках 1.0),
  # и остальные, включая rp-xray, продолжают работать
  systemctl stop rp-serve >/dev/null 2>&1   # временный unit без файла: disable для него не сработает
  systemctl stop rp-link-cleanup >/dev/null 2>&1 || true
  if [[ -f $STATE/link.firewall ]]; then
    local link_port; read -r link_port <"$STATE/link.firewall" || return 1
    link_close "${link_port%/tcp}" || return 1
  elif [[ -d $STATE/serve ]]; then
    link_close '' || return 1
  fi
  local u; for u in rp-migration-recover.timer rp-migration-recover.service rp-ru.timer rp-route-sync.timer rp-serve rp-xray rp-hy2 rp-hy2o rp-echo rp-ru.service rp-route-sync.service rp-net wg-quick@wg0 wg-quick@wg-exit; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  nft delete table inet rp_guard 2>/dev/null; nft delete table ip rp_tp 2>/dev/null; nft delete table ip6 rp_block6 2>/dev/null
  while ip rule del fwmark 1 lookup 100 2>/dev/null; do :; done; while ip rule del fwmark 255 lookup 200 2>/dev/null; do :; done
  while ip -4 rule del from 10.77.0.1/32 lookup 200 priority 101 2>/dev/null; do :; done
  fw_close "$(cf WG_PORT)/udp"; fw_close "$(cf HY2_PORT)/udp"; fw_close "$(cf HY2O_PORT)/udp"; fw_close "$(cf RXH_PORT)/tcp"; fw_close "$(cf RXH2_PORT)/tcp"; fw_close "$(cf RTCP_PORT)/tcp"
  # Remove only files generated by rp, preserving unrelated units and drop-ins.
  for u in rp-xray.service rp-hy2.service rp-hy2o.service rp-echo.service rp-ru.service \
    rp-ru.timer rp-route-sync.timer rp-route-sync.service rp-net.service \
    rp-migration-recover.timer rp-migration-recover.service; do
    rm -f "/etc/systemd/system/$u"
  done
  rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg-exit.conf /etc/sysctl.d/99-rp.conf
  rm -f /etc/systemd/system/wg-quick@wg0.service.d/rp.conf
  rmdir /etc/systemd/system/wg-quick@wg0.service.d 2>/dev/null || true
  if [[ -n ${RP_ENTRY_SOURCE:-} ]]; then rp_restore_single || return 1; fi
  rm -rf "$LIB" "$STATE"
  if yesno "Удалить и настройки с секретами ($ETC)?" n; then rm -rf "$ETC" /root/rp-clients /root/rp-block; fi
  systemctl daemon-reload; ok "Удалено. Бинарники xray/hysteria оставлены в /usr/local/bin"
}
