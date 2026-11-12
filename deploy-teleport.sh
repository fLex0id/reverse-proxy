#!/usr/bin/env bash
# deploy-teleport.sh v1.1.3 — Teleport Community Edition, single-host cluster
# Linux + systemd; Bash >= 4; root; interactive. No unattended modifications to existing installs.
# Deployment: Auth + Proxy + SSH, inbound 443/tcp, internal listeners on loopback.
# Files and data remain owned by the current installation until explicit uninstall.
# Optional: TELEPORT_SETUP_VERSION=18.11.10 bash deploy-teleport.sh
# Optional: TELEPORT_SETUP_ACME_STAGING=1 bash deploy-teleport.sh
# Binary mirror (GitHub Releases assets): TELEPORT_SETUP_GITHUB_REPO=fLex0id/reverse-proxy
# Binary source: TELEPORT_SETUP_BINARY_SOURCE=auto|github|cdn (default auto)
# GitHub mirror release tag: teleport-vX.Y.Z, assets: teleport-vX.Y.Z-linux-ARCH-bin.tar.gz and .sha256
# Offline archives: TELEPORT_SETUP_SHA256=<trusted 64-hex checksum> (verified out of band).
set -o pipefail
set -o nounset
umask 077

SCRIPT_VERSION=1.1.3
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR=/usr/local/bin
CONF=/etc/teleport.yaml
RESOLV_CONF=/etc/resolv.conf
DATA_DIR=/var/lib/teleport
ETC_DIR=/etc/teleport
CERT_DIR=$ETC_DIR/certs
UNIT=/etc/systemd/system/teleport.service
STATE_DIR=/var/lib/teleport-setup
STATE=$STATE_DIR/state.env
LOG=/var/log/teleport-setup.log
CACHE_DIR=/var/cache/teleport-setup
BACKUP_DIR=/var/backups/teleport
TP_RELEASE_API=https://rlz.teleport.sh/versions
TP_CDN=https://cdn.teleport.dev
# Teleport does not publish Linux release binaries in its own GitHub Releases.
# A GitHub Releases mirror must be explicitly populated with the exact official
# archive and its .sha256 sidecar; the archive is never taken from source tarballs.
TP_GITHUB_REPO=${TELEPORT_SETUP_GITHUB_REPO:-fLex0id/reverse-proxy}
TP_BIN_SOURCE=${TELEPORT_SETUP_BINARY_SOURCE:-auto}  # auto (GitHub first, prompt for CDN), github, cdn
ACME_HOME=/opt/acme.sh
ACME_CONF=/etc/acme.sh
ACME_VER=3.1.6
ACME_UNIT=teleport-acme
DOH_VER=2.1.20
DOH_BIN=/usr/local/bin/dnscrypt-proxy
DOH_CONF=/etc/dnscrypt-proxy/teleport-setup.toml
DOH_UNIT=doh-dnscrypt
DOH_LISTEN=127.0.2.1
DNS_BACKUP=$STATE_DIR/dns-backup
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/90-teleport-setup.conf
NM_DROPIN=/etc/NetworkManager/conf.d/90-teleport-setup-dns.conf
TMP_DIR=
ANSWER=
CLUSTER=
NODENAME=
CERT_MODE=
ACME_EMAIL=
ADMIN_USER=
ADMIN_LOGINS=
INVITE=
TP_TARBALL=
TP_TARGET=
LAST_BACKUP=
ARCH=
PKG=

# Display compatibility for Linux virtual consoles (including SPICE/VNC text consoles).
# In a regular SSH/GUI terminal the original Russian/Unicode UI is preserved.
# For a Linux VC: try UTF-8 + an installed Cyrillic font, remove unsupported
# decorative glyphs, and fall back to ASCII transliteration if no font loads.
# Override: TELEPORT_FORCE_ASCII=1 (always ASCII; does not change the console font).
UI_CONSOLE=0
UI_ASCII=0
UI_DISPLAY=

