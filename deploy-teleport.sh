#!/usr/bin/env bash
# Что делает: интерактивно разворачивает Teleport Community Edition «с нуля» на Linux-машине
#             (auth + proxy + ssh в одном процессе, всё на порту 443), получает TLS-сертификат
#             через ACME с автопродлением, проверяет/меняет DNS (в т.ч. на DoH), выводит данные
#             для первого входа. При повторном запуске — обновление и служебное меню.
# Проверено на: Rocky Linux 10.2, Debian 13 (x86_64)
# Перед запуском задать: ничего — всё спрашивается интерактивно. Запуск от root:
#             bash deploy-teleport.sh
# Офлайн/медленная сеть: положите рядом со скриптом teleport-v<версия>-linux-<arch>-bin.tar.gz
# Переменные (необязательно): TELEPORT_SETUP_VERSION=18.11.8 — поставить конкретную версию;
#             TELEPORT_SETUP_ACME_STAGING=1 — сертификаты от тестового CA Let's Encrypt (для проверок).

set -o pipefail
umask 022

SCRIPT_VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

# ─── пути и источники ──────────────────────────────────────────────────────────
BIN_DIR=/usr/local/bin
CONF=/etc/teleport.yaml
CERT_DIR=/etc/teleport/certs
DATA_DIR=/var/lib/teleport
UNIT=/etc/systemd/system/teleport.service
STATE_DIR=/var/lib/teleport-setup
STATE="$STATE_DIR/state.env"
CACHE_DIR=/var/cache/teleport-setup
BACKUP_DIR=/var/backups/teleport
LOG=/var/log/teleport-setup.log

ACME_HOME=/opt/acme.sh
ACME_CONF=/etc/acme.sh
ACME_SH_VER=3.1.6
ACME_UNIT=teleport-acme

DOH_VER=2.1.20
DOH_BIN=/usr/local/bin/dnscrypt-proxy
DOH_CONF=/etc/dnscrypt-proxy/teleport-setup.toml
DOH_UNIT="doh-dnscrypt"
DOH_LISTEN=127.0.2.1
DNS_BACKUP="$STATE_DIR/dns-backup"
RESOLVED_DROPIN=/etc/systemd/resolved.conf.d/90-teleport-setup.conf
NM_DROPIN=/etc/NetworkManager/conf.d/90-teleport-setup-dns.conf

TP_INDEX=https://apt.releases.teleport.dev/debian/dists/bookworm
TP_CDN=https://cdn.teleport.dev

# ─── оформление ───────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
  C0=$'\e[0m'; CB=$'\e[1m'; CH=$'\e[38;5;183m'; CL=$'\e[38;5;117m'
  CG=$'\e[38;5;151m'; CY=$'\e[38;5;223m'; CR=$'\e[38;5;210m'; CD=$'\e[38;5;245m'
elif [ -t 1 ]; then
  C0=$'\e[0m'; CB=$'\e[1m'; CH=$'\e[35m'; CL=$'\e[36m'; CG=$'\e[32m'; CY=$'\e[33m'; CR=$'\e[31m'; CD=$'\e[2m'
else
  C0=; CB=; CH=; CL=; CG=; CY=; CR=; CD=
fi

say()  { printf '%s\n' "$*"; }
info() { printf '  %s•%s %s\n' "$CL" "$C0" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$CG" "$C0" "$*"; }
warn() { printf '  %s!%s %s\n' "$CY" "$C0" "$*"; }
err()  { printf '  %s✖ %s%s\n' "$CR" "$*" "$C0" >&2; }
die()  { err "$*"; say "  Подробный журнал: $LOG"; exit 1; }
hdr()  { printf '\n%s%s━━ %s %s%s\n' "$CB" "$CH" "$*" "$(printf '━%.0s' $(seq 1 $((60 - ${#1}))))" "$C0"; }
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# run "описание" команда… — вывод команды в журнал, на экран только итог
run() {
  local desc=$1; shift
  printf '  %s…%s %s' "$CD" "$C0" "$desc"
  log "RUN: $*"
  if "$@" </dev/null >>"$LOG" 2>&1; then
    printf '\r\e[K  %s✔%s %s\n' "$CG" "$C0" "$desc"; return 0
  fi
  local rc=$?
  printf '\r\e[K  %s✖%s %s (код %s)\n' "$CR" "$C0" "$desc" "$rc"
  say "${CD}── последние строки журнала ($LOG) ──${C0}"
  tail -n 12 "$LOG" | sed 's/^/    /'
  return "$rc"
}

trap 'printf "\n"; warn "Прервано пользователем (Ctrl+C)."; exit 130' INT

# ─── ввод: терпимый к ошибкам ─────────────────────────────────────────────────
pad() { local n=$(( $2 - ${#1} )); printf '%s' "$1"; [ $n -gt 0 ] && printf '%*s' $n ''; return 0; }   # по символам, не байтам
trim() { local s=$1; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# ask "вопрос" [значение по умолчанию] → $ANSWER (по умолчанию подставлено и редактируется)
ask() {
  local a
  if [ -n "${2-}" ]; then read -r -e -p "  › $1: " -i "$2" a; else read -r -e -p "  › $1: " a; fi || { say; die "Ввод прерван."; }
  ANSWER=$(trim "$a")
}

# ask_yn "вопрос" y|n → код 0 = да
ask_yn() {
  local def=${2:-n} hint a
  [ "$def" = y ] && hint="Д/н" || hint="д/Н"
  while true; do
    read -r -p "  › $1 [$hint]: " a || { say; die "Ввод прерван."; }
    a=$(trim "${a,,}")
    [ -z "$a" ] && a=$def
    case "$a" in
      y|yes|д|да|ага|ок|ok|1) return 0 ;;
      n|no|нет|не|т|0) return 1 ;;              # т — «n» в русской раскладке
    esac
    warn "Не понял ответ «$a». Введите «да» или «нет» (Enter — $( [ "$def" = y ] && echo да || echo нет))."
  done
}

# ask_num "вопрос" максимум [по умолчанию] → $ANSWER (число 0..max)
ask_num() {
  local max=$2 def=${3-} a
  while true; do
    read -r -p "  › $1${def:+ [$def]}: " a || { say; die "Ввод прерван."; }
    a=$(trim "$a"); a=${a%[.)]}; [ -z "$a" ] && a=$def
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 0 ] && [ "$a" -le "$max" ]; then ANSWER=$((10#$a)); return 0; fi
    warn "Введите номер пункта от 0 до $max."
  done
}

ask_secret() {
  local a
  while true; do
    read -r -s -p "  › $1 (ввод скрыт): " a || { say; die "Ввод прерван."; }
    say; a=$(trim "$a")
    [ -n "$a" ] && { ANSWER=$a; return 0; }
    warn "Пустое значение. Вставьте ещё раз (правый клик / Ctrl+Shift+V)."
  done
}

# нормализация домена: убирает https://, путь, порт, точку в конце, пробелы, регистр
norm_domain() {
  local d; d=$(trim "$1"); d=${d,,}
  d=${d#*://}; d=${d%%/*}; d=${d%%\?*}; d=${d%:*}; d=${d%.}; d=${d#\*.}
  printf '%s' "$d"
}
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_domain() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; }

ask_domain() {   # ask_domain "вопрос" [default]
  local d raw
  while true; do
    ask "$1" "${2-}"; raw=$ANSWER; d=$(norm_domain "$raw")
    [ -z "$d" ] && { warn "Нужно ввести доменное имя, например teleport.example.com"; continue; }
    if printf '%s' "$d" | LC_ALL=C grep -q '[^ -~]'; then
      warn "Кириллические домены нужно вводить в punycode (xn--...). Пример: xn--80ak6aa92e.xn--p1ai"; continue
    fi
    if is_ip "$d"; then warn "Это IP-адрес. Teleport и ACME нужно доменное имя (A-запись на этот сервер)."; continue; fi
    if ! is_domain "$d"; then warn "«$raw» не похоже на доменное имя. Пример: teleport.example.com"; continue; fi
    [ "$d" != "$raw" ] && info "Принято как: ${CB}$d${C0}"
    ANSWER=$d; return 0
  done
}

ask_email() {
  local e
  while true; do
    ask "$1" "${2-}"; e=$(trim "${ANSWER,,}"); e=${e#mailto:}; e=${e//[<>]/}
    if [[ "$e" =~ ^[a-z0-9._%+-]+@([a-z0-9-]+\.)+[a-z]{2,}$ ]]; then
      [[ "$e" =~ @(example\.(com|org|net)|test\.com)$ ]] && { warn "Let's Encrypt отклоняет адреса на $e — укажите настоящий."; continue; }
      ANSWER=$e; return 0
    fi
    warn "«$ANSWER» не похоже на e-mail. Пример: admin@mydomain.ru"
  done
}

ask_username() {
  local u
  while true; do
    ask "$1" "${2-}"; u=$ANSWER
    if [[ "$u" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$ ]]; then ANSWER=$u; return 0; fi
    warn "Имя может содержать латиницу, цифры и . _ - @ (без пробелов), до 64 символов."
  done
}

ask_logins() {   # системные логины, под которыми пользователь сможет входить на серверы
  local raw l out bad
  while true; do
    ask "$1" "${2:-root}"; raw=${ANSWER//[,;]/ }; out=; bad=
    for l in $raw; do
      if [[ "$l" =~ ^[a-z_][a-z0-9_.-]{0,31}$ ]]; then [[ ",$out," == *",$l,"* ]] || out="${out:+$out,}$l"; else bad="$bad $l"; fi
    done
    [ -n "$bad" ] && { warn "Недопустимые логины:$bad (латиница в нижнем регистре, цифры, _ . -)"; continue; }
    [ -z "$out" ] && { warn "Нужен хотя бы один логин, например root"; continue; }
    ANSWER=$out; return 0
  done
}

# ─── состояние ────────────────────────────────────────────────────────────────
state_get() { [ -f "$STATE" ] && grep -m1 "^$1=" "$STATE" | cut -d= -f2-; }
state_set() {
  mkdir -p "$STATE_DIR"; touch "$STATE"; chmod 600 "$STATE"
  grep -v "^$1=" "$STATE" >"$STATE.tmp" 2>/dev/null; printf '%s=%s\n' "$1" "$2" >>"$STATE.tmp"; mv -f "$STATE.tmp" "$STATE"
}

# ─── система ──────────────────────────────────────────────────────────────────
detect_os() {
  OS_ID=unknown; OS_PRETTY=$(uname -sr)
  if [ -r /etc/os-release ]; then
    OS_ID=$(. /etc/os-release; echo "${ID:-unknown}")
    OS_PRETTY=$(. /etc/os-release; echo "${PRETTY_NAME:-$OS_ID}")
  fi
  PKG=
  for p in apt-get dnf yum zypper pacman; do command -v $p >/dev/null 2>&1 && { PKG=$p; break; }; done
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64; DOH_ARCH=x86_64 ;;
    aarch64|arm64) ARCH=arm64; DOH_ARCH=arm64 ;;
    armv7*|armv6*) ARCH=arm; DOH_ARCH=arm ;;
    *) ARCH=; DOH_ARCH= ;;
  esac
}

selinux_on() { command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; }
fix_context() { selinux_on && command -v restorecon >/dev/null 2>&1 && restorecon -RF "$@" >>"$LOG" 2>&1; return 0; }

prechecks() {
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || die "Нужен bash 4 или новее."
  [ -d /run/systemd/system ] || die "Нужен systemd (на этой системе его нет). Teleport-сервис управляется через systemd."
  [ -n "$ARCH" ] || die "Архитектура $(uname -m) не поддерживается Teleport (нужна x86_64, aarch64 или armv7)."
  if ldd --version 2>&1 | grep -qi musl; then die "Система на musl (Alpine и т.п.) — бинарники Teleport требуют glibc."; fi
  ok "ОС: $OS_PRETTY, архитектура $(uname -m)${PKG:+, пакеты через $PKG}"
  local mem disk
  mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$mem" -lt 900 ]; then warn "Памяти ${mem} МБ — Teleport рекомендует от 1 ГБ (лучше 2 ГБ)."; else ok "Память: ${mem} МБ"; fi
  disk=$(df -Pm /var 2>/dev/null | awk 'NR==2{print $4}')
  if [ "${disk:-0}" -lt 2500 ]; then
    warn "Свободно ${disk} МБ в /var — для установки нужно около 2,5 ГБ (архив + распаковка + бинарники)."
    ask_yn "Продолжить всё равно?" n || exit 1
  else ok "Свободно на диске: $((disk / 1024)) ГБ"; fi
  selinux_on && info "SELinux в режиме Enforcing — учтено."
  [ -z "$PKG" ] && warn "Пакетный менеджер не найден — зависимости придётся ставить вручную, если чего-то не хватит."
}

pkg_install() {
  [ $# -eq 0 ] && return 0
  case "$PKG" in
    apt-get) run "Обновление списка пакетов" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -qq || return 1
             run "Установка: $*" env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y -qq --no-install-recommends "$@" ;;
    dnf|yum) run "Установка: $*" "$PKG" -y -q install "$@" ;;
    zypper)  run "Установка: $*" zypper --non-interactive -q install "$@" ;;
    pacman)  run "Установка: $*" pacman -Sy --noconfirm --needed "$@" ;;
    *) err "Не могу установить автоматически: $*"; return 1 ;;
  esac
}

