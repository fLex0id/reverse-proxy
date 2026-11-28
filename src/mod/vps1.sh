#!/usr/bin/env bash
# ── Бинарники: версия закреплена, SHA256 берётся из файлов релиза ───────
# ОТСТУПЛЕНИЕ от «SHA256 внутри скрипта»: хэши релизов нельзя зашить заранее честно —
# VPS-1 скачивает релиз, сверяет с файлом хэшей самого релиза, запоминает URL+SHA256 в rp.conf
# и вписывает их в блок для VPS-2, где проверка идёт уже по закреплённому значению.
xray_install() {
  local ver=${1:-$(cf XRAY_VER "$XRAY_PINNED")} a name url tmp want got f
  a=$(arch_map xray); name="Xray-linux-$a.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/v$ver/$name"
  tmp=$(mktemp -d "$STATE/dl.XXXXXX") || return 1
  fetch "$url" "$tmp/x.zip" || { rm -rf "${tmp:?}"; err "Не удалось скачать Xray $ver"; return 1; }
  fetch "$url.dgst" "$tmp/x.dgst" || { rm -rf "${tmp:?}"; err "Не удалось скачать файл хэшей Xray"; return 1; }
  want=$(awk -F'= ' 'toupper($1) ~ /^SHA2?-?256/ {print tolower($2)}' "$tmp/x.dgst" | head -1)
  got=$(sha256sum "$tmp/x.zip" | awk '{print $1}')
  [[ -n $want && $want == "$got" ]] || { rm -rf "${tmp:?}"; err "SHA256 Xray не совпал (ожидалось ${want:-—}, получено $got)"; return 1; }
  unzip -qo "$tmp/x.zip" xray geoip.dat geosite.dat -d "$tmp/u" || { rm -rf "${tmp:?}"; return 1; }
  install -m 755 "$tmp/u/xray" "$XRAY_BIN.new" && mv "$XRAY_BIN.new" "$XRAY_BIN"
  mkdir -p "$ASSETS"; for f in geoip.dat geosite.dat; do [[ -s $ASSETS/$f ]] || install -m 644 "$tmp/u/$f" "$ASSETS/$f"; done
  rm -rf "${tmp:?}"
  conf_set XRAY_VER "$ver" XRAY_URL "$url" XRAY_SHA "$got"
}
hy2_install() {
  local ver=${1:-$(cf HY2_VER "$HY2_PINNED")} a url base tmp want got
  a=$(arch_map hy2); base="https://github.com/apernet/hysteria/releases/download/app%2Fv$ver"
  url="$base/hysteria-linux-$a"
  tmp=$(mktemp -d "$STATE/dl.XXXXXX") || return 1
  fetch "$url" "$tmp/h" || { rm -rf "${tmp:?}"; err "Не удалось скачать Hysteria2 $ver"; return 1; }
  fetch "$base/hashes.txt" "$tmp/hashes" || { rm -rf "${tmp:?}"; err "Не удалось скачать файл хэшей Hysteria2"; return 1; }
  want=$(awk -v n="hysteria-linux-$a" '{f=$2; sub(/^.*\//,"",f); if (f==n) print tolower($1)}' "$tmp/hashes" | head -1)
  got=$(sha256sum "$tmp/h" | awk '{print $1}')
  [[ -n $want && $want == "$got" ]] || { rm -rf "${tmp:?}"; err "SHA256 Hysteria2 не совпал"; return 1; }
  install -m 755 "$tmp/h" "$HY2_BIN.new" && mv "$HY2_BIN.new" "$HY2_BIN"
  rm -rf "${tmp:?}"
  conf_set HY2_VER "$ver" HY2_URL "$url" HY2_SHA "$got"
}