ui_prepare() {
  UI_DISPLAY=$1
  [ "$UI_CONSOLE" -eq 1 ] || return 0
  UI_DISPLAY=${UI_DISPLAY//✔/[OK]}
  UI_DISPLAY=${UI_DISPLAY//✖/[ERROR]}
  UI_DISPLAY=${UI_DISPLAY//•/*}
  UI_DISPLAY=${UI_DISPLAY//›/>}
  UI_DISPLAY=${UI_DISPLAY//━/=}
  UI_DISPLAY=${UI_DISPLAY//—/-}
  UI_DISPLAY=${UI_DISPLAY//→/->}
  UI_DISPLAY=${UI_DISPLAY//«/<}
  UI_DISPLAY=${UI_DISPLAY//»/>}
  [ "$UI_ASCII" -eq 1 ] || return 0
  # Built-in transliteration: no iconv, Python or extra packages required.
  local -a from=(Щ Ш Ч Ж Ю Я Ё Ц Х Э Ы Ъ Ь Й щ ш ч ж ю я ё ц х э ы ъ ь й
                 А Б В Г Д Е З И К Л М Н О П Р С Т У Ф а б в г д е з и к л м н о п р с т у ф)
  local -a to=(Shch Sh Ch Zh Yu Ya Yo Ts Kh E Y '' '' Y shch sh ch zh yu ya yo ts kh e y '' '' y
               A B V G D E Z I K L M N O P R S T U F a b v g d e z i k l m n o p r s t u f)
  local i
  for i in "${!from[@]}"; do UI_DISPLAY=${UI_DISPLAY//${from[$i]}/${to[$i]}}; done
}

init_console_ui() {
  if [ "${TELEPORT_FORCE_ASCII:-0}" = 1 ]; then
    UI_CONSOLE=1; UI_ASCII=1; return 0
  fi
  local dev font dir path loaded=0 loc
  # Avoid a persistent change of the system locale. LC_CTYPE only affects
  # this script and its children, not /etc/locale.conf or /etc/default/locale.
  if [ "$(locale charmap 2>/dev/null)" != UTF-8 ]; then
    for loc in C.UTF-8 C.utf8 en_US.UTF-8 ru_RU.UTF-8; do
      if LC_ALL="$loc" locale charmap 2>/dev/null | grep -qx UTF-8; then
        export LC_CTYPE="$loc"
        break
      fi
    done
  fi
  dev=$(tty 2>/dev/null || :)
  case "$dev" in /dev/tty[0-9]*|/dev/console) UI_CONSOLE=1 ;; *) return 0 ;; esac
  # Tell the kernel virtual terminal to decode output as UTF-8.
  printf '\033%%G' >"$dev" 2>/dev/null || :
  if command -v setfont >/dev/null 2>&1 && [ "${TELEPORT_CONSOLE_FONT:-1}" != 0 ]; then
    for font in LatArCyrHeb-16 latarcyrheb-sun16 Uni2-Fixed16 Uni3-Fixed16 Uni2-VGA16 LatGrkCyr-8x16 UniCyr_8x16 cyr-sun16; do
      for dir in /usr/share/consolefonts /usr/share/kbd/consolefonts /usr/lib/kbd/consolefonts; do
        for path in "$dir/$font.psfu.gz" "$dir/$font.psf.gz" "$dir/$font.psfu" "$dir/$font.psf"; do
          [ -r "$path" ] || continue
          if setfont -C "$dev" "$path" >/dev/null 2>&1; then loaded=1; break 3; fi
        done
      done
    done
  fi
  if [ "$loaded" -eq 0 ]; then
    UI_ASCII=1
    printf '[INFO] No Cyrillic console font available; ASCII UI enabled.\n' >&2
  fi
}

# IPv4 for every curl request made by this installer, including GitHub redirects.
curl4() { command curl -4 "$@"; }

say() { ui_prepare "$*"; printf '%s\n' "$UI_DISPLAY"; }
ok() { ui_prepare "$*"; if [ "$UI_CONSOLE" -eq 1 ]; then printf '  [OK] %s\n' "$UI_DISPLAY"; else printf '  ✔ %s\n' "$UI_DISPLAY"; fi; }
info() { ui_prepare "$*"; if [ "$UI_CONSOLE" -eq 1 ]; then printf '  [i] %s\n' "$UI_DISPLAY"; else printf '  • %s\n' "$UI_DISPLAY"; fi; }
warn() { ui_prepare "$*"; printf '  ! %s\n' "$UI_DISPLAY" >&2; }
err() { ui_prepare "$*"; if [ "$UI_CONSOLE" -eq 1 ]; then printf '  [ERROR] %s\n' "$UI_DISPLAY" >&2; else printf '  ✖ %s\n' "$UI_DISPLAY" >&2; fi; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }
die() { err "$*"; err "Журнал: $LOG"; exit 1; }
hdr() { ui_prepare "$*"; if [ "$UI_CONSOLE" -eq 1 ]; then printf '\n========== %s ==========\n' "$UI_DISPLAY"; else printf '\n━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n' "$UI_DISPLAY"; fi; }
cleanup() { if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then rm -rf -- "$TMP_DIR"; fi; }
trap cleanup EXIT
trap 'printf "\n"; warn "Прервано пользователем"; exit 130' INT

# CRITICAL: return the actual status, not the status of an if without else.
run() {
  local desc=$1 rc; shift
  log "RUN: $*"
  if "$@" </dev/null >>"$LOG" 2>&1; then
    ok "$desc"; return 0
  else
    rc=$?
    err "$desc (exit $rc)"
    tail -n 12 "$LOG" | sed 's/^/    /' >&2
    return "$rc"
  fi
}
ask() {
  local prompt=$1 default=${2-} a
  if [ -n "$default" ]; then
    ui_prepare "  › $prompt: "
    read -r -e -p "$UI_DISPLAY" -i "$default" a || die "Ввод прерван"
  else
    ui_prepare "  › $prompt: "
    read -r -e -p "$UI_DISPLAY" a || die "Ввод прерван"
  fi
  ANSWER=$a
}
ask_yn() {
  local prompt=$1 def=${2:-n} a
  while :; do
    ui_prepare "  › $prompt [$([ "$def" = y ] && echo 'Д/н' || echo 'д/Н')]: "
    read -r -p "$UI_DISPLAY" a || die "Ввод прерван"
    a=${a,,}; [ -n "$a" ] || a=$def
    case "$a" in y|yes|д|да|1) return 0 ;; n|no|н|нет|0) return 1 ;; esac
    warn "Ответьте да или нет"
  done
}
ask_num() {
  local prompt=$1 max=$2 def=${3:-0} a
  while :; do
    ui_prepare "  › $prompt [$def]: "
    read -r -p "$UI_DISPLAY" a || die "Ввод прерван"
    a=${a:-$def}; a=${a%[.)]}
    if [[ $a =~ ^[0-9]+$ ]] && [ "${#a}" -le 5 ] && [ "$((10#$a))" -le "$max" ]; then
      ANSWER=$((10#$a)); return 0
    fi
    warn "Нужен номер от 0 до $max"
  done
}
ask_secret() {
  local a
  while :; do
    ui_prepare "  › $1 (скрытый ввод): "
    read -r -s -p "$UI_DISPLAY" a || die "Ввод прерван"
    printf '\n'
    [ -n "$a" ] && { ANSWER=$a; return; }
    warn "Значение не может быть пустым"
  done
}
is_ip() {
  local s=$1 part; local -a parts=()
  [[ $s =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; read -r -a parts <<<"$s"
  for part in "${parts[@]}"; do [ "$part" -le 255 ] || return 1; done
}
is_domain() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; }
ask_domain() {
  local d
  while :; do
    ask "$1" "${2:-}"; d=${ANSWER,,}; d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%.}
    if is_domain "$d" && [ "${#d}" -le 253 ]; then ANSWER=$d; return; fi
    warn "Введите FQDN латиницей, например teleport.example.com"
  done
}
ask_email() {
  while :; do
    ask "$1" "${2:-}"
    if [[ $ANSWER =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then return; fi
    warn "Некорректный e-mail"
  done
}
ask_username() {
  while :; do
    ask "$1" "${2:-}"
    if [[ $ANSWER =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$ ]]; then return; fi
    warn "Имя: латиница, цифры, . _ @ -; максимум 64 символа"
  done
}
ask_logins() {
  local s item bad out
  while :; do
    ask "$1" "${2:-root}"; s=${ANSWER//[,;]/ }; bad=; out=
    for item in $s; do
      if [[ $item =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; then
        [[ ,$out, == *,$item,* ]] || out=${out:+$out,}$item
      else bad="$bad $item"; fi
    done
    if [ -n "$out" ] && [ -z "$bad" ]; then ANSWER=$out; return; fi
    warn "Недопустимые логины:$bad"
  done
}
state_get() { [ -f "$STATE" ] && grep -m1 "^${1}=" "$STATE" | cut -d= -f2- || :; }
state_set() {
  local k=$1 v=$2 tmp
  mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || return 1
  if [ -f "$STATE" ]; then grep -v "^${k}=" "$STATE" >"$tmp" || :; fi
  printf '%s=%s\n' "$k" "$v" >>"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$STATE"
}
fix_context() { if command -v restorecon >/dev/null 2>&1; then restorecon -RF "$@" >>"$LOG" 2>&1 || :; fi; }

prechecks() {
  [ "$(id -u)" -eq 0 ] || die "Нужны права root"
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "Нужен Bash >= 4"
  [ -d /run/systemd/system ] || die "Нужен systemd"
  case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; armv7l) ARCH=arm ;; *) die "Архитектура не поддерживается" ;; esac
  if ldd --version 2>&1 | grep -qi musl; then die "Требуется glibc (не musl)"; fi
  PKG=
  for p in apt-get dnf yum zypper pacman; do
    if command -v "$p" >/dev/null 2>&1; then PKG=$p; break; fi
  done
  [ -n "$PKG" ] || die "Не найден пакетный менеджер"
  info "ОС: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}"); архитектура: $ARCH"
  local disk; disk=$(df -Pm /var | awk 'NR==2{print $4}')
  if [ "${disk:-0}" -lt 2500 ]; then
    warn "Свободно в /var: ${disk:-?} МБ — для Teleport и резервных копий мало места"
    ask_yn "Продолжить?" n || die "Недостаточно места"
  fi
}
pkg_install() {
  case "$PKG" in
    apt-get) run "Обновление apt" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq || return 1
             run "Установка зависимостей" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends "$@" ;;
    dnf|yum) run "Установка зависимостей" "$PKG" -y -q install "$@" ;;
    zypper) run "Установка зависимостей" zypper --non-interactive install "$@" ;;
    pacman) run "Установка зависимостей" pacman -Sy --noconfirm --needed "$@" ;;
  esac
}
deps() {
  local cmd; local -a need=()
  for cmd in curl tar gzip openssl ss pkill flock sha256sum timeout getent; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    case "$cmd:$PKG" in
      ss:apt-get) need+=(iproute2) ;; ss:*) need+=(iproute) ;;
      pkill:apt-get) need+=(procps) ;; pkill:*) need+=(procps-ng) ;;
      flock:*) need+=(util-linux) ;; sha256sum:*) need+=(coreutils) ;;
      timeout:*) need+=(coreutils) ;; getent:*) need+=(glibc-common) ;;
      *) need+=("$cmd") ;;
    esac
  done
  [ "${#need[@]}" -eq 0 ] || pkg_install "${need[@]}" || die "Не удалось поставить зависимости"
}
time_synced() { [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; }
time_check() {
  if time_synced; then ok "Время синхронизировано: $(date '+%F %T %Z')"; return 0; fi
  warn "NTP пока не синхронизирован: $(date '+%F %T %Z')"
  if ! command -v chronyc >/dev/null 2>&1 &&
     [ "$(timedatectl show -p CanNTP --value 2>/dev/null)" != yes ]; then
    warn "Служба NTP не найдена: пробую установить chrony"
    if pkg_install chrony; then
      systemctl enable --now chronyd >>"$LOG" 2>&1 ||
        systemctl enable --now chrony >>"$LOG" 2>&1 || :
    fi
  fi
  if command -v chronyc >/dev/null 2>&1; then
    chronyc -a 'burst 4/4' >>"$LOG" 2>&1 || :
    chronyc -a makestep >>"$LOG" 2>&1 || :
  fi
  if timedatectl show -p CanNTP --value 2>/dev/null | grep -qx yes; then
    timedatectl set-ntp true >>"$LOG" 2>&1 || :
  fi
  local i; for i in 1 2 3 4 5 6 7 8; do time_synced && { ok "NTP синхронизирован"; return 0; }; sleep 2; done
  warn "NTP не подтверждён. Проверьте дату перед ACME и Teleport. Время по HTTP не устанавливается."
}

# DNS management is optional, transactionally reversible and namespaced to this script.
dns_manager() {
  if systemctl is-active -q systemd-resolved && readlink "$RESOLV_CONF" 2>/dev/null | grep -q systemd/resolve; then echo resolved
  elif systemctl is-active -q NetworkManager; then echo nm
  else echo file; fi
}
dns_test() {
  local h bad=0
  for h in api.github.com github.com rlz.teleport.sh acme-v02.api.letsencrypt.org; do
    if timeout 8 getent ahostsv4 "$h" >/dev/null 2>&1; then ok "DNS $h"; else err "DNS $h"; bad=1; fi
  done
  return "$bad"
}
dns_backup_once() {
  [ -d "$DNS_BACKUP" ] && return 0
  [ ! -e "$RESOLVED_DROPIN" ] || { err "Чужой файл $RESOLVED_DROPIN"; return 1; }
  [ ! -e "$NM_DROPIN" ] || { err "Чужой файл $NM_DROPIN"; return 1; }
  [ ! -e "/etc/systemd/system/$DOH_UNIT.service" ] || { err "Чужой сервис $DOH_UNIT"; return 1; }
  [ ! -e "$DOH_CONF" ] || { err "Чужой конфиг $DOH_CONF"; return 1; }
  mkdir -p "$DNS_BACKUP"; chmod 700 "$DNS_BACKUP"
  dns_manager >"$DNS_BACKUP/manager"
  if ! cp -a "$RESOLV_CONF" "$DNS_BACKUP/resolv.conf"; then rm -rf "$DNS_BACKUP"; return 1; fi
}
dns_set_resolv() {
  local list=$1 keep tmp
  keep=$(grep -E '^(search|domain)[[:space:]]' "$RESOLV_CONF" 2>/dev/null || :)
  tmp=$(mktemp "$(dirname "$RESOLV_CONF")/.teleport-resolv.XXXXXX") || return 1
  { printf '# Managed by deploy-teleport.sh; restore from menu\n'; [ -z "$keep" ] || printf '%s\n' "$keep"
    for ip in $list; do printf 'nameserver %s\n' "$ip"; done
    printf 'options timeout:2 attempts:2\n'; } >"$tmp"
  chmod 644 "$tmp"
  rm -f "$RESOLV_CONF"
  mv -f "$tmp" "$RESOLV_CONF"
  fix_context "$RESOLV_CONF"
}
dns_apply_resolver() {
  local addresses=$1 manager
  manager=$(cat "$DNS_BACKUP/manager")
  case "$manager" in
    resolved)
      mkdir -p "${RESOLVED_DROPIN%/*}"
      printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\nDNSOverTLS=no\n' "$addresses" >"$RESOLVED_DROPIN"
      systemctl restart systemd-resolved >>"$LOG" 2>&1 ;;
    nm)
      # Explicit opt-in is required: NetworkManager's global DNS plugin will be changed.
      mkdir -p "${NM_DROPIN%/*}"
      printf '[main]\ndns=none\n' >"$NM_DROPIN"
      systemctl reload NetworkManager >>"$LOG" 2>&1 || return 1
      dns_set_resolv "$addresses" ;;
    file) dns_set_resolv "$addresses" ;;
    *) return 1 ;;
  esac
}
dns_restore() {
  [ -d "$DNS_BACKUP" ] || { info "DNS не изменён этим скриптом"; return 0; }
  local manager; manager=$(cat "$DNS_BACKUP/manager")
  # First restore resolver; only then stop the DoH backend.
  rm -f "$RESOLVED_DROPIN" "$NM_DROPIN"
  local restore_tmp="$(dirname "$RESOLV_CONF")/.teleport-resolv-restore.$$"
  rm -f "$restore_tmp"
  cp -a "$DNS_BACKUP/resolv.conf" "$restore_tmp" || { err "Не удалось подготовить восстановление resolv.conf"; return 1; }
  mv -Tf "$restore_tmp" "$RESOLV_CONF" || { err "Не удалось вернуть resolv.conf"; return 1; }
  fix_context "$RESOLV_CONF"
  case "$manager" in
    resolved) systemctl restart systemd-resolved >>"$LOG" 2>&1 || warn "Не удалось перезапустить resolved" ;;
    nm) systemctl reload NetworkManager >>"$LOG" 2>&1 || warn "Не удалось перечитать NetworkManager" ;;
  esac
  systemctl disable --now "$DOH_UNIT.service" >>"$LOG" 2>&1 || :
  rm -f "/etc/systemd/system/$DOH_UNIT.service" "$DOH_CONF"
  [ ! -f "$DNS_BACKUP/doh_binary_owned" ] || rm -f "$DOH_BIN"
  rmdir "${DOH_CONF%/*}" 2>/dev/null || :
  systemctl daemon-reload >>"$LOG" 2>&1 || :
  if dns_test; then
    rm -rf -- "$DNS_BACKUP"
    ok "Исходный DNS восстановлен и проверен"
  else
    warn "Конфигурация возвращена, но DNS-проверка не прошла. Резервная копия сохранена: $DNS_BACKUP"
    return 1
  fi
}
# DNS stamp: sdns://Ag... for DNS-over-HTTPS (DNSCrypt specification).
doh_stamp() {
  local ip=$1 host=$2 path=/dns-query
  { printf '\x02\x00\x00\x00\x00\x00\x00\x00\x00'
    printf '%b%s' "$(printf '\\x%02x' "${#ip}")" "$ip"
    printf '\x00'
    printf '%b%s' "$(printf '\\x%02x' "${#host}")" "$host"
    printf '%b%s' "$(printf '\\x%02x' "${#path}")" "$path"
  } | openssl base64 -A | tr '+/' '-_' | tr -d '='
}
doh_install_bin() {
  [ -x "$DOH_BIN" ] && return 0
  local da=$ARCH name file dir
  [ "$ARCH" != amd64 ] || da=x86_64
  name="dnscrypt-proxy-linux_${da}-${DOH_VER}.tar.gz"
  dir=$(mktemp -d "$TMP_DIR/doh.XXXXXX") || return 1
  file="$dir/$name"
  run "Загрузка dnscrypt-proxy" curl4 -fsSL --retry 3 -m 180 -o "$file" "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/$DOH_VER/$name" || return 1
  tar -xzf "$file" -C "$dir" "linux-${da}/dnscrypt-proxy" >>"$LOG" 2>&1 || { err "Архив dnscrypt-proxy не подходит"; return 1; }
  install -m 0755 "$dir/linux-${da}/dnscrypt-proxy" "$DOH_BIN" || return 1
  touch "$DNS_BACKUP/doh_binary_owned"
  fix_context "$DOH_BIN"
}
doh_configure() {
  local ips=$1 host=$2 ip i=0 name stamp names=; local -a entries=()
  for ip in $ips; do
    i=$((i + 1)); name="server$i"; names="${names:+$names, }'$name'"
    stamp=$(doh_stamp "$ip" "$host") || return 1
    entries+=("[static.$name]" "stamp = 'sdns://$stamp'")
  done
  mkdir -p "${DOH_CONF%/*}"
  {
    printf 'listen_addresses = [\x27%s:53\x27]\n' "$DOH_LISTEN"
    printf 'ipv4_servers = true\nipv6_servers = false\ndnscrypt_servers = false\ndoh_servers = true\nodoh_servers = false\n'
    printf 'server_names = [%s]\nlb_strategy = \x27first\x27\ntimeout = 3000\nkeepalive = 30\ncache = true\ncache_size = 4096\n' "$names"
    printf 'netprobe_timeout = 15\nnetprobe_address = \x27%s:443\x27\nignore_system_dns = true\n' "${ips%% *}"
    printf 'bootstrap_resolvers = [\x27%s:53\x27]\nlog_level = 2\n\n[static]\n' "${ips%% *}"
    printf '%s\n' "${entries[@]}"
  } >"$DOH_CONF"
  chmod 600 "$DOH_CONF"
  "$DOH_BIN" -config "$DOH_CONF" -check >>"$LOG" 2>&1 || return 1
  cat >"/etc/systemd/system/$DOH_UNIT.service" <<EOF
[Unit]
Description=Teleport setup local DoH resolver
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$DOH_BIN -config $DOH_CONF
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  if systemctl is-active -q "$DOH_UNIT.service"; then
    run "Перезапуск DoH" systemctl restart "$DOH_UNIT.service"
  else
    run "Запуск DoH" systemctl enable --now "$DOH_UNIT.service"
  fi || return 1
  # A systemd active state alone does not prove functioning encrypted upstream.
  if ! systemctl is-active -q "$DOH_UNIT.service"; then
    err "DoH служба не запущена"; return 1
  fi
  info "Проверка реального DoH-запроса (через dnscrypt-proxy)"
  if ! timeout 25 "$DOH_BIN" -config "$DOH_CONF" -resolve example.com >>"$LOG" 2>&1; then
    err "DoH не подтвердил разрешение example.com через защищённый upstream"
    return 1
  fi
  if ! ss -Hlun '( sport = :53 )' 2>/dev/null | grep -Fq "${DOH_LISTEN}:53"; then
    err "DoH активен, но не слушает ${DOH_LISTEN}:53"
    return 1
  fi
  ok "DoH запущен, слушает ${DOH_LISTEN}:53 и разрешает имена через DoH"
}
DNS_PROVIDERS=(
  'Cloudflare|1.1.1.1 1.0.0.1|cloudflare-dns.com'
  'Google|8.8.8.8 8.8.4.4|dns.google'
  'Quad9|9.9.9.9 149.112.112.112|dns.quad9.net'
  'AdGuard без фильтра|94.140.14.140 94.140.14.141|unfiltered.adguard-dns.com'
  'Яндекс|77.88.8.8 77.88.8.1|common.dot.dns.yandex.net'
)
dns_change() {
  local n label ips host mode=plain i p manager snapshot chk
  hdr "Изменение DNS (необязательная функция)"
  i=0; for n in "${DNS_PROVIDERS[@]}"; do i=$((i+1)); IFS='|' read -r label ips host <<<"$n"; say "  $i) $label — $ips"; done
  say "  $((i+1))) Свои IPv4-адреса"; say "  0) Отмена"
  ask_num "DNS-провайдер" "$((i+1))" 0; p=$ANSWER
  [ "$p" -ne 0 ] || return 0
  if [ "$p" -le "${#DNS_PROVIDERS[@]}" ]; then
    IFS='|' read -r label ips host <<<"${DNS_PROVIDERS[$((p-1))]}"
  else
    ask "IPv4 через пробел (DoH для своих IP недоступен)" ""; ips=$ANSWER; host=
    [ -n "$ips" ] || { err "Нужен адрес"; return 1; }
    for n in $ips; do is_ip "$n" || { err "Некорректный IPv4: $n"; return 1; }; done
  fi
  if [ -n "$host" ]; then say "  1) Обычный DNS   2) DNS-over-HTTPS"; ask_num "Режим" 2 1; [ "$ANSWER" -eq 2 ] && mode=doh; [ "$ANSWER" -eq 0 ] && return 0; fi
  manager=$(dns_manager)
  warn "Изменение DNS может прервать SSH/VPN и локальное разрешение имён (*.lan)."
  [ "$manager" != nm ] || warn "NetworkManager: будет временно изменён способ управления resolv.conf."
  ask_yn "Продолжить изменение DNS?" n || return 0
  # Store current managed state for rollback on every switch, without touching original backup.
  snapshot=$(mktemp -d "$TMP_DIR/dns-snapshot.XXXXXX") || return 1
  cp -a "$RESOLV_CONF" "$snapshot/resolv.conf" || return 1
  for n in "$RESOLVED_DROPIN" "$NM_DROPIN" "$DOH_CONF" "/etc/systemd/system/$DOH_UNIT.service"; do
    [ ! -e "$n" ] || { mkdir -p "$snapshot$(dirname "$n")"; cp -a "$n" "$snapshot$n"; }
  done
  local was_doh=0 had_backup=0
  systemctl is-active -q "$DOH_UNIT" && was_doh=1
  [ -d "$DNS_BACKUP" ] && had_backup=1
  dns_backup_once || return 1
  chk=0
  if [ "$mode" = doh ]; then
    doh_install_bin && doh_configure "$ips" "$host" && dns_apply_resolver "$DOH_LISTEN" && dns_test || chk=1
  else
    dns_apply_resolver "$ips" && dns_test || chk=1
  fi
  if [ "$chk" -eq 0 ]; then
    if [ "$mode" = plain ]; then systemctl disable --now "$DOH_UNIT" >>"$LOG" 2>&1 || :; fi
    state_set DNS_MODE "$label/$mode"
    if [ "$mode" = doh ]; then
      ok "DoH включён: системный DNS -> ${DOH_LISTEN}:53 -> HTTPS ($host)"
    else
      ok "DNS переключён: $label ($mode)"
    fi
    return 0
  fi
  err "DNS не прошёл проверку, восстанавливаю предыдущую конфигурацию"
  if cp -a "$snapshot/resolv.conf" "$(dirname "$RESOLV_CONF")/.teleport-dns-rollback.$$"; then
    mv -Tf "$(dirname "$RESOLV_CONF")/.teleport-dns-rollback.$$" "$RESOLV_CONF" || :
  fi
  for n in "$RESOLVED_DROPIN" "$NM_DROPIN" "$DOH_CONF" "/etc/systemd/system/$DOH_UNIT.service"; do
    rm -f "$n"
    if [ -e "$snapshot$n" ]; then mkdir -p "$(dirname "$n")"; cp -a "$snapshot$n" "$n"; fi
  done
  systemctl daemon-reload >>"$LOG" 2>&1 || :
  case "$manager" in resolved) systemctl restart systemd-resolved >>"$LOG" 2>&1 || : ;; nm) systemctl reload NetworkManager >>"$LOG" 2>&1 || : ;; esac
  if [ "$was_doh" -eq 1 ]; then systemctl restart "$DOH_UNIT" >>"$LOG" 2>&1 || :; else systemctl disable --now "$DOH_UNIT" >>"$LOG" 2>&1 || :; fi
  if [ "$had_backup" -eq 0 ]; then
    # If we installed dnscrypt-proxy for this failed operation, do not orphan it.
    [ ! -f "$DNS_BACKUP/doh_binary_owned" ] || rm -f -- "$DOH_BIN"
    rm -rf -- "$DNS_BACKUP"
  fi
  dns_test || warn "DNS всё ещё не работает: проверьте сеть вручную"
  return 1
}
dns_step() {
  if dns_test; then ok "Системный DNS работает"; else warn "Некоторые имена не разрешаются"; fi
  ask_yn "Изменить системный DNS? (не обязательно)" n && dns_change || :
}

# Advisory only: a valid local FQDN resolution does not prove public reachability.
dns_check_domain() {
  local name=$1 mode=$2 resolved publicip
  hdr "Домен и доступность"
  resolved=$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || :)
  if [ -z "$resolved" ]; then
    warn "$name не разрешается локальным DNS. Клиентам понадобится корректная A-запись/hosts."
  else
    info "$name → $resolved"
  fi
  publicip=$(curl4 -fsSL --max-time 7 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || :)
  if is_ip "$publicip"; then info "Публичный IPv4 (по ipify): $publicip"; fi
  if [ "$mode" = acme-teleport ]; then
    warn "Встроенный ACME требует публичный DNS и доступ к TCP/443 из интернета."
    if [ -n "$resolved" ] && is_ip "$publicip" && [[ " $resolved " != *" $publicip "* ]]; then
      warn "Текущая DNS-резолюция не совпадает с публичным IP (NAT/split DNS допустимы)."
    fi
  elif [ -z "$resolved" ]; then
    warn "При DNS-01 сертификат выпустится, но клиенты не найдут этот сервер без DNS/hosts."
  fi
}

