#!/usr/bin/env bash
doh_test() {
  local tmp stats curl_rc=0 rc=0
  tmp=$(mktemp -d "$STATE/doh-probe.XXXXXX") || return 1
  stats=$(sx -m 10 -H 'accept: application/dns-message' -o "$tmp/body" \
    -w '%{http_code}\n%{content_type}\n%{time_total}' "$1?dns=$DOH_Q" 2>"$tmp/curl-error") || curl_rc=$?
  python3 -I - "$tmp" "$curl_rc" "$stats" >"$tmp/result.json" <<'PY_DOH_CHECK' || rc=$?
@PY:doh_test@
PY_DOH_CHECK
  chmod 600 "$tmp/result.json"
  if ((rc)); then install -m 600 "$tmp/result.json" "$STATE/doh-last-failure.json" || true; fi
  mv -f "$tmp/result.json" "$STATE/doh-last.json" || rc=1
  rm -rf "${tmp:?}"
  return "$rc"
}
# ── DNS ──────────────────────────────────────────────────────────────────
dns_info() {
  cat <<'EOT'
quad9|Quad9|9.9.9.9 и 149.112.112.112|DoH (DNS-over-HTTPS, RFC 8484, HTTPS/443); блокирует вредоносные домены
cloudflare|Cloudflare|1.1.1.1 и 1.0.0.1|DoH (DNS-over-HTTPS, RFC 8484, HTTPS/443); быстрый, без фильтрации
google|Google Public DNS|8.8.8.8 и 8.8.4.4|DoH (DNS-over-HTTPS, RFC 8484, HTTPS/443); без фильтрации
adguard|AdGuard DNS|94.140.14.14 и 94.140.15.15|DoH (DNS-over-HTTPS, RFC 8484, HTTPS/443); блокирует рекламу и трекеры
EOT
}
cmd_dns() {
  need_vps1; local act=${1:-show} k n a t u
  case $act in
    show)
      card "DNS"
      kv "Запросы клиентов" "UDP/TCP 53 на wg0 перехватываются и обслуживаются Xray"
      kv "Российские домены" "$([[ $(cf RU_DIRECT 0) == 1 ]] && echo "DNS $(cf DNS_RU 77.88.8.8) напрямую (кроме ru-blocked/ru-proxy)" || echo "все DNS через туннель")"
      kv "Остальные домены" "DoH через туннель, fail-closed; порядок: $(cf DNS_REMOTE)"
      card_end
      printf '\n  %sДоступные серверы (все — DoH, шифруются HTTPS внутри туннеля)%s\n' "$B" "$R"
      while IFS='|' read -r k n a t; do printf '   %s%-11s%s %s — %s\n     %s%s%s\n' "$C_ACC" "$k" "$R" "$n" "$a" "$C_DIM" "$t" "$R"; done < <(dns_info) ;;
    set)
      shift; local v="$*"
      [[ -n $v ]] || die "rp dns set quad9 cloudflare   (пресеты: quad9 cloudflare google adguard; или https://адрес/dns-query)"
      vps1_set DNS_REMOTE "$v" && ok "DNS через туннель: $v" ;;
    test)
      local urls failed=0
      urls=$(py dns) || { err "Не удалось получить список DoH-серверов"; return 1; }
      [[ -n $urls ]] || { err "Список DoH-серверов пуст"; return 1; }
      for u in $urls; do
        if doh_test "$u"; then ok "$u (DoH) отвечает"
        else err "$u (DoH) не прошёл проверку; подробности: $STATE/doh-last-failure.json"; failed=1; fi
      done
      return "$failed" ;;
    ru)
      local addr="${2:-}"
      if [[ -z $addr ]]; then note "Российский DNS: $(cf DNS_RU 77.88.8.8) (напрямую с VPS-1)"; return 0; fi
      [[ $addr == yandex ]] && addr=77.88.8.8
      python3 - "$addr" <<'PY_DNS'
@PY:validate_dns@
PY_DNS
      [[ $? == 0 ]] || return 1
      vps1_set DNS_RU "$addr" && ok "Российский DNS: $addr" ;;
    *) die "rp dns [show] | set СЕРВЕРЫ | ru [IPv4|yandex] | test" ;;
  esac
}