# ── Секреты ──────────────────────────────────────────────────────────────
wg_pair() { local pv; pv=$(wg genkey) || return 1; printf '%s %s\n' "$pv" "$(printf '%s' "$pv" | wg pubkey)"; }
x25519_pair() { # печатает «приватный публичный»; формат вывода менялся между версиями Xray
  local o p q; o=$(XRAY_LOCATION_ASSET=$ASSETS "$XRAY_BIN" x25519 2>&1) || return 1
  p=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$o")
  q=$(awk -F': *' 'tolower($1) ~ /public|password/ {print $2; exit}' <<<"$o")
  [[ -n $p && -n $q ]] || return 1; printf '%s %s\n' "$p" "$q"
}
secrets_wg() {
  local a b
  read -r a b < <(wg_pair) || return 1; conf_set WG_PRIV "$a" WG_PUB "$b"
  read -r a b < <(wg_pair) || return 1; conf_set EXIT_PRIV1 "$a" EXIT_PUB1 "$b"
  read -r a b < <(wg_pair) || return 1; conf_set EXIT_PRIV2 "$a" EXIT_PUB2 "$b"
  conf_set EXIT_PSK "$(wg genpsk)"
}
secrets_reality() {
  local a b; read -r a b < <(x25519_pair) || { err "Не удалось получить ключи x25519 от Xray"; return 1; }
  conf_set RL_PRIV "$a" RL_PUB "$b" RL_SID "$(rand_hex 8)" \
    RL_UUID_X "$(uuid)" RL_UUID_T "$(uuid)" RL_UUID_PX "$(uuid)" RL_UUID_PT "$(uuid)"
}
# Reinstall preserves complete key groups. Partial groups are an error, not an
# excuse to rotate keys and silently disconnect existing clients/peers.
secrets_ensure() {
  local generator=$1 key present=0; shift
  for key in "$@"; do [[ -z $(cf "$key") ]] || present=$((present + 1)); done
  ((present == $#)) && return 0
  ((present == 0)) || { err "Неполный набор ключей: восстановите конфигурацию; автоматическая смена запрещена"; return 1; }
  "$generator"
}
secrets_extra() { # пароль локального SOCKS, пароль обфускации Hysteria2
  [[ -n $(cf SOCKS_PASS) ]] || conf_set SOCKS_USER "rp$(rand_hex 3)" SOCKS_PASS "$(rand_pass)"
  [[ -n $(cf HY2O_OBFS) ]] || conf_set HY2O_OBFS "$(rand_pass)"
}
hy2_cert() { # самоподписанный сертификат: DPI его не видит, клиент проверяет pinSHA256
  local sni=$1 fp pin cert_pub key_pub
  # A reinstall must not rotate the certificate pinned on the running VPS-2.
  if [[ -e $ETC/hy2.key || -e $ETC/hy2.crt || -n $(cf HY2_PIN) ]]; then
    [[ -s $ETC/hy2.key && -s $ETC/hy2.crt && -n $(cf HY2_PIN) ]] || {
      err "Неполный сертификат Hysteria2: восстановите ключ, сертификат и HY2_PIN из резервной копии"; return 1;
    }
    openssl x509 -in "$ETC/hy2.crt" -noout -checkend 0 -checkhost "$sni" >/dev/null 2>&1 || {
      err "Сертификат Hysteria2 истёк или не соответствует SNI; требуется согласованное обновление обоих серверов"; return 1;
    }
    cert_pub=$(openssl x509 -in "$ETC/hy2.crt" -pubkey -noout 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "$ETC/hy2.key" -pubout 2>/dev/null) || return 1
    [[ -n $cert_pub && $cert_pub == "$key_pub" ]] || { err "Ключ Hysteria2 не соответствует сертификату"; return 1; }
    fp=$(openssl x509 -in "$ETC/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2) || return 1
    pin=$(cf HY2_PIN); pin=${pin^^}
    [[ ${fp//:/} == "${pin//:/}" ]] || { err "HY2_PIN не соответствует существующему сертификату"; return 1; }
    return 0
  fi
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" -keyout "$ETC/hy2.key" -out "$ETC/hy2.crt" 2>/dev/null || return 1
  chown root:rp "$ETC/hy2.key" "$ETC/hy2.crt"; chmod 640 "$ETC/hy2.key"; chmod 644 "$ETC/hy2.crt"
  fp=$(openssl x509 -in "$ETC/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2)
  conf_set HY2_PIN "$fp" HY2_SNI "$sni"
}
ssh_key() {
  mkdir -p "$ETC/ssh"; chmod 700 "$ETC/ssh"
  [[ -f $ETC/ssh/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -C "rp@vps1" -f "$ETC/ssh/id_ed25519"
  conf_set SSH_PUB "$(cut -d' ' -f1,2 "$ETC/ssh/id_ed25519.pub")"
}

# ── Юниты и сеть VPS-1 ───────────────────────────────────────────────────
hy2_unit() { # hy2_unit имя описание конфиг
  cat >"/etc/systemd/system/$1.service" <<EOF
[Unit]
Description=$2
After=network-online.target
Wants=network-online.target

[Service]
User=rp
Group=rp
# журнал без адресов клиентов (VPS-2), без обращения к серверу обновлений Hysteria
Environment=HYSTERIA_LOG_LEVEL=error
Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1
ExecStart=$HY2_BIN server -c $3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}
units_vps1() {
  mkdir -p "$LIB" || return 1
  cat >"$LIB/net-up.sh" <<'EOS' || return 1
#!/usr/bin/env bash
# Правила сети VPS-1: kill switch, TPROXY, метка выхода hy2. Идемпотентно.
set -u
nft -f /etc/rp/rp.nft || exit 1
ip rule show | grep -q 'fwmark 0x1 lookup 100' || ip rule add fwmark 1 lookup 100 priority 90
ip route replace local 0.0.0.0/0 dev lo table 100
ip rule show | grep -q 'fwmark 0xff lookup 200' || ip rule add fwmark 255 lookup 200 priority 100
# резервный запрет: если wg-exit упал, исходящий трафик с меткой не утекает в основную таблицу
ip route replace prohibit default table 200 metric 1000
# Kernel replies after a socket closes have no SO_MARK. Keep resets sourced
# from the inner WG address on the same fail-closed exit path.
ip -4 rule show | grep -Eq 'from 10\.77\.0\.1(/32)? lookup 200' || ip -4 rule add from 10.77.0.1/32 lookup 200 priority 101 || exit 1
# rp_filter «loose»: ответы из интернета приходят через wg-exit, а обратный маршрут к их адресам
# в основной таблице ведёт в публичный интерфейс; при strict (1) ядро выбрасывает такие ответы.
sysctl -q -w net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
for i in wg0 wg-exit; do [[ -d /proc/sys/net/ipv4/conf/$i ]] && sysctl -q -w "net.ipv4.conf.$i.rp_filter=2" >/dev/null 2>&1; done
exit 0
EOS
  cat >"$LIB/net-down.sh" <<'EOS' || return 1
#!/usr/bin/env bash
# Останов: снимаем перехват, но kill switch (rp_guard) остаётся.
nft delete table ip rp_tp 2>/dev/null
while ip rule del fwmark 1 lookup 100 2>/dev/null; do :; done
exit 0
EOS
  chmod 755 "$LIB/net-up.sh" "$LIB/net-down.sh" || return 1
  cat >/etc/systemd/system/rp-net.service <<EOF || return 1
[Unit]
Description=rp: правила сети (kill switch, TPROXY)
Before=wg-quick@wg0.service
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB/net-up.sh
ExecStop=$LIB/net-down.sh

[Install]
WantedBy=multi-user.target
EOF
  mkdir -p /etc/systemd/system/wg-quick@wg0.service.d || return 1
  printf '[Unit]\nRequires=rp-net.service\nAfter=rp-net.service\n' >/etc/systemd/system/wg-quick@wg0.service.d/rp.conf || return 1
  cat >"$LIB/route-restore.sh" <<'EOS_ROUTE_RESTORE' || return 1
#!/usr/bin/env bash
# Xray gRPC overrides are in-memory; restore BOTH balancing planes after restart.
# On failure, do not report a healthy service while configuration is inconsistent.
set -uo pipefail
state=/var/lib/rp/route-target
[[ -s $state ]] || exit 0
grep -q '"RoutingService"' /etc/rp/xray.json || exit 0
read -r target <"$state"
case $target in to-exit|r-xhttp|r-xhttp2) : ;; *) exit 1;; esac
# Pending handover: restore the management bridge separately from customer exit.
control_target=$target
policy=$(cat /var/lib/rp/route-policy 2>/dev/null || echo manual)
[[ $policy == auto ]] && control_target=to-exit  # clear rev; observatory chooses live bridge
if [[ -s /var/lib/rp/route-transition ]]; then
  desired=$(sed -n 's/^desired=//p' /var/lib/rp/route-transition | head -1)
  case $desired in
    reality-xhttp) control_target=r-xhttp ;;
    reality-xhttp2) control_target=r-xhttp2 ;;
    hy2-wg|hy2o-wg) control_target=to-exit ;;
  esac
fi
if ! python3 -I - /etc/rp/xray.json "$target" "$control_target" <<'PY_ROUTE_VALID'
@PY:route_restore_validate@
PY_ROUTE_VALID
then echo 'rp route restore: target not configured' >&2; exit 1; fi
for ((i=0;i<25;i++)); do
  if grep -Eq '"tag"[[:space:]]*:[[:space:]]*"rev"' /etc/rp/xray.json; then
    if [[ $control_target == to-exit ]]; then
      /usr/local/bin/xray api bo --server=127.0.0.1:10085 -b rev -r >/dev/null 2>&1 || { sleep 0.4; continue; }
    else
      /usr/local/bin/xray api bo --server=127.0.0.1:10085 -b rev "$control_target" >/dev/null 2>&1 || { sleep 0.4; continue; }
    fi
  fi
  /usr/local/bin/xray api bo --server=127.0.0.1:10085 -b exit "$target" >/dev/null 2>&1 && exit 0
  sleep 0.4
done
echo "rp route restore: Xray API did not accept $target" >&2
exit 1
EOS_ROUTE_RESTORE
  chmod 755 "$LIB/route-restore.sh" || return 1
  cat >/etc/systemd/system/rp-route-sync.service <<EOF_SYNC_SERVICE || return 1
[Unit]
Description=rp: reconcile VPS-1 routing with VPS-2 active transport
After=rp-xray.service
Wants=rp-xray.service

[Service]
Type=oneshot
ExecStart=$SELF_BIN _route_sync
TimeoutStartSec=75
EOF_SYNC_SERVICE
  cat >/etc/systemd/system/rp-route-sync.timer <<'EOF_SYNC_TIMER' || return 1
[Unit]
Description=rp: detect VPS-2 automatic failover and mirror active route

[Timer]
OnBootSec=45s
OnUnitInactiveSec=3s
RandomizedDelaySec=1s
AccuracySec=1s
Unit=rp-route-sync.service

[Install]
WantedBy=timers.target
EOF_SYNC_TIMER
  cat >/etc/systemd/system/rp-xray.service <<EOF || return 1
[Unit]
Description=rp: Xray (VPS-1)
After=network-online.target rp-net.service
Wants=network-online.target

[Service]
User=rp
Group=rp
Environment=XRAY_LOCATION_ASSET=$ASSETS
ExecStart=$XRAY_BIN run -c $ETC/xray.json
ExecStartPost=$LIB/route-restore.sh
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  hy2_unit rp-hy2 "rp: Hysteria2 (сервер, UDP, без обфускации)" "$ETC/hy2.yaml" || return 1
  hy2_unit rp-hy2o "rp: Hysteria2 (сервер, UDP, Salamander)" "$ETC/hy2o.yaml" || return 1
  cat >/etc/systemd/system/rp-echo.service <<EOF || return 1
[Unit]
Description=rp: эхо для проб туннеля (T3)
After=network.target

[Service]
User=rp
Group=rp
ExecStart=/usr/bin/python3 -I $RP_PY echo
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/rp-ru.service <<EOF || return 1
[Unit]
Description=rp: обновление списков РФ через туннель

[Service]
Type=oneshot
ExecStart=$SELF_BIN ru update
EOF
  cat >/etc/systemd/system/rp-ru.timer <<'EOF' || return 1
[Unit]
Description=rp: списки РФ раз в неделю

[Timer]
OnCalendar=weekly
RandomizedDelaySec=12h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  {
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' || return 1
    printf 'net.ipv4.conf.all.rp_filter=2\nnet.ipv4.conf.default.rp_filter=2\n' || return 1
    if [[ $(cf DISABLE_IPV6 1) == 1 ]]; then
      printf 'net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n' || return 1
    fi
  } >/etc/sysctl.d/99-rp.conf || return 1
  sysctl -q -p /etc/sysctl.d/99-rp.conf >/dev/null 2>&1 || return 1
  systemctl daemon-reload
}

# ── apply: генерация → проверка → установка с копией → действия → проверка → откат ──
unit_up() { local i; for i in 1 2 3; do systemctl is-active --quiet "$1" || return 1; sleep 1; done; }
tr_has() { [[ " $(cf TRANSPORT_ORDER) " == *" $1 "* ]]; }
wg_sync_live() {
  local interface=$1 path=$2 mtu
  # wg syncconf ignores wg-quick's MTU. Read the installed file so rollback
  # restores the old link MTU too, even while rp.conf still holds new values.
  mtu=$(sed -n 's/^MTU = \([0-9]\+\)$/\1/p' "$path")
  [[ $mtu =~ ^[0-9]+$ ]] || { err "Нет корректного MTU в $path"; return 1; }
  wg syncconf "$interface" <(wg-quick strip "$path") || return 1
  ip link set dev "$interface" mtu "$mtu"
}
vps1_actions() {
  local a
  [[ -n ${ACT[nft]:-} ]] && { systemctl restart rp-net.service || return 1; }
  if [[ -n ${ACT[wg0]:-} ]]; then
    if ip link show wg0 >/dev/null 2>&1; then wg_sync_live wg0 /etc/wireguard/wg0.conf || return 1; else systemctl restart wg-quick@wg0 || return 1; fi
  fi
  if [[ -n ${ACT[wgexit]:-} ]]; then
    if ip link show wg-exit >/dev/null 2>&1; then wg_sync_live wg-exit /etc/wireguard/wg-exit.conf || return 1; else systemctl restart wg-quick@wg-exit || return 1; fi
  fi
  for a in "${!ACT[@]}"; do [[ $a == restart:* ]] && { systemctl restart "${a#restart:}" || return 1; }; done
  return 0
}
# Ждём работоспособный выход (если туннель уже подключался раньше), до 90 с
vps1_check() {
  local t
  for u in rp-net rp-xray rp-echo wg-quick@wg0; do unit_up "$u.service" 2>/dev/null || unit_up "$u" || { err "Не работает: $u"; return 1; }; done
  for t in $(cf TRANSPORT_ORDER); do
    case $t in
      hy2-wg) unit_up rp-hy2.service || { err "Не работает: rp-hy2"; return 1; } ;;
      hy2o-wg) unit_up rp-hy2o.service || { err "Не работает: rp-hy2o"; return 1; } ;;
      reality-xhttp) ss -lnt | grep -q ":$(cf RXH_PORT) " || { err "Xray не слушает TCP/$(cf RXH_PORT)"; return 1; } ;;
      reality-xhttp2) ss -lnt | grep -q ":$(cf RXH2_PORT) " || { err "Xray не слушает TCP/$(cf RXH2_PORT)"; return 1; } ;;
    esac
  done
  nft list table ip rp_tp >/dev/null 2>&1 || { err "Нет таблицы nft rp_tp (перехват не включён)"; return 1; }
  ss -lnt 2>/dev/null | grep -q ':14205 ' || { err "Xray не слушает TPROXY-порт"; return 1; }
  if tr_has reality-xhttp || tr_has reality-xhttp2; then
    local api_ok=0 check_n
    for ((check_n=1; check_n<=5; check_n++)); do
      if "$XRAY_BIN" api bi --server=127.0.0.1:10085 exit >/dev/null 2>&1; then api_ok=1; break; fi
      sleep 1
    done
    ((api_ok)) || { err "Нет локального RoutingService Xray на 127.0.0.1:10085: проверьте версию Xray и rp-xray.service"; return 1; }
  fi
  # Применение локальных конфигов (включая нового клиента WG) не должно
  # откатываться лишь потому, что VPS-2 сейчас недоступен. End-to-end
  # доступность проверяется отдельно в rp test / rp diag.
  return 0
}
# Службы и порты по списку транспортов: лишнее выключается, нужное включается
vps1_units_sync() {
  local anyhy=0
  if tr_has hy2-wg; then anyhy=1; systemctl enable --now rp-hy2 >/dev/null 2>&1; fw_open "$(cf HY2_PORT)/udp"
  else systemctl disable --now rp-hy2 >/dev/null 2>&1; fw_close "$(cf HY2_PORT)/udp"; fi
  if tr_has hy2o-wg; then anyhy=1; systemctl enable --now rp-hy2o >/dev/null 2>&1; fw_open "$(cf HY2O_PORT)/udp"
  else systemctl disable --now rp-hy2o >/dev/null 2>&1; [[ -n $(cf HY2O_PORT) ]] && fw_close "$(cf HY2O_PORT)/udp"; fi
  if ((anyhy)); then
    systemctl enable --now wg-quick@wg-exit >/dev/null 2>&1 || return 1
    wg_sync_live wg-exit /etc/wireguard/wg-exit.conf || return 1
  else systemctl disable --now wg-quick@wg-exit >/dev/null 2>&1; fi
  if ip link show wg0 >/dev/null 2>&1; then wg_sync_live wg0 /etc/wireguard/wg0.conf || return 1; fi
  if tr_has reality-xhttp; then fw_open "$(cf RXH_PORT)/tcp"; else [[ -n $(cf RXH_PORT) ]] && fw_close "$(cf RXH_PORT)/tcp"; fi
  if tr_has reality-xhttp2; then fw_open "$(cf RXH2_PORT)/tcp"; else [[ -n $(cf RXH2_PORT) ]] && fw_close "$(cf RXH2_PORT)/tcp"; fi
  return 0
}
vps1_apply() {
  local scope=${1:-all}
  [[ $scope == all || $scope == clients-only ]] || { err "Неверная область применения: $scope"; return 1; }
  conf_load
  local stage bk f path mode own act n=0 rc=0 restore_rc=0
  stage=$(mktemp -d "$STATE/stage.XXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf -- "$stage"; return 1; }
  py render "$stage" >"$stage/manifest" || { rm -rf "${stage:?}"; return 1; }
  if [[ $scope == all ]]; then
    XRAY_LOCATION_ASSET=$ASSETS "$XRAY_BIN" run -test -c "$stage/xray.json" >"$stage/xtest.log" 2>&1 \
      || { err "Xray отклонил конфиг (run -test):"; sed 's/^/    /' "$stage/xtest.log" >&2; rm -rf "${stage:?}"; return 1; }
  fi
  install -d -m 700 "$BK_DIR" || { rm -rf -- "$stage"; return 1; }
  bk=$(mktemp -d "$BK_DIR/apply-$(date +%Y%m%d-%H%M%S).XXXXXX") || { rm -rf -- "$stage"; return 1; }
  ACT=(); local -a done_paths=()
  while IFS='|' read -r f path mode own act; do
    [[ -n $f ]] || continue
    # WG-клиент не должен менять Xray, Hysteria2, nftables и firewalld.
    [[ $scope == clients-only && $f != wg0.conf ]] && continue
    if [[ -f $path ]] && cmp -s "$stage/$f" "$path"; then continue; fi
    if [[ -f $path ]]; then
      cp -p "$path" "$bk/$(printf '%s' "$path" | tr / _)" || { rc=1; break; }
    else
      : >"$bk/$(printf '%s' "$path" | tr / _).absent" || { rc=1; break; }
    fi
    install -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$stage/$f" "$path.rp-new" && mv "$path.rp-new" "$path" || {
      rm -f -- "$path.rp-new"; rc=1; break;
    }
    done_paths+=("$path"); ACT[$act]=1; n=$((n + 1))
  done <"$stage/manifest"
  if ((rc == 0)) && [[ $scope == all ]]; then
    vps1_units_sync || rc=1
  fi
  if ((rc == 0 && n > 0)); then
    if [[ $scope == clients-only ]]; then
      vps1_actions && wg show wg0 peers >/dev/null 2>&1 || rc=1
    else
      vps1_actions && vps1_check || rc=1
    fi
  fi
  if ((rc != 0)); then
    err "Применение не удалось — возвращаю прежние файлы"
    for path in "${done_paths[@]}"; do
      local k; k="$bk/$(printf '%s' "$path" | tr / _)"
      if [[ -f $k ]]; then
        cp -p "$k" "$path.rp-new" && mv -f -- "$path.rp-new" "$path" || restore_rc=1
        rm -f -- "$path.rp-new" || restore_rc=1
      elif [[ -f $k.absent ]]; then
        rm -f -- "$path" || restore_rc=1
      else
        restore_rc=1
      fi
    done
    if ((restore_rc)); then
      err "Откат файлов не завершён; резервная копия сохранена: $bk"
    elif ! vps1_actions; then
      err "Файлы восстановлены, но службы не восстановлены; резервная копия: $bk"
    fi
  fi
  rm -rf "${stage:?}"
  # Keep failed operations and script-update backups available for diagnosis.
  if ((rc == 0)); then
    ls -1dt "$BK_DIR"/apply-* 2>/dev/null | tail -n +11 | while read -r d; do [[ -d $d && -f $d/.committed ]] && rm -rf -- "$d"; done
    : >"$bk/.committed" || warn "Не удалось отметить завершённую резервную копию: $bk"
  fi
  return $rc
}
# vps1_set КЛЮЧ ЗНАЧ … — записать, применить; при сбое вернуть прежние значения
vps1_set() {
  local -A old=(); local k i=0 args=("$@")
  for ((i = 0; i < ${#args[@]}; i += 2)); do k=${args[i]}; old[$k]=$(cf "$k"); done
  conf_set "$@"
  if ! vps1_apply; then
    for k in "${!old[@]}"; do conf_set "$k" "${old[$k]}"; done
    vps1_apply || true; return 1
  fi
}

# ── Списки РФ (.dat), релиз закреплён по тегу ────────────────────────────
# Формат .dat (geosite/geoip): понимает Xray, без отдельного ядра. Исходник списков — $RU_REPO.
# ── Роль VPS-1 ───────────────────────────────────────────────────────────
need_vps1() { conf_load; [[ $(cf ROLE) == vps1 ]] || die "Это не VPS-1 (или rp ещё не установлен): выполните «rp install»"; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)); }
# ── Установка ────────────────────────────────────────────────────────────
vps1_install() {
  steps 7
  step "Проверка системы"
  os_check; arch_map xray >/dev/null
  ok "$(. /etc/os-release; echo "$PRETTY_NAME"), $(uname -m), фаервол: $(fw_kind), SELinux: $(getenforce 2>/dev/null || echo —)"
  conf_load
  section "Параметры" "WG клиент → VPS-1 → выбранный обратный туннель. Устойчивость к фильтрации требует отдельных измерений."
  local ip order adv=n transport_default=all ru_default=y
  local -a transport_options=()
  ip=$(cf PUBLIC_IP "${PUBLIC_IP:-}"); [[ -n $ip ]] || ip=$(public_ip)
  PUBLIC_IP=${PUBLIC_IP:-$ip}; ask PUBLIC_IP "Публичный IPv4 этого сервера" "$ip" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "Нужен IPv4-адрес"
  WG_PORT=${WG_PORT:-$(cf WG_PORT $((20000 + RANDOM % 30000)))}
  ask WG_PORT "UDP-порт WireGuard для клиентов" "$WG_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
  if [[ -n $(cf TRANSPORT_ORDER) ]]; then
    transport_default=keep
    transport_options+=("keep|Сохранить текущий набор|$(cf TRANSPORT_ORDER)")
  fi
  choose TRANSPORT_CHOICE "Транспорты туннеля к VPS-2" "$transport_default" "${transport_options[@]}" \
    "all|Все четыре (рекомендуется)|XHTTP packet-up → XHTTP stream-up → HY2 → HY2+Salamander; отказавшие остаются резервом" \
    "udp|Только Hysteria2 (без и с obfs)|если TCP режется ТСПУ" \
    "tcp|Только VLESS Reality · XHTTP (два варианта)|если UDP/QUIC недоступен"
  case ${TRANSPORT_CHOICE:-all} in keep) order=$(cf TRANSPORT_ORDER) ;; udp) order="hy2-wg hy2o-wg" ;; tcp) order="reality-xhttp2 reality-xhttp" ;; *) order="${TR_RANK[*]}" ;; esac
  yesno "Дополнительные параметры (порты туннелей)?" n && adv=y
  HY2_PORT=${HY2_PORT:-$(cf HY2_PORT 443)}; HY2O_PORT=${HY2O_PORT:-$(cf HY2O_PORT 8443)}
  RXH_PORT=${RXH_PORT:-$(cf RXH_PORT 443)}; RXH2_PORT=${RXH2_PORT:-$(cf RXH2_PORT 8443)}
  HY2_MASQ_HOST=${HY2_MASQ_HOST:-$(cf HY2_SNI)}
  RXH_SNI=${RXH_SNI:-$(cf RXH_SNI)}; RXH2_SNI=${RXH2_SNI:-$(cf RXH2_SNI)}
  if [[ $adv == y ]]; then
    ord_has "$order" hy2-wg && ask HY2_PORT "UDP-порт Hysteria2" "$HY2_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
    ord_has "$order" hy2o-wg && ask HY2O_PORT "UDP-порт Hysteria2 с obfs" "$HY2O_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
    ord_has "$order" reality-xhttp && ask RXH_PORT "TCP-порт Reality/XHTTP" "$RXH_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
    ord_has "$order" reality-xhttp2 && ask RXH2_PORT "TCP-порт Reality/XHTTP (packet-up)" "$RXH2_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
  fi
  [[ $order == *hy2* ]] && sni_choose HY2_MASQ_HOST "Сайт для маскировки Hysteria2 (SNI и masquerade, HTTP/3)" masq
  ord_has "$order" reality-xhttp && sni_choose RXH_SNI "SNI для Reality (XHTTP, вариант 1)" reality
  ord_has "$order" reality-xhttp2 && sni_choose RXH2_SNI "SNI для Reality (XHTTP packet-up, вариант 2; лучше другой сайт)" reality "${RXH_SNI:-}"
  [[ $(cf RU_DIRECT 1) == 0 ]] && ru_default=n
  local ru=y; yesno "Российские сайты напрямую с VPS-1 (списки .dat)?" "$ru_default" || ru=n
  printf '\n'; card "Проверьте настройки"
  kv "Публичный IP" "$PUBLIC_IP"; kv "WG клиентов" "UDP/$WG_PORT"; kv "Транспорты" "$order"
  ord_has "$order" hy2-wg && kv "Hysteria2" "UDP/$HY2_PORT · ${HY2_MASQ_HOST:-}"
  ord_has "$order" hy2o-wg && kv "Hysteria2 + obfs" "UDP/$HY2O_PORT · Salamander"
  ord_has "$order" reality-xhttp && kv "XHTTP (stream-up)" "TCP/$RXH_PORT · ${RXH_SNI:-—}"
  ord_has "$order" reality-xhttp2 && kv "XHTTP (packet-up)" "TCP/$RXH2_PORT · ${RXH2_SNI:-—}"
  kv "DNS через туннель" "DoH: $(cf DNS_REMOTE 'quad9 cloudflare')"
  kv "Списки РФ" "$([[ $ru == y ]] && echo напрямую || echo выключены)"; card_end
  yesno "Начать установку?" y || die "Отменено"

  step "Пакеты"
  run "Базовые пакеты" pkg_install curl openssl unzip tar nftables chrony python3 iproute procps-ng openssh-clients || die "dnf не справился: проверьте репозитории"
  run "WireGuard (wireguard-tools)" pkg_wg || die "wireguard-tools не поставились (нужен EPEL на Rocky 9)"
  run "Служебный пользователь" bash -c 'id rp >/dev/null 2>&1 || useradd -r -s /sbin/nologin -M rp'
  systemctl enable --now chronyd >/dev/null 2>&1 || true
  mkdir -p "$ETC" "$LIB" "$STATE" "$ASSETS" "$BK_DIR"; chown root:rp "$ETC"; chmod 750 "$ETC"; chmod 755 "$STATE" "$ASSETS"
  conf_set ROLE vps1 PUBLIC_IP "$PUBLIC_IP" WG_PORT "$WG_PORT" WG_NET "$(cf WG_NET '10.66.0.0/24')" WG_NET_GW "$(cf WG_NET_GW '10.66.0.1')" WG_MTU "$(cf WG_MTU 1380)" \
    TRANSPORT_ORDER "$order" TRANSPORT_FORCE "$(cf TRANSPORT_FORCE)" HY2_PORT "$HY2_PORT" HY2O_PORT "$HY2O_PORT" RXH_PORT "$RXH_PORT" RXH2_PORT "$RXH2_PORT" \
    RXH_SNI "${RXH_SNI:-www.microsoft.com}" RXH2_SNI "${RXH2_SNI:-www.asus.com}" XHTTP_PATH "$(cf XHTTP_PATH "/$(rand_hex 4)")" XHTTP2_PATH "$(cf XHTTP2_PATH "/$(rand_hex 4)")" \
    HY2_MASQ "$(cf HY2_MASQ "https://${HY2_MASQ_HOST:-www.microsoft.com}")" EXIT_MTU "$(cf EXIT_MTU 1280)" DOORS "$(cf DOORS 'ssh=2222=127.0.0.1:22')" \
    RU_DIRECT "$([[ $ru == y ]] && echo 1 || echo 0)" RU_GUARD "$(cf RU_GUARD 1)" RU_GEOIP "$(cf RU_GEOIP 1)" DNS_RU "$(cf DNS_RU '77.88.8.8')" DNS_REMOTE "$(cf DNS_REMOTE 'quad9 cloudflare')" \
    DISABLE_IPV6 "$(cf DISABLE_IPV6 1)" SNIFF "$(cf SNIFF 1)" RL_FP "$(cf RL_FP chrome)" WATCH_MIN "$(cf WATCH_MIN 10)" WATCH_MAX "$(cf WATCH_MAX 15)" CONF_VER 2
  conf_exit_mtu_migrate
  chown root:root "$CONF"; touch "$CLIENTS"; chmod 600 "$CLIENTS"

  step "Xray и Hysteria2"
  run "Xray $(cf XRAY_VER "$XRAY_PINNED")" xray_install "$(cf XRAY_VER "$XRAY_PINNED")" || die "Не удалось поставить Xray"
  if [[ $order == *hy2* ]]; then run "Hysteria2 $(cf HY2_VER "$HY2_PINNED")" hy2_install "$(cf HY2_VER "$HY2_PINNED")" || die "Не удалось поставить Hysteria2"; fi
  run "Хэши релизов для VPS-2" pin_release || warn "Хэши для VPS-2 не получены — блок можно будет собрать позже (rp block)"

  step "Ключи и сертификат"
  py_install; secrets_ensure secrets_wg WG_PRIV WG_PUB EXIT_PRIV1 EXIT_PUB1 EXIT_PRIV2 EXIT_PUB2 EXIT_PSK || die "Не удалось создать ключи WireGuard"
  secrets_ensure secrets_reality RL_PRIV RL_PUB RL_SID RL_UUID_X RL_UUID_T RL_UUID_PX RL_UUID_PT || die "Не удалось создать ключи Reality"
  secrets_extra; [[ -n $(cf HY2_PASS) ]] || conf_set HY2_PASS "$(rand_pass)"
  [[ $order == *hy2* ]] && { hy2_cert "${HY2_MASQ_HOST:-www.microsoft.com}" || die "Сертификат не создан"; }
  ssh_key; ok "Ключи созданы (секреты только в $CONF, права 600)"

  step "Списки РФ"
  if [[ $ru == y ]]; then
    # RU split was explicitly requested. Never switch it off silently.
    # Stop before enabling services if the verified asset set is unavailable.
    run "Списки РФ (.dat)" ru_update || die "Проверка списков РФ не прошла — установка остановлена без изменения RU_DIRECT. Исправьте источник/конфигурацию и повторите: rp ru update; rp migrate"
  else note "Выключены"; fi

  step "Службы и применение"
  units_vps1 || die "Не удалось записать или применить службы и sysctl; установка остановлена"
  systemctl enable --now rp-echo >/dev/null 2>&1
  fw_open "$WG_PORT/udp"
  fw_trust_if wg0; fw_trust_if wg-exit; selinux_fix
  systemctl enable rp-net rp-xray wg-quick@wg0 >/dev/null 2>&1
  run "Применение конфигурации" vps1_apply || die "Конфигурация не применилась (изменения откатены)"
  self_install || die "Конфигурация применена, но команду rp не удалось сохранить"
  [[ $ru == y ]] && systemctl enable --now rp-ru.timer >/dev/null 2>&1
  if tr_has reality-xhttp || tr_has reality-xhttp2; then
    systemctl enable --now rp-route-sync.timer >/dev/null 2>&1 || warn "Не удалось включить синхронизацию маршрута"
  fi

  step "Готово"
  banner "VPS-1 готов" "$PUBLIC_IP"
  card "Дальше"
  card_line "1. rp link        — короткая строка для VPS-2: он сам скачает блок с VPS-1"
  card_line "   rp block       — запасной путь: блок для вставки в веб-консоль VPS-2"
  card_line "2. rp client add  — добавить клиента WG (OpenWrt и др.)"
  card_line "3. rp test        — проверки T1–T8 после подключения VPS-2"
  card_line "   rp diag --fix  — если выход в интернет не работает: поиск и исправление по участкам"
  card_end
  note "Меню: rp"
  if [[ -t 0 && -t 1 ]]; then
    printf '\n'; yesno "Сформировать строку для VPS-2 сейчас?" y && { (cmd_link); }
  fi
}