# Installation: conservative by design. Neither packages nor /opt/teleport are overwritten.
tp_installed() {
  [ -f "$UNIT" ] || [ -f /lib/systemd/system/teleport.service ] || [ -f /usr/lib/systemd/system/teleport.service ] ||
  [ -x "$BIN_DIR/teleport" ] || command -v teleport >/dev/null 2>&1
}
tp_owned() {
  [ -f "$STATE" ] && [ -f "$UNIT" ] && [ -x "$BIN_DIR/teleport" ] || return 1
  local p
  p=$(readlink -f "$BIN_DIR/teleport")
  [[ $p == "$BIN_DIR/teleport" ]] || return 1
  if command -v rpm >/dev/null 2>&1 && rpm -qf "$p" >/dev/null 2>&1; then return 1; fi
  if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$p" >/dev/null 2>&1; then return 1; fi
  return 0
}
tp_version() { "$BIN_DIR/teleport" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v || :; }
# Teleport's maintainers publish the current stable version through rlz.teleport.sh.
# GitHub Releases is no longer updated consistently (the last release object is
# v18.10.0, although newer stable binaries are published by Teleport).
# The APT repository must not be used to discover releases: it can contain
# non-public/test versions (e.g. 999.0.3).
tp_valid_version() {
  local v=${1#v} major minor patch
  [[ $v =~ ^([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{1,3})$ ]] || return 1
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}; patch=${BASH_REMATCH[3]}
  # Reject leading zeros, pseudo-versions and implausible major releases.
  [ "$major" = "$((10#$major))" ] && [ "$minor" = "$((10#$minor))" ] &&
    [ "$patch" = "$((10#$patch))" ] && [ "$major" -ge 10 ] && [ "$major" -lt 100 ]
}
tp_release_latest() {
  local payload matched version
  payload=$(curl4 --proto '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 -m 25 \
    "$TP_RELEASE_API" 2>>"$LOG") || return 1
  # We need only the top-level `latest` string; no jq dependency for minimal OSes.
  # Reject anything but a plain stable numeric version (no -rc/-dev/build).
  matched=$(printf '%s' "$payload" | grep -oEm1 '"latest"[[:space:]]*:[[:space:]]*"v?[0-9]+\.[0-9]+\.[0-9]+"') || return 1
  version=${matched%\"}; version=${version##*\"}; version=${version#v}
  tp_valid_version "$version" || return 1
  printf '%s\n' "$version"
}

local_tarball() {
  local v=$1 f name
  for f in "$(pwd)"/teleport-v"$v"-linux-"$ARCH"-bin.tar.gz \
           "$SCRIPT_DIR"/teleport-v"$v"-linux-"$ARCH"-bin.tar.gz; do
    [ ! -f "$f" ] || { echo "$f"; return 0; }
  done
  return 1
}
tp_pick_version() {
  local version
  TP_TARGET=
  if [ -n "${TELEPORT_SETUP_VERSION:-}" ]; then
    version=${TELEPORT_SETUP_VERSION#v}
    tp_valid_version "$version" || { err "Некорректная версия: $TELEPORT_SETUP_VERSION (только X.Y.Z, без pre-release)"; return 1; }
    TP_TARGET=$version
    info "Версия задана вручную: $TP_TARGET; SHA256 обязателен"
    return 0
  fi
  info "Запрос последнего стабильного выпуска Teleport (IPv4)..."
  if version=$(tp_release_latest); then
    TP_TARGET=$version
    ok "Последний стабильный Teleport: $TP_TARGET (официальный сервис релизов)"
    return 0
  fi
  warn "Не удалось получить подтверждённую стабильную версию с $TP_RELEASE_API"
  warn "Версия из APT-индекса не используется; GitHub Releases может отставать от бинарных выпусков."
  while :; do
    ask "Укажите точную стабильную версию X.Y.Z (пусто — отмена)" ""
    version=${ANSWER#v}
    if [ -z "$version" ]; then err "Не удалось определить версию Teleport"; return 1; fi
    if tp_valid_version "$version"; then
      TP_TARGET=$version
      warn "Ручная версия будет установлена только при наличии проверенной SHA256-суммы"
      return 0
    fi
    warn "Некорректная версия; допустимо, например, 18.11.10"
  done
}

# Validate the GitHub release repository path; never permit arbitrary URLs/hosts.
tp_github_repo_valid() {
  [[ $TP_GITHUB_REPO =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$ ]]
}

# Only release assets count as binaries: GitHub's source tarball is not Teleport.
# Returns: 0 (asset listed), 1 (release missing), 2 (GitHub API unavailable).
tp_github_assets() {
  local v=$1 file=$2 payload
  tp_github_repo_valid || { err "Некорректный GitHub репозиторий: $TP_GITHUB_REPO"; return 2; }
  info "Проверка GitHub Releases: $TP_GITHUB_REPO / teleport-v$v (IPv4)"
  if ! payload=$(curl4 --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
      --connect-timeout 10 --max-time 20 --retry 1 \
      -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$TP_GITHUB_REPO/releases/tags/teleport-v$v" 2>>"$LOG"); then
    warn "GitHub API не вернул выпуск v$v (подробности: $LOG)"; return 2
  fi
  if ! grep -Eq '"name"[[:space:]]*:[[:space:]]*"'"$file"'"' <<<"$payload"; then
    warn "В GitHub Releases нет готового Linux-архива: $file"
    return 1
  fi
  return 0
}

# Validate official-style SHA256 sidecar (hex + the exact archive filename).
# This verifies integrity; when mirror and checksum share an account,
# authenticity still depends on the integrity of the mirror account.
tp_read_checksum() {
  local url=$1 archive=$2 max_time=${3:-25} output sum name rest
  output=$(curl4 --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL \
    --connect-timeout 8 --max-time "$max_time" --retry 0 "$url" 2>>"$LOG") || return 1
  read -r sum name rest <<<"$output"
  sum=${sum,,}
  [[ $sum =~ ^[a-f0-9]{64}$ ]] && [ -z "${rest:-}" ] && \
    { [ "$name" = "$archive" ] || [ "$name" = "*$archive" ]; } || return 1
  printf '%s\n' "$sum"
}

# An absent mirror must not silently redirect the user back to the blocked CDN.
tp_select_source() {
  local v=$1 file=$2 gh_rc
  TP_BINARY_BASE=; TP_HASH_BASE=
  case "$TP_BIN_SOURCE" in github|cdn|auto) : ;; *) err "TELEPORT_SETUP_BINARY_SOURCE: допустимо auto, github, cdn"; return 1 ;; esac
  if [ "$TP_BIN_SOURCE" != cdn ]; then
    gh_rc=0
    tp_github_assets "$v" "$file" || gh_rc=$?
    if [ "$gh_rc" -eq 0 ]; then
      TP_BINARY_BASE="https://github.com/$TP_GITHUB_REPO/releases/download/teleport-v$v"
      TP_HASH_BASE=$TP_BINARY_BASE
      ok "Выбран GitHub Releases ($TP_GITHUB_REPO)"
      return 0
    fi
    [ "$TP_BIN_SOURCE" != github ] || {
      err "Источник github выбран строго, но бинарника нет. Нужен GitHub Release teleport-v$v с активами $file и $file.sha256."
      return 1
    }
    warn "У официального gravitational/teleport нет Linux-бинарников в GitHub Releases."
    warn "Добавьте официальный архив и файл SHA256 в GitHub Release своего зеркала либо используйте локальный архив."
    if ! ask_yn "Попробовать официальный CDN вместо GitHub? (со скоростным тайм-аутом)" n; then
      err "Скачивание отменено; никакой неподтверждённый архив не запускается"
      return 1
    fi
  fi
  TP_BINARY_BASE=$TP_CDN
  TP_HASH_BASE=$TP_CDN
  info "Выбран официальный CDN (IPv4, тайм-аут при отсутствии передачи данных)"
}

# Fetch archive from GitHub Releases mirror or official CDN; SHA256 is mandatory.
# Never consider a source archive / GitHub tag to be a compiled binary.
tp_fetch() {
  local v=$1 file sum f part attempt actual localfile remote_url curl_rc
  tp_valid_version "$v" || { err "Неподдерживаемая версия Teleport: $v"; return 1; }
  file="teleport-v${v}-linux-${ARCH}-bin.tar.gz"
  localfile=$(local_tarball "$v") || localfile=

  # Offline override is only valid when explicitly provided by the operator.
  if [ -n "${TELEPORT_SETUP_SHA256:-}" ]; then
    sum=${TELEPORT_SETUP_SHA256,,}
    [[ $sum =~ ^[a-f0-9]{64}$ ]] || { err "TELEPORT_SETUP_SHA256: нужно 64 hex-символа"; return 1; }
    warn "Используется явно заданная SHA256: подтвердите её происхождение независимо"
    if [ -n "$localfile" ]; then
      actual=$(sha256sum "$localfile" | awk '{print $1}') || return 1
      if [ "$actual" = "$sum" ]; then TP_TARBALL=$localfile; ok "Локальный архив проверен по SHA256"; return 0; fi
      err "Локальный архив имеет неправильную SHA256"; return 1
    fi
  fi

  tp_select_source "$v" "$file" || return 1
  remote_url="$TP_BINARY_BASE/$file"
  if [ -z "${sum:-}" ]; then
    info "Получение SHA256 для $file (IPv4, ожидание не более 25 секунд)"
    if [ "$TP_BINARY_BASE" = "$TP_CDN" ]; then
      sum=$(tp_read_checksum "$TP_CDN/$file.sha256" "$file") || {
        err "Не удалось получить проверяемую SHA256 с официального CDN"; return 1;
      }
    else
      # Prefer official checksum, but only wait briefly for a blocked CDN.
      if sum=$(tp_read_checksum "$TP_CDN/$file.sha256" "$file" 8); then
        info "SHA256 получена с официального CDN"
      else
        sum=$(tp_read_checksum "$TP_HASH_BASE/$file.sha256" "$file") || {
          err "В зеркале GitHub нет корректного $file.sha256"; return 1;
        }
        warn "SHA256 взята из того же GitHub-зеркала: это контроль целостности, но не независимое подтверждение происхождения"
      fi
    fi
  fi

  mkdir -p "$CACHE_DIR" || return 1
  if [ -n "$localfile" ]; then
    actual=$(sha256sum "$localfile" | awk '{print $1}') || return 1
    if [ "$actual" = "$sum" ]; then TP_TARBALL=$localfile; ok "Локальный архив подтверждён по SHA256"; return 0; fi
    warn "Локальный архив не совпадает с контрольной суммой; будет загружен новый"
  fi
  f="$CACHE_DIR/$file"; part="$f.part"
  if [ -f "$f" ]; then
    actual=$(sha256sum "$f" | awk '{print $1}') || return 1
    if [ "$actual" = "$sum" ]; then TP_TARBALL=$f; ok "Кэш: SHA256 подтверждена"; return 0; fi
    rm -f -- "$f"  # invalid completed file must not be used as a partial
  fi
  for attempt in 1 2 3; do
    info "Загрузка Teleport v$v, попытка $attempt/3, IPv4; отмена при скорости менее 2 КБ/с в течение 30 секунд"
    # Keep .part between retries; --continue-at - resumes if server supports it.
    # -4 even on redirected release-assets.githubusercontent.com downloads.
    curl_rc=0
    curl4 --proto '=https' --proto-redir '=https' --tlsv1.2 -fL \
        --connect-timeout 12 --max-time 300 --speed-limit 2048 --speed-time 30 \
        --progress-bar -C - -o "$part" "$remote_url" || curl_rc=$?
    if [ "$curl_rc" -ne 0 ]; then
      # curl code 33 means the server refuses byte-range resumption.
      if [ "$curl_rc" -eq 33 ]; then
        rm -f -- "$part"
        warn "Сервер не поддержал докачку; следующая попытка начнётся с нуля"
      else
        warn "Загрузка не идёт (curl exit $curl_rc); сохранил частичный файл для докачки"
      fi
      continue
    fi
    actual=$(sha256sum "$part" | awk '{print $1}') || return 1
    if [ "$actual" = "$sum" ]; then
      mv -f -- "$part" "$f" || return 1
      TP_TARBALL=$f; ok "Teleport $v получен и проверен по SHA256"; return 0
    fi
    rm -f -- "$part"
    err "Контрольная сумма не совпала (попытка $attempt)"
  done
  err "Не удалось скачать Teleport $v. Установку останавливаю, лог: $LOG"
  return 1
}

tp_install_bins() {
  local dest b staged; local -a bins=(teleport tctl tsh tbot fdpass-teleport)
  dest=$(mktemp -d "$TMP_DIR/teleport-extract.XXXXXX") || return 1
  tar -tzf "$TP_TARBALL" >/dev/null 2>>"$LOG" || return 1
  tar -xzf "$TP_TARBALL" -C "$dest" \
    teleport/teleport teleport/tctl teleport/tsh teleport/tbot teleport/fdpass-teleport \
    >>"$LOG" 2>&1 || return 1
  mkdir -p "$BIN_DIR" "$DATA_DIR"
  chmod 700 "$DATA_DIR"
  for b in "${bins[@]}"; do
    [ -f "$dest/teleport/$b" ] || { err "Бинарник $b отсутствует в архиве"; return 1; }
    staged="$BIN_DIR/.$b.teleport-setup.$$"
    install -m 0755 "$dest/teleport/$b" "$staged" || return 1
  done
  for b in "${bins[@]}"; do
    mv -f "$BIN_DIR/.$b.teleport-setup.$$" "$BIN_DIR/$b" || return 1
  done
  fix_context "$BIN_DIR/teleport" "$BIN_DIR/tctl" "$BIN_DIR/tsh" "$BIN_DIR/tbot" "$BIN_DIR/fdpass-teleport"
  hash -r; ok "Бинарники Teleport $(tp_version) установлены"
}

# Full, verified, offline backup. Caller stops Teleport first for a consistent data snapshot.
tp_backup() {
  local label=$1 p dir size free archive; local -a paths=()
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  archive="$BACKUP_DIR/teleport-$label-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
  for p in "$CONF" "$ETC_DIR" "$DATA_DIR" "$UNIT" "$STATE_DIR" \
           "$BIN_DIR/teleport" "$BIN_DIR/tctl" "$BIN_DIR/tsh" "$BIN_DIR/tbot" "$BIN_DIR/fdpass-teleport"; do
    [ ! -e "$p" ] || paths+=("${p#/}")
  done
  [ "${#paths[@]}" -gt 0 ] || { err "Нет файлов для резервного копирования"; return 1; }
  size=$(du -sm "$DATA_DIR" 2>/dev/null | awk '{print $1}')
  free=$(df -Pm "$BACKUP_DIR" | awk 'NR==2{print $4}')
  if [ -n "$size" ] && [ "$free" -lt "$((size+200))" ]; then
    err "Для надёжного backup недостаточно места (${free} МБ свободно; данных ${size} МБ)"; return 1
  fi
  if ! run "Создание резервной копии" tar -czf "$archive.part" -C / "${paths[@]}"; then
    rm -f "$archive.part"; return 1
  fi
  if ! gzip -t "$archive.part" || ! tar -tzf "$archive.part" >/dev/null; then
    rm -f "$archive.part"; err "Архив не проходит проверку"; return 1
  fi
  chmod 600 "$archive.part"; mv -f "$archive.part" "$archive"
  LAST_BACKUP=$archive
  ok "Проверенная резервная копия: $archive"
}
backup_prune() {
  local -a backups=(); local i
  mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'teleport-*.tar.gz' -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
  for ((i=3; i<${#backups[@]}; i++)); do rm -f -- "${backups[$i]}"; done
}
tp_restore() {
  local archive=$1 p
  [ -f "$archive" ] && gzip -t "$archive" && tar -tzf "$archive" >/dev/null || { err "Резервная копия недоступна/повреждена"; return 1; }
  systemctl stop teleport >>"$LOG" 2>&1 || :
  # Remove only script-owned paths. Backup includes all node data, binaries, certificates, unit and state.
  for p in "$CONF" "$ETC_DIR" "$DATA_DIR" "$UNIT" "$STATE_DIR" \
           "$BIN_DIR/teleport" "$BIN_DIR/tctl" "$BIN_DIR/tsh" "$BIN_DIR/tbot" "$BIN_DIR/fdpass-teleport"; do
    rm -rf -- "$p" || return 1
  done
  run "Восстановление данных из копии" tar -xzf "$archive" -C / || return 1
  fix_context "$DATA_DIR" "$CONF" "$ETC_DIR" "$UNIT"
  systemctl daemon-reload
  systemctl enable --now teleport >>"$LOG" 2>&1 || return 1
  wait_healthy
}

# TLS certificate handling: secrets are never passed to run() or printed into logs.
acme_sh() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_CONF" --request-v4 "$@"; }
acme_install() {
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  local t="$CACHE_DIR/acme"; mkdir -p "$t"
  run "Загрузка acme.sh $ACME_VER" curl4 -fsSL --retry 3 -m 120 \
    -o "$t/acme.tar.gz" "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACME_VER.tar.gz" || return 1
  tar -xzf "$t/acme.tar.gz" -C "$t" >>"$LOG" 2>&1 || return 1
  ( cd "$t/acme.sh-$ACME_VER" && ./acme.sh --install --home "$ACME_HOME" \
    --config-home "$ACME_CONF" --cert-home "$ACME_CONF/certs" \
    --accountemail "$ACME_EMAIL" --nocron --noprofile ) >>"$LOG" 2>&1 || return 1
  chmod 700 "$ACME_HOME" "$ACME_CONF" 2>/dev/null || :
  fix_context "$ACME_HOME"; ok "acme.sh установлен"
}
acme_timer_install() {
  cat >"/etc/systemd/system/$ACME_UNIT.service" <<EOF
[Unit]
Description=Teleport ACME certificate renewal
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$ACME_HOME/acme.sh --cron --home $ACME_HOME --config-home $ACME_CONF --request-v4
EOF
  cat >"/etc/systemd/system/$ACME_UNIT.timer" <<EOF
[Unit]
Description=Check Teleport certificate renewal twice a day
[Timer]
OnCalendar=*-*-* 04,16:20:00
RandomizedDelaySec=45min
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  run "Таймер продления сертификатов" systemctl enable --now "$ACME_UNIT.timer"
}
cert_check_files() {
  local crt=$1 key=$2 domain=$3 a b
  [ -s "$crt" ] && [ -s "$key" ] || return 1
  openssl x509 -in "$crt" -noout -checkend 604800 >/dev/null 2>&1 || { err "Сертификат истекает менее чем через 7 дней"; return 1; }
  openssl x509 -in "$crt" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match' || { err "SAN не содержит $domain"; return 1; }
  a=$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | openssl sha256)
  b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)
  [ -n "$a" ] && [ "$a" = "$b" ] || { err "Закрытый ключ не соответствует сертификату"; return 1; }
}
cert_install_pair() {
  local crt=$1 key=$2 d
  cert_check_files "$crt" "$key" "$CLUSTER" || return 1
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  d=$(mktemp -d "$CERT_DIR/.staging.XXXXXX") || return 1
  install -m 0600 "$key" "$d/tls.key" || return 1
  install -m 0644 "$crt" "$d/tls.crt" || return 1
  mv -f "$d/tls.key" "$CERT_DIR/tls.key"
  mv -f "$d/tls.crt" "$CERT_DIR/tls.crt"
  rmdir "$d" || :
  fix_context "$CERT_DIR"
}
acme_providers=(
  'Cloudflare|dns_cf|CF_Token'
  'reg.ru|dns_regru|REGRU_API_Username REGRU_API_Password'
  'Timeweb Cloud|dns_timeweb|TW_Token'
  'Beget|dns_beget|Beget_Username Beget_Password'
  'DuckDNS|dns_duckdns|DuckDNS_Token'
)
cert_acme_dns() {
  local n provider hook keys k server=letsencrypt out; local -a envs=() domains=()
  hdr "ACME DNS-01"
  n=0; for provider in "${acme_providers[@]}"; do n=$((n+1)); say "  $n) ${provider%%|*}"; done
  say "  $((n+1))) Другой DNS-провайдер"; say "  0) Отмена"
  ask_num "Провайдер" "$((n+1))" 1
  [ "$ANSWER" -ne 0 ] || return 1
  if [ "$ANSWER" -le "${#acme_providers[@]}" ]; then
    IFS='|' read -r provider hook keys <<<"${acme_providers[$((ANSWER-1))]}"
    for k in $keys; do ask_secret "$k"; envs+=("$k=$ANSWER"); done
  else
    ask "Модуль acme.sh (например dns_aws)" ""
    hook=$ANSWER
    [[ $hook =~ ^dns_[A-Za-z0-9_]+$ ]] || { err "Некорректный модуль"; return 1; }
    info "Переменные DNS-провайдеров: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
    while :; do
      ask "Переменная ИМЯ=значение (пусто — закончить)" ""
      [ -n "$ANSWER" ] || break
      k=${ANSWER%%=*}
      [[ $ANSWER == *=* && $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "Неверный формат"; continue; }
      envs+=("$ANSWER")
    done
    [ "${#envs[@]}" -gt 0 ] || return 1
  fi
  domains=(-d "$CLUSTER")
  ask_yn "Добавить wildcard *.$CLUSTER?" y && domains+=(-d "*.$CLUSTER")
  acme_install || return 1
  [ "${TELEPORT_SETUP_ACME_STAGING:-0}" != 1 ] || server=letsencrypt_test
  run "CA Let's Encrypt" acme_sh --set-default-ca --server "$server" || return 1
  run "Регистрация ACME-аккаунта" acme_sh --register-account -m "$ACME_EMAIL" --server "$server" || return 1
  info "Получение сертификата; секреты не записываются в журнал команд"
  local rc=0
  env "${envs[@]}" "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_CONF" \
      --issue --request-v4 --server "$server" --dns "$hook" "${domains[@]}" --keylength ec-256 \
      </dev/null >>"$LOG" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
    err "Не удалось выпустить сертификат (код $rc; подробности в $LOG)"; return 1
  fi
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  # acme.sh controls its managed target files on renew. Teleport periodically reloads them.
  if ! run "Установка сертификата" acme_sh --install-cert -d "$CLUSTER" --ecc \
      --key-file "$CERT_DIR/tls.key" --fullchain-file "$CERT_DIR/tls.crt" \
      --reloadcmd 'systemctl try-restart teleport.service'; then return 1; fi
  if [ "$server" = letsencrypt ]; then
    cert_check_files "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key" "$CLUSTER" || return 1
  else
    warn "Staging-сертификат не доверен браузером — только для теста"
  fi
  chmod 600 "$CERT_DIR/tls.key"
  acme_timer_install || return 1
  ok "DNS-01: сертификат установлен"
}
cert_from_files() {
  local crt key
  hdr "Свой PEM-сертификат"
  ask "Абсолютный путь fullchain PEM" ""; crt=$ANSWER
  ask "Абсолютный путь private key PEM" ""; key=$ANSWER
  [ -r "$crt" ] && [ -r "$key" ] || { err "Файлы не читаются"; return 1; }
  cert_install_pair "$crt" "$key" || return 1
  ok "Сертификат установлен"
}
choose_cert() {
  say "  1) acme.sh DNS-01 (рекомендуется, в том числе для LAN)"
  say "  2) Встроенный ACME Teleport (публичный 443/tcp и FQDN)"
  say "  3) Свой PEM-сертификат"
  say "  4) Самоподписанный (только тест)"
  ask_num "Режим TLS" 4 "${1:-1}"
  case "$ANSWER" in
    1) CERT_MODE=acme-dns ;; 2) CERT_MODE=acme-teleport ;;
    3) CERT_MODE=files ;; 4) CERT_MODE=self ;; 0) return 1 ;;
  esac
}
cert_apply() {
  case "$CERT_MODE" in
    acme-dns) cert_acme_dns ;;
    files) cert_from_files ;;
    acme-teleport|self) return 0 ;;
    *) return 1 ;;
  esac
}
write_config_to() {
  local dest=$1
  cat >"$dest" <<EOF
# deploy-teleport.sh $SCRIPT_VERSION
version: v3
teleport:
  nodename: "$NODENAME"
  data_dir: $DATA_DIR
  log:
    output: stderr
    severity: INFO

auth_service:
  enabled: "yes"
  listen_addr: 127.0.0.1:3025
  cluster_name: "$CLUSTER"
  proxy_listener_mode: multiplex

ssh_service:
  enabled: "yes"
  listen_addr: 127.0.0.1:3022

proxy_service:
  enabled: "yes"
  web_listen_addr: 0.0.0.0:443
  public_addr: "$CLUSTER:443"
EOF
  case "$CERT_MODE" in
    acme-teleport)
      printf '  acme:\n    enabled: "yes"\n    email: "%s"\n' "$ACME_EMAIL" >>"$dest" ;;
    files|acme-dns)
      cat >>"$dest" <<EOF
  https_keypairs:
  - key_file: $CERT_DIR/tls.key
    cert_file: $CERT_DIR/tls.crt
  https_keypairs_reload_interval: 1h
