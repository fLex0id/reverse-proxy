#!/usr/bin/env bash
# ── Обновление VPS-2 по SSH: передача, ожидание, подтверждение ───────────
# push_start [задержка_с] — блок на VPS-2 и запуск в отдельном сеансе (туннель при проверке транспортов
# перезапускается, SSH-сеанс оборвётся); откат на VPS-2 сработает сам через 30 минут без подтверждения
# Одна временная потеря SSH не должна отменять rp push: обратный XHTTP-мост
# может еще регистрироваться, либо сторож меняет активный транспорт.
# Проверяем РЕАЛЬНЫЙ SSH (а не только ss -lnt на 127.0.0.1:2222),
# затем выполняем действие; при отказе пробуем другой доступный путь.
# Не повторяем ошибку аутентификации/host key: это не сетевой сбой.
push_ssh() { # push_ssh "команда на VPS-2" файл-stdin(или /dev/null)
  local command=$1 input=${2:-/dev/null} attempt method msg rc=1 auth=0
  local -a a=() methods=()
  local errfile
  errfile=$(mktemp "$STATE/push-ssh.XXXXXXXX") || return 1
  for ((attempt=1; attempt<=6; attempt++)); do
    if hy2_live; then methods=(hy2 xhttp); else methods=(xhttp hy2); fi
    for method in "${methods[@]}"; do
      # Проверка применимости пути выполняется до передачи файла.
      # mapfile не передаёт код возврата process substitution, поэтому сначала
      # проверяем наличие порта/свежего WG handshake.
      if [[ $method == hy2 ]]; then
        hy2_live || continue
      else
        { tr_has reality-xhttp || tr_has reality-xhttp2; } || continue
        door_port ssh >/dev/null || continue
      fi
      mapfile -t a < <(ssh_args_for "$method")
      ((${#a[@]})) || continue
      if ssh -o BatchMode=yes "${a[@]}" true </dev/null 2>"$errfile"; then
        if ssh -o BatchMode=yes "${a[@]}" "$command" <"$input" 2>"$errfile"; then
          rm -f "$errfile"
          return 0
        else
          rc=$?
        fi
      else
        rc=$?
      fi
      # Код 255 означает ошибку соединения SSH. Ошибки remote-команды не
      # исправятся повторами и могут означать недостаток места/неверный хэш.
      if ((rc != 255)); then
        msg=$(tail -n 3 "$errfile")
        rm -f "$errfile"
        err "Команда на VPS-2 завершилась с ошибкой $rc: ${msg:-без вывода}"
        return "$rc"
      fi
      # Лог не содержит содержимого передаваемого блока с секретами.
      msg=$(tail -n 2 "$errfile" | tr '\n' ' ')
      printf '%s push_ssh attempt=%s path=%s status=%s error=%s\n' "$(date -Is)" "$attempt" "$method" "$rc" "$msg" >>"$LOG"
      if grep -Eqi 'Permission denied|Host key verification failed|REMOTE HOST IDENTIFICATION HAS CHANGED|Too many authentication failures|Bad owner or permissions' "$errfile"; then
        auth=1; break
      fi
    done
    ((auth)) && break
    ((attempt < 6)) && { warn "SSH к VPS-2 пока недоступен (попытка $attempt/6); повторяю"; sleep 3; }
  done
  msg=$(tail -n 3 "$errfile")
  rm -f "$errfile"
  err "SSH к VPS-2 не установился после проверок: ${msg:-нет доступного обратного пути}"
  if ((auth)); then
    warn "Проверьте SSH-ключ и host key; автоматический повтор при ошибке аутентификации отключён"
  else
    warn "Возможна задержка регистрации XHTTP Reverse или переключение транспорта. Диагностика: rp status; rp ssh; rp logs"
  fi
  return 1
}

push_start() {
  local delay=${1:-0} out blk digest upload_cmd start_cmd id
  out=$(block_make /root/rp-block single | tail -n1); blk="$out/block.sh"
  [[ -f $blk ]] || { err "Блок состоит из нескольких частей; для push задайте BLOCK_MAX побольше (rp.conf) или вставьте части вручную"; return 1; }
  digest=$(sha256sum "$blk" | awk '{print $1}') || return 1
  [[ $digest =~ ^[0-9a-f]{64}$ ]] || return 1
  # Сначала передаём во временный файл, проверяем SHA256 и лишь затем публикуем.
  # При сетевом сбросе повторная передача безопасна и не оставляет частичный блок.
  upload_cmd=$(cat <<EOF
umask 077
install -d -m 700 /var/lib/rp || exit 1
tmp=\$(mktemp /root/.rp-push.XXXXXXXX) || exit 1
trap 'rm -f "\$tmp"' EXIT
cat >"\$tmp" || exit 1
printf '%s  %s\n' '$digest' "\$tmp" | sha256sum -c - --status || exit 1
mv -f -- "\$tmp" /root/.rp-push.sh
EOF
)
  if ! push_ssh "$upload_cmd" "$blk"; then
    rm -rf "${out:?}"
    err "Не удалось передать проверенный блок на VPS-2"
    return 1
  fi
  # Идентификатор операции нужен, чтобы повтор SSH после сброса не запустил
  # установку дважды. Файл push.runid и запуск защищены отдельным flock на VPS-2.
  id=$(uuid)   # каждое сознательное rp push — новая транзакция; повторы SSH используют тот же id
  start_cmd=$(cat <<EOF
install -d -m 700 /var/lib/rp || exit 1
flock -x /var/lib/rp/push-launch.lock bash -c '
  if [ "\$(cat /var/lib/rp/push.runid 2>/dev/null)" = "$id" ]; then exit 0; fi
  rm -f /var/lib/rp/push.rc
  setsid -f bash -c "sleep $delay; RP_SAFE=1 bash /root/.rp-push.sh" >/var/lib/rp/push.log 2>&1 </dev/null || exit 1
  printf "%s\n" "$id" >/var/lib/rp/push.runid
'
EOF
)
  if ! push_ssh "$start_cmd" /dev/null; then
    rm -rf "${out:?}"
    err "Не удалось подтвердить запуск обновления на VPS-2"
    return 1
  fi
  rm -rf "${out:?}"
  ok "Обновление запущено на VPS-2 (откат через 30 минут, если не подтвердить)"
}

# Require exactly one successful result per configured transport. Empty, partial,
# duplicated and unrecognised results are UNKNOWN/FAILED, never FULL_OK.
push_results_ok() {
  local results=$1 t line name value
  local -A expected=() seen=()
  for t in $(cf TRANSPORT_ORDER); do
    case $t in reality-xhttp2|reality-xhttp|hy2-wg|hy2o-wg) expected[$t]=1 ;; *) return 1 ;; esac
  done
  ((${#expected[@]} > 0)) || return 1
  while IFS= read -r line; do
    [[ $line == *=* ]] || return 1
    name=${line%%=*}; value=${line#*=}
    [[ -n $name && $value == ok ]] || return 1
    [[ -n ${expected[$name]:-} && -z ${seen[$name]:-} ]] || return 1
    seen[$name]=1
  done <<<"$results"
  ((${#seen[@]} == ${#expected[@]}))
}

# push_wait — до 27 минут: все четыре транспорта и полные T1/T2/T3,
# оставляя запас до 30-минутного отката для подтверждения.
push_wait() {
  local t=0 rc=""
  note "Жду полной проверки T1–T3 ВСЕХ транспортов на VPS-2 (до 27 минут)…"
  sleep 20; t=20
  while ((t < 1620)); do
    rc=$(vps2_run 'cat /var/lib/rp/push.rc 2>/dev/null' 2>/dev/null) && [[ -n $rc ]] && break
    rc=""; sleep 6; t=$((t + 6))
  done
  [[ -n $rc ]] || { err "VPS-2 не вернулся на связь за 27 минут (автоматический откат через 30 минут)"; return 1; }
  [[ $rc =~ ^[0-9]{1,3}$ ]] || { err "Недостоверный код установки: обновление НЕ подтверждено"; return 1; }
  if ((10#$rc != 0)); then
    err "Установка на VPS-2 завершилась с ошибкой (код $rc)"
    local tail_log
    tail_log=$(RP_READ_RETRIES=1 vps2_read 'tail -n 32 /var/lib/rp/push.log' 2>/dev/null || true)
    if [[ -n $tail_log ]]; then
      printf '%s\n' "$tail_log" | sed 's/^/    [VPS-2] /' >&2
    else
      warn "Управляющий SSH не отвечает. Откройте VPS-2 через консоль хостера и выполните: tail -n 80 /var/lib/rp/push.log"
    fi
    warn "Повторный rp push пока не выполняйте: сначала выясните причину ошибки"
    return 1
  fi
  local res_now
  res_now=$(tr_results 2>/dev/null) && push_results_ok "$res_now" || {
    err "FAILED/UNKNOWN: нет полного успешного результата T1–T3 всех транспортов; обновление НЕ подтверждено"
    return 1
  }
  route_sync_locked >/dev/null 2>&1 || {
    err "Маршрут Xray VPS-1 не согласован: обновление НЕ подтверждено"; return 1
  }
  wait_exit || { err "Выход через VPS-2 не работает после обновления (откат на VPS-2 сработает сам)"; return 1; }
  touch "$STATE/linked"
  local cf_try cf_ok=0
  for ((cf_try=1; cf_try<=3; cf_try++)); do
    vps2_run '/usr/local/bin/rp confirm' >/dev/null 2>&1 && { cf_ok=1; break; }
    sleep 3
  done
  ((cf_ok)) || { err "VPS-2 не подтвердил обновление: выполните там  rp confirm  до истечения 30 минут, иначе сработает откат"; return 1; }
  ok "Итог: FULL_OK — все транспорты прошли T1–T3"
  ok "VPS-2 обновлён и подтверждён"
  route_sync_locked >/dev/null 2>&1 || warn "Маршрут VPS-1 пока не подтверждён; выполните rp tunnel sync"
}
cmd_push() {
  need_vps1; push_start 0 && push_wait || return 1
  prune_offer
}
# rotate — новые UUID, пароли, shortId и ключи Reality; VPS-1 применяет значения, пока VPS-2 ставит блок
cmd_rotate() {
  need_vps1; yesno "Сменить UUID, пароли, shortId и ключи Reality? Туннель переподключится" y || return 0
  hy2_live || vps2_run true >/dev/null 2>&1 || die "Нет связи с VPS-2: сначала поднимите туннель"
  local bk a b; bk=$(mktemp "$STATE/conf.XXXXXX"); cp -p "$CONF" "$bk"
  read -r a b < <(x25519_pair) || { rm -f "$bk"; die "Ключи x25519 не созданы"; }
  conf_set HY2_PASS "$(rand_pass)" HY2O_OBFS "$(rand_pass)" RL_SID "$(rand_hex 8)" RL_PRIV "$a" RL_PUB "$b" \
    RL_UUID_X "$(uuid)" RL_UUID_T "$(uuid)" RL_UUID_PX "$(uuid)" RL_UUID_PT "$(uuid)"
  push_start 25 || { cp -p "$bk" "$CONF"; rm -f "$bk"; conf_load; die "Не удалось передать обновление"; }
  rm -f "$STATE/linked"
  vps1_apply || { cp -p "$bk" "$CONF"; conf_load; vps1_apply || true; rm -f "$bk"; die "Не применилось; VPS-2 откатится сам через 30 минут"; }
  if push_wait; then rm -f "$bk"; ok "Секреты сменены, туннель работает"
  else cp -p "$bk" "$CONF"; conf_load; vps1_apply || true; rm -f "$bk"; die "VPS-2 не переподключился: на VPS-1 возвращены прежние значения, VPS-2 откатится сам"; fi
}
