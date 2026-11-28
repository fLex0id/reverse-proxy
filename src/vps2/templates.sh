#!/usr/bin/env bash
# END GENERATED TRANSACTION HELPER

vps2_files() { # vps2_files КАТАЛОГ — раскладывает CLI, сторож и юниты в дерево пакета
  local d=$1; mkdir -p "$d/usr/local/bin" "$d/usr/local/lib/rp" "$d/etc/systemd/system" "$d/etc/rp"
  transaction_source >"$d/usr/local/lib/rp/transaction.py"
  # NAT как файл nft: загрузка идемпотентна (delete + create), счётчики для диагностики
  cat >"$d/etc/rp/nat.nft" <<'EOS'
table ip rp_nat
delete table ip rp_nat
table ip rp_nat {
  chain post {
    type nat hook postrouting priority 100; policy accept;
    ip saddr 10.77.0.1 oifname != "rp-wg" counter masquerade
  }
}
EOS
  cat >"$d/usr/local/bin/rp" <<'EOS'
@VPS2:cli@
EOS

  cat >"$d/usr/local/lib/rp/watch.sh" <<'EOS'
@VPS2:watch@
EOS
  chmod 755 "$d/usr/local/lib/rp/watch.sh" "$d/usr/local/bin/rp"

  local u desc cfgf
  for u in "rp-hy2|Hysteria2 (клиент, без обфускации)|hy2.yaml" "rp-hy2o|Hysteria2 (клиент, Salamander)|hy2o.yaml"; do
    IFS='|' read -r u desc cfgf <<<"$u"
    cat >"$d/etc/systemd/system/$u.service" <<EOS
[Unit]
Description=rp: $desc, исходящее соединение
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
# без обращения к серверу обновлений Hysteria (иначе адрес VPS-2 виден третьей стороне)
Environment=HYSTERIA_DISABLE_UPDATE_CHECK=1
ExecStart=/usr/local/bin/hysteria client -c /etc/rp/$cfgf
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Restart=always
RestartSec=15
EOS
  done
  cat >"$d/etc/systemd/system/rp-xray@.service" <<'EOS'
[Unit]
Description=rp: Xray (мост VLESS Reverse, режим %i)
After=network-online.target
Wants=network-online.target

[Service]
User=xray
Group=xray
Environment=XRAY_LOCATION_ASSET=/usr/local/share/rp
ExecStart=/usr/local/bin/xray run -c /etc/rp/xray-%i.json
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
Restart=always
RestartSec=15
LimitNOFILE=65536
EOS
  cat >"$d/etc/systemd/system/rp-watch.service" <<'EOS'
[Unit]
Description=rp: сторож туннеля
After=network-online.target rp-nat.service
Wants=network-online.target rp-nat.service

[Service]
ExecStart=/usr/local/lib/rp/watch.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOS
  cat >"$d/etc/systemd/system/rp-nat.service" <<'EOS'
[Unit]
Description=rp: MASQUERADE для трафика VPS-1 (режимы hy2)
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/sysctl -q -w net.ipv4.ip_forward=1
ExecStart=/usr/sbin/nft -f /etc/rp/nat.nft
ExecStop=/usr/sbin/nft delete table ip rp_nat

[Install]
WantedBy=multi-user.target
EOS
  cat >"$d/etc/systemd/system/rp-rollback.service" <<'EOS'
[Unit]
Description=rp: откат обновления, если оно не подтверждено

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rp rollback
EOS
}

# vps2_installer — полный текст блока (bash). Бандл с конфигами добавляется в конец как base64.
vps2_installer() { # vps2_installer БАНДЛ.tgz
  conf_load
  local b64 xu hu; b64=$(base64 -w 76 "$1"); xu=$(cf XRAY_URL); hu=$(cf HY2_URL)
  cat <<EOS
#!/usr/bin/env bash
set +o history 2>/dev/null
# rp: блок установки VPS-2 (создан на VPS-1, версия $SELF_VERSION). Входящих портов не открывает.
RP_X_URL_64="${xu%Xray-linux-*}Xray-linux-64.zip"
RP_X_URL_ARM="${xu%Xray-linux-*}Xray-linux-arm64-v8a.zip"
RP_X_SHA_64="$(cf XRAY_SHA_64)"
RP_X_SHA_ARM="$(cf XRAY_SHA_ARM64_V8A)"
RP_H_URL_AMD64="${hu%hysteria-linux-*}hysteria-linux-amd64"
RP_H_URL_ARM64="${hu%hysteria-linux-*}hysteria-linux-arm64"
RP_H_SHA_AMD64="$(cf HY2_SHA_AMD64)"
RP_H_SHA_ARM64="$(cf HY2_SHA_ARM64)"
RP_BUNDLE_SHA="$(sha256sum "$1" | awk '{print $1}')"
RP_SAFE="\${RP_SAFE:-0}"
EOS
  cat <<'EOS'
@VPS2:install@
EOS
  printf 'rp_bundle() { cat <<'"'"'RP_BUNDLE_END'"'"'\n%s\nRP_BUNDLE_END\n}\nrp_main "$@"\n' "$b64"
}
