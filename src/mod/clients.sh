#!/usr/bin/env bash
# ── Клиенты WG ───────────────────────────────────────────────────────────
client_names() { awk -F'\t' '!/^#/ && NF>=5 {print $1}' "$CLIENTS" 2>/dev/null; }
cl_restore() { # private, same-filesystem backup; never discard it on restore failure
  local backup=$1
  if ! mv -f -- "$backup" "$CLIENTS"; then
    err "Не удалось восстановить список клиентов; резервная копия сохранена: $backup"
    return 1
  fi
  if ! vps1_apply clients-only; then
    err "Файл клиентов восстановлен, но wg0 не восстановлен — проверьте wg show wg0"
    return 1
  fi
  note "Прежний список клиентов применён"
}
cl_show() { # cl_show имя — конфиг и QR
  local n=${1:-}; mapfile -t _l < <(client_names)
  [[ -n $n ]] || pick_from n "Клиент" "${_l[@]}" || { warn "Клиентов нет"; return 1; }
  [[ $n =~ ^[A-Za-z0-9_-]{1,24}$ ]] || { err "Недопустимое имя клиента"; return 1; }
  local conf tmp; conf=$(py client "$n") || return 1
  install -d -m 700 /root/rp-clients || { err "Не удалось создать каталог конфигураций клиентов"; return 1; }
  tmp=$(mktemp /root/rp-clients/.client.XXXXXX) || return 1
  if ! printf '%s\n' "$conf" >"$tmp" || ! chmod 600 "$tmp" ||
     ! mv -f -- "$tmp" "/root/rp-clients/$n.conf"; then
    rm -f -- "$tmp"
    err "Не удалось сохранить конфигурацию клиента $n"
    return 1
  fi
  printf '\n%s\n' "$conf"
  printf '\n'; py qr "/root/rp-clients/$n.conf" || note "QR не построен (конфиг длиннее 458 байт?) — используйте файл"; printf '\n'
  note "Файл: /root/rp-clients/$n.conf"
}
cl_add() {
  need_vps1
  local n=${1:-} ip a b psk backup stage dir
  ask n "Имя клиента" "" '^[A-Za-z0-9_-]{1,24}$' "Латиница, цифры, _ и -, до 24 знаков"
  client_names | grep -Fxq "$n" && { err "Клиент «$n» уже есть"; return 1; }
  [[ -f $CLIENTS ]] || { err "Отсутствует файл клиентов $CLIENTS"; return 1; }
  ip=$(py next-ip) || return 1
  read -r a b < <(wg_pair) || return 1
  [[ -n $a && -n $b ]] || { err "Не удалось получить ключи WireGuard"; return 1; }
  psk=$(wg genpsk) || return 1
  dir=$(dirname -- "$CLIENTS")
  backup=$(mktemp "$dir/.clients.rollback.XXXXXX") || return 1
  if ! cp -- "$CLIENTS" "$backup" || ! chmod 600 "$backup"; then rm -f -- "$backup"; return 1; fi
  stage=$(mktemp "$dir/.clients.new.XXXXXX") || { rm -f -- "$backup"; return 1; }
  if ! cat -- "$backup" >"$stage" ||
     ! printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$a" "$b" "$psk" "$ip" >>"$stage" ||
     ! chmod 600 "$stage" || ! mv -f -- "$stage" "$CLIENTS"; then
    rm -f -- "$stage" "$backup"
    err "Не удалось записать новый список клиентов; прежний файл сохранён"
    return 1
  fi
  # Проверка конфигурации до установки и после применения.
  if ! py client "$n" >/dev/null || ! vps1_apply clients-only ||
     ! wg show wg0 peers 2>/dev/null | grep -Fxq "$b"; then
    err "Клиент не был успешно добавлен в работающий wg0; возвращаю прежний список"
    cl_restore "$backup" || return 1
    return 1
  fi
  rm -f "$backup"
  ok "Клиент «$n» добавлен ($ip); peer подтверждён в wg0"
  cl_show "$n"
}

cl_del() {
  need_vps1; local n=${1:-} pub peers backup stage dir; mapfile -t _l < <(client_names)
  [[ -n $n ]] || pick_from n "Удалить клиента" "${_l[@]}" || { warn "Клиентов нет"; return 1; }
  client_names | grep -Fxq "$n" || die "Клиента «$n» нет"
  pub=$(awk -F '\t' -v n="$n" '$1==n {print $3; exit}' "$CLIENTS")
  [[ -n $pub ]] || { err "Публичный ключ клиента $n не найден"; return 1; }
  dir=$(dirname -- "$CLIENTS")
  backup=$(mktemp "$dir/.clients.rollback.XXXXXX") || return 1
  if ! cp -- "$CLIENTS" "$backup" || ! chmod 600 "$backup"; then rm -f -- "$backup"; return 1; fi
  stage=$(mktemp "$dir/.clients.new.XXXXXX") || { rm -f -- "$backup"; return 1; }
  if ! awk -F '\t' -v n="$n" '$1!=n' "$backup" >"$stage" ||
     ! chmod 600 "$stage" || ! mv -f -- "$stage" "$CLIENTS"; then
    rm -f -- "$stage" "$backup"
    err "Не удалось записать новый список клиентов; прежний файл сохранён"
    return 1
  fi
  if ! vps1_apply clients-only; then
    err "Не удалось применить удаление; возвращаю прежний список"
    cl_restore "$backup" || return 1
    return 1
  fi
  if ! peers=$(wg show wg0 peers 2>/dev/null) || printf '%s\n' "$peers" | grep -Fxq "$pub"; then
    err "Peer не удалён из работающего wg0; откатываю изменение"
    cl_restore "$backup" || return 1
    return 1
  fi
  rm -f -- "$backup" "/root/rp-clients/$n.conf" || { err "Peer удалён, но не удалось удалить сохранённую конфигурацию клиента"; return 1; }
  ok "Клиент «$n» удалён (wg0 проверен)"
}
cl_list() {
  need_vps1; local n=0 name ip
  while IFS=$'\t' read -r name _ _ _ ip; do [[ -n $name && $name != \#* ]] || continue; printf '   %-24s %s\n' "$name" "$ip"; n=$((n + 1)); done <"$CLIENTS"
  ((n)) || note "Клиентов нет: rp client add"
}
