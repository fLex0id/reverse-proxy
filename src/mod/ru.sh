#!/usr/bin/env bash
# ОТСТУПЛЕНИЕ от tt.sh (.srs для sing-box): Xray читает только .dat.
ru_resolve_ref() { # возвращает неизменяемый тег, никогда скользящую ветку release
  local ref api tmp
  ref=$(cf RU_REF latest)
  if [[ $ref == latest ]]; then
    ref=""
    tmp=$(mktemp "$STATE/ru-ref.XXXXXXXX") || return 1
    api="https://api.github.com/repos/$RU_REPO/releases/latest"
    # 1) GitHub API (лимит 60 запросов/час на IP: на общих VPS нередко 403)
    if curl -fLsS --connect-timeout 8 --max-time 25 --retry 2 --retry-delay 2 \
        -H 'Accept: application/vnd.github+json' -o "$tmp" "$api" 2>/dev/null; then
      ref=$(python3 - "$tmp" <<'PY_REF'
@PY:ru_resolve_ref@
PY_REF
) || ref=""
    fi
    rm -f "$tmp"
    # 2) редирект github.com/…/releases/latest — без лимитов API
    if [[ ! $ref =~ ^20[0-9]{10}$ ]]; then
      ref=$(latest_tag "$RU_REPO" | tr -d '[:space:]')
      [[ $ref =~ ^20[0-9]{10}$ ]] || ref=""
    fi
    # 3) последний успешно установленный тег (повторная загрузка того же релиза)
    if [[ ! $ref =~ ^20[0-9]{10}$ ]]; then
      ref=$(cf RU_TAG)
      if [[ $ref =~ ^20[0-9]{10}$ ]]; then warn "Не удалось узнать новый тег; использую ранее установленный $ref"; else ref=""; fi
    fi
    [[ -n $ref ]] || { err "Не удалось определить стабильный тег geosite (GitHub API и redirect недоступны). Рабочие базы сохранены; повторите позже или задайте RU_REF=ГГГГММДДччмм в $CONF"; return 1; }
  fi
  [[ $ref =~ ^20[0-9]{10}$ ]] || { err "RU_REF должен быть 'latest' либо точным тегом YYYYMMDDHHMM"; return 1; }
  printf '%s\n' "$ref"
}
ru_fetch_one() { # данные и SHA одного конкретного релиза, не из скользящей ветки
  local n=$1 dir=$2 ref=$3 base want got mirror attempt rc=1 pre
  base="https://github.com/$RU_REPO/releases/download/$ref"
  mirror=$(cf GH_MIRROR)
  rm -f "$dir/$n" "$dir/$n.sha256sum"
  # Файл крупный, а канал РФ→GitHub нередко медленный: вместо жёсткого общего лимита —
  # лимит на «зависание» (менее 20 КБ/с в течение 40 с) и докачка (-C -) между попытками.
  local -a pres=("")
  [[ -n $mirror ]] && pres+=("${mirror%/}/")
  for pre in "${pres[@]}"; do
    for attempt in 1 2 3 4; do
      curl -fLsS --connect-timeout 12 --max-time 1500 --speed-limit 20000 --speed-time 40 -C - \
        -o "$dir/$n" "$pre$base/$n" 2>"$dir/.curl.err"; rc=$?
      # 33 = сервер не поддержал докачку: начать заново
      if ((rc == 33 || rc == 36)); then rm -f "$dir/$n"; fi
      ((rc == 0)) && [[ -s $dir/$n ]] && break
      sleep $((attempt * 3))
    done
    if ((rc == 0)); then
      curl -fLsS --connect-timeout 12 --max-time 60 --retry 3 --retry-delay 2 \
        -o "$dir/$n.sha256sum" "$pre$base/$n.sha256sum" 2>"$dir/.curl.err"; rc=$?
    fi
    ((rc == 0)) && break
    [[ -z $pre && -n $mirror ]] && warn "GitHub не отдал $n, пробую зеркало"
    rm -f "$dir/$n" "$dir/$n.sha256sum"
  done
  if ((rc != 0)); then
    err "Не удалось скачать $n и SHA256 из зафиксированного релиза $ref (curl код $rc: $(head -c 200 "$dir/.curl.err" 2>/dev/null | tr '\n' ' '))"
    return 1
  fi
  want=$(awk 'NF {print tolower($1); exit}' "$dir/$n.sha256sum")
  got=$(sha256sum "$dir/$n" | awk '{print $1}')
  [[ $want =~ ^[0-9a-f]{64}$ && $want == "$got" ]] || {
    err "SHA256 $n не совпал (релиз $ref). Ничего не заменено"; return 1;
  }
  local bytes
  bytes=$(stat -c %s "$dir/$n") || return 1
  if ((bytes < 1048576 || bytes > 367001600)); then
    err "Размер $n подозрителен ($bytes байт); установка отменена"; return 1
  fi
  return 0
}
# Восстановить штатную geoip.dat из того же проверенного релиза Xray.
# RunetFreedom geoip.dat содержит собственные наборы блокировок, но не заменяет
# базовую Xray geoip.dat с country-категориями (в частности geoip:ru).
xray_restore_geoip() {
  local dest=$1 ver arch name url tmp want got
  ver=$(cf XRAY_VER "$XRAY_PINNED"); arch=$(arch_map xray); name="Xray-linux-$arch.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/v$ver/$name"
  tmp=$(mktemp -d "$STATE/xgeoip.XXXXXX") || return 1
  if ! curl -fLsS --connect-timeout 10 --max-time 120 --retry 1 --retry-delay 2 -o "$tmp/x.zip" "$url" 2>/dev/null ||
     ! curl -fLsS --connect-timeout 10 --max-time 30 --retry 1 --retry-delay 1 -o "$tmp/x.dgst" "$url.dgst" 2>/dev/null; then
    err "Не удалось скачать штатную geoip.dat из релиза Xray $ver"
    rm -rf "${tmp:?}"; return 1
  fi
  want=$(awk -F'= ' 'toupper($1) ~ /^SHA2?-?256/ {print tolower($2)}' "$tmp/x.dgst" | head -1)
  got=$(sha256sum "$tmp/x.zip" | awk '{print $1}')
  if [[ -z $want || $want != "$got" ]] || ! unzip -p "$tmp/x.zip" geoip.dat >"$dest/geoip.dat" || [[ ! -s $dest/geoip.dat ]]; then
    err "Не удалось проверить или извлечь штатную geoip.dat Xray"
    rm -rf "${tmp:?}"; return 1
  fi
  rm -rf "${tmp:?}"
  return 0
}
ru_update() { # обновление: geosite РФ + штатная geoip Xray; тест до замены, откат при ошибке
  conf_load
  local tmp n old new changed=0 active=0 rc=0 restore_geoip=0 ref=""
  tmp=$(mktemp -d "$STATE/ru.XXXXXX") || return 1
  mkdir -p "$tmp/assets" "$tmp/config" "$tmp/backup"

  # Прокси включаем только если уже существует рабочий выход через локальный SOCKS.
  if [[ -f $STATE/linked ]] && sx -m 8 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
    export ALL_PROXY; ALL_PROXY=$(sx_proxy)
  fi
  ref=$(ru_resolve_ref) || { unset ALL_PROXY; rm -rf "${tmp:?}"; return 1; }
  if ! ru_fetch_one geosite.dat "$tmp/assets" "$ref"; then unset ALL_PROXY; rm -rf "${tmp:?}"; return 1; fi
  unset ALL_PROXY
  # Структурная проверка: ru-blocked, российские наборы, контрольные домены и пересечения.
  if ! py verify-geo "$tmp/assets/geosite.dat" >"$tmp/geo-verify.log" 2>&1; then
    err "Новая геобаза не прошла проверку безопасности; текущие базы не изменены:"
    sed 's/^/    /' "$tmp/geo-verify.log" >&2
    rm -rf "${tmp:?}"; return 1
  fi

  # Сохраняем штатный geoip.dat Xray. Не заменяем его российским custom geoip:
  # тот не гарантирует наличие стандартной категории geoip:ru.
  if [[ -s $ASSETS/geoip.dat ]]; then
    cp -p "$ASSETS/geoip.dat" "$tmp/assets/geoip.dat"
  else
    restore_geoip=1
    xray_restore_geoip "$tmp/assets" || { rm -rf "${tmp:?}"; return 1; }
  fi

  # Проверяем именно будущую конфигурацию и оба candidate-файла до публикации.
  if ! py render "$tmp/config" >"$tmp/render.log" 2>&1; then
    err "Не удалось сформировать конфигурацию Xray для проверки:"
    sed 's/^/    /' "$tmp/render.log" >&2
    rm -rf "${tmp:?}"; return 1
  fi
  if ! XRAY_LOCATION_ASSET="$tmp/assets" "$XRAY_BIN" run -test -c "$tmp/config/xray.json" >"$tmp/xray-test.log" 2>&1; then
    # Differentiate an invalid JSON/outbound (retrying geoip cannot help)
    # from the narrow case of missing/broken geoip.dat.
    if grep -Eqi 'unknown action|invalid .*action|failed to build outbound|invalid config|invalid.*DNS|failed to build DNS outbound' "$tmp/xray-test.log"; then
      err "Синтаксис/возможности Xray не соответствуют генератору. Базы не изменены:"
      sed 's/^/    /' "$tmp/xray-test.log" >&2
      rm -rf "${tmp:?}"; return 1
    fi
    if (( ! restore_geoip )) && grep -Eqi 'geoip:|geoip.dat|invalid geoip|failed to load geoip' "$tmp/xray-test.log"; then
      err "Только geoip.dat не прошла проверку; проверяю штатную базу того же релиза Xray"
      restore_geoip=1
      xray_restore_geoip "$tmp/assets" || { sed 's/^/    /' "$tmp/xray-test.log" >&2; rm -rf "${tmp:?}"; return 1; }
      if XRAY_LOCATION_ASSET="$tmp/assets" "$XRAY_BIN" run -test -c "$tmp/config/xray.json" >"$tmp/xray-test.log" 2>&1; then
        : # strict verification succeeded with trusted stock geoip
      else
        err "Конфигурация или базы не прошли проверку Xray. Рабочие файлы не изменены:"
        sed 's/^/    /' "$tmp/xray-test.log" >&2
        rm -rf "${tmp:?}"; return 1
      fi
    else
      err "Проверка новой конфигурации/баз Xray не прошла. Рабочие файлы не изменены:"
      sed 's/^/    /' "$tmp/xray-test.log" >&2
      rm -rf "${tmp:?}"; return 1
    fi
  fi

  # Публикуем только geosite и (при необходимости) восстановленный штатный geoip.
  for n in geosite.dat geoip.dat; do
    [[ $n == geoip.dat && $restore_geoip == 0 ]] && continue
    old=$(stat -c %s "$ASSETS/$n" 2>/dev/null || echo 0)
    new=$(stat -c %s "$tmp/assets/$n" 2>/dev/null || echo 0)
    if [[ -f $ASSETS/$n ]] && cmp -s "$tmp/assets/$n" "$ASSETS/$n"; then continue; fi
    [[ -s $tmp/assets/$n ]] || { err "$n отсутствует в подготовленном наборе"; rm -rf "${tmp:?}"; return 1; }
    [[ -f $ASSETS/$n ]] && cp -p "$ASSETS/$n" "$tmp/backup/$n"
    install -m 644 "$tmp/assets/$n" "$ASSETS/$n.new" || { rc=1; break; }
    changed=1
  done
  if ((rc == 0)); then
    for n in geosite.dat geoip.dat; do
      [[ -f $ASSETS/$n.new ]] || continue
      mv -f "$ASSETS/$n.new" "$ASSETS/$n" || { rc=1; break; }
    done
  fi
  if ((rc != 0)); then
    for n in geosite.dat geoip.dat; do
      if [[ -f $tmp/backup/$n ]]; then cp -p "$tmp/backup/$n" "$ASSETS/$n"; fi
      rm -f "$ASSETS/$n.new"
    done
    err "Не удалось установить списки; прежние файлы сохранены"
    rm -rf "${tmp:?}"; return 1
  fi

  if ((changed)) && systemctl is-active --quiet rp-xray; then
    active=1
    if ! systemctl restart rp-xray || ! systemctl is-active --quiet rp-xray; then
      rc=1
      err "Xray не запустился с новыми базами — возвращаю прежние файлы"
    fi
  fi
  if ((rc != 0)); then
    for n in geosite.dat geoip.dat; do
      if [[ -f $tmp/backup/$n ]]; then cp -p "$tmp/backup/$n" "$ASSETS/$n"; elif [[ $n == geosite.dat || $restore_geoip == 1 ]]; then rm -f "$ASSETS/$n"; fi
    done
    ((active)) && systemctl restart rp-xray >/dev/null 2>&1 || true
    rm -rf "${tmp:?}"; return 1
  fi

  conf_set RU_TAG "$ref" RU_UPDATED "$(date -u +%Y%m%dT%H%M%SZ)"
  rm -rf "${tmp:?}"
  ok "Списки РФ: geosite обновлён и проверен; штатный geoip Xray сохранён$( ((restore_geoip)) && echo ' (восстановлен)' )"
  return 0
}