deps() {
  local need=() c
  for c in curl tar gzip openssl ss pkill; do
    command -v $c >/dev/null 2>&1 && continue
    case "$c:$PKG" in
      ss:apt-get) need+=(iproute2) ;; ss:*) need+=(iproute) ;;
      pkill:apt-get) need+=(procps) ;; pkill:zypper) need+=(procps) ;; pkill:*) need+=(procps-ng) ;;
      *) need+=("$c") ;;
    esac
  done
  [ -e /etc/ssl/certs/ca-certificates.crt ] || [ -e /etc/pki/tls/certs/ca-bundle.crt ] || [ -e /etc/ssl/ca-bundle.pem ] || need+=(ca-certificates)
  if [ ${#need[@]} -eq 0 ]; then ok "Все зависимости уже есть (curl, tar, gzip, openssl, ss, pkill)"; return 0; fi
  info "Не хватает: ${need[*]}"
  pkg_install "${need[@]}" || die "Не удалось установить зависимости. Проверьте доступ к репозиториям (DNS, время, прокси)."
}

# ─── время ────────────────────────────────────────────────────────────────────
time_synced() { [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ]; }

http_epoch() {   # время по заголовку Date (без TLS — работает даже при сбитых часах)
  local h d
  for h in www.google.com www.cloudflare.com ya.ru; do
    d=$(timeout 6 bash -c "exec 3<>/dev/tcp/$h/80; printf 'HEAD / HTTP/1.1\r\nHost: $h\r\nConnection: close\r\n\r\n' >&3; cat <&3" 2>/dev/null \
        | tr -d '\r' | sed -n 's/^[Dd]ate: //p' | head -1)
    [ -n "$d" ] && date -d "$d" +%s 2>/dev/null && return 0
  done
  return 1
}

time_fix() {
  if time_synced; then ok "Время синхронизировано: $(date '+%F %T %Z')"; return 0; fi
  warn "Часы не синхронизированы ($(date '+%F %T %Z')). Для TLS, ACME и Teleport это критично."
  if command -v chronyc >/dev/null 2>&1 && systemctl is-active -q chronyd chrony 2>/dev/null; then
    chronyc -a 'burst 4/4' >>"$LOG" 2>&1; sleep 6; run "chrony: принудительная коррекция (makestep)" chronyc -a makestep
  elif systemctl list-unit-files systemd-timesyncd.service >/dev/null 2>&1; then
    timedatectl set-ntp true >>"$LOG" 2>&1; run "Перезапуск systemd-timesyncd" systemctl restart systemd-timesyncd
  fi
  local i; for i in $(seq 1 15); do time_synced && break; sleep 2; done
  if time_synced; then ok "Время синхронизировано: $(date '+%F %T %Z')"; return 0; fi
  local web now diff
  web=$(http_epoch) || { warn "NTP не отвечает и проверить время по сети не удалось. Продолжаю как есть."; return 0; }
  now=$(date +%s); diff=$((web - now)); [ $diff -lt 0 ] && diff=$((-diff))
  if [ $diff -gt 30 ]; then
    warn "Часы расходятся с реальным временем на $diff с."
    if ask_yn "Установить время по сети сейчас?" y; then
      date -s "@$web" >>"$LOG" 2>&1 && hwclock --systohc >>"$LOG" 2>&1
      ok "Время установлено: $(date '+%F %T %Z')"
    fi
  else ok "Отклонение $diff с — допустимо (NTP досинхронизирует сам)."; fi
}

ensure_ntp() {   # после установки зависимостей: должна быть включена служба NTP
  [ "$(timedatectl show -p NTP --value 2>/dev/null)" = yes ] && return 0
  if [ "$(timedatectl show -p CanNTP --value 2>/dev/null)" = yes ]; then
    run "Включение синхронизации времени (NTP)" timedatectl set-ntp true; return 0
  fi
  pkg_install chrony && { systemctl enable --now chronyd >>"$LOG" 2>&1 || systemctl enable --now chrony >>"$LOG" 2>&1; } \
    && ok "Установлен и включён chrony" || warn "Службу NTP включить не удалось — следите за временем вручную."
}

# ─── DNS ──────────────────────────────────────────────────────────────────────
DNS_TEST_HOSTS="cdn.teleport.dev apt.releases.teleport.dev acme-v02.api.letsencrypt.org github.com"

dns_manager() {
  if systemctl is-active -q systemd-resolved 2>/dev/null && readlink /etc/resolv.conf 2>/dev/null | grep -q systemd/resolve; then echo resolved
  elif systemctl is-active -q NetworkManager 2>/dev/null; then echo nm
  else echo file; fi
}

dns_show() {
  local m; m=$(dns_manager)
  case "$m" in
    resolved) info "DNS управляет systemd-resolved: $(resolvectl dns 2>/dev/null | awk -F': ' '$2!=""{print $2}' | xargs | tr ' ' ',')" ;;
    nm) info "DNS управляет NetworkManager; сейчас: $(awk '/^nameserver/{print $2}' /etc/resolv.conf | xargs | tr ' ' ',')" ;;
    file) info "DNS из /etc/resolv.conf: $(awk '/^nameserver/{print $2}' /etc/resolv.conf | xargs | tr ' ' ',')" ;;
  esac
  systemctl is-active -q "$DOH_UNIT" 2>/dev/null && info "Включён DoH-прокси ($DOH_UNIT, ${DOH_LISTEN}:53)."
  [ -d "$DNS_BACKUP" ] && info "DNS изменён этим скриптом — в меню DNS доступен откат."
}

dns_test() {   # → число неудачных разрешений; печатает результат по каждому имени
  local h t0 ms fails=0
  for h in $DNS_TEST_HOSTS; do
    t0=$(date +%s%N)
    if timeout 6 getent ahostsv4 "$h" >/dev/null 2>&1; then ms=$(( ($(date +%s%N) - t0) / 1000000 )); ok "$h — ${ms} мс"
    else err "$h — не разрешается"; fails=$((fails + 1)); fi
  done
  return $fails
}

