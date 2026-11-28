#!/usr/bin/env bash
# ── Блок для VPS-2 ───────────────────────────────────────────────────────
block_make() { # block_make [каталог] [single] → печатает пути файлов; single — одним файлом, без деления на части
 (
  need_vps1; local out=${1:-/root/rp-block} extra='' bund='' max raw gz='' n i sha made=0
  # Keep cleanup traps in a subshell: callers also use traps for transactions.
  trap 'rc=$?; [[ -z $extra ]] || rm -rf -- "$extra"; [[ -z $bund ]] || rm -rf -- "$bund"; [[ -z $gz ]] || rm -f -- "$gz"; if [[ $rc != 0 && $made == 1 ]]; then rm -rf -- "$out"; fi; exit "$rc"' EXIT
  umask 077
  [[ -n $(cf XRAY_SHA_64) && -n $(cf HY2_SHA_AMD64) ]] || pin_release || die "Нет хэшей релизов (GitHub недоступен?)"
  rm -rf "${out:?}" && mkdir -p "$out" || return 1
  made=1
  chmod 700 "$out" || return 1
  extra=$(mktemp -d "$STATE/ex.XXXXXX") || return 1
  bund=$(mktemp -d "$STATE/bd.XXXXXX") || return 1
  vps2_files "$extra" && py bundle "$bund" "$extra" >/dev/null || return 1
  vps2_installer "$bund/bundle.tgz" >"$out/block.sh" || return 1
  max=$(cf BLOCK_MAX 60000); [[ ${2:-} == single ]] && max=999999999
  [[ $max =~ ^[1-9][0-9]{3,8}$ ]] && ((max > 1200)) || { err "BLOCK_MAX должен быть 1201..999999999"; return 1; }
  raw=$(stat -c %s "$out/block.sh") || return 1
  ((raw > 0)) || { err "Создан пустой установочный блок"; return 1; }
  if ((raw <= max)); then
    ok "Блок: $out/block.sh ($raw байт, SHA256 внутри)"
  else
    gz=$(mktemp "$STATE/gz.XXXXXX") || return 1
    gzip -9 -c "$out/block.sh" | base64 -w0 >"$gz" || return 1
    sha=$(sha256sum "$gz" | awk '{print $1}') || return 1
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || return 1
    rm -f "$out/block.sh" || return 1
    n=$(py chunk "$gz" $((max - 1200)) "$out") || return 1
    [[ $n =~ ^[1-9][0-9]*$ ]] || return 1
    for ((i = 1; i <= n; i++)); do
      local f; f=$(printf '%s/part%02d' "$out" "$i")
      {
        printf 'set +o history 2>/dev/null\n(\nset -o pipefail; umask 077\nmkdir -p /root/.rp && chmod 700 /root/.rp || exit 1\n' || return 1
        if ((i == 1)); then printf 'rm -f /root/.rp/blk.b64 || exit 1\n' || return 1; fi
        printf "cat >>/root/.rp/blk.b64 <<'RP_PART_END' || exit 1\n" && cat "$f" && printf 'RP_PART_END\n' || return 1
        printf 'echo "rp: часть %d из %d принята"\n' "$i" "$n" || return 1
        if ((i == n)); then
          printf '[ "$(tr -d "\\n" </root/.rp/blk.b64 | sha256sum | cut -d" " -f1)" = "%s" ] || { echo "rp: SHA256 частей не совпала — вставьте все части заново по порядку"; rm -f /root/.rp/blk.b64; exit 1; }\n' "$sha" || return 1
          printf 'base64 -d /root/.rp/blk.b64 | gunzip | bash\nrp_rc=$?\nrm -rf /root/.rp || { ((rp_rc != 0)) || rp_rc=1; }\nexit "$rp_rc"\n' || return 1
        fi
        printf ')\n' || return 1
      } >"$f.sh" || return 1
      rm -f "$f" || return 1
    done
    ok "Блок велик для одной вставки: $n частей в $out (part01.sh … part$(printf '%02d' "$n").sh), вставлять по порядку"
  fi
  note "Содержит секреты: не пересылайте по открытым каналам, удалите после установки (rm -rf $out)"
  printf '%s\n' "$out"
 )
}
cmd_block() {
  local out; out=$(block_make "${1:-}" | tail -n1) || return 1
  note "Вставка на VPS-2: откройте веб-консоль, выполните  cat > b.sh  (вставить, Ctrl-D)  и  bash b.sh"
  note "или сразу вставьте содержимое $out/*.sh в консоль"
  ls -1 "$out"
}

