#!/usr/bin/env bash
# ── Загрузки: ретраи, зеркало ────────────────────────────────────────────
# fetch URL файл — до 5 попыток с нарастающей паузой; затем зеркало (GH_MIRROR, если задано)
fetch() {
  local url=$1 out=$2 i d=2 m
  for i in 1 2 3 4 5; do
    curl -fsSL --connect-timeout 10 -m 180 -o "$out" "$url" && [[ -s $out ]] && return 0
    sleep "$d"; d=$((d * 2)); ((d > 20)) && d=20
  done
  m=$(cf GH_MIRROR)
  if [[ -n $m && $url == https://github.com/* ]]; then
    warn "GitHub не ответил, пробую зеркало (целостность проверяется по SHA256 релиза)"
    curl -fsSL --connect-timeout 10 -m 180 -o "$out" "${m%/}/$url" && [[ -s $out ]] && return 0
  fi
  return 1
}
# latest_tag репозиторий — тег последнего релиза через redirect (без лимитов API)
latest_tag() {
  curl -fsSI -m 15 "https://github.com/$1/releases/latest" 2>/dev/null | tr -d '\r' | awk -F/ 'tolower($1) ~ /^location/ {print $NF}' | tail -1
}

# gh_tags репозиторий [префикс-тега] [N] — последние N стабильных версий из ленты релизов (новые первыми)
# Лента releases.atom не имеет лимитов API; префикс: «v» для Xray, «app/v» для Hysteria2.
gh_tags() {
  local repo=$1 pre=${2:-v} n=${3:-5}
  curl -fsSL --connect-timeout 10 -m 25 "https://github.com/$repo/releases.atom" 2>/dev/null \
    | grep -o 'releases/tag/[^"<]*' | sed 's|^releases/tag/||; s|%2F|/|g' \
    | awk -v p="$pre" 'index($0, p) == 1 {v = substr($0, length(p) + 1); if (v ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ && !(v in s)) {s[v] = 1; print v}}' | head -n "$n"
}

# ── Скрытие IP VPS-2 ─────────────────────────────────────────────────────
# В rp.conf и на экране адрес VPS-2 не хранится: только отпечаток (для сверки «выход = VPS-2»)
# и маска. Полностью скрыть нельзя: адрес видят сайты, на которые идёт трафик, и ТСПУ на участке VPS-1↔VPS-2.
ip_hash() { printf '%s' "$1" | sha256sum | cut -c1-16; }
mask_ip() { local ip=$1; [[ $ip =~ ^([0-9]+)\.([0-9]+)\.[0-9]+\.[0-9]+$ ]] && printf '%s.%s.*.*' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" || printf '—'; }
# Запросы через локальный SOCKS Xray: пароль — в переменной окружения, не в аргументах процесса
sx_proxy() { printf 'socks5h://%s:%s@127.0.0.1:%s' "$(cf SOCKS_USER)" "$(cf SOCKS_PASS)" "$SOCKS_PORT"; }
sx() { ALL_PROXY=$(sx_proxy) curl -fsS --connect-timeout 8 "$@"; }

# pin_release — SHA256 релизов Xray/Hysteria2 для обеих архитектур (без скачивания бинарников)
pin_release() {
  conf_load; local xv hv tmp a n w base
  xv=$(cf XRAY_VER "$XRAY_PINNED"); hv=$(cf HY2_VER "$HY2_PINNED"); tmp=$(mktemp -d "$STATE/pin.XXXXXX")
  for a in 64 arm64-v8a; do
    n=Xray-linux-$a.zip
    fetch "https://github.com/XTLS/Xray-core/releases/download/v$xv/$n.dgst" "$tmp/x$a" || { rm -rf "${tmp:?}"; err "Нет файла хэшей Xray для $a"; return 1; }
    w=$(awk -F'= ' 'toupper($1) ~ /^SHA2?-?256/ {print tolower($2)}' "$tmp/x$a" | head -1); [[ -n $w ]] || { rm -rf "${tmp:?}"; return 1; }
    conf_set "XRAY_SHA_$(printf '%s' "$a" | tr -c 'A-Za-z0-9' '_' | tr a-z A-Z)" "$w"
  done
  base="https://github.com/apernet/hysteria/releases/download/app%2Fv$hv"
  fetch "$base/hashes.txt" "$tmp/h" || { rm -rf "${tmp:?}"; err "Нет файла хэшей Hysteria2"; return 1; }
  for a in amd64 arm64; do
    w=$(awk -v n="hysteria-linux-$a" '{f=$2; sub(/^.*\//,"",f); if (f==n) print tolower($1)}' "$tmp/h" | head -1); [[ -n $w ]] || { rm -rf "${tmp:?}"; return 1; }
    conf_set "HY2_SHA_$(printf '%s' "$a" | tr a-z A-Z)" "$w"
  done
  rm -rf "${tmp:?}"
}
