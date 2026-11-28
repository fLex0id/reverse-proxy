#!/usr/bin/env bash
self_version_of() { sed -n 's/^SELF_VERSION="\([^"]*\)"$/\1/p' "$1" | head -1; }
self_ok() {  # verify a complete rp release, never just a plausible version line
  local file=$1 header ver sz
  [[ -f $file && -r $file && -s $file ]] || return 1
  if declare -F rp_distribution_kind >/dev/null && rp_distribution_kind "$file" >/dev/null; then return 0; fi
  sz=$(wc -c <"$file") || return 1
  ((sz >= 32768)) || return 1  # reject truncated HTTP/proxy responses
  [[ $(head -n 1 "$file") == '#!/usr/bin/env bash' ]] || return 1
  header=$(sed -n '2p' "$file")
  case "$header" in '# rp — '*|'# rp - '*) ;; *) return 1 ;; esac
  ver=$(self_version_of "$file")
  [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+[-+a-zA-Z0-9.]*$ ]] || return 1
  [[ $(grep -c '^SELF_VERSION=' "$file") == 1 ]] || return 1
  grep -Fq "py_source() { cat <<'RP_PY_EOF'" "$file" || return 1
  [[ $(tail -n 1 "$file") == 'main "$@"' ]] || return 1
  bash -n "$file" >/dev/null 2>&1
}
self_explain_invalid() { # prints specific reason; called only after failed self_ok
  local file=$1 sz ver
  if [[ ! -s $file ]]; then err "Скачанный файл пуст или отсутствует"; return 1; fi
  sz=$(wc -c <"$file" 2>/dev/null || echo 0)
  if [[ $(sed -n '3p' "$file") == "# rp-distribution: "* ]]; then
    err "Не прошли проверку метаданные или синтаксис пакета rp"; return 1
  fi
  if ((sz < 32768)); then err "Скачано только ${sz} байт (ожидался полный rp.sh): файл обрезан или вместо него пришла HTML-страница"; return 1; fi
  if [[ $(head -n 1 "$file") != '#!/usr/bin/env bash' ]]; then
    err "В ответе сервера нет Bash shebang: возможно, вместо скрипта скачана страница ошибки"; return 1
  fi
  ver=$(self_version_of "$file")
  if [[ -z $ver ]]; then err "В загруженном файле отсутствует SELF_VERSION"; return 1; fi
  if ! bash -n "$file" >/dev/null 2>&1; then
    err "В загруженном скрипте есть синтаксическая ошибка Bash"; bash -n "$file" >&2; return 1
  fi
  err "Файл $ver не прошёл проверку структуры rp (заголовок, встроенный генератор или завершающий main)"
  return 1
}
self_fetch() {  # retrieve and validate; never hide a successful download as a network error
  local dest=$1
  if [[ $RP_URL == *[[:space:]]* ]]; then
    err "RP_URL содержит пробел или перенос строки: $(printf '%q' "$RP_URL")"; return 1
  fi
  if ! fetch "$RP_URL" "$dest"; then
    err "Не удалось скачать $RP_URL (сеть, DNS, TLS или HTTP). Проверьте curl -fLI '$RP_URL'"
    return 1
  fi
  if ! self_ok "$dest"; then
    self_explain_invalid "$dest"
    return 1
  fi
}
self_source() { # self_source DEST: current regular script, otherwise the configured URL
  local dest=$1 current=${RP_ENTRY_SOURCE:-${BASH_SOURCE[0]}}
  if [[ -f $current && -r $current ]] && self_ok "$current"; then
    cp -- "$current" "$dest" || return 1
    self_ok "$dest" || { self_explain_invalid "$dest"; return 1; }
  else
    note "Исходный код запущен через поток; скачиваю опубликованную версию: $RP_URL"
    self_fetch "$dest" || return 1
  fi
}
self_install_file() { # pre-validated file, same filesystem atomic rename + backup
  local from=$1 base stage old_backup="" stamp
  self_ok "$from" || { self_explain_invalid "$from"; return 1; }
  [[ $(self_version_of "$from") == "$SELF_VERSION" ]] || {
    err "Версия файла ($(self_version_of "$from")) не совпадает с запущенной ($SELF_VERSION); сохранение отменено"
    return 1
  }
  if [[ -f $SELF_BIN ]] && cmp -s "$from" "$SELF_BIN"; then
    ok "Команда rp уже соответствует версии $SELF_VERSION"
    return 0
  fi
  mkdir -p "$(dirname "$SELF_BIN")" "$BK_DIR" || return 1
  chmod 700 "$BK_DIR" 2>/dev/null || true
  stage=$(mktemp -d "$(dirname "$SELF_BIN")/.rp-stage.XXXXXXXX") || return 1
  if ! install -m 755 "$from" "$stage/rp" || ! self_ok "$stage/rp"; then
    rm -rf "$stage"; err "Не удалось подготовить исполняемый файл"; return 1
  fi
  if [[ -f $SELF_BIN ]]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    old_backup="$BK_DIR/rp-${stamp}-$$.sh"
    cp -p -- "$SELF_BIN" "$old_backup" || { rm -rf "$stage"; err "Резервная копия не создана"; return 1; }
    chmod 700 "$old_backup" 2>/dev/null || true
  fi
  if ! mv -f -- "$stage/rp" "$SELF_BIN"; then
    rm -rf "$stage"; err "Атомарная замена $SELF_BIN не удалась"; return 1
  fi
  rmdir "$stage" 2>/dev/null || true
  ok "Сохранено: $SELF_BIN ($(self_version_of "$SELF_BIN"))"
  [[ -n $old_backup ]] && note "Предыдущая версия: $old_backup"
  return 0
}
self_install() {
  local tmp rv
  if [[ -n ${RP_ENTRY_SOURCE:-} ]]; then
    if [[ $RP_ROOT == "$LIB/releases/$RP_RELEASE_ID" ]] && cmp -s "$RP_ENTRY_SOURCE" "$SELF_BIN"; then return 0; fi
    rp_publish_modules && self_install_file "$RP_ENTRY_SOURCE"
    return
  fi
  # The already-installed script does not need to download itself.
  [[ -f $SELF_BIN ]] && [[ $(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) == $(readlink -f "$SELF_BIN" 2>/dev/null) ]] &&
    [[ $(self_version_of "$SELF_BIN") == "$SELF_VERSION" ]] && return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/rp-save.XXXXXXXX") || return 1
  if ! self_source "$tmp"; then
    rm -f "$tmp"; err "Невозможно получить исполняемый файл для сохранения"; return 1
  fi
  rv=$(self_version_of "$tmp")
  if [[ $rv != "$SELF_VERSION" ]]; then
    rm -f "$tmp"
    err "На GitHub находится версия $rv, а сейчас запущена $SELF_VERSION."
    err "Обновите rp.sh в репозитории или запустите скачанный файл как обычный файл."
    return 1
  fi
  self_install_file "$tmp"; rv=$?
  rm -f "$tmp"
  return "$rv"
}
# Update self from the configured GitHub URL and migrate only after the new
# executable has passed independent validation. Snapshot all managed migration state.
self_upgrade() {
  local tmp nv old_version
  need_root; need_vps1
  mkdir -p "$STATE" "$BK_DIR" || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/rp-update.XXXXXXXX") || return 1
  if ! self_fetch "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  nv=$(self_version_of "$tmp")
  old_version=$(self_version_of "$SELF_BIN")
  if [[ -f $SELF_BIN ]] && { cmp -s "$tmp" "$SELF_BIN" ||
    { [[ -n ${RP_RELEASE_ID:-} ]] &&
      [[ $(sed -n 's/^RP_RELEASE_ID="\([^"]*\)"$/\1/p' "$tmp") == "$RP_RELEASE_ID" ]] &&
      [[ $(rp_distribution_kind "$SELF_BIN") == dispatcher ]]; }; }; then
    rm -f "$tmp"; ok "Установлена актуальная сборка: $nv"; return 0
  fi
  note "Установлена: ${old_version:-нет}; в репозитории: $nv"
  [[ $nv != "$old_version" && -n $old_version ]] &&
    [[ $(printf '%s\n' "${nv%%-*}" "${old_version%%-*}" | sort -V | tail -1) != "${nv%%-*}" ]] &&
    warn "В репозитории может находиться более старая версия"
  yesno "Сохранить $nv и выполнить миграцию (VPS-2 затем обновляется отдельно)?" y || { rm -f "$tmp"; return 0; }
  # The candidate owns the snapshot schema/helper for this migration. Keep
  # the parent's descriptor locked while its validated migrate command runs.
  if ! grep -q '^migrate_apply() {$' "$tmp" &&
    ! { declare -F rp_distribution_kind >/dev/null && [[ $(rp_distribution_kind "$tmp") == bootstrap ]]; }; then
    rm -f "$tmp"; err "Версия не поддерживает транзакционную миграцию"; return 1
  fi
  if ! bash "$tmp" migrate; then
    rm -f "$tmp"
    err "Обновление не завершено; проверьте состояние отката"
    return 1
  fi
  rm -f "$tmp"
  ok "Команда rp обновлена до $nv"
  note "Проверка: rp test. Для изменения конфигурации VPS-2 отдельно используйте rp push"
  return 0
}