# ── Строка для VPS-2: VPS-2 сам скачивает блок ───────────────────────────
# VPS-1 на время поднимает одноразовый HTTPS-сервер (rp.py serve, пользователь rp). Строка для консоли VPS-2:
#   curl -fsSk --pinnedpubkey sha256//ПИН https://IP:ПОРТ/ТОКЕН|bash
# Самоподписанный сертификат создаётся на сессию; --pinnedpubkey проверяет ключ сервера (без него VPS-1 нельзя
# отличить от подмены, а блок содержит секреты). Токен — одноразовый (12 знаков, ~60 бит), TTL 30 минут.
# Обрыв загрузки безопасен: блок состоит из функций, rp_main вызывается последней строкой.
fw_open_rt() { # only the runtime rule created by this link may be removed
  [[ $(fw_kind) == firewalld ]] || return 0
  local rc=0
  firewall-cmd --query-port="$1" >/dev/null 2>&1 && return 0 || rc=$?
  ((rc == 1)) || return 1
  # Root-owned metadata stays outside the directory writable by the rp user.
  (umask 077; printf '%s\n' "$1" >"$STATE/link.firewall") || return 1
  firewall-cmd --add-port="$1" >/dev/null 2>&1
}
link_close() { # rp _link_close ПОРТ — после остановки сервера: результат, закрыть порт, удалить файлы с секретами
  local port=${1:-} d=$STATE/serve res=unknown owned='' rc=0 tmp
  if [[ -s $d/result ]]; then read -r res <"$d/result" || rc=1; fi
  if [[ -f $STATE/link.firewall ]]; then
    read -r owned <"$STATE/link.firewall" || rc=1
    if [[ $port =~ ^[0-9]+$ && $owned == "$port/tcp" ]] &&
       firewall-cmd --remove-port="$owned" >/dev/null 2>&1; then
      rm -f -- "$STATE/link.firewall" || rc=1
    else
      err "Не удалось удалить временное правило порта; повторите rp _link_close $port"
      rc=1
    fi
  fi
  rm -rf "${d:?}" || rc=1
  ((rc == 0)) || res=cleanup-failed
  tmp=$(mktemp "$STATE/.link-result.XXXXXX") || return 1
  if ! printf '%s\n' "$res" >"$tmp" || ! mv -f -- "$tmp" "$STATE/link.result"; then
    rm -f -- "$tmp"; return 1
  fi
  return "$rc"
}
cmd_link() { # rp link [порт]
  need_vps1; conf_load
  local port=${1:-$(cf LINK_PORT 8444)} ttl=${LINK_TTL:-1800} dir=$STATE/serve ip p token pin str res i
  valid_port "$port" || die "Недопустимый порт «$port»"
  [[ $ttl =~ ^[1-9][0-9]{0,5}$ ]] || die "LINK_TTL должен быть положительным числом секунд (до 999999)"
  ip=$(cf PUBLIC_IP); [[ -n $ip ]] || die "Не задан PUBLIC_IP"
  for p in WG_PORT HY2_PORT HY2O_PORT RXH_PORT RXH2_PORT; do [[ $(cf $p) == "$port" ]] && die "Порт $port занят туннелем ($p): rp link ДРУГОЙ_ПОРТ"; done
  systemctl stop rp-serve >/dev/null 2>&1; systemctl reset-failed rp-serve >/dev/null 2>&1
  if [[ -f $STATE/link.firewall ]]; then
    local previous_port; read -r previous_port <"$STATE/link.firewall" || return 1
    link_close "${previous_port%/tcp}" || die "Не завершена очистка предыдущей ссылки"
  fi
  ss -ltnH "sport = :$port" 2>/dev/null | grep -q . && die "TCP-порт $port уже занят: rp link ДРУГОЙ_ПОРТ"
  rm -rf "${dir:?}" "$STATE/link.result" && mkdir -p "$dir" && chmod 700 "$dir" || die "Не удалось подготовить закрытый каталог ссылки"
  run "Блок для VPS-2" block_make "$dir/blk" single || { rm -rf "${dir:?}"; die "Блок не собран"; }
  [[ -s $dir/blk/block.sh ]] || { rm -rf "${dir:?}"; die "Блок не создан"; }
  mv "$dir/blk/block.sh" "$dir/block.sh" && rm -rf "$dir/blk" || { rm -rf "${dir:?}"; die "Не удалось сохранить блок ссылки"; }
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=$ip" \
    -keyout "$dir/key.pem" -out "$dir/crt.pem" >/dev/null 2>&1 || { rm -rf "${dir:?}"; die "openssl: сертификат не создан"; }
  pin=$(openssl x509 -in "$dir/crt.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64 -w0)
  token=$(LC_ALL=C tr -dc 'a-km-np-z2-9' </dev/urandom | head -c 12)   # без похожих знаков (l, o, 0, 1)
  [[ ${#token} == 12 && ${#pin} == 44 ]] || { rm -rf "${dir:?}"; die "Не удалось создать токен или отпечаток"; }
  chown -R rp:rp "$dir" && chmod 700 "$dir" && chmod 600 "$dir"/*.pem "$dir/block.sh" || { rm -rf "${dir:?}"; die "Не удалось защитить файлы ссылки"; }
  fw_open_rt "$port/tcp" || { link_close "$port"; die "Не удалось открыть временный порт ссылки"; }
  # ReadWritePaths makes dir a bind mount inside rp-serve's namespace. Cleanup
  # must run in a separate root unit, where removing that directory is legal.
  systemd-run --quiet --collect --unit=rp-serve --description="rp: одноразовая отдача блока VPS-2" \
    -p User=rp -p Group=rp -p RuntimeMaxSec=$((ttl + 60)) -p NoNewPrivileges=true -p ProtectSystem=strict -p ProtectHome=true \
    -p PrivateTmp=true -p "ReadWritePaths=$dir" \
    -p "ExecStopPost=+/usr/bin/systemd-run --quiet --no-block --collect --unit=rp-link-cleanup $SELF_BIN _link_close $port" \
    /usr/bin/python3 -I "$RP_PY" serve "$port" "$token" "$dir/block.sh" "$dir/crt.pem" "$dir/key.pem" "$ttl" \
    || { link_close "$port"; die "Не удалось запустить сервер (systemd-run)"; }
  sleep 1; systemctl is-active --quiet rp-serve || { err "Сервер не запустился:"; journalctl -u rp-serve -n 8 --no-pager 2>/dev/null | sed 's/^/    /' >&2; link_close "$port"; return 1; }
  str="curl -fsSk --pinnedpubkey sha256//$pin https://$ip:$port/$token|bash"
  printf '\n'; card "Введите на VPS-2 (консоль хостера, root)"; card_line ""; card_line "$str"; card_line ""; card_end
  note "Длина строки: ${#str} символов. Действует $((ttl / 60)) мин и только для одной загрузки; временное правило $port/tcp будет удалено. Прежние правила firewall сохраняются."
  note "Если VPS-2 не достаёт порт: rp link ДРУГОЙ_ПОРТ, либо запасной путь — rp block (вставка вручную)."
  trap 'printf "\n"; systemctl stop rp-serve >/dev/null 2>&1; link_close "$port" || warn "Очистка ссылки не завершена"; warn "Создание ссылки прервано"; exit 130' INT TERM
  printf '  Жду загрузку блока (Ctrl-C — отмена) '
  for ((i = 0; i < ttl + 90; i++)); do
    systemctl is-active --quiet rp-serve || break
    ((i % 5 == 0)) && printf '.'; sleep 1
  done
  printf '\n'; trap - INT TERM
  for ((i = 0; i < 15; i++)); do [[ ! -d $dir && -s $STATE/link.result ]] && break; sleep 1; done
  res=$(cat "$STATE/link.result" 2>/dev/null)
  case $res in
    ok) ok "VPS-2 скачал блок; сервер остановлен, файлы ссылки и временное правило удалены" ;;
    timeout) warn "Время вышло: блок не скачан, файлы ссылки и временное правило удалены. Повторите: rp link"; return 1 ;;
    cleanup-failed) err "Не завершена очистка ссылки; проверьте rp _link_close $port"; return 1 ;;
    *) warn "Сервер остановлен без результата. Повторите: rp link"; return 1 ;;
  esac
  note "VPS-2 устанавливает пакеты и полностью проверяет T1–T3 для каждого транспорта; жду подключения до 30 минут…"
  for ((i = 0; i < 900; i++)); do
    if hy2_live || vps2_run true >/dev/null 2>&1; then
      touch "$STATE/linked"; ok "VPS-2 подключился"
      note "Проверка выхода: rp test    (если часть транспортов не прошла — rp prune)"
      return 0
    fi
    sleep 2
  done
  warn "VPS-2 пока не подключился. На VPS-2 смотрите: rp status / rp logs; здесь: rp status, rp test"
  return 1
}