local_ips() { ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | xargs; }
public_ip() {
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -fs -m5 "$u" 2>/dev/null | tr -d '[:space:]'); is_ip "$ip" && { echo "$ip"; return 0; }
  done; return 1
}
public_a() {   # A-записи домена в публичном DNS (через DoH, мимо локального резолвера)
  local r
  r=$(curl -fs -m6 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$1&type=A" 2>/dev/null) \
    || r=$(curl -fs -m6 "https://dns.google/resolve?name=$1&type=A" 2>/dev/null)
  grep -oE '"data": ?"[0-9.]+"' <<<"$r" | grep -oE '[0-9.]{7,}' | xargs
}

dns_check_domain() {   # dns_check_domain домен режим_сертификата
  local d=$1 mode=$2 loc pub lips pip
  hdr "Проверка DNS для $d"
  loc=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u | xargs)
  pub=$(public_a "$d"); lips=$(local_ips); pip=$(public_ip)
  info "Адреса этой машины: ${lips:-?}; внешний IP: ${pip:-не определён}"
  if [ -n "$loc" ]; then ok "Локально $d → $loc"; else warn "Локальный DNS не знает $d"; fi
  if [ -n "$pub" ]; then ok "Публичный DNS: $d → $pub"; else warn "В публичном DNS записи $d нет"; fi
  if [ "$mode" = acme-teleport ]; then
    if [ -z "$pub" ]; then
      warn "Встроенному ACME Teleport нужна ПУБЛИЧНАЯ A-запись $d → ${pip:-внешний IP} и доступный из интернета порт 443."
      warn "Без этого сертификат не выпустится (Teleport будет работать, но с ошибкой TLS)."
    elif [ -n "$pip" ] && [[ " $pub " != *" $pip "* ]]; then
      warn "Публичная запись ($pub) не совпадает с внешним IP ($pip). Проверьте A-запись и проброс 443."
    else ok "Публичная запись совпадает с внешним IP — встроенный ACME должен сработать (если 443 открыт снаружи)."; fi
  else
    if [ -z "$loc" ]; then
      warn "Клиенты должны находить $d. Добавьте A-запись $d → ${lips%% *} в DNS (роутер/локальный DNS/регистратор)"
      warn "или строку «${lips%% *} $d» в hosts на клиентских машинах."
    elif ! grep -qw -- "${loc%% *}" <<<"$lips $pip"; then
      warn "$d указывает на ${loc%% *}, а у этой машины адреса $lips. Если это не NAT/проброс — исправьте запись."
    fi
  fi
}

# DNS-провайдеры: имя | обычные адреса | DoH-хост (пусто — DoH нет)
DNS_PROVIDERS=(
  "Cloudflare|1.1.1.1 1.0.0.1|cloudflare-dns.com"
  "Google|8.8.8.8 8.8.4.4|dns.google"
  "Quad9|9.9.9.9 149.112.112.112|dns.quad9.net"
  "AdGuard (без фильтрации)|94.140.14.140 94.140.14.141|unfiltered.adguard-dns.com"
  "Яндекс|77.88.8.8 77.88.8.1|common.dot.dns.yandex.net"
)

dns_backup() {
  [ -d "$DNS_BACKUP" ] && return 0
  mkdir -p "$DNS_BACKUP"; dns_manager >"$DNS_BACKUP/manager"
  cp -P /etc/resolv.conf "$DNS_BACKUP/resolv.conf" 2>/dev/null
  log "DNS backup saved to $DNS_BACKUP"
}

write_resolv() {   # write_resolv "ip ip"
  local keep; keep=$(grep -E '^(search|domain)[[:space:]]' "$DNS_BACKUP/resolv.conf" 2>/dev/null || grep -E '^(search|domain)[[:space:]]' /etc/resolv.conf 2>/dev/null)
  rm -f /etc/resolv.conf.tmp
  {
    echo "# Создано deploy-teleport.sh $(date '+%F %T'). Откат: меню скрипта → DNS → вернуть исходные."
    [ -n "$keep" ] && echo "$keep"
    for ip in $1; do echo "nameserver $ip"; done
    echo "options timeout:2 attempts:2"
  } >/etc/resolv.conf.tmp
  [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
  mv -f /etc/resolv.conf.tmp /etc/resolv.conf; chmod 644 /etc/resolv.conf; fix_context /etc/resolv.conf
}

dns_point_to() {   # направить системный резолвер на адреса "ip ip"
  local m; m=$(cat "$DNS_BACKUP/manager" 2>/dev/null || dns_manager)
  case "$m" in
    resolved)
      mkdir -p "${RESOLVED_DROPIN%/*}"
      printf '# deploy-teleport.sh — откат: удалить файл и перезапустить systemd-resolved\n[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\nDNSOverTLS=no\n' "$1" >"$RESOLVED_DROPIN"
      systemctl restart systemd-resolved >>"$LOG" 2>&1 ;;
    nm)
      printf '# deploy-teleport.sh — NetworkManager не трогает resolv.conf\n[main]\ndns=none\n' >"$NM_DROPIN"
      systemctl reload NetworkManager >>"$LOG" 2>&1 || systemctl restart NetworkManager >>"$LOG" 2>&1
      write_resolv "$1" ;;
    *) write_resolv "$1" ;;
  esac
}

dns_restore() {
  [ -d "$DNS_BACKUP" ] || { info "DNS этим скриптом не менялся — откатывать нечего."; return 0; }
  local m; m=$(cat "$DNS_BACKUP/manager")
  rm -f "$RESOLVED_DROPIN" "$NM_DROPIN"
  if systemctl list-unit-files "$DOH_UNIT.service" >/dev/null 2>&1; then
    systemctl disable --now "$DOH_UNIT" >>"$LOG" 2>&1; rm -f "/etc/systemd/system/$DOH_UNIT.service"; systemctl daemon-reload
  fi
  rm -f "$DOH_BIN" "$DOH_CONF"; rmdir "${DOH_CONF%/*}" 2>/dev/null
  if [ -e "$DNS_BACKUP/resolv.conf" ] || [ -L "$DNS_BACKUP/resolv.conf" ]; then rm -f /etc/resolv.conf; cp -P "$DNS_BACKUP/resolv.conf" /etc/resolv.conf; fix_context /etc/resolv.conf; fi
  case "$m" in
    resolved) systemctl restart systemd-resolved >>"$LOG" 2>&1 ;;
    nm) systemctl reload NetworkManager >>"$LOG" 2>&1 || systemctl restart NetworkManager >>"$LOG" 2>&1 ;;
  esac
  rm -rf "$DNS_BACKUP"
  ok "Исходные настройки DNS восстановлены."
}

doh_stamp() {   # DoH-штамп dnscrypt без пиннинга сертификата: адрес, хост, путь
  _lp() { printf "\\x$(printf %02x ${#1})%s" "$1"; }
  { printf '\x02\x00\x00\x00\x00\x00\x00\x00\x00'; _lp "$1"; printf '\x00'; _lp "$2"; _lp "$3"; } | base64 -w0 | tr '+/' '-_' | tr -d '='
}

doh_install() {   # doh_install "ip ip" хост
  if [ ! -x "$DOH_BIN" ]; then
    [ -n "$DOH_ARCH" ] || { err "Для этой архитектуры DoH-прокси не поддерживается."; return 1; }
    local f="dnscrypt-proxy-linux_${DOH_ARCH}-${DOH_VER}.tar.gz" tmp="$CACHE_DIR/doh"
    rm -rf "$tmp"; mkdir -p "$tmp"
    run "Загрузка dnscrypt-proxy $DOH_VER" curl -fsSL --retry 3 -m 180 -o "$tmp/$f" "https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/$DOH_VER/$f" || return 1
    tar xzf "$tmp/$f" -C "$tmp" || return 1
    install -m 0755 "$tmp/linux-${DOH_ARCH}/dnscrypt-proxy" "$DOH_BIN" && fix_context "$DOH_BIN"; rm -rf "$tmp"
  fi
  if ss -Hlnu 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]|${DOH_LISTEN//./\\.}):53$"; then
    err "Порт 53 на ${DOH_LISTEN} или на всех адресах уже занят: $(ss -Hlnup 'sport = :53' | awk '{print $NF}' | head -1)"; return 1
  fi
  local names='' static='' i=0 ip
  for ip in $1; do
    i=$((i + 1)); names="${names:+$names, }'s$i'"
    static+="[static.s$i]"$'\n'"stamp = 'sdns://$(doh_stamp "$ip" "$2" /dns-query)'"$'\n'
  done
  mkdir -p "${DOH_CONF%/*}"
  cat >"$DOH_CONF" <<EOF
# deploy-teleport.sh — DoH-прокси ($2). Откат: меню скрипта → DNS → вернуть исходные.
listen_addresses = ['${DOH_LISTEN}:53']
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
server_names = [$names]
lb_strategy = 'first'
timeout = 3000
keepalive = 30
cache = true
cache_size = 4096
netprobe_timeout = -1
netprobe_address = '${1%% *}:443'
ignore_system_dns = true
bootstrap_resolvers = ['${1%% *}:53']
log_level = 2

[static]
$static
EOF
  cat >"/etc/systemd/system/$DOH_UNIT.service" <<EOF
[Unit]
Description=DNS-over-HTTPS proxy (dnscrypt-proxy, deploy-teleport.sh)
After=network-online.target
Wants=network-online.target nss-lookup.target
Before=nss-lookup.target

[Service]
ExecStart=$DOH_BIN -config $DOH_CONF
Restart=always
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  run "Проверка конфигурации DoH" "$DOH_BIN" -config "$DOH_CONF" -check || return 1
  run "Запуск DoH-прокси" systemctl enable --now "$DOH_UNIT" || return 1
  local _; for _ in $(seq 1 10); do "$DOH_BIN" -config "$DOH_CONF" -resolve example.com >>"$LOG" 2>&1 && return 0; sleep 1; done
  err "DoH-прокси запустился, но не отвечает (провайдер недоступен по HTTPS?)."; return 1
}

