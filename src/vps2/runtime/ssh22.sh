#!/usr/bin/env bash
# VPS-2 policy, independent of sshd and firewalld.
set -uo pipefail
pending=/run/rp-ssh22.pending
enabled=/etc/rp/ssh22.enabled
unit=rp-ssh22.service
unit_file=/etc/systemd/system/$unit
unit_stage=$unit_file.new
enabled_stage=$enabled.new
timer=rp-ssh22-rollback.timer

ssh22_apply() {
  nft -f - <<'NFT'
table inet rp_ssh22
delete table inet rp_ssh22
table inet rp_ssh22 {
  chain input {
    type filter hook input priority -50; policy accept;
    iifname "lo" tcp dport 22 return
    iifname "rp-wg" ip saddr 10.77.0.1 tcp dport 22 return
    tcp dport 22 counter drop
  }
}
NFT
}

ssh22_delete() {
  local tables
  if nft delete table inet rp_ssh22 2>/dev/null; then return 0; fi
  tables=$(nft list tables) || return 1
  ! grep -Fxq 'table inet rp_ssh22' <<<"$tables"
}

ssh22_enable() {
  if [[ -e $enabled || -e $pending ]]; then
    ssh22_status
    return
  fi
  if nft list table inet rp_ssh22 >/dev/null 2>&1 || [[ -e $unit_file ]]; then
    printf >&2 'rp: найдено правило или служба TCP/22 без состояния rp. Включение отменено.\n'
    return 1
  fi
  install -m 600 /dev/null "$pending" || return 1
  if ! systemd-run --quiet --collect --unit=rp-ssh22-rollback --on-active=30min \
    --property=Restart=on-failure --property=RestartSec=5s --property=StartLimitIntervalSec=0 \
    /usr/local/lib/rp/ssh22.sh expire ||
    ! systemctl is-active --quiet "$timer"; then
    rm -f -- "$pending"
    printf >&2 'rp: таймер отката TCP/22 не запущен. Правило не применялось.\n'
    return 1
  fi
  if ! ssh22_apply; then
    rm -f -- "$pending"
    systemctl stop "$timer" >/dev/null 2>&1 || true
    return 1
  fi
  printf '%s\n' 'TCP/22 ограничен. Проверьте вход через rp ssh и подтвердите в течение 30 минут:' \
    '  rp ssh rp ssh22 confirm' 'До подтверждения перезагрузка или таймер снимут ограничение.'
}

ssh22_confirm() {
  if [[ -e $enabled ]]; then ssh22_status; return; fi
  if [[ ! -e $pending ]] || ! systemctl is-active --quiet "$timer" ||
    ! nft list table inet rp_ssh22 >/dev/null 2>&1; then
    printf >&2 'rp: TCP/22 не ожидает подтверждения.\n'
    return 1
  fi
  if ! install -m 644 /dev/null "$unit_stage" || ! cat >"$unit_stage" <<'UNIT'
# Managed by rp VPS-2 TCP/22
[Unit]
Description=rp VPS-2 SSH ingress restriction
Wants=network-pre.target
After=local-fs.target
Before=network-pre.target sshd.service sshd.socket

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/rp/ssh22.sh boot

[Install]
WantedBy=multi-user.target
UNIT
  then rm -f -- "$unit_stage"; return 1; fi
  mv -f -- "$unit_stage" "$unit_file" || return 1
  systemctl daemon-reload && systemctl enable "$unit" >/dev/null &&
    sync -f /etc/systemd/system || return 1
  # Publish the decision only after the boot unit has been installed. The
  # timeout reads the same flag under the same lock.
  install -m 600 /dev/null "$enabled_stage" &&
    mv -f -- "$enabled_stage" "$enabled" || return 1
  rm -f -- "$pending"
  systemctl stop "$timer" >/dev/null 2>&1 || true
  ssh22_status
}

ssh22_expire() {
  [[ -e $pending && ! -e $enabled ]] || return 0
  ssh22_delete || return 1
  if [[ -e $unit_file ]]; then
    systemctl disable "$unit" >/dev/null 2>&1 || return 1
    rm -f -- "$unit_file" && systemctl daemon-reload || return 1
  fi
  rm -f -- "$pending" "$unit_stage" "$enabled_stage"
}

ssh22_disable() {
  if [[ ! -e $enabled && ! -e $pending ]] &&
    ! grep -Fxq '# Managed by rp VPS-2 TCP/22' "$unit_file" 2>/dev/null; then
    return 0
  fi
  if [[ -e $unit_file ]]; then systemctl disable --now "$unit" >/dev/null || return 1; fi
  ssh22_delete || return 1
  rm -f -- "$enabled" "$pending" "$unit_file" "$unit_stage" "$enabled_stage" || return 1
  systemctl stop "$timer" >/dev/null 2>&1 || true
  systemctl daemon-reload
}

ssh22_status() {
  if [[ -e $enabled ]]; then
    printf '%s\n' 'TCP/22: ограничение подтверждено.'
  elif [[ -e $pending ]]; then
    printf '%s\n' 'TCP/22: ожидается подтверждение. Активен таймер отката.'
  else
    printf '%s\n' 'TCP/22: ограничение rp выключено.'
  fi
}

exec 9>/run/rp-ssh22.lock
flock -w 5 9 || exit 1
case ${1:-status} in
  enable) ssh22_enable ;;
  confirm) ssh22_confirm ;;
  disable) ssh22_disable ;;
  expire) ssh22_expire ;;
  boot) if [[ -e $enabled ]]; then ssh22_apply; fi ;;
  status) ssh22_status ;;
  *) printf >&2 'rp ssh22 [status|enable|confirm|disable]\n'; exit 2 ;;
esac