EOF
      ;;
  esac
  chmod 600 "$dest"
}
validate_config() { run "Проверка teleport.yaml" "$BIN_DIR/teleport" configure --test "$1"; }
config_apply() {
  local new
  new=$(mktemp /etc/.teleport.yaml.XXXXXX) || return 1
  write_config_to "$new" || return 1
  validate_config "$new" || { rm -f "$new"; return 1; }
  mv -f "$new" "$CONF"
  fix_context "$CONF"
}
write_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=Teleport Community (deploy-teleport.sh)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Restart=on-failure
RestartSec=5
EnvironmentFile=-/etc/default/teleport
ExecStart=$BIN_DIR/teleport start --config=$CONF
LimitNOFILE=524288
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"; systemctl daemon-reload
}
port_check() {
  local conflict
  conflict=$(ss -Hltnp '( sport = :443 )' 2>/dev/null || :)
  if [ -n "$conflict" ] && ! systemctl is-active -q teleport; then
    err "443/tcp занят другим процессом. Ничего не останавливаю автоматически:"
    say "$conflict"; return 1
  fi
}
firewall_open() {
  if systemctl is-active -q firewalld; then
    local iface zone
    iface=$(ip -4 route show default 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')
    zone=
    [ -z "$iface" ] || zone=$(firewall-cmd --get-zone-of-interface="$iface" 2>/dev/null || :)
    [ -n "$zone" ] || zone=$(firewall-cmd --get-default-zone 2>/dev/null) || return 1
    if firewall-cmd --zone="$zone" -q --query-service=https || firewall-cmd --zone="$zone" -q --query-port=443/tcp; then
      ok "firewalld/$zone: 443/tcp уже доступен"; return 0
    fi
    run "Открытие 443/tcp в firewalld/$zone" firewall-cmd --permanent --zone="$zone" --add-service=https || return 1
    run "Перечитать firewalld" firewall-cmd --reload || return 1
    state_set FIREWALL_CHANGED "firewalld/$zone"
  elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    run "Открытие 443/tcp в UFW" ufw allow 443/tcp || return 1
    state_set FIREWALL_CHANGED ufw
  else
    warn "Не найден активный firewalld/UFW: самостоятельно ограничьте входящие порты, разрешив 443/tcp"
  fi
}
proxy_health() {
  # Insecure TLS validation is used ONLY for probing the local web endpoint;
  # public certificate verification is a separate concern.
  curl4 -kfsS --max-time 6 --resolve "$CLUSTER:443:127.0.0.1" \
    "https://$CLUSTER/webapi/ping" >/dev/null 2>&1
}
wait_healthy() {
  local i
  for i in $(seq 1 45); do
    if systemctl is-active -q teleport && "$BIN_DIR/tctl" status >/dev/null 2>&1 && proxy_health; then
      ok "Teleport: Auth и HTTPS Proxy отвечают локально"; return 0
    fi
    sleep 2
  done
  err "Teleport (Auth/Proxy) не отвечает за 90 секунд"
  journalctl -u teleport -n 30 --no-pager >&2 || :
  return 1
}

live_tls() {
  local out
  out=$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$CLUSTER" </dev/null 2>/dev/null |
    openssl x509 -noout -subject -issuer -enddate 2>/dev/null) || return 1
  [ -n "$out" ] && { info "TLS: $out"; return 0; }
  return 1
}
create_admin() {
  local user=$1 logins=$2 output i
  for i in 1 2 3; do
    if output=$("$BIN_DIR/tctl" users add "$user" --roles=editor,access --logins="$logins" 2>&1); then break; fi
    if grep -qi 'already exists' <<<"$output"; then
      warn "Пользователь $user уже существует"
      ask_yn "Создать ссылку сброса его пароля и MFA?" n || return 1
      output=$("$BIN_DIR/tctl" users reset "$user" 2>&1) || { err "$output"; return 1; }
      break
    fi
    sleep 2
  done
  # Never persist invitation URLs in logs.
  INVITE=$(grep -oE 'https://[^ ]+/web/(invite|reset)/[A-Za-z0-9_-]+' <<<"$output" | head -1 || :)
  [ -n "$INVITE" ] || { err "Не удалось получить ссылку приглашения: ${output:0:180}"; return 1; }
  INVITE=${INVITE/:443\//\/}
}
load_state() {
  CLUSTER=$(state_get CLUSTER); NODENAME=$(state_get NODENAME)
  CERT_MODE=$(state_get CERT_MODE); ACME_EMAIL=$(state_get ACME_EMAIL)
  ADMIN_USER=$(state_get ADMIN_USER); ADMIN_LOGINS=$(state_get ADMIN_LOGINS)
  [ -n "$CLUSTER" ] && [ -n "$NODENAME" ] || die "Файл состояния неполон: $STATE"
}

collect_params() {
  local h
  ask_domain "Домен и имя кластера" "$CLUSTER"; CLUSTER=$ANSWER
  h=$(hostname -s 2>/dev/null || echo teleport)
  ask "Имя локального сервера Teleport" "${NODENAME:-$h}"; NODENAME=$ANSWER
  [[ $NODENAME =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || { err "Некорректное имя"; return 1; }
  choose_cert 1 || return 1
  if [[ $CERT_MODE == acme-* ]]; then ask_email "E-mail ACME" "$ACME_EMAIL"; ACME_EMAIL=$ANSWER; fi
  ask_username "Имя первого администратора" "${ADMIN_USER:-admin}"; ADMIN_USER=$ANSWER
  ask_logins "Linux-логины для доступа" "${ADMIN_LOGINS:-root}"; ADMIN_LOGINS=$ANSWER
}
fresh_install() {
  hdr "Предварительные проверки"
  if [ -d "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    die "В $DATA_DIR уже есть данные Teleport. Автоматическое удаление запрещено: разберите старую установку вручную."
  fi
  if [ -e "$CONF" ]; then die "Существует $CONF; чужую конфигурацию не перезаписываю."; fi
  local b
  for b in teleport tctl tsh tbot fdpass-teleport; do
    [ ! -e "$BIN_DIR/$b" ] && [ ! -L "$BIN_DIR/$b" ] || die "Обнаружен чужой бинарник: $BIN_DIR/$b"
  done
  deps
  port_check || return 1
  time_check; dns_step
  collect_params || return 1
  hdr "Параметры"
  info "Кластер: $CLUSTER, узел: $NODENAME"
  info "TLS: $CERT_MODE, первый пользователь: $ADMIN_USER ($ADMIN_LOGINS)"
  dns_check_domain "$CLUSTER" "$CERT_MODE"
  warn "Teleport будет публично слушать 443/tcp; 3022 и 3025 ограничены loopback"
  ask_yn "Начать установку?" n || return 0
  port_check || return 1
  local b
  for b in teleport tctl tsh tbot fdpass-teleport; do
    if [ -e "$BIN_DIR/$b" ] || [ -L "$BIN_DIR/$b" ]; then
      err "Файл $BIN_DIR/$b уже существует. Не заменяю чужой бинарник без переноса/очистки."
      return 1
    fi
  done
  [ ! -e "$CONF" ] || { err "Существует $CONF. Нельзя перезаписывать чужую конфигурацию."; return 1; }
  tp_pick_version || return 1
  tp_fetch "$TP_TARGET" || return 1
  if ! cert_apply; then
    err "TLS-сертификат не получен; Teleport ещё не установлен"; return 1
  fi
  if ! tp_install_bins; then
    rm -f "$BIN_DIR"/{teleport,tctl,tsh,tbot,fdpass-teleport} "$BIN_DIR"/.*.teleport-setup.$$
    return 1
  fi
  if ! config_apply || ! write_unit; then
    rm -f "$BIN_DIR"/{teleport,tctl,tsh,tbot,fdpass-teleport}
    rm -f "$CONF" "$UNIT"
    return 1
  fi
  # Mark ownership before starting service to allow recovery after failure.
  state_set SCRIPT_VERSION "$SCRIPT_VERSION"
  state_set CLUSTER "$CLUSTER"; state_set NODENAME "$NODENAME"
  state_set CERT_MODE "$CERT_MODE"; state_set ACME_EMAIL "$ACME_EMAIL"
  state_set ADMIN_USER "$ADMIN_USER"; state_set ADMIN_LOGINS "$ADMIN_LOGINS"
  firewall_open || warn "Проверьте фаервол вручную"
  run "Запуск teleport.service" systemctl enable --now teleport || die "systemd не запустил Teleport"
  wait_healthy || die "Teleport не запустился. Данные сохранены; проверьте журнал."
  create_admin "$ADMIN_USER" "$ADMIN_LOGINS" || { warn "Teleport работает, но приглашение не создано. Используйте меню администратора."; return 1; }
  final_summary "$ADMIN_USER" "$INVITE"
}
final_summary() {
  hdr "Teleport установлен"
  say "  Веб-интерфейс: https://$CLUSTER"
  say "  Пользователь: $1 (роли editor + access; права аудита назначаются отдельно)"
  say "  Первая ссылка (срок ограничен): $2"
  say "  tsh login --proxy=$CLUSTER:443 --user=$1$([ "$CERT_MODE" = self ] && printf ' --insecure' || :)"
  say "  tsh ls; tsh ssh ${ADMIN_LOGINS%%,*}@$NODENAME"
  say "  Проверка из другой сети: curl -4 -fsS https://$CLUSTER/webapi/ping"
  if [ "$CERT_MODE" != self ] && ! curl4 -fsS --max-time 8 \
     --resolve "$CLUSTER:443:127.0.0.1" "https://$CLUSTER/webapi/ping" >/dev/null 2>&1; then
    warn "Проверка доверия TLS не прошла: проверьте SAN/fullchain, ACME и системные CA"
  fi
  say "  Журнал: journalctl -u teleport -f; действия: bash deploy-teleport.sh"
  [ "$CERT_MODE" != self ] || warn "Самоподписанный TLS — не используйте в production"
}

# In-place update: backup after stopping, revalidate and restore on any failure.
menu_update() {
  deps
  local current latest cm lm target backup
  current=$(tp_version)
  [ -n "$current" ] && tp_valid_version "$current" || { err "Версия установленного Teleport не определена"; return 1; }
  cm=${current%%.*}
  if [ -n "${TELEPORT_SETUP_VERSION:-}" ]; then
    target=${TELEPORT_SETUP_VERSION#v}
    tp_valid_version "$target" || { err "Некорректная TELEPORT_SETUP_VERSION"; return 1; }
    info "Обновление до явно заданной версии $target"
  else
    latest=$(tp_release_latest) || {
      err "Не удалось получить свежую стабильную версию с $TP_RELEASE_API"
      err "Укажите TELEPORT_SETUP_VERSION=X.Y.Z для ручного обновления"
      return 1
    }
    target=$latest
    info "Официальный последний стабильный релиз: $latest"
  fi
  lm=${target%%.*}
  if [ "$lm" -gt "$((cm+1))" ]; then
    err "Переход v$cm -> v$lm запрещён: Teleport обновляется по одной major-версии"
    err "Сначала обновитесь до последней поддерживаемой версии v$((cm+1)) (через TELEPORT_SETUP_VERSION)"
    return 1
  fi
  if [ "$lm" -lt "$cm" ] ||
     [ "$(printf '%s\n%s\n' "$current" "$target" | sort -V | tail -1)" != "$target" ] ||
     [ "$current" = "$target" ]; then
    ok "Обновление не требуется (установлено: $current)"
    return 0
  fi
  info "Обновление $current -> $target"
  warn "Агенты Teleport должны быть совместимы. Планируйте окно обслуживания."
  ask_yn "Остановить Teleport для offline-бэкапа и обновления?" n || return 0
  tp_fetch "$target" || return 1
  run "Остановка Teleport" systemctl stop teleport || return 1
  if ! tp_backup "before-v$target"; then
    run "Возврат Teleport в работу" systemctl start teleport && wait_healthy ||
      err "Не удалось вернуть Teleport в работу после сбоя backup"
    return 1
  fi
  backup=$LAST_BACKUP
  if tp_install_bins && validate_config "$CONF" && run "Запуск обновлённого Teleport" systemctl start teleport && wait_healthy && [ "$(tp_version)" = "$target" ]; then
    ok "Teleport обновлён до $target"; backup_prune; return 0
  fi
  err "Обновление не удалось. Выполняется автоматический rollback на $current"
  if tp_restore "$backup"; then warn "Восстановлена версия $(tp_version) из $backup"; else
    err "Автовосстановление не удалось. Не удаляйте резервную копию: $backup"
  fi
  return 1
}

menu_admin() {
  local u logins
  ask_username "Новый администратор" ""; u=$ANSWER
  ask_logins "Linux-логины" root; logins=$ANSWER
  create_admin "$u" "$logins" || return 1
  ok "Приглашение $u (срок ограничен): $INVITE"
}
menu_reset() {
  local u output
  "$BIN_DIR/tctl" users ls || :
  ask_username "Пользователь для сброса пароля/MFA" "$ADMIN_USER"; u=$ANSWER
  "$BIN_DIR/tctl" get "user/$u" >/dev/null 2>&1 || { err "Пользователя нет"; return 1; }
  output=$("$BIN_DIR/tctl" users reset "$u" 2>&1) || { err "Сброс не удался"; return 1; }
  INVITE=$(grep -oE 'https://[^ ]+/web/reset/[A-Za-z0-9_-]+' <<<"$output" | head -1 || :)
  [ -n "$INVITE" ] || { err "В ответе нет ссылки"; return 1; }
  info "Ссылка сброса (ограниченное время): ${INVITE/:443\//\/}"
}
menu_token() {
  local token
  # In Teleport 18, --format=text writes only the token, which can be stored as a file.
  token=$("$BIN_DIR/tctl" tokens add --type=node --ttl=1h --format=text 2>>"$LOG") || {
    err "Не удалось создать токен"; return 1;
  }
  token=${token//$'\r'/}
  token=${token//$'\n'/}
  [[ $token =~ ^[A-Za-z0-9_-]{16,256}$ ]] || { err "Неожиданный формат токена; секрет не отображён"; return 1; }
  say "  Токен (1 час): $token"
  say "  На новом сервере установите Teleport версии, совместимой с $(tp_version)."
  say "  Сохраните токен в файле /root/teleport-token (chmod 600), затем:"
  say "    teleport node configure --output=file --proxy=$CLUSTER:443 --token=/root/teleport-token"
  say "    systemctl enable --now teleport"
  warn "Не вставляйте токен в shell-команду: он попадёт в историю."
}
menu_cert() {
  local oldmode oldemail dir oldtimer=0 rc=0
  live_tls || warn "TLS на 443 не отвечает"
  info "Текущий TLS: $CERT_MODE"
  say "  1) Проверить/продлить acme.sh"
  say "  2) Изменить способ TLS"
  say "  0) Назад"
  ask_num "Выбор" 2 0
  case "$ANSWER" in
    0) return 0 ;;
    1)
      [ "$CERT_MODE" = acme-dns ] || { warn "Только для acme-dns"; return 1; }
      run "Принудительное продление" acme_sh --renew -d "$CLUSTER" --ecc --force || return 1
      cert_check_files "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key" "$CLUSTER" ;;
    2)
      oldmode=$CERT_MODE; oldemail=$ACME_EMAIL
      dir=$(mktemp -d "$CACHE_DIR/tls-rollback.XXXXXX") || return 1
      cp -a "$CONF" "$dir/config" || return 1
      [ ! -d "$CERT_DIR" ] || cp -a "$CERT_DIR" "$dir/certs"
      systemctl is-enabled -q "$ACME_UNIT.timer" && oldtimer=1
      if ! choose_cert 1; then CERT_MODE=$oldmode; return 0; fi
      if [[ $CERT_MODE == acme-* ]]; then ask_email "E-mail ACME" "$ACME_EMAIL"; ACME_EMAIL=$ANSWER; fi
      if cert_apply && config_apply && run "Перезапуск Teleport" systemctl restart teleport && wait_healthy; then
        state_set CERT_MODE "$CERT_MODE"; state_set ACME_EMAIL "$ACME_EMAIL"
        if [ "$CERT_MODE" != acme-dns ]; then systemctl disable --now "$ACME_UNIT.timer" >>"$LOG" 2>&1 || :; fi
        ok "Сертификат и конфигурация переключены"; return 0
      fi
      err "TLS-изменение не прошло: восстанавливаю предыдущие файлы"
      cp -a "$dir/config" "$CONF" || rc=1
      rm -rf "$CERT_DIR"
      [ ! -d "$dir/certs" ] || cp -a "$dir/certs" "$CERT_DIR" || rc=1
      CERT_MODE=$oldmode; ACME_EMAIL=$oldemail
      if [ "$oldtimer" -eq 1 ]; then
        systemctl enable --now "$ACME_UNIT.timer" >>"$LOG" 2>&1 || :
      else
        systemctl disable --now "$ACME_UNIT.timer" >>"$LOG" 2>&1 || :
      fi
      run "Возврат прежнего Teleport" systemctl restart teleport && wait_healthy || rc=1
      return 1 ;;
  esac
}
menu_dns() {
  local choice
  while :; do
    hdr "DNS"
    info "Текущие nameserver: $(grep -E '^nameserver' "$RESOLV_CONF" | tr '\n' ' ')"
    say '  1) Проверить   2) Изменить   3) Вернуть исходный   0) Назад'
    ask_num "Действие" 3 0; choice=$ANSWER
    case "$choice" in
      1) dns_test || : ;; 2) dns_change || : ;; 3) dns_restore || : ;; 0) return 0 ;;
    esac
  done
}
menu_status() {
  hdr "Teleport status"
  systemctl --no-pager status teleport | head -n 12 || :
  "$BIN_DIR/tctl" status || :
  info "Публичные listeners:"
  ss -Hlntp '( sport = :443 or sport = :3022 or sport = :3025 )' || :
  info "Последние события:"
  journalctl -u teleport -n 15 --no-pager || :
  ask_yn "Перезапустить Teleport?" n && { run "Перезапуск" systemctl restart teleport && wait_healthy; } || :
}
menu_uninstall() {
  local remove=0 backup
  hdr "Удаление только этой установки"
  warn "Сначала offline-бэкап; общие утилиты и сторонние файлы не удаляются."
  ask_yn "Удалить Teleport?" n || return 0
  ask_yn "Удалить также конфигурацию, сертификаты и данные кластера?" n && remove=1 || :
  run "Остановка Teleport" systemctl stop teleport || return 1
  if ! tp_backup uninstall; then
    run "Возврат сервиса" systemctl start teleport || :
    err "Без успешного backup удаление запрещено"; return 1
  fi
  backup=$LAST_BACKUP
  systemctl disable teleport >>"$LOG" 2>&1 || :
  rm -f "$UNIT"
  local b; for b in teleport tctl tsh tbot fdpass-teleport; do rm -f "$BIN_DIR/$b"; done
  if [ "$remove" -eq 1 ]; then rm -rf -- "$DATA_DIR" "$CONF" "$ETC_DIR"; fi
  systemctl disable --now "$ACME_UNIT.timer" >>"$LOG" 2>&1 || :
  rm -f "/etc/systemd/system/$ACME_UNIT.timer" "/etc/systemd/system/$ACME_UNIT.service"
  systemctl daemon-reload
  [ ! -d "$DNS_BACKUP" ] || dns_restore || warn "DNS нуждается в ручном восстановлении"
  rm -f "$STATE"
  info "acme.sh и секреты сохранены в $ACME_HOME и $ACME_CONF — удаляйте отдельно после проверки."
  info "Правило 443/tcp в фаерволе оставлено, чтобы не нарушить другие сервисы."
  ok "Удалено. Резервная копия: $backup"
  exit 0
}
menu_installed() {
  load_state
  while :; do
    hdr "Teleport $(tp_version) | $CLUSTER | $(systemctl is-active teleport 2>/dev/null || :)"
    say "  1) Обновить Teleport"
    say "  2) Создать пользователя-администратора"
    say "  3) Сбросить пароль и MFA"
    say "  4) Список пользователей"
    say "  5) Создать токен узла"
    say "  6) Сертификат и продление"
    say "  7) DNS и DoH"
    say "  8) Проверка времени"
    say "  9) Состояние и журнал"
    say " 10) Удалить Teleport"
    say "  0) Выход"
    ask_num "Действие" 10 0
    case "$ANSWER" in
      1) menu_update || : ;; 2) menu_admin || : ;; 3) menu_reset || : ;;
      4) "$BIN_DIR/tctl" users ls || : ;; 5) menu_token || : ;;
      6) menu_cert || : ;; 7) menu_dns || : ;; 8) time_check || : ;;
      9) menu_status || : ;; 10) menu_uninstall || : ;; 0) return 0 ;;
    esac
    ui_prepare '  Enter — продолжить...'
    read -r -p "$UI_DISPLAY" _ || return 0
  done
}
main() {
  [ "$(id -u)" -eq 0 ] || { err "Запустите от root"; exit 1; }
  if [ ! -t 0 ]; then [ -r /dev/tty ] && exec </dev/tty || die "Нужен интерактивный терминал"; fi
  mkdir -p "${LOG%/*}" "$STATE_DIR" "$CACHE_DIR"
  chmod 700 "$STATE_DIR" "$CACHE_DIR"
  touch "$LOG"; chmod 600 "$LOG"
  command -v flock >/dev/null 2>&1 || die "Нужен flock (util-linux)"
  mkdir -p /run/lock
  exec 9>/run/lock/deploy-teleport.lock
  flock -n 9 || die "Другой экземпляр deploy-teleport.sh уже работает"
  TMP_DIR=$(mktemp -d "$CACHE_DIR/session.XXXXXX") || die "Нет временного каталога"
  export PATH="$BIN_DIR:$PATH"
  init_console_ui
  log "=== deploy-teleport.sh $SCRIPT_VERSION ==="
  prechecks
  if [ "${1:-}" = dns-restore ]; then dns_restore; return $?; fi
  hdr "Teleport Community — deploy-teleport.sh $SCRIPT_VERSION"
  if tp_installed; then
    if ! tp_owned; then die "Найдена сторонняя/неполная установка Teleport. Автоматическое принятие под управление запрещено."; fi
    menu_installed
  else
    fresh_install
  fi
}
[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