# ── Миграция конфигурации v1.0 → v1.1 ────────────────────────────────────
# reality-tcp заменён на XHTTP (ТСПУ замораживает TCP-поток после ~16 КБ); добавлены hy2 с обфускацией,
# пароль локального SOCKS, DNS-пресеты; адрес VPS-2 заменён отпечатком.
conf_migrate() {
  conf_load; [[ $(cf CONF_VER 1) == 2 ]] && return 0
  local old t new="" ip dr
  old=$(cf TRANSPORT_ORDER "hy2-wg reality-xhttp reality-tcp")
  for t in "${TR_RANK[@]}"; do
    case $t in
      hy2o-wg) [[ " $old " == *" hy2-wg "* || " $old " == *" hy2o-wg "* ]] && new+="${new:+ }$t" ;;
      reality-xhttp2) [[ " $old " == *" reality-xhttp2 "* || " $old " == *" reality-tcp "* ]] && new+="${new:+ }$t" ;;
      *) [[ " $old " == *" $t "* ]] && new+="${new:+ }$t" ;;
    esac
  done
  [[ -n $new ]] || new="${TR_RANK[*]}"
  dr=$(cf DNS_REMOTE); [[ -z $dr || $dr == "https://1.1.1.1/dns-query" ]] && dr="quad9 cloudflare"
  conf_set TRANSPORT_ORDER "$new" DNS_REMOTE "$dr" HY2O_PORT "$(cf HY2O_PORT 8443)" \
    RXH2_PORT "$(cf RXH2_PORT "$(cf RTCP_PORT 8443)")" RXH2_SNI "$(cf RXH2_SNI "$(cf RTCP_SNI "$(cf RXH_SNI www.microsoft.com)")")" \
    XHTTP2_PATH "$(cf XHTTP2_PATH "/$(rand_hex 4)")" DISABLE_IPV6 "$(cf DISABLE_IPV6 1)" SNIFF "$(cf SNIFF 1)" RL_FP "$(cf RL_FP chrome)"
  secrets_extra
  ip=$(cf VPS2_IP)
  if [[ -n $ip ]]; then conf_set VPS2_IPH "$(ip_hash "$ip")"; sed -i '/^VPS2_IP=/d' "$CONF"; conf_load; fi
  conf_set CONF_VER 2
  ok "Конфигурация обновлена до v1.1: транспорты «$new»"
}
conf_exit_mtu_migrate() {
  # The old 1080-byte factory MTU cannot carry QUIC's 1200-byte UDP Initial.
  # Keep operator values; the renderer rejects values incompatible with QUIC.
  if [[ -z $(cf EXIT_MTU) || $(cf EXIT_MTU) == 1080 ]]; then
    conf_set EXIT_MTU 1280
    note "MTU внутреннего WireGuard: 1280 (для QUIC/HTTP3). Выполните rp push для обновления VPS-2"
  fi
}
migration_run() {
  local candidate=$1 helper rc=0
  self_ok "$candidate" || { self_explain_invalid "$candidate"; return 1; }
  mkdir -p "$STATE" || return 1
  helper=$(mktemp "$STATE/migration-helper.XXXXXXXX") || return 1
  migration_source >"$helper" || { rm -f "$helper"; return 1; }
  python3 "$helper" run "$candidate" || rc=$?
  rm -f "$helper"
  return "$rc"
}
cmd_migrate() {
  need_root; need_vps1
  local candidate rc=0
  candidate=$(mktemp "${TMPDIR:-/tmp}/rp-migrate.XXXXXXXX") || return 1
  if ! self_source "$candidate"; then rm -f "$candidate"; return 1; fi
  if [[ $(self_version_of "$candidate") != "$SELF_VERSION" ]]; then
    rm -f "$candidate"; err "Версия для миграции не совпадает с запущенной"; return 1
  fi
  migration_run "$candidate" || rc=$?
  rm -f "$candidate"
  return "$rc"
}
migrate_apply() {
  need_root; need_vps1
  banner "Применение rp $SELF_VERSION" "обновление действующей конфигурации"
  mkdir -p "$STATE" "$BK_DIR" || die "Не удалось подготовить каталог миграции"
  chmod 755 "$STATE" && chmod 700 "$BK_DIR" || die "Не удалось защитить резервные копии"
  cp -p "$CONF" "$BK_DIR/rp.conf.pre-migrate.$(date +%s).$$" || die "Резервная копия конфигурации не создана; миграция остановлена"
  self_install || die "Не удалось сохранить исполняемый rp; миграция остановлена"
  py_install || die "Не удалось установить rp.py"
  conf_migrate
  conf_exit_mtu_migrate
  conf_set TRANSPORT_ORDER "$(tr_sort "$(cf TRANSPORT_ORDER)")"
  # Upgrade existing installations without replacing the user's explicit browser preset.
  [[ $(cf RL_FP random) == random ]] && conf_set RL_FP chrome
  # Migrate the previous factory defaults; preserve other operator settings.
  if [[ $(cf WATCH_MIN 15) == 15 && $(cf WATCH_MAX 35) == 35 ]]; then
    conf_set WATCH_MIN 10 WATCH_MAX 15
  fi
  [[ -n $(cf WATCH_MIN) ]] || conf_set WATCH_MIN 10
  [[ -n $(cf WATCH_MAX) ]] || conf_set WATCH_MAX 15
  units_vps1 || die "Не удалось записать или применить службы и sysctl; миграция остановлена"
  systemctl is-active --quiet rp-net || systemctl start rp-net >/dev/null 2>&1 || die "Не удалось запустить rp-net"
  if [[ $(cf TRANSPORT_ORDER) == *hy2* && ! -x $HY2_BIN ]]; then
    run "Hysteria2" hy2_install "$(cf HY2_VER "$HY2_PINNED")" || die "Не удалось установить бинарный файл транспорта"
  fi
  run "Хэши релизов для VPS-2" pin_release || warn "Хэши для VPS-2 не получены (rp link/rp block повторят попытку)"
  if [[ $(cf RU_DIRECT 0) == 1 ]]; then
    if ! py verify-geo "$ASSETS/geosite.dat" >"$STATE/ru-current-check.log" 2>&1; then
      warn "Установленные списки РФ не прошли полную проверку; восстанавливаю проверенную базу ДО применения конфигурации"
      run "Проверка и восстановление списков РФ" ru_update || die "Не удалось восстановить списки РФ. Миграция остановлена; RU_DIRECT не выключен"
    fi
  fi
  vps1_apply || die "Конфигурация не применилась; требуется откат транзакции"
  vps1_check || die "Миграция не подтверждена: службы не прошли проверку готовности"
  if tr_has reality-xhttp || tr_has reality-xhttp2; then
    systemctl enable --now rp-route-sync.timer >/dev/null 2>&1 || die "Не удалось запустить фоновую синхронизацию маршрута"
    # A previous manual pin on VPS-2 must be discovered after upgrading VPS-1.
    # No fail-open fallback if the control link is transiently unavailable.
    route_sync_locked >/dev/null 2>&1 || warn "Текущий маршрут пока не подтверждён; позже выполните rp tunnel sync"
  fi
  note "Локальная готовность $SELF_VERSION проверена; ожидается подтверждение транзакции"
  note "Дальше: rp test. rp push требуется, если изменились конфигурация или код VPS-2"
}