# ── VPS-2: файлы пакета (CLI, сторож, юниты) и установочный блок ────────
# ── Списки РФ ────────────────────────────────────────────────────────────
ru_lists_restore() { # private backup directory, whether application was attempted
  local stage=$1 reapply=$2 kind rc=0
  for kind in proxy direct; do
    if [[ -f $stage/$kind.absent ]]; then
      rm -f -- "$ETC/ru-$kind.list" || rc=1
    else
      mv -f -- "$stage/$kind.old" "$ETC/ru-$kind.list" || rc=1
    fi
  done
  if ((rc)); then
    err "Списки РФ восстановлены не полностью; резервная копия: $stage"
    return 1
  fi
  if ((reapply)) && ! vps1_apply; then
    err "Файлы списков РФ восстановлены, но применить их не удалось; проверьте rp diag"
    return 1
  fi
  rm -rf -- "$stage"
}
ru_lists_edit() { # ru_lists_edit proxy|direct|del домен
  local kind=$1 d=${2,,} list stage path
  [[ $kind == proxy || $kind == direct || $kind == del ]] || return 1
  [[ $d =~ ^[a-z0-9.-]+\.[a-z0-9-]+$ ]] || die "Нужен домен вида example.com"
  if [[ $kind == direct && $d =~ (^|\.)(google\.com|youtube\.com|instagram\.com|telegram\.org|cloudflare\.com|github\.com|openai\.com|whatsapp\.com)$ ]]; then
    err "$d закреплён за туннелем (защита от DNS/маршрутной утечки), прямое исключение отклонено"
    return 1
  fi
  stage=$(mktemp -d "$ETC/.ru-list.XXXXXX") || return 1
  for list in proxy direct; do
    path="$ETC/ru-$list.list"
    if [[ -f $path ]]; then
      cp -p -- "$path" "$stage/$list.old" || { rm -rf -- "$stage"; return 1; }
    else
      : >"$stage/$list.absent" && : >"$stage/$list.old" || { rm -rf -- "$stage"; return 1; }
    fi
    # Exact string comparison also makes deletion independent of regex syntax.
    if ! awk -v d="$d" '$0!=d' "$stage/$list.old" >"$stage/$list.new" ||
       ! chmod --reference="$stage/$list.old" "$stage/$list.new"; then
      rm -rf -- "$stage"; return 1
    fi
    if [[ $list == "$kind" ]]; then
      printf '%s\n' "$d" >>"$stage/$list.new" || { rm -rf -- "$stage"; return 1; }
    fi
  done
  for list in proxy direct; do
    if ! mv -f -- "$stage/$list.new" "$ETC/ru-$list.list"; then
      ru_lists_restore "$stage" 0 || return 1
      return 1
    fi
  done
  if ! vps1_apply; then
    ru_lists_restore "$stage" 1 || return 1
    return 1
  fi
  rm -rf -- "$stage" || return 1
  case $kind in
    proxy) ok "$d: через туннель" ;;
    direct) ok "$d: напрямую" ;;
    del) ok "$d: исключение удалено" ;;
  esac
}
cmd_ru() {
  need_vps1; case ${1:-status} in
    update) ru_update "${2:-}" ;;
    on) ru_update && vps1_set RU_DIRECT 1 && systemctl enable --now rp-ru.timer >/dev/null 2>&1 ;;
    off) vps1_set RU_DIRECT 0 && systemctl disable --now rp-ru.timer >/dev/null 2>&1 && ok "Всё идёт через туннель" ;;
    proxy|direct) ru_lists_edit "$1" "${2:-}" ;;
    del) [[ -n ${2:-} ]] || die "rp ru del домен"; ru_lists_edit del "$2" ;;
    status) card "Списки РФ"; kv "Режим" "$([[ $(cf RU_DIRECT) == 1 ]] && echo 'напрямую с VPS-1' || echo выключены)"; kv "Релиз" "$(cf RU_TAG —)"
      kv "Исключения: туннель" "$(wc -l <"$ETC/ru-proxy.list" 2>/dev/null || echo 0)"; kv "Исключения: напрямую" "$(wc -l <"$ETC/ru-direct.list" 2>/dev/null || echo 0)"; card_end ;;
    *) die "rp ru update|on|off|proxy ДОМЕН|direct ДОМЕН|del ДОМЕН|status" ;;
  esac
}
