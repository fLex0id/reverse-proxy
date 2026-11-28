#!/usr/bin/env bash
# ── Система ──────────────────────────────────────────────────────────────
need_root() { ((EUID == 0)) || die "Нужны права root: sudo bash rp.sh"; }
os_check() {
  local id ver; id=$(. /etc/os-release; echo "${ID:-}"); ver=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
  [[ $ver =~ ^(9|10)$ ]] || warn "Проверялось на Rocky Linux 9/10; здесь: ${id:-?} ${ver:-?}"
  command -v dnf >/dev/null || die "Нужен dnf (семейство RHEL)"
}
arch_map() { # arch_map xray|hy2
  case $(uname -m) in
    x86_64|amd64)  [[ $1 == xray ]] && echo "64" || echo "amd64" ;;
    aarch64|arm64) [[ $1 == xray ]] && echo "arm64-v8a" || echo "arm64" ;;
    *) die "Архитектура $(uname -m) не поддерживается" ;;
  esac
}
fw_kind() { if systemctl is-active --quiet firewalld 2>/dev/null; then echo firewalld; else echo none; fi; }
fw_open() { # идемпотентно и без ALREADY_ENABLED; одна явно выбранная зона
  [[ $(fw_kind) == firewalld ]] || return 0
  local port=${1:-} zone out rc
  local -a opts=()
  [[ $port =~ ^[0-9]+/(tcp|udp)$ ]] || { err "Неверный порт firewalld: $port"; return 1; }
  zone=$(firewall-cmd --get-default-zone 2>/dev/null) || { err "firewalld: не удалось узнать зону"; return 1; }
  [[ -n $zone ]] || { err "firewalld: зона не определена"; return 1; }
  # Runtime и permanent различаются; используем одну и ту же зону.
  # Код 11 ALREADY_ENABLED при конкурентном/повторном добавлении — не ошибка.
  local scope
  for scope in permanent runtime; do
    opts=(--zone="$zone")
    [[ $scope == permanent ]] && opts=(--permanent "${opts[@]}")
    if firewall-cmd "${opts[@]}" --query-port="$port" >/dev/null 2>&1; then continue; fi
    if out=$(firewall-cmd "${opts[@]}" --add-port="$port" 2>&1); then continue; else rc=$?; fi
    if ((rc == 11)) || [[ $out == *ALREADY_ENABLED* ]]; then continue; fi
    err "firewalld: не удалось открыть $port ($scope, зона $zone): ${out:-код $rc}"
    return "${rc:-1}"
  done
  return 0
}
fw_close() { [[ $(fw_kind) == firewalld && $1 =~ ^[0-9] ]] || return 0; firewall-cmd --permanent --remove-port="$1" >/dev/null 2>&1; firewall-cmd --remove-port="$1" >/dev/null 2>&1; return 0; }
fw_trust_if() { [[ $(fw_kind) == firewalld ]] || return 0; firewall-cmd --permanent --zone=trusted --add-interface="$1" >/dev/null 2>&1; firewall-cmd --zone=trusted --add-interface="$1" >/dev/null 2>&1; return 0; }
selinux_fix() { command -v restorecon >/dev/null && restorecon -R "$ETC" "$LIB" "$STATE" /usr/local/bin 2>/dev/null; return 0; }
pkg_install() {
  local p; for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || dnf -y install "$p" || return 1; done
}
# DNF: ограничиваем не только сетевые таймауты, но и полное время каждой операции.
dnf_q() { timeout --signal=TERM --kill-after=10 "${DNF_TIMEOUT:-180}" dnf -y --setopt=timeout=10 --setopt=retries=1 "$@"; }
pkg_epel() { rpm -q epel-release >/dev/null 2>&1 || dnf_q install epel-release; }
# Включить CRB на Rocky 9 без обязательной установки dnf-plugins-core.
# Репозиторий CRB нужен EPEL для части зависимостей.
enable_crb() {
  dnf config-manager --set-enabled crb >/dev/null 2>&1 && return 0
  python3 - <<'PYCRB'
@PY:enable_crb@
PYCRB
}
# QR-коды строит встроенный генератор (rp.py qr): пакет qrencode из EPEL не нужен.
pkg_wg() { # wireguard-tools: в Rocky 9 — EPEL, в 10 — может быть в основном репозитории
  rpm -q wireguard-tools >/dev/null 2>&1 && return 0
  dnf_q install wireguard-tools || { pkg_epel && dnf_q install wireguard-tools; }
}
public_ip() {
  local ip u; for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
    ip=$(curl -4 -fsS -m 8 "$u" 2>/dev/null | tr -d '[:space:]') && [[ $ip =~ ^[0-9.]+$ ]] && { echo "$ip"; return 0; }
  done
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
}
