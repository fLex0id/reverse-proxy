#!/usr/bin/env bash
# ── SNI / masquerade: кандидаты и проверка с VPS-1 ───────────────────────
# Для Reality на сервере в РФ лучше сайты из РФ: адрес сервера и SNI выглядят согласованно.
# Список — пул кандидатов: рабочие определяются проверкой с самого VPS-1 (TLS 1.3, h2, X25519).
# sni_check хост → «TLS1.3 + h2 + X25519 + h3 +» (+ / - / ?)
sni_check() {
  # Надёжно проверяем свойства TLS на стороне VPS-1. curl --http2 не является
  # доказательством поддержки TLS1.3: на разных сборках curl бывают отличия.
  # У Reality X25519 обязателен; h2 желателен, но его отсутствие не является
  # доказательством непригодности SNI. Для masquerade h3 только индикатор.
  local h=$1 t13=- h2=- x=- h3='?' v hdr
  [[ $h =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || {
    printf 'TLS1.3 -  h2 -  X25519 -  h3 ?'; return 1;
  }
  # Some OpenSSL builds print NUL bytes (or binary TLS data) on stdout.
  # Remove them BEFORE Bash command substitution to avoid noisy warnings.
  v=$(printf '\n' | timeout 9 openssl s_client -brief -connect "$h:443" \
      -servername "$h" -tls1_3 -groups X25519 -alpn 'h2,http/1.1' 2>&1 | LC_ALL=C tr -d '\000') || true
  printf '%s\n' "$v" | grep -qiE 'Protocol( version)?[[:space:]]*:[[:space:]]*TLSv1\.3|New, TLSv1\.3' && t13=+
  printf '%s\n' "$v" | grep -qiE '(Peer |Server )?Temp Key:[[:space:]]*X25519' && x=+
  printf '%s\n' "$v" | grep -qiE 'ALPN protocol:[[:space:]]*h2' && h2=+
  # В старых openssl ALPN печатался иначе; дополнительная проверка — только
  # если curl действительно собран с HTTP/2. Это не обязательный критерий.
  if [[ ${2:-full} == full && $t13 == + && $h2 == - ]] && curl -V 2>/dev/null | grep -qi 'HTTP2'; then
    [[ $(curl -sS -o /dev/null -m 6 --http2 -w '%{http_version}' "https://$h/" 2>/dev/null) == 2 ]] && h2=+
  fi
  if [[ ${2:-full} == full ]]; then
    hdr=$(curl -fsSI -m 6 "https://$h/" 2>/dev/null | tr 'A-Z' 'a-z' | grep '^alt-svc:' | head -1 || true)
    [[ $hdr == *h3* ]] && h3=+
  fi
  printf 'TLS1.3 %s  h2 %s  X25519 %s  h3 %s' "$t13" "$h2" "$x" "$h3"
}
# Every SNI candidate is checked, including TLS 1.3, h2, X25519 and h3.
# Stable ordering and bounded parallelism affect only throughput, not coverage.
# sni_scan OUT [all] → host|result|RU/—; all 15+23 entries, no shortlists.
sni_scan() {
  local out=$1 scope=${2:-all} tmp h i=0 n=0 ru rc=0
  local -a hosts=("${SNI_RU[@]}" "${SNI_WORLD[@]}")
  [[ $scope == all ]] || { err "Неполный SNI-режим не допускается: $scope"; return 2; }
  tmp=$(mktemp -d "$STATE/sni.XXXXXX") || return 1
  for h in "${hosts[@]}"; do
    i=$((i + 1))
    ru=—; [[ " ${SNI_RU[*]} " == *" $h "* ]] && ru=RU
    ( printf '%s|%s|%s\n' "$h" "$(sni_check "$h" full)" "$ru" >"$tmp/$(printf '%03d' "$i")" ) &
    n=$((n + 1)); ((n % 5 == 0)) && wait
  done
  wait
  if [[ $(find "$tmp" -maxdepth 1 -type f | wc -l) -ne ${#hosts[@]} ]]; then
    err "Проверка SNI неполная: отсутствуют результаты некоторых кандидатов"
    rc=1
  else
    cat "$tmp"/* >"$out" 2>/dev/null || rc=1
    [[ $(wc -l <"$out") -eq ${#hosts[@]} ]] || rc=1
  fi
  rm -rf "$tmp"
  return "$rc"
}
sni_stream_validate() {
  local host=$1 check protocol
  check=$(sni_check "$host" tls)
  if [[ $check == *"TLS1.3 +"*"X25519 +"* ]]; then
    protocol=$(curl -q --noproxy '*' -sS -o /dev/null -m 6 --http2 \
      --tlsv1.3 --tls-max 1.3 -w '%{http_version}' -- "https://$host/" 2>/dev/null) || protocol=
    [[ $protocol == 2 ]] && return 0
  fi
  err "SNI «$host» не прошёл проверку stream-up: нужны TLS 1.3, X25519 и HTTP/2 по curl --http2."
  return 1
}
sni_choose() { # sni_choose ПЕРЕМЕННАЯ «Заголовок» reality|stream-up|masq [исключить-хост]
  local var=$1 title=$2 kind=$3 skip=${4:-} h chk ru line
  if [[ -n "${!var:-}" ]]; then
    if [[ $kind == stream-up ]]; then sni_stream_validate "${!var}"; return; fi
    return 0
  fi
  if [[ -z $SNI_CACHE || ! -s $SNI_CACHE ]]; then
    SNI_CACHE=$(mktemp "$STATE/snicache.XXXXXX")
    note "Проверяю все ${#SNI_RU[@]}+${#SNI_WORLD[@]} SNI-кандидатов (TLS1.3, h2, X25519, h3)…"
    sni_scan "$SNI_CACHE" all || { warn "Полная проверка SNI не завершилась; результаты не считаются достоверными"; : >"$SNI_CACHE"; }
  fi
  local -a items=() good=() unchecked=()
  if [[ $kind == stream-up ]]; then
    for h in "${SNI_STREAM_PREFERRED[@]}"; do
      [[ $h != "$skip" ]] || continue
      chk=$(sni_check "$h")
      if [[ $chk == *"TLS1.3 +"*"h2 +"*"X25519 +"* ]]; then
        items+=("$h|$h|$chk")
      fi
    done
  fi
  while IFS= read -r line; do
    h=${line%%|*}; chk=${line#*|}; ru=${chk##*|}; chk=${chk%|*}
    [[ $h == "$skip" ]] && continue
    if [[ $kind == stream-up ]]; then
      [[ " ${SNI_STREAM_PREFERRED[*]} www.microsoft.com " == *" $h "* ]] && continue
    fi
    if [[ $kind == reality || $kind == stream-up ]]; then
      if [[ $chk == *"TLS1.3 +"*"X25519 +"* ]] &&
        { [[ $kind != stream-up ]] || [[ $chk == *"h2 +"* ]]; }; then
        good+=("$h|$h|$chk · $ru")
      else
        unchecked+=("$h|$h|не подтверждён: $chk")
      fi
    else
      if [[ $chk == *"TLS1.3 +"* ]]; then
        good+=("$h|$h|$chk · $ru")
      else
        unchecked+=("$h|$h|не подтверждён: $chk")
      fi
    fi
  done <"$SNI_CACHE"
  # Проверенные российские — первыми, затем проверенные иностранные.
  local g
  for g in "${good[@]}"; do [[ $g == *"· RU" ]] && items+=("$g"); done
  for g in "${good[@]}"; do [[ $g == *"· RU" ]] || items+=("$g"); done
  if ((${#items[@]} == 0)) && [[ $kind != stream-up ]]; then
    warn "Автопроверка не подтвердила подходящий SNI. Это не доказывает, что все домены непригодны."
    warn "Ниже — НЕПРОВЕРЕННЫЕ кандидаты. Их использование требует проверки соединения VPS-2."
    items=("${unchecked[@]}")
  fi
  if ((${#items[@]})); then
    items+=("custom|Свой адрес|ввести вручную")
    choose "$var" "$title" "${items[0]%%|*}" "${items[@]}"
  else
    warn "Список кандидатов пуст; нужен домен вручную"
  fi
  if [[ ${!var:-} == custom || -z ${!var:-} ]]; then
    printf -v "$var" '%s' ""
    ask "$var" "Домен (без https://)" "" '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' "Нужен домен вида example.com"
  fi
  if [[ $kind == stream-up ]]; then sni_stream_validate "${!var}"; return; fi
  chk=$(sni_check "${!var}")
  if [[ $kind == reality ]]; then
    [[ $chk == *"TLS1.3 +"*"X25519 +"* ]] || warn "SNI «${!var}» не подтверждён для Reality (TLS1.3 + X25519): $chk"
  else
    [[ $chk == *"TLS1.3 +"* ]] || warn "TLS1.3 для маскировки «${!var}» не подтверждён: $chk"
    [[ $chk == *"h3 ?"* ]] && note "HTTP/3 не подтверждён: у сервера может отсутствовать доступ к Alt-Svc"
  fi
  return 0
}

cmd_sni() { # rp sni [хост …] — проверка кандидатов (по умолчанию весь пул)
  local h
  local -a hosts=("$@")
  ((${#hosts[@]})) || hosts=("${SNI_RU[@]}" "${SNI_WORLD[@]}")
  for h in "${hosts[@]}"; do printf '  %-24s %s\n' "$h" "$(sni_check "$h")"; done
}