# ── Обновления Xray и Hysteria2 ──────────────────────────────────────────
# Порядок: ставим на VPS-1 → применяем (проверка конфига новым Xray, откат при сбое) → передаём на VPS-2 с таймером отката.
upg_list() { # upg_list xray|hy2 → «текущая» + последние стабильные
  local cur n; case $1 in xray) cur=$(cf XRAY_VER); n=$(gh_tags XTLS/Xray-core v 6) ;; hy2) cur=$(cf HY2_VER); n=$(gh_tags apernet/hysteria app/v 6) ;; esac
  [[ -n $n ]] || return 1; printf '%s\n' "$n"
}
cmd_upgrade() {
  need_vps1; local what=${1:-check} ver=${2:-} cur list v
  case $what in
    check)
      for v in xray hy2; do
        cur=$(cf "$([[ $v == xray ]] && echo XRAY_VER || echo HY2_VER)")
        list=$(upg_list "$v") || { warn "$v: лента релизов GitHub недоступна"; continue; }
        printf '   %-8s установлена %s%s%s; доступны: %s\n' "$v" "$B" "${cur:-—}" "$R" "$(tr '\n' ' ' <<<"$list")"
      done ;;
    xray|hy2)
      local verkey bin label; if [[ $what == xray ]]; then verkey=XRAY_VER; bin=$XRAY_BIN; label=Xray; else verkey=HY2_VER; bin=$HY2_BIN; label=Hysteria2; fi
      cur=$(cf "$verkey")
      if [[ -z $ver ]]; then
        list=$(upg_list "$what") || die "Не удалось получить список версий (GitHub недоступен). Версию можно указать вручную: rp upgrade $what 1.2.3"
        mapfile -t _v <<<"$list"; note "Установлена: $cur. Новые версии принимаются только после проверки и с откатом."
        pick_from ver "$label: какую версию поставить" "${_v[@]}" || return 1
      fi
      [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Версия вида 1.2.3"
      [[ $ver == "$cur" ]] && { ok "$label $ver уже установлен"; return 0; }
      yesno "Обновить $label $cur → $ver (VPS-1, затем VPS-2 с откатом)?" y || return 0
      cp -p "$bin" "$bin.old" 2>/dev/null; local bk; bk=$(mktemp "$STATE/conf.XXXXXX"); cp -p "$CONF" "$bk"
      if [[ $what == xray ]]; then run "Xray $ver" xray_install "$ver"; else run "Hysteria2 $ver" hy2_install "$ver"; fi || { mv -f "$bin.old" "$bin" 2>/dev/null; cp -p "$bk" "$CONF"; rm -f "$bk"; conf_load; die "Не установилось; прежняя версия на месте"; }
      run "Хэши релизов для VPS-2" pin_release || { warn "Хэши не получены"; upg_revert "$what" "$bin" "$bk"; return 1; }
      if [[ $what == hy2 ]]; then systemctl restart rp-hy2 rp-hy2o 2>/dev/null; fi
      vps1_apply || { upg_revert "$what" "$bin" "$bk"; die "Новая версия не прошла применение на VPS-1; возвращена $cur"; }
      if hy2_live || vps2_run true >/dev/null 2>&1; then
        if push_start 0 && push_wait; then rm -f "$bin.old" "$bk"; ok "$label $ver работает на обоих концах"; prune_offer
        else upg_revert "$what" "$bin" "$bk"; die "На VPS-2 не удалось: VPS-2 откатится сам; на VPS-1 возвращена $cur"; fi
      else rm -f "$bin.old" "$bk"; warn "VPS-2 не на связи: обновление поставлено на VPS-1; на VPS-2 передайте блок (rp link или rp block)"; fi ;;
    ru) ru_update --latest ;;
    self) self_upgrade ;;
    *) die "rp upgrade [check] | xray [версия] | hy2 [версия] | ru | self" ;;
  esac
}
upg_revert() { # upg_revert xray|hy2 бинарник копия-конфига
  local bin=$2 bk=$3
  mv -f "$bin.old" "$bin" 2>/dev/null; cp -p "$bk" "$CONF"; rm -f "$bk"; conf_load
  [[ $1 == hy2 ]] && systemctl restart rp-hy2 rp-hy2o 2>/dev/null
  vps1_apply || true
}