dns_change() {
  hdr "Замена DNS-серверов"
  local i p name ips doh
  for i in "${!DNS_PROVIDERS[@]}"; do
    IFS='|' read -r name ips doh <<<"${DNS_PROVIDERS[$i]}"
    printf '   %s%d)%s %s %s\n' "$CL" $((i + 1)) "$C0" "$(pad "$name" 26)" "$CD$ips${doh:+ · DoH: $doh}$C0"
  done
  printf '   %s%d)%s Свои адреса DNS-серверов\n   %s0)%s Отмена\n' "$CL" $(( ${#DNS_PROVIDERS[@]} + 1 )) "$C0" "$CL" "$C0"
  ask_num "Провайдер" $(( ${#DNS_PROVIDERS[@]} + 1 )) 1; p=$ANSWER
  [ "$p" -eq 0 ] && return 0
  local mode=plain
  if [ "$p" -le ${#DNS_PROVIDERS[@]} ]; then
    IFS='|' read -r name ips doh <<<"${DNS_PROVIDERS[$((p - 1))]}"
    if [ -n "$doh" ]; then
      say "   ${CL}1)${C0} Обычный DNS (порт 53)   ${CL}2)${C0} DNS-over-HTTPS (шифрованный, через локальный прокси dnscrypt-proxy)"
      ask_num "Режим" 2 2; [ "$ANSWER" -eq 2 ] && mode=doh; [ "$ANSWER" -eq 0 ] && return 0
    fi
  else
    while true; do
      ask "IP-адреса DNS-серверов через пробел или запятую" ""
      ips=; local bad=; for i in ${ANSWER//[,;]/ }; do if is_ip "$i"; then ips="${ips:+$ips }$i"; else bad="$bad $i"; fi; done
      [ -n "$bad" ] && { warn "Не IPv4-адреса:$bad"; continue; }
      [ -n "$ips" ] && break; warn "Нужен хотя бы один адрес."
    done; name="свои ($ips)"
  fi
  local cur; cur=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
  [ "$(dns_manager)" = resolved ] && cur=$(resolvectl dns 2>/dev/null | awk -F': ' '$2!=""{print $2; exit}' | awk '{print $1}')
  if [ ! -d "$DNS_BACKUP" ] && [[ "$cur" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
    warn "Сейчас DNS — локальный сервер $cur (обычно роутер). Если он резолвит локальные имена (*.lan),"
    warn "блокирует рекламу или маршрутизирует по доменам (podkop, VPN по спискам) — после замены это перестанет работать."
    ask_yn "Всё равно заменить?" n || return 0
  fi
  local fresh=0; [ -d "$DNS_BACKUP" ] || fresh=1
  dns_backup
  if [ "$mode" = doh ]; then
    if ! doh_install "$ips" "$doh"; then
      warn "DoH не включён. Системные DNS остались прежними."
      systemctl disable --now "$DOH_UNIT" >>"$LOG" 2>&1; [ $fresh = 1 ] && rm -rf "$DNS_BACKUP"; return 1
    fi
    dns_point_to "$DOH_LISTEN"
  else
    dns_point_to "$ips"
  fi
  info "Проверка после замены:"
  if dns_test; then ok "DNS переключён: $name$( [ "$mode" = doh ] && echo " (DNS-over-HTTPS)")"; state_set DNS_MODE "$name/$mode"
  else
    warn "С новыми DNS не всё разрешается."
    if ask_yn "Вернуть исходные настройки DNS?" y; then dns_restore; fi
  fi
}

dns_step() {   # шаг установки: проверить DNS, предложить замену
  dns_show
  if [ -d "$DNS_BACKUP" ] && ask_yn "DNS ранее изменён этим скриптом. Вернуть исходные настройки?" n; then dns_restore; fi
  if dns_test; then
    ok "DNS работает."
    ask_yn "Заменить DNS на публичные серверы (можно с шифрованием DoH)? Необязательно." n && dns_change
  else
    warn "Часть адресов не разрешается — установка может не пройти."
    ask_yn "Заменить DNS на публичные серверы сейчас?" y && dns_change
  fi
}

# ─── Teleport: версии, загрузка, бинарники ────────────────────────────────────
tp_installed() { [ -x "$BIN_DIR/teleport" ] || command -v teleport >/dev/null 2>&1 || [ -f "$UNIT" ] || [ -f /lib/systemd/system/teleport.service ] || [ -f /usr/lib/systemd/system/teleport.service ]; }
tp_version() { teleport version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | tr -d v; }
tp_pkg_managed() {   # установлен пакетом (deb/rpm) или teleport-update (/opt/teleport)?
  local p; p=$(readlink -f "$(command -v teleport 2>/dev/null)" 2>/dev/null)
  [[ "$p" == /opt/teleport/* ]] && return 0
  rpm -q teleport >/dev/null 2>&1 || rpm -q teleport-ent >/dev/null 2>&1 && return 0
  dpkg -s teleport >/dev/null 2>&1 && return 0
  return 1
}
tp_majors() {
  curl -fsSL -m 25 "$TP_INDEX/Release" 2>>"$LOG" | awk '/^Components:/{for(i=2;i<=NF;i++) if($i ~ /^stable\/v[0-9]+$/){v=substr($i,9); if(v+0<900) print v}}' | sort -n
}
tp_latest_in() {
  curl -fsSL -m 40 "$TP_INDEX/stable/v$1/binary-amd64/Packages.gz" 2>>"$LOG" | gzip -dc 2>/dev/null \
    | awk '/^Package: /{p=($2=="teleport")} p&&/^Version: /{print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}
ver_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

local_tarball() {   # найти заранее скачанный архив; $1 — версия или пусто (любая)
  local f
  for f in "$SCRIPT_DIR"/teleport-v${1:-*}-linux-"$ARCH"-bin.tar.gz "$PWD"/teleport-v${1:-*}-linux-"$ARCH"-bin.tar.gz; do
    [ -f "$f" ] && { echo "$f"; return 0; }
  done; return 1
}

tp_pick_version() {   # → $TP_TARGET
  TP_TARGET=; local majors last lt
  if [[ "${TELEPORT_SETUP_VERSION#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    TP_TARGET=${TELEPORT_SETUP_VERSION#v}; info "Версия задана через TELEPORT_SETUP_VERSION: $TP_TARGET"; return 0
  fi
  printf '  %s…%s Определяю последнюю версию Teleport' "$CD" "$C0"
  majors=$(tp_majors); last=$(echo "$majors" | tail -1)
  [ -n "$last" ] && TP_TARGET=$(tp_latest_in "$last")
  printf '\r\e[K'
  if [ -n "$TP_TARGET" ]; then ok "Последняя версия Teleport: $TP_TARGET"; return 0; fi
  warn "Не удалось получить список версий с apt.releases.teleport.dev."
  if lt=$(local_tarball ""); then
    TP_TARGET=$(basename "$lt" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'); info "Найден локальный архив: $lt"
    ask_yn "Установить из него версию $TP_TARGET?" y && return 0
  fi
  while true; do
    ask "Введите версию вручную (например 18.11.8)" ""
    [[ "${ANSWER#v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && { TP_TARGET=${ANSWER#v}; return 0; }
    warn "Формат версии: X.Y.Z"
  done
}

tp_fetch() {   # tp_fetch версия → $TP_TARBALL (проверенный архив)
  local v=$1 f="teleport-v$1-linux-$ARCH-bin.tar.gz" sum='' lf try
  sum=$(curl -fsSL -m 20 "$TP_CDN/$f.sha256" 2>>"$LOG" | awk '{print $1}')
  if lf=$(local_tarball "$v"); then
    info "Использую локальный архив: $lf"
    if [ -z "$sum" ]; then
      warn "Контрольную сумму с сайта получить не удалось — проверить архив нельзя."
      ask_yn "Использовать архив без проверки?" n || return 1
      TP_TARBALL=$lf; return 0
    fi
    if [ "$(sha256sum "$lf" | awk '{print $1}')" = "$sum" ]; then ok "Контрольная сумма совпадает"; TP_TARBALL=$lf; return 0; fi
    warn "Локальный архив повреждён (sha256 не совпадает) — скачаю заново."
  fi
  [ -n "$sum" ] || { err "Нет доступа к $TP_CDN. Скачайте $f вручную и положите рядом со скриптом."; return 1; }
  mkdir -p "$CACHE_DIR"; TP_TARBALL="$CACHE_DIR/$f"
  for try in 1 2; do
    if [ -f "$TP_TARBALL" ] && [ "$(sha256sum "$TP_TARBALL" | awk '{print $1}')" = "$sum" ]; then ok "Архив уже скачан и проверен"; return 0; fi
    rm -f "$TP_TARBALL"
    info "Загрузка $f (~230 МБ, докачка поддерживается):"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 -C - --progress-bar -o "$TP_TARBALL.part" "$TP_CDN/$f" \
      || curl -fL --retry 3 --connect-timeout 20 -C - --progress-bar -o "$TP_TARBALL.part" "$TP_CDN/$f"
    [ -f "$TP_TARBALL.part" ] && mv -f "$TP_TARBALL.part" "$TP_TARBALL"
    if [ -f "$TP_TARBALL" ] && [ "$(sha256sum "$TP_TARBALL" | awk '{print $1}')" = "$sum" ]; then ok "Загружено, sha256 совпадает"; return 0; fi
    warn "Архив не скачался целиком или повреждён (попытка $try)."
  done
  rm -f "$TP_TARBALL" "$TP_TARBALL.part"
  err "Не удалось скачать $f. Если сеть медленная — скачайте файл другим способом и положите рядом со скриптом:"
  err "$TP_CDN/$f"; return 1
}

tp_install_bins() {   # распаковать нужные бинарники и атомарно заменить в $BIN_DIR
  local tmp="$CACHE_DIR/extract" b
  rm -rf "$tmp"; mkdir -p "$tmp" "$BIN_DIR" "$DATA_DIR"
  run "Распаковка" tar xzf "$TP_TARBALL" -C "$tmp" teleport/teleport teleport/tctl teleport/tsh teleport/tbot teleport/fdpass-teleport || { rm -rf "$tmp"; return 1; }
  for b in teleport tctl tsh tbot fdpass-teleport; do
    install -m 0755 "$tmp/teleport/$b" "$BIN_DIR/.$b.new" && mv -f "$BIN_DIR/.$b.new" "$BIN_DIR/$b" || { rm -rf "$tmp"; return 1; }
  done
  rm -rf "$tmp"; fix_context "$BIN_DIR"/teleport "$BIN_DIR"/tctl "$BIN_DIR"/tsh "$BIN_DIR"/tbot "$BIN_DIR"/fdpass-teleport
  hash -r; ok "Установлено: $("$BIN_DIR/teleport" version 2>/dev/null | head -1)"
  case "$TP_TARBALL" in "$CACHE_DIR"/*) rm -f "$TP_TARBALL" ;; esac
}

# ─── сертификаты ──────────────────────────────────────────────────────────────
ACME_PROVIDERS=(
  "Cloudflare|dns_cf|CF_Token:s|API-токен: dash.cloudflare.com → My Profile → API Tokens → шаблон «Edit zone DNS» для нужной зоны."
  "reg.ru|dns_regru|REGRU_API_Username REGRU_API_Password:s|Логин reg.ru и альтернативный пароль API (ЛК → Настройки → API); IP этой машины добавьте в разрешённые."
  "Timeweb Cloud|dns_timeweb|TW_Token:s|API-токен: панель Timeweb Cloud → API и Terraform."
  "Beget|dns_beget|Beget_Username Beget_Password:s|Логин Beget и пароль API (ЛК → API → включить доступ к API)."
  "DuckDNS|dns_duckdns|DuckDNS_Token:s|Токен со страницы duckdns.org (домен должен быть *.duckdns.org)."
)

acme_sh() { "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_CONF" "$@"; }

acme_sh_install() {
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  local tmp="$CACHE_DIR/acme"; rm -rf "$tmp"; mkdir -p "$tmp"
  run "Загрузка acme.sh $ACME_SH_VER" curl -fsSL --retry 3 -m 120 -o "$tmp/a.tgz" "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACME_SH_VER.tar.gz" || return 1
  tar xzf "$tmp/a.tgz" -C "$tmp" || return 1
  ( cd "$tmp/acme.sh-$ACME_SH_VER" && ./acme.sh --install --home "$ACME_HOME" --config-home "$ACME_CONF" --cert-home "$ACME_CONF/certs" \
      --accountemail "$ACME_EMAIL" --nocron --noprofile ) >>"$LOG" 2>&1 || { rm -rf "$tmp"; err "Установка acme.sh не удалась."; return 1; }
  rm -rf "$tmp"; fix_context "$ACME_HOME"; ok "acme.sh $ACME_SH_VER установлен в $ACME_HOME"
}

acme_timer_install() {
  cat >"/etc/systemd/system/$ACME_UNIT.service" <<EOF
[Unit]
Description=Продление сертификата Teleport (acme.sh)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ACME_HOME/acme.sh --cron --home $ACME_HOME --config-home $ACME_CONF
EOF
  cat >"/etc/systemd/system/$ACME_UNIT.timer" <<EOF
[Unit]
Description=Проверка/продление сертификата Teleport дважды в сутки

[Timer]
OnCalendar=*-*-* 04,16:20:00
RandomizedDelaySec=45min
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && run "Таймер автопродления ($ACME_UNIT.timer)" systemctl enable --now "$ACME_UNIT.timer"
}

# получить сертификат через acme.sh (DNS-01); ставит $CERT_DOMAINS
cert_acme_dns() {
  local i name hook vars hint p v vname secret
  hdr "Сертификат через acme.sh (DNS-01)"
  say "  DNS-01 подтверждает владение доменом через API DNS-провайдера: открытые порты и"
  say "  публичный IP не нужны — подходит и для серверов в локальной сети."
  for i in "${!ACME_PROVIDERS[@]}"; do
    IFS='|' read -r name hook vars hint <<<"${ACME_PROVIDERS[$i]}"; printf '   %s%d)%s %s\n' "$CL" $((i + 1)) "$C0" "$name"
  done
  printf '   %s%d)%s Другой провайдер (любой из ~150, поддерживаемых acme.sh)\n' "$CL" $(( ${#ACME_PROVIDERS[@]} + 1 )) "$C0"
  ask_num "DNS-провайдер вашего домена" $(( ${#ACME_PROVIDERS[@]} + 1 )) 1; p=$ANSWER
  [ "$p" -eq 0 ] && return 1
  local -a envs=()
  if [ "$p" -le ${#ACME_PROVIDERS[@]} ]; then
    IFS='|' read -r name hook vars hint <<<"${ACME_PROVIDERS[$((p - 1))]}"
    info "$hint"
    for v in $vars; do
      vname=${v%:s}
      if [[ "$v" == *:s ]]; then ask_secret "$vname"; else ask "$vname" ""; while [ -z "$ANSWER" ]; do warn "Не может быть пустым."; ask "$vname" ""; done; fi
      envs+=("$vname=$ANSWER")
    done
  else
    info "Список провайдеров и их переменных: https://github.com/acmesh-official/acme.sh/wiki/dnsapi"
    while true; do
      ask "Имя модуля (например dns_gd, dns_aws, dns_yc)" ""; hook=${ANSWER,,}; hook=${hook%.sh}; [[ "$hook" == dns_* ]] || hook="dns_$hook"
      [[ "$hook" =~ ^dns_[a-z0-9_]+$ ]] && break; warn "Имя модуля — латиница/цифры, вида dns_xxx"
    done
    say "  Введите переменные модуля по одной в виде ИМЯ=значение. Пустая строка — закончить."
    while true; do
      read -r -p "  › " v || break; v=$(trim "$v"); [ -z "$v" ] && { [ ${#envs[@]} -gt 0 ] && break; warn "Нужна хотя бы одна переменная."; continue; }
      v=${v#export }; vname=${v%%=*}; secret=${v#*=}; secret=${secret#[\"\']}; secret=${secret%[\"\']}
      [[ "$v" == *=* && "$vname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { warn "Формат: ИМЯ=значение"; continue; }
      envs+=("$vname=$secret")
    done
  fi
  CERT_DOMAINS="$CLUSTER"
  ask_yn "Добавить в сертификат *.$CLUSTER (wildcard — нужен для доступа к веб-приложениям через Teleport)?" y && CERT_DOMAINS="$CLUSTER *.$CLUSTER"

  acme_sh_install || return 1
  local server=letsencrypt; [ "${TELEPORT_SETUP_ACME_STAGING:-0}" = 1 ] && { server=letsencrypt_test; warn "Тестовый режим: сертификат от staging CA (браузеры ему не доверяют)."; }
  run "CA по умолчанию: Let's Encrypt" acme_sh --set-default-ca --server "$server" || return 1
  run "Регистрация ACME-аккаунта ($ACME_EMAIL)" acme_sh --register-account -m "$ACME_EMAIL" --server "$server" || return 1
  local dargs=() d; for d in $CERT_DOMAINS; do dargs+=(-d "$d"); done
  info "Выпуск сертификата: DNS-запись, ожидание распространения, проверка — обычно 1–3 минуты."
  printf '  %s…%s Запрос сертификата для %s' "$CD" "$C0" "$CERT_DOMAINS"; log "RUN: acme.sh --issue --dns $hook ${dargs[*]}"
  env "${envs[@]}" "$ACME_HOME/acme.sh" --home "$ACME_HOME" --config-home "$ACME_CONF" --issue --server "$server" --dns "$hook" "${dargs[@]}" --keylength ec-256 </dev/null >>"$LOG" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
    printf '\r  %s✖%s Сертификат не выпущен (код %s)\n' "$CR" "$C0" "$rc"
    grep -E 'error|Error|invalid|denied|Unauthorized|Please' "$LOG" | grep -vE "_error_level|_stopRenewOnError|di='" | tail -n 6 | sed 's/^/    /'
    warn "Частые причины: неверный токен/пароль, у токена нет прав на зону, домен не в этом аккаунте провайдера."
    return 1
  fi
  printf '\r  %s✔%s Сертификат выпущен для %s\n' "$CG" "$C0" "$CERT_DOMAINS"
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  run "Установка сертификата в $CERT_DIR" acme_sh --install-cert -d "$CLUSTER" --ecc \
      --key-file "$CERT_DIR/tls.key" --fullchain-file "$CERT_DIR/tls.crt" \
      --reloadcmd "systemctl try-reload-or-restart teleport.service" || return 1
  chmod 600 "$CERT_DIR/tls.key"; fix_context "$CERT_DIR"
  acme_timer_install
  state_set ACME_DOMAINS "$CERT_DOMAINS"
}

cert_files() {   # свой сертификат (например, его привозит центральный ACME-сервер)
  local crt key
  hdr "Свой сертификат"
  while true; do
    ask "Путь к сертификату (fullchain, PEM)" ""; crt=$ANSWER
    ask "Путь к закрытому ключу (PEM)" ""; key=$ANSWER
    [ -r "$crt" ] && [ -r "$key" ] || { warn "Файл не найден или не читается."; ask_yn "Попробовать ещё раз?" y && continue; return 1; }
    openssl x509 -in "$crt" -noout 2>/dev/null || { warn "$crt — не PEM-сертификат."; continue; }
    if [ "$(openssl x509 -in "$crt" -noout -pubkey 2>/dev/null | sha256sum)" != "$(openssl pkey -in "$key" -pubout 2>/dev/null | sha256sum)" ]; then
      warn "Ключ не подходит к сертификату."; continue
    fi
    openssl x509 -in "$crt" -noout -checkend 0 >/dev/null || warn "Сертификат уже просрочен!"
    openssl x509 -in "$crt" -noout -checkhost "$CLUSTER" 2>/dev/null | grep -q 'does match' || warn "Сертификат не выдан на $CLUSTER — браузеры будут ругаться."
    break
  done
  mkdir -p "$CERT_DIR"; chmod 700 "$CERT_DIR"
  [ "$(readlink -f "$crt")" != "$CERT_DIR/tls.crt" ] && install -m 0644 "$crt" "$CERT_DIR/tls.crt"
  [ "$(readlink -f "$key")" != "$CERT_DIR/tls.key" ] && install -m 0600 "$key" "$CERT_DIR/tls.key"
  fix_context "$CERT_DIR"
  ok "Сертификат установлен. Для продления просто заменяйте $CERT_DIR/tls.{crt,key} — Teleport перечитывает их каждый час."
}

choose_cert_mode() {   # → $CERT_MODE
  say "  Как получать TLS-сертификат для веб-интерфейса и подключений:"
  say "   ${CL}1)${C0} acme.sh, DNS-01 — Let's Encrypt через API DNS-провайдера. ${CG}Работает и в локальной сети${C0}, можно wildcard."
  say "   ${CL}2)${C0} Встроенный ACME Teleport — проще всего, но нужен публичный домен и порт 443, открытый из интернета."
  say "   ${CL}3)${C0} Свой сертификат из файлов (например, его доставляет ваш ACME-сервер)."
  say "   ${CL}4)${C0} Самоподписанный — только для теста: браузер предупредит, tsh нужен --insecure."
  ask_num "Способ" 4 "${1:-1}"
  case "$ANSWER" in 1) CERT_MODE=acme-dns ;; 2) CERT_MODE=acme-teleport ;; 3) CERT_MODE=files ;; 4) CERT_MODE=self ;; 0) choose_cert_mode "$@" ;; esac
}

cert_apply() {   # выполнить выбранный способ; при неудаче предложить другой
  while true; do
    case "$CERT_MODE" in
      acme-dns) cert_acme_dns && return 0 ;;
      files) cert_files && return 0 ;;
      acme-teleport|self) return 0 ;;
    esac
    warn "Сертификат получить не удалось."
    say "   ${CL}1)${C0} Попробовать снова   ${CL}2)${C0} Выбрать другой способ   ${CL}3)${C0} Пока самоподписанный (сменить можно потом в меню)"
    ask_num "Что делаем" 3 1
    case "$ANSWER" in 2) choose_cert_mode ;; 3) CERT_MODE=self; return 0 ;; esac
  done
}

cert_live_info() {   # что реально отдаёт порт 443
  local out; out=$(timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$1" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)
  [ -z "$out" ] && { warn "На 443 сертификат не получен (Teleport ещё запускается или ACME не выпустил сертификат)."; return 1; }
  info "Сертификат на 443: $(sed -n 's/^subject=//p' <<<"$out" | sed 's/^ *//')"
  info "Выдан: $(sed -n 's/^issuer=//p' <<<"$out" | sed 's/^ *//')"
  info "Действует до: $(date -d "$(sed -n 's/^notAfter=//p' <<<"$out")" '+%F %H:%M' 2>/dev/null)"
}

# ─── конфигурация и служба ────────────────────────────────────────────────────
write_config() {
  local tls=
  case "$CERT_MODE" in
    acme-teleport) tls=$(printf '  acme:\n    enabled: "yes"\n    email: "%s"' "$ACME_EMAIL") ;;
    acme-dns) tls=$(printf '  https_keypairs:\n  - key_file: %s/tls.key\n    cert_file: %s/tls.crt\n  https_keypairs_reload_interval: 0s' "$CERT_DIR" "$CERT_DIR") ;;
    files) tls=$(printf '  https_keypairs:\n  - key_file: %s/tls.key\n    cert_file: %s/tls.crt\n  https_keypairs_reload_interval: 1h' "$CERT_DIR" "$CERT_DIR") ;;
    self) tls='  # сертификат самоподписанный (генерирует Teleport)' ;;
  esac
  [ -f "$CONF" ] && cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
  cat >"$CONF" <<EOF
# Создано deploy-teleport.sh $SCRIPT_VERSION — $(date '+%F %T')
# Один процесс: auth + proxy + ssh. Веб-интерфейс, tsh и агенты — всё через порт 443.
version: v3
teleport:
  nodename: "$NODENAME"
  data_dir: $DATA_DIR
  log:
    output: stderr
    severity: INFO
    format:
      output: text

auth_service:
  enabled: "yes"
  listen_addr: 0.0.0.0:3025
  cluster_name: "$CLUSTER"
  proxy_listener_mode: multiplex

ssh_service:
  enabled: "yes"

proxy_service:
  enabled: "yes"
  web_listen_addr: 0.0.0.0:443
  public_addr: "$CLUSTER:443"
$tls
EOF
  chmod 600 "$CONF"
}

validate_config() {
  run "Проверка конфигурации (teleport configure --test)" "$BIN_DIR/teleport" configure --test "$CONF" && return 0
  local last; last=$(ls -1t "$CONF".bak-* 2>/dev/null | head -1)
  if [ -n "$last" ]; then cp -p "$last" "$CONF"; warn "Конфигурация отклонена — восстановлена предыдущая ($last)."; fi
  return 1
}

cert_label() { case "$1" in acme-dns) echo "acme.sh DNS-01 (Let's Encrypt)";; acme-teleport) echo "встроенный ACME Teleport";; files) echo "свой из файлов";; self) echo "самоподписанный";; *) echo "${1:-?}";; esac; }

write_unit() {
  cat >"$UNIT" <<EOF
[Unit]
Description=Teleport Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=5
EnvironmentFile=-/etc/default/teleport
ExecStart=$BIN_DIR/teleport start --config $CONF --pid-file=/run/teleport.pid
ExecReload=/bin/sh -c "exec pkill -HUP -L -F /run/teleport.pid"
PIDFile=/run/teleport.pid
LimitNOFILE=524288

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

firewall_open() {
  if systemctl is-active -q firewalld 2>/dev/null; then
    if firewall-cmd -q --query-service=https 2>/dev/null || firewall-cmd -q --query-port=443/tcp 2>/dev/null; then ok "firewalld: 443/tcp уже открыт"
    else run "firewalld: открыть 443/tcp" sh -c 'firewall-cmd -q --permanent --add-service=https && firewall-cmd -q --reload'; fi
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    run "ufw: открыть 443/tcp" ufw allow 443/tcp
  else
    info "Фаервол (firewalld/ufw) не активен — если есть другой, откройте входящий 443/tcp."
  fi
}

port443_check() {
  local who; who=$(ss -Hltnp 'sport = :443' 2>/dev/null | grep -v teleport | grep -oE 'users:\(\("[^"]+' | cut -d'"' -f2 | sort -u | xargs)
  [ -z "$who" ] && return 0
  warn "Порт 443 уже занят: $who. Teleport должен слушать 443 сам."
  ask_yn "Остановить и отключить $who?" n && { for s in $who; do systemctl disable --now "$s" >>"$LOG" 2>&1 && ok "Остановлен $s"; done; return 0; }
  ask_yn "Продолжить без этого (Teleport не запустится, пока порт занят)?" n || exit 1
}

wait_healthy() {
  local i
  printf '  %s…%s Ожидание запуска Teleport' "$CD" "$C0"
  for i in $(seq 1 60); do
    if systemctl is-active -q teleport && tctl status >/dev/null 2>&1; then printf '\r  %s✔%s Teleport запущен и отвечает (%s с)\n' "$CG" "$C0" $((i * 2)); return 0; fi
    sleep 2
  done
  printf '\r  %s✖%s Teleport не поднялся за 2 минуты\n' "$CR" "$C0"
  journalctl -u teleport -n 25 --no-pager 2>/dev/null | sed 's/^/    /'
  return 1
}

tp_backup() {   # tp_backup метка [full] → $LAST_BACKUP
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  LAST_BACKUP="$BACKUP_DIR/teleport-$1-$(date +%Y%m%d-%H%M%S).tar.gz"
  local ex=(--exclude="${DATA_DIR#/}/log")
  [ "${2-}" = full ] && ex=()
  run "Резервная копия → $LAST_BACKUP" tar czf "$LAST_BACKUP" "${ex[@]}" -C / \
      $(for p in "${CONF#/}" etc/teleport "${DATA_DIR#/}" "${BIN_DIR#/}/teleport" "${BIN_DIR#/}/tctl" "${BIN_DIR#/}/tsh" "${BIN_DIR#/}/tbot" "${BIN_DIR#/}/fdpass-teleport"; do [ -e "/$p" ] && echo "$p"; done) || return 1
  ls -1t "$BACKUP_DIR"/teleport-*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f   # храним 3 последние
}

# ─── пользователи ─────────────────────────────────────────────────────────────
invite_url() { grep -oE 'https://[^ ]+/web/(invite|reset)/[A-Za-z0-9]+' <<<"$1" | head -1; }

user_exists() { tctl get "user/$1" >/dev/null 2>&1; }

create_admin() {   # create_admin имя логины → $INVITE
  local out i
  for i in 1 2 3 4 5; do
    out=$(tctl users add "$1" --roles=editor,access --logins="$2" 2>&1) && break
    grep -q 'already exists' <<<"$out" && break; sleep 3
  done
  log "tctl users add $1: $(sed -E 's#/web/invite/[A-Za-z0-9]+#/web/invite/***#' <<<"$out")"
  if grep -q 'already exists' <<<"$out"; then
    warn "Пользователь $1 уже существует."
    ask_yn "Сбросить ему пароль и 2FA (получить новую ссылку)?" y || return 1
    out=$(tctl users reset "$1" 2>&1)
  fi
  INVITE=$(invite_url "$out")
  [ -n "$INVITE" ] || { err "Не удалось получить ссылку: $out"; return 1; }
  INVITE=${INVITE/:443\//\/}
}

# ─── итоговая информация ──────────────────────────────────────────────────────
final_summary() {   # final_summary пользователь ссылка
  local url="https://$CLUSTER" ins=
  [ "$CERT_MODE" = self ] && ins=" --insecure"
  say
  say "${CB}${CH}╔══════════════════════════════════════════════════════════════════════╗${C0}"
  say "${CB}${CH}║                   Teleport готов к работе                            ║${C0}"
  say "${CB}${CH}╚══════════════════════════════════════════════════════════════════════╝${C0}"
  say
  say "  ${CL}Веб-интерфейс:${C0}   ${CB}$url${C0}"
  say "  ${CL}Пользователь:${C0}    ${CB}$1${C0} (роли editor + access — полный администратор)"
  say "  ${CL}Версия:${C0}          Teleport $(tp_version)"
  say
  say "  ${CB}Первый вход — ссылка-приглашение (действует 1 час):${C0}"
  say "  ${CG}$2${C0}"
  say
  say "  1. Откройте ссылку в браузере и задайте пароль."
  say "  2. Настройте второй фактор: отсканируйте QR-код приложением (Google Authenticator,"
  say "     Яндекс Ключ, Aegis и т.п.) или зарегистрируйте ключ безопасности / passkey."
  say "  3. Войдите на $url — сервер «$NODENAME» уже виден в списке Resources."
  [ "$CERT_MODE" = self ] && say "  ${CY}Сертификат самоподписанный: браузер покажет предупреждение — это ожидаемо.${C0}"
  [ "$CERT_MODE" = acme-teleport ] && say "  ${CY}Сертификат Let's Encrypt выпустится при первом обращении к $url (нужен доступ из интернета).${C0}"
  say
  say "  ${CB}Подключение из терминала (tsh):${C0}"
  say "    установить клиент: https://goteleport.com/download/ (раздел Teleport Community, «tsh»)"
  say "    ${CD}tsh login --proxy=$CLUSTER:443 --user=$1$ins${C0}"
  say "    ${CD}tsh ls${C0}                      — список серверов"
  say "    ${CD}tsh ssh root@$NODENAME${C0}"
  say
  say "  ${CB}Полезное:${C0}"
  say "    Ссылка истекла / забыли пароль — запустите скрипт снова → «Сбросить пароль»."
  say "    Добавить сервер — скрипт → «Токен для подключения сервера»."
  case "$CERT_MODE" in
    acme-dns) say "    Сертификат продлевается автоматически: таймер $ACME_UNIT.timer (acme.sh в $ACME_HOME)." ;;
    files) say "    Сертификат: заменяйте $CERT_DIR/tls.{crt,key} — Teleport перечитывает их каждый час." ;;
  esac
  say "    Конфигурация: $CONF · данные: $DATA_DIR · журнал скрипта: $LOG"
  say "    Логи Teleport: journalctl -u teleport -f"
  say
}

# ─── установка с нуля ─────────────────────────────────────────────────────────
collect_params() {
  hdr "Параметры"
  say "  Домен — адрес, по которому пользователи будут открывать Teleport (A-запись на этот сервер)."
  say "  ${CY}Важно: домен становится именем кластера, сменить его потом нельзя без переустановки.${C0}"
  ask_domain "Домен Teleport (например teleport.example.com)" "${CLUSTER-}"; CLUSTER=$ANSWER
  local hn; hn=$(hostname -s 2>/dev/null); [[ -z "$hn" || "$hn" == localhost* ]] && hn=teleport
  while true; do
    ask "Имя этого сервера в Teleport" "${NODENAME:-$hn}"; NODENAME=$ANSWER
    [[ "$NODENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] && break; warn "Латиница, цифры, точка, дефис, подчёркивание; без пробелов."
  done
  say; choose_cert_mode "$( case "${CERT_MODE-}" in acme-teleport) echo 2;; files) echo 3;; self) echo 4;; *) echo 1;; esac )"
  if [ "$CERT_MODE" = acme-dns ] || [ "$CERT_MODE" = acme-teleport ]; then
    say "  E-mail нужен Let's Encrypt для уведомлений о сертификате."
    ask_email "E-mail для Let's Encrypt" "${ACME_EMAIL-}"; ACME_EMAIL=$ANSWER
  fi
  say
  ask_username "Имя первого администратора Teleport" "${ADMIN_USER:-admin}"; ADMIN_USER=$ANSWER
  say "  Системные логины — под какими учётками Linux администратор сможет входить на серверы."
  ask_logins "Логины через запятую" "${ADMIN_LOGINS:-root}"; ADMIN_LOGINS=$ANSWER
}

show_params() {
  local m; m=$(cert_label "$CERT_MODE")
  hdr "Проверьте параметры"
  say "  ${CL}Домен (кластер):${C0}  $CLUSTER"
  say "  ${CL}Имя сервера:${C0}      $NODENAME"
  say "  ${CL}Сертификат:${C0}       $m"
  [ -n "${ACME_EMAIL-}" ] && [[ "$CERT_MODE" == acme-* ]] && say "  ${CL}E-mail:${C0}           $ACME_EMAIL"
  say "  ${CL}Администратор:${C0}    $ADMIN_USER (логины: $ADMIN_LOGINS)"
}

fresh_install() {
  hdr "1/8 Проверка системы";  prechecks
  hdr "2/8 Время";             time_fix
  hdr "3/8 Зависимости";       deps; ensure_ntp
  hdr "4/8 DNS";               dns_step
  if [ -d "$DATA_DIR" ] && [ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    warn "В $DATA_DIR остались данные прежней установки Teleport."
    if ask_yn "Удалить их (будет создана резервная копия)?" y; then tp_backup old-data full && rm -rf "${DATA_DIR:?}"/*; fi
  fi
  while true; do
    collect_params
    dns_check_domain "$CLUSTER" "$CERT_MODE"
    show_params
    ask_yn "Всё верно, начинаем установку?" y && break
    say "  Хорошо, пройдём параметры ещё раз (введённые значения подставлены)."
  done
  port443_check
  hdr "5/8 Установка Teleport"
  tp_pick_version
  tp_fetch "$TP_TARGET" || die "Установка прервана: архив Teleport не получен."
  tp_install_bins || die "Не удалось установить бинарники Teleport."
  hdr "6/8 Сертификат"
  cert_apply
  hdr "7/8 Настройка и запуск"
  write_config; ok "Конфигурация: $CONF"
  validate_config || die "Сгенерированная конфигурация не прошла проверку (подробности выше)."
  write_unit; ok "Служба: $UNIT"
  firewall_open
  run "Запуск teleport.service" systemctl enable --now teleport || true
  wait_healthy || die "Teleport не запустился. Проверьте: journalctl -u teleport -n 100"
  state_set CLUSTER "$CLUSTER"; state_set NODENAME "$NODENAME"; state_set CERT_MODE "$CERT_MODE"
  state_set ACME_EMAIL "${ACME_EMAIL-}"; state_set ADMIN_USER "$ADMIN_USER"; state_set INSTALLED "$(date '+%F %T')"
  hdr "8/8 Администратор"
  create_admin "$ADMIN_USER" "$ADMIN_LOGINS" || die "Teleport работает, но пользователя создать не удалось. Запустите скрипт снова → «Создать администратора»."
  ok "Пользователь $ADMIN_USER создан"
  [ "$CERT_MODE" != acme-teleport ] && cert_live_info "$CLUSTER"
  final_summary "$ADMIN_USER" "$INVITE"
}

# ─── служебное меню ───────────────────────────────────────────────────────────
load_state() {
  CLUSTER=$(state_get CLUSTER); NODENAME=$(state_get NODENAME); CERT_MODE=$(state_get CERT_MODE); ACME_EMAIL=$(state_get ACME_EMAIL)
  [ -z "$CLUSTER" ] && [ -f "$CONF" ] && CLUSTER=$(sed -n 's/^ *cluster_name: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONF" | head -1)
  [ -z "$NODENAME" ] && [ -f "$CONF" ] && NODENAME=$(sed -n 's/^ *nodename: *"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONF" | head -1)
  if [ -z "$CERT_MODE" ] && [ -f "$CONF" ]; then
    if grep -A2 '^  acme:' "$CONF" | grep -q 'enabled: "yes"'; then CERT_MODE=acme-teleport
    elif grep -q https_keypairs: "$CONF"; then CERT_MODE=files; else CERT_MODE=self; fi
  fi
}

status_header() {
  local v st
  v=$(tp_version); st=$(systemctl is-active teleport 2>/dev/null)
  hdr "Teleport уже установлен"
  info "Версия: ${CB}${v:-?}${C0}   служба: $( [ "$st" = active ] && echo "${CG}работает${C0}" || echo "${CR}${st:-нет}${C0}" )"
  info "Кластер: ${CLUSTER:-?}   сервер: ${NODENAME:-?}   сертификат: $(cert_label "$CERT_MODE")"
  tp_pkg_managed && info "Установлен пакетом/teleport-update — обновление через пакетный менеджер."
}

menu_update() {
  hdr "Обновление Teleport"
  local cur majors cm next target
  cur=$(tp_version); [ -n "$cur" ] || { err "Не удалось определить текущую версию."; return 1; }
  if tp_pkg_managed; then
    info "Teleport установлен пакетом — обновляю штатно через $PKG (в пределах текущей ветки v${cur%%.*})."
    case "$PKG" in
      apt-get) run "apt: обновление teleport" sh -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade "teleport*"' ;;
      dnf|yum) run "$PKG: обновление teleport" "$PKG" -y -q upgrade 'teleport*' ;;
      zypper) run "zypper: обновление teleport" zypper --non-interactive update 'teleport*' ;;
    esac
    systemctl try-restart teleport; wait_healthy; ok "Версия: $(tp_version)"
    info "Переход на следующую мажорную версию — сменой ветки репозитория (stable/vNN) по документации Teleport."
    return 0
  fi
  printf '  %s…%s Проверяю доступные версии' "$CD" "$C0"
  majors=$(tp_majors); cm=${cur%%.*}; next=$((cm + 1)); printf '\r\e[K'
  [ -n "$majors" ] || { err "Список версий недоступен (apt.releases.teleport.dev). Проверьте DNS/сеть."; return 1; }
  if grep -qx "$next" <<<"$majors"; then target=$(tp_latest_in "$next"); else target=$(tp_latest_in "$cm"); fi
  [ -n "$target" ] || { err "Не удалось определить целевую версию."; return 1; }
  info "Установлена: $cur   доступна: $target"
  if ! ver_gt "$target" "$cur"; then ok "Обновление не требуется — установлена актуальная версия."; return 0; fi
  [ "${target%%.*}" != "$cm" ] && warn "Мажорное обновление v$cm → v${target%%.*}. Teleport обновляют по одной мажорной версии за раз."
  [ "$(echo "$majors" | tail -1)" -gt "$next" ] 2>/dev/null && info "После этого обновления запустите его ещё раз — есть и более новые ветки."
  ask_yn "Обновить $cur → $target?" y || return 0
  tp_fetch "$target" || return 1
  run "Остановка Teleport" systemctl stop teleport
  tp_backup "$cur" || { systemctl start teleport; err "Резервная копия не создана — обновление отменено."; return 1; }
  local bak=$LAST_BACKUP
  if tp_install_bins && run "Запуск Teleport" systemctl start teleport && wait_healthy; then
    ok "Обновлено до $(tp_version). Резервная копия: $bak"; return 0
  fi
  err "После обновления Teleport не работает."
  if ask_yn "Откатить на $cur из резервной копии?" y; then
    systemctl stop teleport
    find "${DATA_DIR:?}" -mindepth 1 -maxdepth 1 ! -name log -exec rm -rf {} +   # журнал аудита (log/) не в копии — сохраняем
    tar xzf "$bak" -C / && systemctl start teleport && wait_healthy && ok "Откат выполнен: $(tp_version)"
  fi
}

menu_add_admin() {
  hdr "Новый администратор"
  ask_username "Имя пользователя" ""; local u=$ANSWER
  ask_logins "Системные логины через запятую" root
  create_admin "$u" "$ANSWER" || return 1
  ok "Готово. Ссылка для $u (действует 1 час):"; say "  ${CG}$INVITE${C0}"
}

menu_reset() {
  hdr "Сброс пароля и второго фактора"
  tctl users ls 2>/dev/null | sed 's/^/  /'
  local u out
  ask_username "Кому сбросить" "$(state_get ADMIN_USER)"; u=$ANSWER
  user_exists "$u" || { err "Пользователя $u нет."; return 1; }
  out=$(tctl users reset "$u" 2>&1); INVITE=$(invite_url "$out"); INVITE=${INVITE/:443\//\/}
  [ -n "$INVITE" ] || { err "$out"; return 1; }
  ok "Пароль и 2FA сброшены. Ссылка для $u (действует 8 часов): "; say "  ${CG}$INVITE${C0}"
}

menu_users() { hdr "Пользователи"; tctl users ls 2>&1 | sed 's/^/  /'; }

menu_token() {
  hdr "Подключение нового сервера (узла)"
  local out tok
  out=$(tctl tokens add --type=node --ttl=1h --format=text 2>&1) || { err "$out"; return 1; }
  tok=$(tail -1 <<<"$out" | tr -d '[:space:]')
  ok "Токен (действует 1 час): ${CB}$tok${C0}"
  say "  На подключаемом сервере (нужен только исходящий доступ к $CLUSTER:443):"
  say "    ${CD}curl -fsSL https://cdn.teleport.dev/install.sh | bash -s $(tp_version) oss${C0}"
  say "    ${CD}teleport node configure --output=file --proxy=$CLUSTER:443 --token=$tok${C0}"
  say "    ${CD}systemctl enable --now teleport${C0}"
  say "  Если install.sh не знает вашу ОС — поставьте бинарники так же, как этот скрипт (tar.gz с cdn.teleport.dev)."
}

menu_cert() {
  hdr "Сертификат"
  cert_live_info "$CLUSTER"
  info "Способ: $(cert_label "$CERT_MODE")"
  [ "$CERT_MODE" = acme-dns ] && info "Автопродление: $(systemctl list-timers "$ACME_UNIT.timer" --no-pager 2>/dev/null | awk 'NR==2{print "следующая проверка "$1" "$2" "$3}')"
  say "   ${CL}1)${C0} Продлить сейчас (только acme.sh)   ${CL}2)${C0} Сменить способ получения   ${CL}0)${C0} Назад"
  ask_num "Действие" 2 0
  case "$ANSWER" in
    1) [ "$CERT_MODE" = acme-dns ] || { warn "Доступно только для способа acme.sh."; return 0; }
       run "Принудительное продление" acme_sh --renew -d "$CLUSTER" --ecc --force && cert_live_info "$CLUSTER" ;;
    2) choose_cert_mode
       if [[ "$CERT_MODE" == acme-* ]]; then ask_email "E-mail для Let's Encrypt" "$ACME_EMAIL"; ACME_EMAIL=$ANSWER; fi
       cert_apply
       write_config; validate_config || return 1
       state_set CERT_MODE "$CERT_MODE"; state_set ACME_EMAIL "$ACME_EMAIL"
       [ "$CERT_MODE" != acme-dns ] && systemctl disable --now "$ACME_UNIT.timer" >>"$LOG" 2>&1
       run "Перезапуск Teleport" systemctl restart teleport && wait_healthy && sleep 2 && cert_live_info "$CLUSTER" ;;
  esac
}

menu_dns() {
  while true; do
    hdr "DNS"; dns_show
    say "   ${CL}1)${C0} Проверить   ${CL}2)${C0} Заменить на публичные / DoH   ${CL}3)${C0} Вернуть исходные   ${CL}4)${C0} Проверить домен $CLUSTER   ${CL}0)${C0} Назад"
    ask_num "Действие" 4 0
    case "$ANSWER" in 1) dns_test ;; 2) dns_change ;; 3) dns_restore ;; 4) dns_check_domain "$CLUSTER" "$CERT_MODE" ;; 0) return 0 ;; esac
  done
}

menu_status() {
  hdr "Состояние"
  systemctl status teleport --no-pager -n 0 2>&1 | sed -n '1,5p' | sed 's/^/  /'
  tctl status 2>&1 | head -2 | sed 's/^/  /'
  info "Серверов в кластере: $(tctl nodes ls --format=json 2>/dev/null | grep -c '"hostname"')   пользователей: $(tctl users ls 2>/dev/null | tail -n +3 | grep -c .)"
  say "  ${CD}── журнал (последние 15 строк, полностью: journalctl -u teleport) ──${C0}"
  journalctl -u teleport -n 15 --no-pager -o short 2>/dev/null | sed -E 's/ [0-9T:.+-]{25,} / /' | cut -c1-200 | sed 's/^/  /'
  ask_yn "Перезапустить Teleport?" n && run "Перезапуск" systemctl restart teleport && wait_healthy
}

menu_uninstall() {
  hdr "Удаление Teleport"
  warn "Будут удалены служба и бинарники Teleport. Перед удалением создаётся полная резервная копия."
  ask_yn "Точно удалить Teleport?" n || return 0
  local keepdata=1; ask_yn "Удалить также данные и конфигурацию ($DATA_DIR, $CONF, /etc/teleport)?" n && keepdata=0
  systemctl stop teleport >>"$LOG" 2>&1
  tp_backup uninstall full || { ask_yn "Резервная копия не создана. Всё равно удалить?" n || return 1; }
  systemctl disable teleport >>"$LOG" 2>&1; rm -f "$UNIT"
  rm -f "$BIN_DIR"/{teleport,tctl,tsh,tbot,fdpass-teleport}
  if [ $keepdata = 0 ]; then rm -rf "${DATA_DIR:?}" "$CONF" "$CONF".bak-* /etc/teleport; fi
  if [ -f "/etc/systemd/system/$ACME_UNIT.timer" ]; then
    systemctl disable --now "$ACME_UNIT.timer" >>"$LOG" 2>&1; rm -f "/etc/systemd/system/$ACME_UNIT".{timer,service}
    ask_yn "Удалить acme.sh и его настройки ($ACME_HOME, $ACME_CONF — там токен DNS-провайдера)?" y && rm -rf "$ACME_HOME" "$ACME_CONF"
  fi
  systemctl daemon-reload; rm -f "$STATE"
  ok "Teleport удалён.${LAST_BACKUP:+ Резервная копия: $LAST_BACKUP}"
  [ -d "$DNS_BACKUP" ] && info "Настройки DNS не трогал — откат через этот скрипт («DNS» при новой установке) или вручную."
  info "Правило фаервола для 443/tcp оставлено."
  exit 0
}

menu_installed() {
  load_state
  while true; do
    status_header
    say
    say "   ${CL}1)${C0} Проверить и установить обновление"
    say "   ${CL}2)${C0} Создать администратора"
    say "   ${CL}3)${C0} Сбросить пароль / 2FA пользователя"
    say "   ${CL}4)${C0} Список пользователей"
    say "   ${CL}5)${C0} Токен для подключения нового сервера"
    say "   ${CL}6)${C0} Сертификат: состояние, продление, смена способа"
    say "   ${CL}7)${C0} DNS: проверка, замена (в т.ч. DoH), откат"
    say "   ${CL}8)${C0} Время: проверка синхронизации"
    say "   ${CL}9)${C0} Состояние и журнал Teleport"
    say "  ${CL}10)${C0} Удалить Teleport"
    say "   ${CL}0)${C0} Выход"
    ask_num "Выберите действие" 10 0
    case "$ANSWER" in
      1) menu_update ;; 2) menu_add_admin ;; 3) menu_reset ;; 4) menu_users ;; 5) menu_token ;;
      6) menu_cert ;; 7) menu_dns ;; 8) hdr "Время"; time_fix ;; 9) menu_status ;; 10) menu_uninstall ;;
      0) exit 0 ;;
    esac
    say; read -r -p "  ${CD}Enter — вернуться в меню${C0} " _ || exit 0
  done
}

# ─── точка входа ──────────────────────────────────────────────────────────────
main() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустите от root: sudo bash $0"; exit 1; }
  if [ ! -t 0 ]; then
    if [ -r /dev/tty ]; then exec </dev/tty; else echo "Скрипт интерактивный — нужен терминал."; exit 1; fi
  fi
  mkdir -p "${LOG%/*}" "$STATE_DIR"; touch "$LOG"; chmod 600 "$LOG"
  if [ "$(locale charmap 2>/dev/null)" != UTF-8 ]; then   # иначе кириллица считается байтами
    for l in C.UTF-8 C.utf8 en_US.UTF-8 ru_RU.UTF-8; do locale -a 2>/dev/null | grep -qix "${l/UTF-8/utf8}" && { export LC_CTYPE=$l; break; }; done
  fi
  log "=== deploy-teleport.sh $SCRIPT_VERSION start ==="
  export PATH="$BIN_DIR:$PATH"
  detect_os
  say "${CB}${CH}Teleport Community Edition — установка и обслуживание${C0} ${CD}(deploy-teleport.sh $SCRIPT_VERSION)${C0}"
  if tp_installed; then
    menu_installed
  else
    say "  Teleport на этой машине не найден — начнём установку с нуля."
    say "  ${CD}Ответы можно редактировать стрелками; Enter принимает значение по умолчанию; Ctrl+C — выход.${C0}"
    fresh_install
  fi
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"   # при source (для тестов) только функции

