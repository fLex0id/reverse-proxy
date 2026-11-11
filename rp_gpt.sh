#!/usr/bin/env bash
# rp — цепочка «клиенты WG → VPS-1 (РФ) → туннель, устойчивый к ТСПУ → VPS-2 (выход)».
# Локальная сборка 1.1.4-hardened-priority: приоритет XHTTP, гистерезис и fail-closed.
# Один файл: роль VPS-1 (сервер, меню, генератор) или VPS-2 (блок на чистом bash, сторож).
# Образец по структуре и стилю — tt.sh; отступления помечены «ОТСТУПЛЕНИЕ» с причиной.
# Rocky Linux 9/10. Конфигурация: /etc/rp/rp.conf (единственный источник правды).
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
SELF_VERSION="1.1.4-hardened-priority"

# ── Пути и константы ─────────────────────────────────────────────────────
ETC=/etc/rp
CONF=$ETC/rp.conf
CLIENTS=$ETC/clients.tsv
LIB=/usr/local/lib/rp
STATE=/var/lib/rp
ASSETS=$STATE/assets
BK_DIR=$STATE/backup
LOG=/var/log/rp.log
XRAY_BIN=/usr/local/bin/xray
HY2_BIN=/usr/local/bin/hysteria
SELF_BIN=/usr/local/bin/rp
# Версии на случай, если GitHub не ответил при установке; закрепляются в rp.conf.
# Новые версии берутся из ленты релизов (меню «Обновления»), принимаются только после проверки и с откатом.
XRAY_PINNED="26.4.25"
HY2_PINNED="2.8.2"
RU_REPO="runetfreedom/russia-v2ray-rules-dat"
SOCKS_PORT=1080
# Адрес для установки команды rp и обновления самого скрипта (можно переопределить переменной RP_URL)
RP_URL="${RP_URL:-https://raw.githubusercontent.com/fLex0id/reverse-proxy/main/rp.sh}"

declare -gA CFG=()
ASSUME_YES="${ASSUME_YES:-0}"

# ── UI ───────────────────────────────────────────────────────────────────
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  c() { printf '\033[38;5;%sm' "$1"; }; R=$'\033[0m'; B=$'\033[1m'
  C_ACC=$(c 39); C_OK=$(c 42); C_WARN=$(c 214); C_ERR=$(c 203); C_DIM=$(c 245)
else
  R=""; B=""; C_ACC=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""
fi
export LC_ALL=C.UTF-8 2>/dev/null || true

ok()   { printf '  %s✓%s %s\n' "$C_OK" "$R" "$*"; }
note() { printf '  %s%s%s\n' "$C_DIM" "$*" "$R"; }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$R" "$*" >&2; }
err()  { printf '  %s✗%s %s\n' "$C_ERR" "$R" "$*" >&2; }
die()  { err "$*"; exit 1; }
rule() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────" "$R"; }
banner() { printf '\n%s%s◆ %s%s' "$B" "$C_ACC" "$1" "$R"; [[ -n "${2:-}" ]] && printf '  %s%s%s' "$C_DIM" "$2" "$R"; printf '\n'; rule; }
section() { printf '\n%s%s%s\n' "$B" "$1" "$R"; shift; local l; for l in "$@"; do note "$l"; done; }
cls() { [[ -t 1 ]] && printf '\033[H\033[2J'; return 0; }
pause() { [[ -t 0 ]] && { printf '\n%s  Любая клавиша — назад%s' "$C_DIM" "$R"; read -rsn1 _ </dev/tty || true; }; return 0; }
STEP_N=0; STEP_I=0
steps() { STEP_N=$1; STEP_I=0; }
step() { STEP_I=$((STEP_I + 1)); printf '\n%s%s%d/%d%s  %s\n' "$B" "$C_ACC" "$STEP_I" "$STEP_N" "$R" "$*"; }
dot_state() { if systemctl is-active --quiet "$1" 2>/dev/null; then printf '%s●%s работает' "$C_OK" "$R"; else printf '%s●%s остановлена' "$C_ERR" "$R"; fi; }

KV_W=18
card() { printf '  %s┌─ %s%s\n' "$C_DIM" "$1" "$R"; }
kv() { printf '  %s│%s %-*s %s\n' "$C_DIM" "$R" "$KV_W" "$1" "$2"; }
card_line() { printf '  %s│%s %s\n' "$C_DIM" "$R" "$*"; }
card_end() { printf '  %s└─%s\n' "$C_DIM" "$R"; }

# run «Что делаем» команда… — вывод в журнал, на экране спиннер и итог.
run() {
  local what=$1; shift
  local t0=$SECONDS rc pid i=0 fr=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) off
  mkdir -p "$(dirname "$LOG")"; printf '\n### %s: %s\n' "$(date '+%F %T')" "$what" >>"$LOG"
  off=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do printf '\r  %s%s%s %s' "$C_ACC" "${fr[i % 10]}" "$R" "$what"; i=$((i + 1)); sleep 0.1; done
    printf '\r\033[K'
  fi
  wait "$pid"; rc=$?
  if ((rc == 0)); then
    local dt=$((SECONDS - t0)); ok "$what$( ((dt >= 3)) && printf ' (%d с)' "$dt")"
  else
    err "$what"; tail -c +"$((off + 1))" "$LOG" | tail -n 12 | sed 's/^/    /' >&2   # только вывод этого шага
  fi
  return $rc
}

# ask ПЕРЕМЕННАЯ «Вопрос» [умолч] [regex] [текст ошибки] [функция-проверка]
ask() {
  local _un=$1 _uq=$2 _ud=${3:-} _ure=${4:-} _uer=${5:-Неверное значение} _uf=${6:-} _uv
  _uv=${!_un:-}
  if [[ -n "$_uv" ]] && { [[ -z "$_ure" || "$_uv" =~ $_ure ]]; } && { [[ -z "$_uf" ]] || "$_uf" "$_uv"; }; then return 0; fi
  if [[ ! -t 0 ]]; then
    [[ -n "$_ud" ]] || die "Нужно значение «$_uq» (нет терминала)"; printf -v "$_un" '%s' "$_ud"; return 0
  fi
  while :; do
    printf '  %s%s%s%s %s›%s ' "$B" "$_uq" "$R" "${_ud:+ [$_ud]}" "$C_ACC" "$R"
    read -r _uv </dev/tty || die "Ввод прерван"
    _uv=${_uv:-$_ud}
    if [[ -n "$_uv" ]] && { [[ -z "$_ure" || "$_uv" =~ $_ure ]]; } && { [[ -z "$_uf" ]] || "$_uf" "$_uv"; }; then printf -v "$_un" '%s' "$_uv"; return 0; fi
    warn "$_uer"
  done
}
yesno() {
  local q=$1 d=${2:-y} a
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || { [[ $d == y ]]; return; }
  while :; do
    printf '  %s%s%s [%s] %s›%s ' "$B" "$q" "$R" "$([[ $d == y ]] && echo Y/n || echo y/N)" "$C_ACC" "$R"
    read -r a </dev/tty || return 1; a=${a:-$d}
    case ${a,,} in y|yes|д|да) return 0 ;; n|no|н|нет) return 1 ;; esac
  done
}
# choose ПЕРЕМЕННАЯ «Заголовок» «ключ-умолч» «ключ|Название|пояснение»…
choose() {
  local _cn=$1 _ct=$2 _cd=$3; shift 3
  local -a keys=() items=("$@"); local i=0 it k n e sel
  [[ -n "${!_cn:-}" ]] && for it in "${items[@]}"; do [[ ${it%%|*} == "${!_cn}" ]] && return 0; done
  for it in "${items[@]}"; do keys+=("${it%%|*}"); done
  [[ -t 0 ]] || { printf -v "$_cn" '%s' "$_cd"; return 0; }
  printf '\n  %s%s%s\n' "$B" "$_ct" "$R"
  for it in "${items[@]}"; do
    i=$((i + 1)); k=${it%%|*}; e=${it#*|}; n=${e%%|*}; e=${e#"$n"}; e=${e#|}
    printf '   %s%d%s  %s%s%s%s\n' "$C_ACC" "$i" "$R" "$B" "$n" "$R" "${e:+  ${C_DIM}$e${R}}"
  done
  while :; do
    printf '  Номер %s[%s]%s %s›%s ' "$C_DIM" "$_cd" "$R" "$C_ACC" "$R"; read -r sel </dev/tty || die "Ввод прерван"
    [[ -z "$sel" ]] && { printf -v "$_cn" '%s' "$_cd"; return 0; }
    [[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#keys[@]})) && { printf -v "$_cn" '%s' "${keys[sel-1]}"; return 0; }
    warn "Введите число от 1 до ${#keys[@]}"
  done
}
# Меню
MI_W=34
mhead() { printf '\n  %s%s%s\n' "$C_DIM" "$1" "$R"; }
mi() { printf '   %s%2s%s  %-*s %s%s%s\n' "$C_ACC" "$1" "$R" "$MI_W" "$2" "$C_DIM" "${3:-}" "$R"; }
mpick() { printf '\n  %s›%s ' "$C_ACC" "$R"; read -r "$1" </dev/tty || exit 0; }
pick_from() { # pick_from ПЕРЕМЕННАЯ «Заголовок» элементы… (номер или имя; один элемент — Enter)
  local _pn=$1 _pt=$2; shift 2; local -a a=("$@"); local s i
  ((${#a[@]})) || return 1
  if ((${#a[@]} == 1)); then printf -v "$_pn" '%s' "${a[0]}"; return 0; fi
  printf '\n  %s%s%s\n' "$B" "$_pt" "$R"; for i in "${!a[@]}"; do printf '   %s%d%s  %s\n' "$C_ACC" $((i + 1)) "$R" "${a[i]}"; done
  while :; do
    printf '  Номер или имя %s›%s ' "$C_ACC" "$R"; read -r s </dev/tty || return 1
    [[ $s =~ ^[0-9]+$ ]] && ((s >= 1 && s <= ${#a[@]})) && { printf -v "$_pn" '%s' "${a[s-1]}"; return 0; }
    for i in "${!a[@]}"; do [[ ${a[i]} == "$s" ]] && { printf -v "$_pn" '%s' "$s"; return 0; }; done
    warn "Нет такого элемента"
  done
}

# ── Конфигурация ─────────────────────────────────────────────────────────
conf_load() {
  CFG=(); [[ -f $CONF ]] || return 0
  local l k v
  while IFS= read -r l || [[ -n $l ]]; do
    [[ $l =~ ^[A-Z0-9_]+=\".*\"$ ]] || continue
    k=${l%%=*}; v=${l#*=\"}; v=${v%\"}; CFG[$k]=$v
  done <"$CONF"
}
cf() { printf '%s' "${CFG[$1]:-${2:-}}"; }
# conf_set КЛЮЧ ЗНАЧ … — атомарно; значения без " $ ` \ и перевода строки
conf_set() {
  local k v tmp; mkdir -p "$ETC"; touch "$CONF"; tmp=$(mktemp "$ETC/.rp.XXXXXX")
  cp -p "$CONF" "$tmp"
  while (($# >= 2)); do
    k=$1; v=$2; shift 2
    [[ $k =~ ^[A-Z0-9_]+$ ]] || { rm -f "$tmp"; die "Неверное имя параметра: $k"; }
    [[ $v == *[\"\$\`\\]* || $v == *$'\n'* ]] && { rm -f "$tmp"; die "Недопустимые символы в значении $k"; }
    grep -v "^${k}=" "$tmp" >"$tmp.n" || true; mv "$tmp.n" "$tmp"
    printf '%s="%s"\n' "$k" "$v" >>"$tmp"
  done
  chmod 600 "$tmp"; mv "$tmp" "$CONF"; conf_load
}

rand_hex() { openssl rand -hex "$1"; }
rand_pass() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }
uuid() { cat /proc/sys/kernel/random/uuid; }

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
fw_open() { # fw_open порт/прото
  [[ $(fw_kind) == firewalld ]] || return 0
  firewall-cmd --permanent --add-port="$1" >/dev/null && firewall-cmd --add-port="$1" >/dev/null
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
import glob, os, re, tempfile
rid = re.compile(r'^\[crb\]\s*$')
for path in glob.glob('/etc/yum.repos.d/*.repo'):
    try:
        with open(path, encoding='utf-8') as f: lines = f.readlines()
    except OSError:
        continue
    for i, line in enumerate(lines):
        if rid.match(line.strip()):
            j = i + 1
            while j < len(lines) and not lines[j].lstrip().startswith('['): j += 1
            section = ''.join(lines[i+1:j])
            if re.search(r'(?m)^\s*enabled\s*=', section):
                section = re.sub(r'(?m)^(\s*enabled\s*=\s*)\S+', r'\g<1>1', section)
            else:
                section = 'enabled=1\n' + section
            lines[i+1:j] = [section]
            fd, tmp = tempfile.mkstemp(prefix='.rp-crb-', dir=os.path.dirname(path))
            with os.fdopen(fd, 'w', encoding='utf-8') as f: f.writelines(lines)
            os.chmod(tmp, os.stat(path).st_mode & 0o777)
            os.replace(tmp, path)
            raise SystemExit(0)
raise SystemExit(1)
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

# ── Python-генератор ─────────────────────────────────────────────────────
RP_PY=$LIB/rp.py
py() { RP_CONF=$CONF RP_CLIENTS=$CLIENTS RP_ETC=$ETC python3 -I "$RP_PY" "$@"; }

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
secrets_extra() { # пароль локального SOCKS, пароль обфускации Hysteria2
  [[ -n $(cf SOCKS_PASS) ]] || conf_set SOCKS_USER "rp$(rand_hex 3)" SOCKS_PASS "$(rand_pass)"
  [[ -n $(cf HY2O_OBFS) ]] || conf_set HY2O_OBFS "$(rand_pass)"
}
hy2_cert() { # самоподписанный сертификат: DPI его не видит, клиент проверяет pinSHA256
  local sni=$1 fp
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

# ── SNI / masquerade: кандидаты и проверка с VPS-1 ───────────────────────
# Для Reality на сервере в РФ лучше сайты из РФ: адрес сервера и SNI выглядят согласованно.
# Список — пул кандидатов: рабочие определяются проверкой с самого VPS-1 (TLS 1.3, h2, X25519).
SNI_RU=(www.rzd.ru www.mos.ru www.aeroflot.ru www.vtb.ru www.pochta.ru www.hh.ru www.drom.ru www.lenta.com
  www.dns-shop.ru www.citilink.ru www.mvideo.ru www.sportmaster.ru www.ozon.ru www.sberbank.ru ya.ru)
SNI_WORLD=(www.lovelive-anime.jp www.msi.com www.asus.com www.gigabyte.com www.logitech.com www.razer.com
  www.corsair.com www.synology.com www.mikrotik.com www.jetbrains.com www.sap.com www.cisco.com www.lenovo.com
  www.canon.com www.nikon.com www.philips.com www.bosch.com www.siemens.com www.decathlon.com www.ikea.com
  www.zalando.com dl.google.com www.microsoft.com)
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
  v=$(printf '\n' | timeout 9 openssl s_client -brief -connect "$h:443" \
      -servername "$h" -tls1_3 -groups X25519 -alpn 'h2,http/1.1' 2>&1) || true
  printf '%s\n' "$v" | grep -qiE 'Protocol( version)?[[:space:]]*:[[:space:]]*TLSv1\.3|New, TLSv1\.3' && t13=+
  printf '%s\n' "$v" | grep -qiE '(Peer |Server )?Temp Key:[[:space:]]*X25519' && x=+
  printf '%s\n' "$v" | grep -qiE 'ALPN protocol:[[:space:]]*h2' && h2=+
  # В старых openssl ALPN печатался иначе; дополнительная проверка — только
  # если curl действительно собран с HTTP/2. Это не обязательный критерий.
  if [[ $t13 == + && $h2 == - ]] && curl -V 2>/dev/null | grep -qi 'HTTP2'; then
    [[ $(curl -sS -o /dev/null -m 6 --http2 -w '%{http_version}' "https://$h/" 2>/dev/null) == 2 ]] && h2=+
  fi
  hdr=$(curl -fsSI -m 6 "https://$h/" 2>/dev/null | tr 'A-Z' 'a-z' | grep '^alt-svc:' | head -1 || true)
  [[ $hdr == *h3* ]] && h3=+
  printf 'TLS1.3 %s  h2 %s  X25519 %s  h3 %s' "$t13" "$h2" "$x" "$h3"
}
# sni_scan → строки «хост|результат|RU/—» во временном файле; проверки идут параллельно
sni_scan() {
  local out=$1 tmp h i=0 n=0; tmp=$(mktemp -d "$STATE/sni.XXXXXX")
  for h in "${SNI_RU[@]}" "${SNI_WORLD[@]}"; do
    i=$((i + 1))
    ( printf '%s|%s|%s\n' "$h" "$(sni_check "$h")" "$([[ " ${SNI_RU[*]} " == *" $h "* ]] && echo RU || echo —)" >"$tmp/$i" ) &
    n=$((n + 1)); ((n % 12 == 0)) && wait
  done
  wait; cat "$tmp"/* >"$out" 2>/dev/null; rm -rf "${tmp:?}"
}
SNI_CACHE=""
sni_choose() { # sni_choose ПЕРЕМЕННАЯ «Заголовок» reality|masq [исключить-хост]
  local var=$1 title=$2 kind=$3 skip=${4:-} h chk ru line shown=0
  [[ -n "${!var:-}" ]] && return 0
  if [[ -z $SNI_CACHE || ! -s $SNI_CACHE ]]; then
    SNI_CACHE=$(mktemp "$STATE/snicache.XXXXXX")
    note "Проверяю ${#SNI_RU[@]}+${#SNI_WORLD[@]} кандидатов с этого сервера…"
    sni_scan "$SNI_CACHE"
  fi
  local -a items=() good=() unchecked=()
  while IFS= read -r line; do
    h=${line%%|*}; chk=${line#*|}; ru=${chk##*|}; chk=${chk%|*}
    [[ $h == "$skip" ]] && continue
    if [[ $kind == reality ]]; then
      if [[ $chk == *"TLS1.3 +"*"X25519 +"* ]]; then
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
  if ((${#items[@]} == 0)); then
    warn "Автопроверка не подтвердила подходящий SNI. Это не доказывает, что все домены непригодны."
    warn "Ниже — НЕПРОВЕРЕННЫЕ кандидаты. Их использование требует проверки соединения VPS-2."
    items=("${unchecked[@]}")
  fi
  ((${#items[@]} > 12)) && items=("${items[@]:0:12}")
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
  chk=$(sni_check "${!var}")
  if [[ $kind == reality ]]; then
    [[ $chk == *"TLS1.3 +"*"X25519 +"* ]] || warn "SNI «${!var}» не подтверждён для Reality (TLS1.3 + X25519): $chk"
  else
    [[ $chk == *"TLS1.3 +"* ]] || warn "TLS1.3 для маскировки «${!var}» не подтверждён: $chk"
    [[ $chk == *"h3 ?"* ]] && note "HTTP/3 не подтверждён: у сервера может отсутствовать доступ к Alt-Svc"
  fi
  return 0
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
  mkdir -p "$LIB"
  cat >"$LIB/net-up.sh" <<'EOS'
#!/usr/bin/env bash
# Правила сети VPS-1: kill switch, TPROXY, метка выхода hy2. Идемпотентно.
set -u
nft -f /etc/rp/rp.nft || exit 1
ip rule show | grep -q 'fwmark 0x1 lookup 100' || ip rule add fwmark 1 lookup 100 priority 90
ip route replace local 0.0.0.0/0 dev lo table 100
ip rule show | grep -q 'fwmark 0xff lookup 200' || ip rule add fwmark 255 lookup 200 priority 100
# резервный запрет: если wg-exit упал, исходящий трафик с меткой не утекает в основную таблицу
ip route replace prohibit default table 200 metric 1000
# rp_filter «loose»: ответы из интернета приходят через wg-exit, а обратный маршрут к их адресам
# в основной таблице ведёт в публичный интерфейс; при strict (1) ядро выбрасывает такие ответы.
sysctl -q -w net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 >/dev/null 2>&1
for i in wg0 wg-exit; do [[ -d /proc/sys/net/ipv4/conf/$i ]] && sysctl -q -w "net.ipv4.conf.$i.rp_filter=2" >/dev/null 2>&1; done
exit 0
EOS
  cat >"$LIB/net-down.sh" <<'EOS'
#!/usr/bin/env bash
# Останов: снимаем перехват, но kill switch (rp_guard) остаётся.
nft delete table ip rp_tp 2>/dev/null
while ip rule del fwmark 1 lookup 100 2>/dev/null; do :; done
exit 0
EOS
  chmod 755 "$LIB/net-up.sh" "$LIB/net-down.sh"
  cat >/etc/systemd/system/rp-net.service <<EOF
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
  mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
  printf '[Unit]\nRequires=rp-net.service\nAfter=rp-net.service\n' >/etc/systemd/system/wg-quick@wg0.service.d/rp.conf
  cat >/etc/systemd/system/rp-xray.service <<EOF
[Unit]
Description=rp: Xray (VPS-1)
After=network-online.target rp-net.service
Wants=network-online.target

[Service]
User=rp
Group=rp
Environment=XRAY_LOCATION_ASSET=$ASSETS
ExecStart=$XRAY_BIN run -c $ETC/xray.json
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
  hy2_unit rp-hy2 "rp: Hysteria2 (сервер, UDP, без обфускации)" "$ETC/hy2.yaml"
  hy2_unit rp-hy2o "rp: Hysteria2 (сервер, UDP, Salamander)" "$ETC/hy2o.yaml"
  cat >/etc/systemd/system/rp-echo.service <<EOF
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
  cat >/etc/systemd/system/rp-ru.service <<EOF
[Unit]
Description=rp: обновление списков РФ через туннель

[Service]
Type=oneshot
ExecStart=$SELF_BIN ru update
EOF
  cat >/etc/systemd/system/rp-ru.timer <<'EOF'
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
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n'
    printf 'net.ipv4.conf.all.rp_filter=2\nnet.ipv4.conf.default.rp_filter=2\n'
    [[ $(cf DISABLE_IPV6 1) == 1 ]] && printf 'net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n'
  } >/etc/sysctl.d/99-rp.conf
  sysctl -q -p /etc/sysctl.d/99-rp.conf >/dev/null 2>&1 || true
  systemctl daemon-reload
}

# ── apply: генерация → проверка → установка с копией → действия → проверка → откат ──
declare -gA ACT=()
unit_up() { local i; for i in 1 2 3; do systemctl is-active --quiet "$1" || return 1; sleep 1; done; }
tr_has() { [[ " $(cf TRANSPORT_ORDER) " == *" $1 "* ]]; }
vps1_actions() {
  local a
  [[ -n ${ACT[nft]:-} ]] && { systemctl restart rp-net.service || return 1; }
  if [[ -n ${ACT[wg0]:-} ]]; then
    if ip link show wg0 >/dev/null 2>&1; then wg syncconf wg0 <(wg-quick strip wg0) || return 1; else systemctl restart wg-quick@wg0 || return 1; fi
  fi
  if [[ -n ${ACT[wgexit]:-} ]]; then
    if ip link show wg-exit >/dev/null 2>&1; then wg syncconf wg-exit <(wg-quick strip wg-exit) || return 1; else systemctl restart wg-quick@wg-exit || return 1; fi
  fi
  for a in "${!ACT[@]}"; do [[ $a == restart:* ]] && { systemctl restart "${a#restart:}" || return 1; }; done
  return 0
}
# Ждём работоспособный выход (если туннель уже подключался раньше), до 90 с
wait_exit_once() { local ip; ip=$(sx -m 6 https://api.ipify.org 2>/dev/null) && [[ -n $ip ]] && { [[ -z $(cf VPS2_IPH) || $(ip_hash "$ip") == "$(cf VPS2_IPH)" ]]; }; }
wait_exit() { local t=0; while ((t < 90)); do wait_exit_once && return 0; sleep 3; t=$((t + 3)); done; return 1; }
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
  if ((anyhy)); then systemctl enable --now wg-quick@wg-exit >/dev/null 2>&1; else systemctl disable --now wg-quick@wg-exit >/dev/null 2>&1; fi
  if tr_has reality-xhttp; then fw_open "$(cf RXH_PORT)/tcp"; else [[ -n $(cf RXH_PORT) ]] && fw_close "$(cf RXH_PORT)/tcp"; fi
  if tr_has reality-xhttp2; then fw_open "$(cf RXH2_PORT)/tcp"; else [[ -n $(cf RXH2_PORT) ]] && fw_close "$(cf RXH2_PORT)/tcp"; fi
  return 0
}
vps1_apply() {
  conf_load
  local stage bk f path mode own act n=0 rc=0
  stage=$(mktemp -d "$STATE/stage.XXXXXX") || return 1; chmod 700 "$stage"
  py render "$stage" >"$stage/manifest" || { rm -rf "${stage:?}"; return 1; }
  XRAY_LOCATION_ASSET=$ASSETS "$XRAY_BIN" run -test -c "$stage/xray.json" >"$stage/xtest.log" 2>&1 \
    || { err "Xray отклонил конфиг (run -test):"; sed 's/^/    /' "$stage/xtest.log" >&2; rm -rf "${stage:?}"; return 1; }
  bk="$BK_DIR/$(date +%Y%m%d-%H%M%S)-$$"; mkdir -p "$bk"
  ACT=(); local -a done_paths=()
  while IFS='|' read -r f path mode own act; do
    [[ -n $f ]] || continue
    if [[ -f $path ]] && cmp -s "$stage/$f" "$path"; then continue; fi
    if [[ -f $path ]]; then cp -p "$path" "$bk/$(printf '%s' "$path" | tr / _)"; else : >"$bk/$(printf '%s' "$path" | tr / _).absent"; fi
    install -m "$mode" -o "${own%%:*}" -g "${own##*:}" "$stage/$f" "$path.rp-new" && mv "$path.rp-new" "$path" || { rc=1; break; }
    done_paths+=("$path"); ACT[$act]=1; n=$((n + 1))
  done <"$stage/manifest"
  if ((rc == 0)); then vps1_units_sync; fi
  if ((rc == 0 && n > 0)); then vps1_actions && vps1_check || rc=1; fi
  if ((rc != 0)); then
    err "Применение не удалось — возвращаю прежние файлы"
    for path in "${done_paths[@]}"; do
      local k; k="$bk/$(printf '%s' "$path" | tr / _)"
      if [[ -f $k ]]; then cp -p "$k" "$path"; elif [[ -f $k.absent ]]; then rm -f "$path"; fi
    done
    vps1_actions || true
  fi
  rm -rf "${stage:?}"
  ls -1dt "$BK_DIR"/* 2>/dev/null | tail -n +11 | while read -r d; do rm -rf "${d:?}"; done
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
# ОТСТУПЛЕНИЕ от tt.sh (.srs для sing-box): Xray читает только .dat.
ru_fetch_one() { # geosite.dat каталог; официальный файл + SHA256 из одного источника
  local n=$1 dir=$2 base want got
  local -a bases=("https://raw.githubusercontent.com/$RU_REPO/release" "https://cdn.jsdelivr.net/gh/$RU_REPO@release")
  for base in "${bases[@]}"; do
    rm -f "$dir/$n" "$dir/$n.sha256sum"
    if curl -fLsS --connect-timeout 8 --max-time 30 --retry 1 --retry-delay 1 \
        -o "$dir/$n" "$base/$n" 2>/dev/null && [[ -s $dir/$n ]] &&
       curl -fLsS --connect-timeout 8 --max-time 20 --retry 1 --retry-delay 1 \
        -o "$dir/$n.sha256sum" "$base/$n.sha256sum" 2>/dev/null; then
      want=$(awk 'NF {print tolower($1); exit}' "$dir/$n.sha256sum")
      got=$(sha256sum "$dir/$n" | awk '{print $1}')
      if [[ $want =~ ^[0-9a-f]{64}$ && $want == "$got" ]]; then return 0; fi
      err "SHA256 $n не совпал на источнике $base"
    fi
  done
  err "Не удалось получить проверенный $n ни с GitHub Raw, ни с jsDelivr"
  return 1
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
  local tmp n old new changed=0 active=0 rc=0 restore_geoip=0
  tmp=$(mktemp -d "$STATE/ru.XXXXXX") || return 1
  mkdir -p "$tmp/assets" "$tmp/config" "$tmp/backup"

  # Прокси включаем только если уже существует рабочий выход через локальный SOCKS.
  if [[ -f $STATE/linked ]] && sx -m 8 -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
    export ALL_PROXY; ALL_PROXY=$(sx_proxy)
  fi
  if ! ru_fetch_one geosite.dat "$tmp/assets"; then unset ALL_PROXY; rm -rf "${tmp:?}"; return 1; fi
  unset ALL_PROXY

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
    # Самовосстановление после прежней версии rp: она могла затереть штатный geoip.dat.
    if (( ! restore_geoip )); then
      err "Проверка Xray не прошла с текущей geoip.dat; проверяю штатную базу из релиза Xray"
      restore_geoip=1
      xray_restore_geoip "$tmp/assets" || { sed 's/^/    /' "$tmp/xray-test.log" >&2; rm -rf "${tmp:?}"; return 1; }
    fi
    if ! XRAY_LOCATION_ASSET="$tmp/assets" "$XRAY_BIN" run -test -c "$tmp/config/xray.json" >"$tmp/xray-test.log" 2>&1; then
      err "Xray отклонил geosite.dat или конфигурацию. Рабочие файлы не изменены; подробности:"
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

  conf_set RU_TAG release RU_UPDATED "$(date -u +%Y%m%dT%H%M%SZ)"
  rm -rf "${tmp:?}"
  ok "Списки РФ: geosite обновлён и проверен; штатный geoip Xray сохранён$( ((restore_geoip)) && echo ' (восстановлен)' )"
  return 0
}

# ── VPS-2: файлы пакета (CLI, сторож, юниты) и установочный блок ────────
# Всё, что попадает на VPS-2, — чистый bash без Python; конфиги статичны (их генерирует VPS-1).

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

vps2_files() { # vps2_files КАТАЛОГ — раскладывает CLI, сторож и юниты в дерево пакета
  local d=$1; mkdir -p "$d/usr/local/bin" "$d/usr/local/lib/rp" "$d/etc/systemd/system" "$d/etc/rp"
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
#!/usr/bin/env bash
# rp (VPS-2) — минимальное управление. Обновление параметров: вставить новый блок из VPS-1.
set -uo pipefail
ETC=/etc/rp; STATE=/var/lib/rp
# shellcheck disable=SC1091
. "$ETC/rp2.conf"
mkdir -p "$STATE"
VPS1_WG=10.77.0.1
N=204800
say() { printf '%s\n' "$*"; }
tr_all() { echo "$TRANSPORT_ORDER"; }
# usable/results — последний снимок диагностики, а не постоянный запрет транспорта.
# Иначе временная потеря UDP исключает HY2 навсегда до ручного rp select.
tr_order() { if [[ -n ${TRANSPORT_FORCE:-} ]]; then echo "$TRANSPORT_FORCE"; else tr_all; fi; }
active() { cat "$STATE/active" 2>/dev/null; }
unit_of() { case $1 in hy2-wg) echo rp-hy2 ;; hy2o-wg) echo rp-hy2o ;; reality-xhttp) echo rp-xray@xhttp ;; reality-xhttp2) echo rp-xray@xhttp2 ;; esac; }
tr_stop_all() { systemctl stop rp-xray@xhttp rp-xray@xhttp2 rp-xray@tcp wg-quick@rp-wg rp-hy2 rp-hy2o 2>/dev/null; return 0; }
wait_udp_fwd() { local i; for ((i = 0; i < ${1:-20}; i++)); do ss -lunH sport = :51820 2>/dev/null | grep -q . && return 0; sleep 1; done; return 1; }
tr_start() {
  tr_stop_all
  case $1 in
    hy2-wg|hy2o-wg) systemctl start "$(unit_of "$1")" || return 1; wait_udp_fwd 30 || return 1; systemctl start wg-quick@rp-wg || return 1; wg_kick || true ;;
    reality-xhttp|reality-xhttp2) systemctl start "$(unit_of "$1")" ;;
    *) return 1 ;;
  esac
}
tr_probe_addr() { case $1 in hy2*) echo "$VPS1_WG $ECHO_PORT" ;; *) echo "127.0.0.1 7777" ;; esac; }
xfer_down() { local got; got=$(timeout 25 bash -c 'exec 3<>/dev/tcp/$0/$1 || exit 1; printf "DN %d\n" "$2" >&3; head -c "$2" <&3 | wc -c' "$1" "$2" "$3" 2>/dev/null) || got=0; echo "${got:-0}"; }
xfer_up() { timeout 25 bash -c 'exec 3<>/dev/tcp/$0/$1 || exit 1; printf "UP %d\n" "$2" >&3; head -c "$2" /dev/zero >&3; read -r -t 15 l <&3; [[ $l == "OK $2" ]]' "$1" "$2" "$3" 2>/dev/null; }
# WireGuard is quiet until the first packet. Without PersistentKeepalive, merely
# starting the interface and waiting for a handshake (old T2 logic) is a deadlock.
# Generate local WG traffic; it is carried by Hysteria2 UDP forwarding (127.0.0.1:51820).
# This is not an external UDP connection and opens no public listening port.
wg_kick() {
  ip link show rp-wg >/dev/null 2>&1 || return 1
  # Fail closed if the WG route is missing (avoid sending the probe via VPS-2 public NIC).
  ip -4 route get 10.77.0.1 2>/dev/null | grep -Eq '(^|[[:space:]])dev rp-wg([[:space:]]|$)' || return 1
  ( printf 'rp\n' > /dev/udp/10.77.0.1/9 ) 2>/dev/null
}
wg_handshake_fresh() {
  local hs now
  hs=$(wg show rp-wg latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  [[ ${hs:-} =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  ((hs > 0 && hs <= now && now - hs < 150))
}
# Lightweight end-to-end health checks for both Hysteria2+WG and VLESS+XHTTP.
# Vary payload sizes independently: every probe must carry actual reverse-tunnel data.
probe_size() {
  local raw
  raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null) || raw=""
  [[ $raw =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || raw=$RANDOM
  printf '%d\n' "$((640 + raw % 1409))"
}
func_ok() {
  local t=$1 h p dn up
  if [[ $t == hy2* ]]; then
    # Active liveness probe supplies real traffic at the watchdog's randomized cadence.
    local attempt
    for ((attempt=0; attempt<5; attempt++)); do
      wg_kick || return 1
      wg_handshake_fresh && break
      sleep 1
    done
    wg_handshake_fresh || return 1
  fi
  read -r h p < <(tr_probe_addr "$t")
  dn=$(probe_size); up=$(probe_size)
  [[ $(xfer_down "$h" "$p" "$dn") -eq "$dn" ]] && xfer_up "$h" "$p" "$up"
}
t1_check() { # T1: доступность порта / UDP-сессии
  local t=$1 port
  case $t in
    hy2-wg|hy2o-wg) wait_udp_fwd 40; return ;;
    reality-xhttp) port=$RXH_PORT ;;
    reality-xhttp2) port=$RXH2_PORT ;;
    *) return 1 ;;
  esac
  timeout 8 bash -c '</dev/tcp/$0/$1' "$PUBLIC_IP" "$port" 2>/dev/null
}
t2_check() { # T2: initiate WG handshake (hy2) or verify Reality path
  local t=$1 i
  for ((i=1; i<=20; i++)); do
    if [[ $t == hy2* ]]; then
      # Explicitly initiate handshake rather than relying solely on 28s keepalive.
      wg_kick && wg_handshake_fresh && return 0
    else
      func_ok "$t" && return 0
    fi
    sleep 2
  done
  return 1
}
t3_check() { # T3: ≥200 КБ в обе стороны (против замирания потока на 15–20 КБ)
  local t=$1 h p got
  read -r h p < <(tr_probe_addr "$t")
  got=$(xfer_down "$h" "$p" $N)
  if ((got != N)); then say "обрыв после ~$((got / 1024)) КБ на приёме"; return 1; fi
  xfer_up "$h" "$p" $N || { say "обрыв на передаче"; return 1; }
}
unit_failed() { systemctl is-failed --quiet "$(unit_of "$1")"; }
# Диагностика различает: нет ответа, обрыв после N КБ, сброс, ошибка конфигурации
diag() {
  local t=$1 stage=$2 detail=${3:-}
  case $stage in
    cfg) say "    ошибка конфигурации: смотрите «rp logs» (параметры не подошли версии Xray/Hysteria2)" ;;
    t1)
      if [[ $t == hy2* ]]; then say "    нет ответа по UDP: QUIC режется или порт фильтруется → смените порт, SNI или транспорт"
      elif timeout 5 bash -c '</dev/tcp/$0/$1' "$PUBLIC_IP" "$([[ $t == reality-xhttp ]] && echo "$RXH_PORT" || echo "$RXH2_PORT")" 2>&1 | grep -qi refused; then
        say "    сброс: порт закрыт или сервис VPS-1 не запущен → проверьте «rp status» на VPS-1"
      else say "    нет ответа: пакеты теряются (фильтрация по IP/порту) → смените порт или транспорт"; fi ;;
    t2)
      if [[ $t == hy2* ]]; then
        say "    QUIC мог успешно подключиться, но WG handshake через UDP forwarding не состоялся."
        say "    Проверьте: wg show rp-wg; ip route get 10.77.0.1; ss -lunp; rp logs."
      else say "    Reality/XHTTP: нет ответа через обратный канал; проверьте SNI, порт и журнал Xray"; fi ;;
    t3) say "    ${detail:-обрыв передачи}: так проявляется замирание потока ТСПУ → смените порт, SNI или транспорт" ;;
  esac
}
cmd_select() {
  # Проверяются ВСЕ транспорты; рабочие попадают в usable, неработающие исключаются (VPS-1 уберёт их командой rp prune)
  local t first="" res tmpu=() ok_n=0 bad=""
  systemctl stop rp-watch >/dev/null 2>&1
  : >"$STATE/results"
  say "Проверка транспортов (T1–T3): ${TRANSPORT_FORCE:-$TRANSPORT_ORDER}"
  for t in ${TRANSPORT_FORCE:-$TRANSPORT_ORDER}; do
    say "── $t"
    if ! tr_start "$t" || unit_failed "$t"; then
      say "  ✗ транспорт не запустился"; diag "$t" cfg
      echo "$t=fail:cfg" >>"$STATE/results"; bad+=" $t"; continue
    fi
    sleep 2
    t1_check "$t" || { say "  ✗ T1 доступность"; diag "$t" t1; echo "$t=fail:t1" >>"$STATE/results"; bad+=" $t"; continue; }; say "  ✓ T1"
    t2_check "$t" || { say "  ✗ T2 рукопожатие"; diag "$t" t2; echo "$t=fail:t2" >>"$STATE/results"; bad+=" $t"; continue; }; say "  ✓ T2"
    res=$(t3_check "$t") || { say "  ✗ T3 передача ≥200 КБ"; diag "$t" t3 "$res"; echo "$t=fail:t3" >>"$STATE/results"; bad+=" $t"; continue; }; say "  ✓ T3"
    echo "$t=ok" >>"$STATE/results"; tmpu+=("$t"); ok_n=$((ok_n + 1))
  done
  tr_stop_all
  say ""
  if ((ok_n > 0)); then
    printf '%s\n' "${tmpu[@]}" >"$STATE/usable"
  else
    : >"$STATE/usable"
  fi
  # Результат предварительного сканирования может устареть. Ещё раз проверяем
  # окончательно выбранный канал после его повторного запуска.
  first=""
  for t in "${tmpu[@]}"; do
    if tr_start "$t" && t2_check "$t" && t3_check "$t" >/dev/null && func_ok "$t"; then
      first=$t; break
    fi
    say "  ! $t не прошёл повторную проверку, пробую следующий"
  done
  if [[ -n $first ]]; then
    printf '%s\n' "$first" >"$STATE/active"; date +%s >"$STATE/since"
  else
    # Нет выхода — активный маршрут не назначается (Xray: fallback=block).
    tr_stop_all; rm -f "$STATE/active" "$STATE/since"
  fi
  # Сторож обязан запускаться даже при нуле пригодных транспортов: он сам
  # будет периодически перепроверять ВСЕ настроенные, не отключая их навсегда.
  systemctl enable --now rp-watch >/dev/null 2>&1 || {
    say "Не удалось включить rp-watch: проверьте systemctl status rp-watch" >&2
    return 1
  }
  say "Прошли T1–T3: ${tmpu[*]:-ни один}"
  [[ -n $bad ]] && say "Не прошли при первом сканировании:$bad (сохранены для повторных проверок)"
  if [[ -z $first ]]; then
    say "Нет активного выхода: действует fail-closed; сторож продолжит восстановление"
    return 1
  fi
  say "Активен транспорт: $first"
}
cmd_results() { cat "$STATE/results" 2>/dev/null; }
cmd_setorder() { # rp _setorder список — оставить только перечисленные транспорты
  local l="$*" t
  [[ $l =~ ^[a-z0-9\ -]+$ ]] || { say "неверный список"; return 1; }
  sed -i "s|^TRANSPORT_ORDER=.*|TRANSPORT_ORDER=\"$l\"|" "$ETC/rp2.conf"
  for t in $l; do echo "$t"; done >"$STATE/usable"
  systemctl is-active --quiet rp-watch && systemctl restart rp-watch
  say "Приоритеты: $l (остальные намеренно исключены администратором)"
}
# egress — отчёт «ключ=значение» о том, может ли VPS-2 пропускать трафик VPS-1 в интернет
cmd_egress() {
  local z ez
  say "ip_forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
  say "rp_filter_all=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)"
  say "nat=$(nft list table ip rp_nat >/dev/null 2>&1 && echo yes || echo NO)"
  say "nat_packets=$(nft list table ip rp_nat 2>/dev/null | sed -n 's/.*counter packets \([0-9]*\).*/\1/p' | head -1)"
  say "default_if=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  if systemctl is-active --quiet firewalld; then
    ez=$(ip -4 route show default | awk '{print $5; exit}')
    z=$(firewall-cmd --get-zone-of-interface=rp-wg 2>/dev/null)
    say "fw_zone_wg=${z:-—}"
    say "fw_zone_ext=$(firewall-cmd --get-zone-of-interface="$ez" 2>/dev/null || echo —)"
    say "fw_forward=$([[ -n $z ]] && firewall-cmd --zone="$z" --query-forward 2>/dev/null || echo no)"
  else say "fw_zone_wg=нет-firewalld"; fi
  say "internet=$(curl -4 -fsS -m 8 -o /dev/null https://1.1.1.1/cdn-cgi/trace && echo ok || echo FAIL)"
}
# fixnet — привести пересылку и NAT в рабочее состояние (идемпотентно)
cmd_fixnet() {
  local ez z
  sysctl -q -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
  systemctl enable --now rp-nat >/dev/null 2>&1 || { say "Ошибка включения rp-nat" >&2; return 1; }
  systemctl restart rp-nat >/dev/null 2>&1 || { say "Ошибка загрузки NAT" >&2; return 1; }
  if systemctl is-active --quiet firewalld; then
    # rp-wg — в той же зоне, что и внешний интерфейс: пересылка внутри зоны разрешена без политик
    ez=$(ip -4 route show default | awk '{print $5; exit}')
    z=$(firewall-cmd --get-zone-of-interface="$ez" 2>/dev/null); [[ -n $z ]] || z=$(firewall-cmd --get-default-zone)
    firewall-cmd --permanent --zone=trusted --remove-interface=rp-wg >/dev/null 2>&1
    firewall-cmd --permanent --delete-policy=rp-egress >/dev/null 2>&1
    firewall-cmd --permanent --zone="$z" --add-interface=rp-wg >/dev/null 2>&1
    firewall-cmd --permanent --zone="$z" --add-forward >/dev/null 2>&1
    # SSH с VPS-1 по туннелю остаётся доступным, даже если закрыть порт 22 снаружи
    firewall-cmd --permanent --zone="$z" --add-rich-rule='rule family="ipv4" source address="10.77.0.1" service name="ssh" accept' >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    ip link show rp-wg >/dev/null 2>&1 && firewall-cmd --zone="$z" --change-interface=rp-wg >/dev/null 2>&1
    say "firewalld: rp-wg в зоне $z, пересылка включена"
  fi
  [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]] &&
    nft list table ip rp_nat >/dev/null 2>&1 || {
      say "Ошибка: forwarding или rp_nat отсутствуют" >&2; return 1;
    }
  say "fixnet: готово"
}
cmd_status() {
  local t; t=$(active)
  say "Транспорт: ${t:-нет — fail-closed}  (приоритеты: $(tr_order); прошли первичный тест: $(tr '\n' ' ' <"$STATE/usable" 2>/dev/null))"
  say "Сквозная проба (HY2 и XHTTP): случайный интервал ${WATCH_MIN:-15}–${WATCH_MAX:-35} с; штатные QUIC/TCP keepalive не меняются"
  say "hy2: $(systemctl is-active rp-hy2)  hy2o: $(systemctl is-active rp-hy2o)  wg: $(systemctl is-active wg-quick@rp-wg)  xhttp: $(systemctl is-active rp-xray@xhttp)  xhttp2: $(systemctl is-active rp-xray@xhttp2)  сторож: $(systemctl is-active rp-watch)"
  [[ -n $t ]] && { func_ok "$t" && say "Проверка: туннель работает" || say "Проверка: туннель НЕ отвечает"; }
  [[ $t == hy2* ]] && wg show rp-wg latest-handshakes 2>/dev/null | awk '{print "Рукопожатие WG: " (($2>0)? systime()-$2 " с назад" : "не было")}'
  say "NAT: $(nft list table ip rp_nat >/dev/null 2>&1 && echo есть || echo ОТСУТСТВУЕТ)  пересылка: $(sysctl -n net.ipv4.ip_forward)"
  say "Версии: $(cmd_version)"
}
cmd_version() { echo "xray $(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}') hysteria $(/usr/local/bin/hysteria version 2>/dev/null | awk '/^Version:/{print $2}')"; }
cmd_logs() { journalctl -u rp-watch -u rp-hy2 -u rp-hy2o -u 'rp-xray@*' -u wg-quick@rp-wg -n "${1:-80}" --no-pager; }
cmd_restart() { local t; t=$(active); [[ -n $t ]] || { say "Транспорт не выбран: rp select"; return 1; }; tr_start "$t"; say "Перезапущено: $t"; }
cmd_remove() {
  read -rp "Удалить rp с VPS-2 (туннель, конфиги, ключ SSH)? [y/N] " a; [[ ${a,,} == y ]] || return 0
  systemctl disable --now rp-watch rp-nat rp-rollback.timer >/dev/null 2>&1; tr_stop_all
  rm -f /etc/systemd/system/rp-*.service /etc/systemd/system/rp-*.timer /etc/wireguard/rp-wg.conf /usr/local/lib/rp/watch.sh
  rm -rf /etc/systemd/system/rp-* /usr/local/share/rp "$ETC" "$STATE"
  [[ -f /root/.ssh/authorized_keys ]] && sed -i '/ rp@vps1$/d' /root/.ssh/authorized_keys
  nft delete table ip rp_nat 2>/dev/null; rm -f /etc/sysctl.d/99-rp.conf
  systemctl daemon-reload; say "Удалено. Бинарники /usr/local/bin/{xray,hysteria,rp} оставлены; rm — вручную."
}
cmd_confirm() { systemctl stop rp-rollback.timer >/dev/null 2>&1; rm -f "$STATE/backup.tgz"; say "Обновление подтверждено, откат отменён"; }
cmd_rollback() {
  [[ -f $STATE/backup.tgz ]] || { say "Резервной копии нет"; return 1; }
  tar -xzf "$STATE/backup.tgz" -C / && systemctl daemon-reload && cmd_restart; say "Возврат к прежним параметрам выполнен"
}
menu() {
  while :; do
    printf '\n◆ rp · VPS-2   транспорт: %s\n  1 Статус\n  2 Перезапуск\n  3 Журнал\n  4 Проверить все транспорты заново\n  5 Починить NAT и пересылку\n  6 Удалить\n  0 Выход\n› ' "$(active)"
    read -r c || exit 0
    case $c in 1) cmd_status ;; 2) cmd_restart ;; 3) cmd_logs 60 ;; 4) cmd_select ;; 5) cmd_fixnet ;; 6) cmd_remove ;; 0) exit 0 ;; *) say "Введите число от 0 до 6" ;; esac
  done
}
case ${1:-menu} in
  menu) menu ;; status) cmd_status ;; restart) cmd_restart ;; logs) cmd_logs "${2:-80}" ;; select) cmd_select ;;
  test) t=$(active); t1_check "$t" && t2_check "$t" && t3_check "$t" && say "T1–T3: ок" ;;
  remove) cmd_remove ;; version) cmd_version ;; confirm) cmd_confirm ;; rollback) cmd_rollback ;;
  results) cmd_results ;; egress) cmd_egress ;; fixnet) cmd_fixnet ;; _setorder) shift; cmd_setorder "$@" ;;
  _func) func_ok "$(active)" ;;
  _fn) shift; "$@" ;;
  *) say "rp: status | restart | logs [N] | select | test | results | egress | fixnet | version | remove (без аргументов — меню)"; say "Заменить параметры: вставьте новый блок из VPS-1." ;;
esac
EOS

  cat >"$d/usr/local/lib/rp/watch.sh" <<'EOS'
#!/usr/bin/env bash
# rp: VPS-2 supervisor. One active transport; all configured candidates retained.
# Conservative failover (3 failures), two-way T2+T3 validation, circuit breaker.
# Hysteria2 owns QUIC keepalive; inner WG remains at PersistentKeepalive=28.
set -u
ST=/var/lib/rp
# shellcheck disable=SC1091
. /etc/rp/rp2.conf
WATCH_MIN=${WATCH_MIN:-15}; WATCH_MAX=${WATCH_MAX:-35}
if [[ ! $WATCH_MIN =~ ^[0-9]+$ || ! $WATCH_MAX =~ ^[0-9]+$ ]] ||
   ((WATCH_MIN < 5 || WATCH_MAX > 120 || WATCH_MAX < WATCH_MIN)); then
  logger -t rp-watch 'invalid WATCH_MIN/WATCH_MAX, using 15..35'
  WATCH_MIN=15; WATCH_MAX=35
fi
fn() { /usr/local/bin/rp _fn "$@"; }
rand_between() {
  local lo=$1 hi=$2 raw
  raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null) || raw=""
  [[ $raw =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || raw=$(( (RANDOM << 16) | RANDOM ))
  printf '%d\n' "$((lo + raw % (hi - lo + 1)))"
}
activity_sleep() { sleep "$(rand_between "$WATCH_MIN" "$WATCH_MAX")"; }
error_sleep() { sleep "$(rand_between 8 15)"; }
log() { logger -t rp-watch -- "$*"; }
active() { cat "$ST/active" 2>/dev/null || true; }
set_active() {
  printf '%s\n' "$1" >"$ST/active.new" && mv -f "$ST/active.new" "$ST/active"
  date +%s >"$ST/since"
}
clear_active() { rm -f "$ST/active" "$ST/since"; }
order_now() { fn tr_order; }
# Cooldown per transport after failures; memory is intentionally reset on service restart.
declare -A blocked_until=() strike=()
penalize() {
  local t=$1 now=$(date +%s) n=${strike[$1]:-0} seconds
  n=$((n + 1)); ((n > 4)) && n=4
  strike[$t]=$n
  seconds=$((300 * (1 << (n - 1))))  # 5, 10, 20, 40 minutes
  blocked_until[$t]=$((now + seconds))
  log "$t unavailable; quarantine for ${seconds}s (attempt $n)"
}
allowed() { (( $(date +%s) >= ${blocked_until[$1]:-0} )); }
# A transport is eligible only if it really carries data through both directions.
# A successful process start / TCP or QUIC handshake alone is NOT enough.
try_transport() {
  local t=$1
  fn tr_start "$t" || return 1
  fn t2_check "$t" || return 1
  fn t3_check "$t" >/dev/null || return 1
  fn func_ok "$t" || return 1
  return 0
}
choose_candidate() {
  local skip=${1:-} t
  for t in "${order[@]}"; do
    [[ $t == "$skip" ]] && continue
    allowed "$t" || continue
    if try_transport "$t"; then
      set_active "$t"; strike[$t]=0; blocked_until[$t]=0
      log "active transport: $t"
      return 0
    fi
    penalize "$t"
  done
  return 1
}
# On reboot services might not be enabled individually: bring back the stored active.
order=()
read -ra order <<<"$(order_now)"
if ((${#order[@]})) && [[ -n $(active) ]]; then
  current=$(active)
  if [[ " ${order[*]} " == *" $current "* ]]; then
    # rp select may have just started a healthy transport. Do not tear it down
    # merely because the watchdog service was (re)started.
    fn func_ok "$current" || fn tr_start "$current" || log "startup recovery failed for $current"
  else
    clear_active
  fi
fi
errors=0; last_switch=$(date +%s)
next_deep=$((last_switch + $(rand_between 480 900)))
last_failback=0
while :; do
  read -ra order <<<"$(order_now)"
  if ((${#order[@]} == 0)); then
    # Misconfigured or empty policy: no permission to use an unlisted channel.
    fn tr_stop_all >/dev/null 2>&1 || true
    clear_active
    log 'empty TRANSPORT_ORDER; fail-closed'
    sleep 30; continue
  fi
  t=$(active)
  if [[ -n $t && " ${order[*]} " != *" $t "* ]]; then
    clear_active; t=""
  fi
  if [[ -z $t ]]; then
    # No active transport. Retry failed ones after their cooldown expires.
    if choose_candidate ""; then
      errors=0; last_switch=$(date +%s)
      next_deep=$((last_switch + $(rand_between 480 900)))
      activity_sleep
    else
      fn tr_stop_all >/dev/null 2>&1 || true
      clear_active
      error_sleep
    fi
    continue
  fi
  now=$(date +%s)
  good=0
  if fn func_ok "$t"; then good=1; fi
  if ((good && now >= next_deep)); then
    next_deep=$((now + $(rand_between 480 900)))
    fn t3_check "$t" >/dev/null || good=0
  fi
  if ((good)); then
    errors=0
    # On fallback: wait for 30 min of uninterrupted operation before failback.
    # Failed failback must not cause immediate repeated attempts or lose the old path.
    if [[ $t != "${order[0]}" ]] && ((now - last_switch >= 1800)) &&
       ((now - last_failback >= 1800)); then
      last_failback=$now
      attempted=0; upgraded=""
      # Try ALL higher-priority candidates in rank order, not just position 1.
      # Example: if packet-up stays blocked but auto recovers, leave Hysteria2 for auto.
      for preferred in "${order[@]}"; do
        [[ $preferred == "$t" ]] && break
        allowed "$preferred" || continue
        attempted=1
        log "probing higher-priority $preferred (current $t)"
        if try_transport "$preferred"; then upgraded=$preferred; break; fi
        penalize "$preferred"
      done
      if [[ -n $upgraded ]]; then
        set_active "$upgraded"; strike[$upgraded]=0; blocked_until[$upgraded]=0
        log "failback $t -> $upgraded (T2+T3 passed)"
        last_switch=$(date +%s); errors=0
        next_deep=$((last_switch + $(rand_between 480 900)))
        activity_sleep; continue
      fi
      if ((attempted)); then
        # Restore the previously healthy transport. Verify it before marking active.
        if try_transport "$t"; then
          set_active "$t"
          log "failed failback, restored $t"
          last_switch=$(date +%s); errors=0
          next_deep=$((last_switch + $(rand_between 480 900)))
          activity_sleep; continue
        fi
        penalize "$t"
        clear_active
        log 'failed to restore previous transport; fail-closed'
        if choose_candidate ""; then
          last_switch=$(date +%s); errors=0
        else
          fn tr_stop_all >/dev/null 2>&1 || true
        fi
        error_sleep; continue
      fi
    fi
    activity_sleep; continue
  fi
  errors=$((errors + 1))
  # Failback requires 30 minutes of clean health checks, not just uptime.
  last_switch=$(date +%s)
  log "$t end-to-end probe failed ($errors/3)"
  if ((errors < 3)); then error_sleep; continue; fi
  errors=0
  log "restarting unhealthy $t"
  if try_transport "$t"; then
    set_active "$t"; strike[$t]=0; blocked_until[$t]=0
    log "recovered $t after restart"
    last_switch=$(date +%s)
    next_deep=$((last_switch + $(rand_between 480 900)))
    activity_sleep; continue
  fi
  penalize "$t"
  clear_active
  if choose_candidate "$t"; then
    last_switch=$(date +%s)
    next_deep=$((last_switch + $(rand_between 480 900)))
  else
    fn tr_stop_all >/dev/null 2>&1 || true
    log 'all eligible transports unavailable: fail-closed'
  fi
  error_sleep
done
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
rp_fail() { echo "✗ $*" >&2; exit 1; }
rp_dl() { local d=2; for _ in 1 2 3 4 5; do curl -fsSL --connect-timeout 10 -m 180 -o "$2" "$1" && [[ -s $2 ]] && return 0; sleep $d; d=$((d * 2)); done; return 1; }
rp_main() {
  exec </dev/null   # скрипт уже прочитан целиком (rp_main — последняя строка): команды не должны читать остаток потока
  [[ $EUID -eq 0 ]] || rp_fail "Нужен root"
  command -v dnf >/dev/null || rp_fail "Нужен dnf (Rocky Linux 9/10)"
  local tmp xurl xsha hurl hsha
  tmp=$(mktemp -d) || rp_fail "mktemp"
  mkdir -p /var/lib/rp; rm -f /var/lib/rp/push.rc
  # код завершения читает VPS-1 (rp push ждёт его, прежде чем подтвердить обновление)
  trap 'rc=$?; rm -rf "$tmp"; echo "$rc" >/var/lib/rp/push.rc' EXIT
  # 0. копия для отката (обновление по SSH с таймером)
  if [[ $RP_SAFE == 1 && -d /etc/rp ]]; then
    tar -czf /var/lib/rp/backup.tgz -C / etc/rp usr/local/lib/rp usr/local/bin/rp etc/systemd/system 2>/dev/null
  fi
  # 1. бандл: проверка суммы до любых изменений
  rp_bundle | base64 -d >"$tmp/b.tgz" 2>/dev/null || rp_fail "Бандл повреждён (base64)"
  [[ $(sha256sum "$tmp/b.tgz" | awk '{print $1}') == "$RP_BUNDLE_SHA" ]] || rp_fail "SHA256 бандла не совпала — вставьте блок заново целиком"
  echo "◆ rp: установка VPS-2"
  # 2. пакеты
  echo "· пакеты"
  dnf -y install chrony nftables curl unzip tar >/dev/null 2>&1 || rp_fail "dnf: не поставились базовые пакеты"
  command -v wg >/dev/null || { dnf -y install wireguard-tools >/dev/null 2>&1 || { dnf -y install epel-release >/dev/null 2>&1 && dnf -y install wireguard-tools >/dev/null 2>&1; }; }
  command -v wg >/dev/null || rp_fail "wireguard-tools не установились (нужен EPEL на Rocky 9)"
  systemctl enable --now chronyd >/dev/null 2>&1
  id xray >/dev/null 2>&1 || useradd -r -s /sbin/nologin -M xray
  # 3. бинарники: закреплённые URL и SHA256
  case $(uname -m) in
    x86_64) xurl=$RP_X_URL_64; xsha=$RP_X_SHA_64; hurl=$RP_H_URL_AMD64; hsha=$RP_H_SHA_AMD64 ;;
    aarch64) xurl=$RP_X_URL_ARM; xsha=$RP_X_SHA_ARM; hurl=$RP_H_URL_ARM64; hsha=$RP_H_SHA_ARM64 ;;
    *) rp_fail "Архитектура $(uname -m) не поддерживается" ;;
  esac
  echo "· Xray и Hysteria2"
  rp_dl "$xurl" "$tmp/x.zip" || rp_fail "не скачался Xray"
  [[ $(sha256sum "$tmp/x.zip" | awk '{print $1}') == "$xsha" ]] || rp_fail "SHA256 Xray не совпала"
  unzip -qo "$tmp/x.zip" xray geoip.dat geosite.dat -d "$tmp/x" || rp_fail "не распаковался Xray"
  install -m 755 "$tmp/x/xray" /usr/local/bin/xray.new && mv /usr/local/bin/xray.new /usr/local/bin/xray
  install -d -m 755 /usr/local/share/rp; install -m 644 "$tmp/x/geoip.dat" "$tmp/x/geosite.dat" /usr/local/share/rp/
  rp_dl "$hurl" "$tmp/h" || rp_fail "не скачалась Hysteria2"
  [[ $(sha256sum "$tmp/h" | awk '{print $1}') == "$hsha" ]] || rp_fail "SHA256 Hysteria2 не совпала"
  install -m 755 "$tmp/h" /usr/local/bin/hysteria.new && mv /usr/local/bin/hysteria.new /usr/local/bin/hysteria
  # 4. файлы бандла
  echo "· конфигурация и юниты"
  install -d -m 755 /var/lib/rp
  tar -xzf "$tmp/b.tgz" -C / || rp_fail "не распаковался бандл"
  chown root:xray /etc/rp; chmod 750 /etc/rp
  local f; for f in /etc/rp/rp2.conf /etc/rp/hy2.yaml /etc/rp/hy2o.yaml /etc/rp/xray-xhttp.json /etc/rp/xray-xhttp2.json; do
    [[ -f $f ]] && { chown root:xray "$f"; chmod 640 "$f"; }
  done
  install -d -m 700 /etc/wireguard; install -m 600 /etc/rp/rp-wg.conf /etc/wireguard/rp-wg.conf; chmod 600 /etc/rp/rp-wg.conf
  # shellcheck disable=SC1091
  . /etc/rp/rp2.conf
  { printf 'net.ipv4.ip_forward=1\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\nnet.ipv4.conf.all.rp_filter=2\n'
    [[ ${DISABLE_IPV6:-1} == 1 ]] && printf 'net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n'
  } >/etc/sysctl.d/99-rp.conf; sysctl -q -p /etc/sysctl.d/99-rp.conf >/dev/null 2>&1
  command -v restorecon >/dev/null && restorecon -R /etc/rp /usr/local/bin /usr/local/lib/rp /usr/local/share/rp 2>/dev/null
  systemctl daemon-reload
  # 5. NAT и пересылка, фаервол (порты наружу не открываются); rp fixnet — единая реализация
  echo "· NAT и пересылка"
  /usr/local/bin/rp fixnet || rp_fail "не удалось включить NAT/firewalld на VPS-2"
  # 6. SSH: ключ с ограничениями (только с loopback и внутреннего WG-адреса, без форвардинга)
  install -d -m 700 /root/.ssh; touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  sed -i '/ rp@vps1$/d' /root/.ssh/authorized_keys
  printf 'from="127.0.0.1,10.77.0.1",no-port-forwarding,no-agent-forwarding,no-X11-forwarding %s rp@vps1\n' "$(grep '^SSH_PUB=' /etc/rp/rp2.conf | cut -d'"' -f2)" >>/root/.ssh/authorized_keys
  systemctl is-active --quiet sshd || systemctl enable --now sshd >/dev/null 2>&1
  local prl; prl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
  [[ $prl == no ]] && echo "! В sshd запрещён вход root (PermitRootLogin no): ключ rp работать не будет"
  # 7. запуск и проверка транспортов (проверяются все, неработающие исключаются)
  if [[ $RP_SAFE == 1 ]]; then systemd-run --on-active=600 --unit=rp-rollback --description="rp: откат обновления" /usr/local/bin/rp rollback >/dev/null 2>&1; fi
  /usr/local/bin/rp select; local rc=$?
  echo
  echo "Отпечаток host key этого сервера (сверьте при первом «rp ssh» на VPS-1):"
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null
  echo "SSH снаружи можно закрыть: доступ с VPS-1 по туннелю сохранится (правило для 10.77.0.1)."
  return $rc
}
EOS
  printf 'rp_bundle() { cat <<'"'"'RP_BUNDLE_END'"'"'\n%s\nRP_BUNDLE_END\n}\nrp_main "$@"\n' "$b64"
}

# ── Роль VPS-1 ───────────────────────────────────────────────────────────
need_vps1() { conf_load; [[ $(cf ROLE) == vps1 ]] || die "Это не VPS-1 (или rp ещё не установлен): выполните «rp install»"; }
py_install() { mkdir -p "$LIB"; py_source >"$LIB/rp.py.new" && mv "$LIB/rp.py.new" "$LIB/rp.py" && chmod 644 "$LIB/rp.py"; }
# self_install — команда rp из текущего файла; при запуске через bash <(curl …) файла нет (поток уже прочитан),
# тогда скрипт скачивает себя по RP_URL
self_ok() { head -c 300 "$1" 2>/dev/null | grep -q 'rp — цепочка' && bash -n "$1" 2>/dev/null; }
self_install() {
  local tmp
  if [[ -f $0 && $(readlink -f "$0") != "$SELF_BIN" ]] && self_ok "$0"; then install -m 755 "$0" "$SELF_BIN.new" && mv "$SELF_BIN.new" "$SELF_BIN"; return 0; fi
  [[ -f $0 ]] && return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/rp.XXXXXX") && fetch "$RP_URL" "$tmp" && self_ok "$tmp" && install -m 755 "$tmp" "$SELF_BIN.new" && mv "$SELF_BIN.new" "$SELF_BIN" \
    || warn "Команда rp не установлена: не удалось скачать $RP_URL"
  rm -f "${tmp:-}"; return 0
}
# upgrade self — новая версия скрипта с GitHub, проверка, установка и rp migrate (обновляет встроенный генератор и службы)
self_upgrade() {
  [[ $SELF_VERSION == *-fix* || $SELF_VERSION == *-hardened* ]] && die "Это локальная исправленная сборка. rp upgrade self заменит её файлом с GitHub; обновление отключено."
  local tmp nv; tmp=$(mktemp "${TMPDIR:-/tmp}/rp.XXXXXX")
  fetch "$RP_URL" "$tmp" && self_ok "$tmp" || { rm -f "$tmp"; die "Не удалось скачать корректный rp.sh с $RP_URL"; }
  nv=$(sed -n 's/^SELF_VERSION="\(.*\)"/\1/p' "$tmp" | head -1)
  note "Установлена $SELF_VERSION, на GitHub $nv"
  [[ $nv == "$SELF_VERSION" ]] && { rm -f "$tmp"; ok "Обновление не требуется"; return 0; }
  yesno "Обновить rp $SELF_VERSION → $nv?" y || { rm -f "$tmp"; return 0; }
  cp -p "$SELF_BIN" "$BK_DIR/rp.sh.$SELF_VERSION" 2>/dev/null
  install -m 755 "$tmp" "$SELF_BIN.new" && mv "$SELF_BIN.new" "$SELF_BIN"; rm -f "$tmp"
  ok "rp $nv установлен (прежний файл: $BK_DIR/rp.sh.$SELF_VERSION)"
  "$SELF_BIN" migrate
}
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)); }
transport_label() {
  case $1 in
    hy2-wg) echo "Hysteria2 · QUIC/UDP · без обфускации · несёт WG" ;;
    hy2o-wg) echo "Hysteria2 · QUIC/UDP · обфускация Salamander · несёт WG" ;;
    reality-xhttp) echo "VLESS Reverse · Reality · XHTTP (auto) · TCP" ;;
    reality-xhttp2) echo "VLESS Reverse · Reality · XHTTP (packet-up) · TCP" ;;
    *) echo "$1" ;;
  esac
}
ord_has() { [[ " $1 " == *" $2 "* ]]; }   # ord_has "список" имя
# Приоритет для этой инсталляции: XHTTP packet-up, затем XHTTP auto,
# затем HY2/QUIC и HY2+Salamander. Это политика, а не гарантия невидимости DPI.
# Один рабочий транспорт VPS-2 за раз; остальные сохраняются для повторных попыток.
TR_RANK=(reality-xhttp2 reality-xhttp hy2-wg hy2o-wg)
tr_sort() { # tr_sort "список" → тот же набор в порядке TR_RANK (неизвестные имена отбрасываются)
  local t out=""; for t in "${TR_RANK[@]}"; do [[ " $* " == *" $t "* ]] && out+="${out:+ }$t"; done
  printf '%s\n' "$out"
}
tr_port() { case $1 in hy2-wg) echo "UDP/$(cf HY2_PORT)" ;; hy2o-wg) echo "UDP/$(cf HY2O_PORT)" ;; reality-xhttp) echo "TCP/$(cf RXH_PORT)" ;; reality-xhttp2) echo "TCP/$(cf RXH2_PORT)" ;; esac; }

# ── Миграция конфигурации v1.0 → v1.1 ────────────────────────────────────
# reality-tcp заменён на XHTTP (ТСПУ замораживает TCP-поток после ~16 КБ); добавлены hy2 с обфускацией,
# пароль локального SOCKS, DNS-пресеты; адрес VPS-2 заменён отпечатком.
conf_migrate() {
  conf_load; [[ $(cf CONF_VER 1) == 2 ]] && return 0
  local old t new="" ip dr
  old=$(cf TRANSPORT_ORDER "hy2-wg reality-xhttp reality-tcp")
  for t in "${TR_RANK[@]}"; do
    case $t in
      hy2o-wg) [[ " $old " == *" hy2-wg "* || " $old " == *" hy2o-wg "* ]] && new+="${new:+ }$t" ;;
      reality-xhttp2) [[ " $old " == *" reality-xhttp2 "* || " $old " == *" reality-tcp "* ]] && new+="${new:+ }$t" ;;
      *) [[ " $old " == *" $t "* ]] && new+="${new:+ }$t" ;;
    esac
  done
  [[ -n $new ]] || new="${TR_RANK[*]}"
  dr=$(cf DNS_REMOTE); [[ -z $dr || $dr == "https://1.1.1.1/dns-query" ]] && dr="quad9 cloudflare"
  conf_set TRANSPORT_ORDER "$new" DNS_REMOTE "$dr" HY2O_PORT "$(cf HY2O_PORT 8443)" \
    RXH2_PORT "$(cf RXH2_PORT "$(cf RTCP_PORT 8443)")" RXH2_SNI "$(cf RXH2_SNI "$(cf RTCP_SNI "$(cf RXH_SNI www.microsoft.com)")")" \
    XHTTP2_PATH "$(cf XHTTP2_PATH "/$(rand_hex 4)")" DISABLE_IPV6 "$(cf DISABLE_IPV6 1)" SNIFF "$(cf SNIFF 1)" RL_FP "$(cf RL_FP chrome)"
  secrets_extra
  ip=$(cf VPS2_IP)
  if [[ -n $ip ]]; then conf_set VPS2_IPH "$(ip_hash "$ip")"; sed -i '/^VPS2_IP=/d' "$CONF"; conf_load; fi
  conf_set CONF_VER 2
  ok "Конфигурация обновлена до v1.1: транспорты «$new»"
}
cmd_migrate() {
  need_root; need_vps1
  banner "Переход на rp $SELF_VERSION" "с версии 1.0"
  mkdir -p "$STATE"; chmod 755 "$STATE"
  cp -p "$CONF" "$BK_DIR/rp.conf.v1.$(date +%s)" 2>/dev/null || { mkdir -p "$BK_DIR"; cp -p "$CONF" "$BK_DIR/rp.conf.v1.$(date +%s)"; }
  self_install; py_install
  conf_migrate
  conf_set TRANSPORT_ORDER "$(tr_sort "$(cf TRANSPORT_ORDER)")"
  # Upgrade existing installations without replacing the user's explicit browser preset.
  [[ $(cf RL_FP random) == random ]] && conf_set RL_FP chrome
  [[ -n $(cf WATCH_MIN) ]] || conf_set WATCH_MIN 15
  [[ -n $(cf WATCH_MAX) ]] || conf_set WATCH_MAX 35
  units_vps1
  systemctl restart rp-net >/dev/null 2>&1
  tr_has hy2-wg && ! [[ -x $HY2_BIN ]] && run "Hysteria2" hy2_install "$(cf HY2_VER "$HY2_PINNED")"
  run "Хэши релизов для VPS-2" pin_release || warn "Хэши для VPS-2 не получены (rp link/rp block повторят попытку)"
  vps1_apply || die "Конфигурация не применилась (изменения откатены)"
  ok "VPS-1 переведён на $SELF_VERSION"
  note "Дальше: rp push — передать обновление на VPS-2 (по SSH, откат через 10 минут без подтверждения), затем rp test"
}

# ── Установка ────────────────────────────────────────────────────────────
vps1_install() {
  steps 7
  step "Проверка системы"
  os_check; arch_map xray >/dev/null
  ok "$(. /etc/os-release; echo "$PRETTY_NAME"), $(uname -m), фаервол: $(fw_kind), SELinux: $(getenforce 2>/dev/null || echo —)"
  conf_load
  section "Параметры" "Единственный канал без маскировки — WG клиент → VPS-1; всё остальное идёт внутри туннеля, устойчивого к ТСПУ."
  local ip order adv=n
  ip=$(cf PUBLIC_IP "${PUBLIC_IP:-}"); [[ -n $ip ]] || ip=$(public_ip)
  PUBLIC_IP=${PUBLIC_IP:-$ip}; ask PUBLIC_IP "Публичный IPv4 этого сервера" "$ip" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' "Нужен IPv4-адрес"
  WG_PORT=${WG_PORT:-$(cf WG_PORT $((20000 + RANDOM % 30000)))}
  ask WG_PORT "UDP-порт WireGuard для клиентов" "$WG_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
  choose TRANSPORT_CHOICE "Транспорты туннеля к VPS-2" all \
    "all|Все четыре (рекомендуется)|XHTTP packet-up → XHTTP auto → HY2 → HY2+Salamander; отказавшие остаются резервом" \
    "udp|Только Hysteria2 (без и с obfs)|если TCP режется ТСПУ" \
    "tcp|Только VLESS Reality · XHTTP (два варианта)|если UDP/QUIC недоступен"
  case ${TRANSPORT_CHOICE:-all} in udp) order="hy2-wg hy2o-wg" ;; tcp) order="reality-xhttp2 reality-xhttp" ;; *) order="${TR_RANK[*]}" ;; esac
  yesno "Дополнительные параметры (порты туннелей)?" n && adv=y
  HY2_PORT=${HY2_PORT:-443}; HY2O_PORT=${HY2O_PORT:-8443}; RXH_PORT=${RXH_PORT:-443}; RXH2_PORT=${RXH2_PORT:-8443}
  if [[ $adv == y ]]; then
    ord_has "$order" hy2-wg && ask HY2_PORT "UDP-порт Hysteria2" "$HY2_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
    ord_has "$order" hy2o-wg && ask HY2O_PORT "UDP-порт Hysteria2 с obfs" "$HY2O_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
    ord_has "$order" reality-xhttp && ask RXH_PORT "TCP-порт Reality/XHTTP" "$RXH_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
    ord_has "$order" reality-xhttp2 && ask RXH2_PORT "TCP-порт Reality/XHTTP (packet-up)" "$RXH2_PORT" '^[0-9]+$' "Нужен номер порта" valid_port
  fi
  [[ $order == *hy2* ]] && sni_choose HY2_MASQ_HOST "Сайт для маскировки Hysteria2 (SNI и masquerade, HTTP/3)" masq
  ord_has "$order" reality-xhttp && sni_choose RXH_SNI "SNI для Reality (XHTTP, вариант 1)" reality
  ord_has "$order" reality-xhttp2 && sni_choose RXH2_SNI "SNI для Reality (XHTTP packet-up, вариант 2; лучше другой сайт)" reality "${RXH_SNI:-}"
  local ru=y; yesno "Российские сайты напрямую с VPS-1 (списки .dat)?" y || ru=n
  printf '\n'; card "Проверьте настройки"
  kv "Публичный IP" "$PUBLIC_IP"; kv "WG клиентов" "UDP/$WG_PORT"; kv "Транспорты" "$order"
  ord_has "$order" hy2-wg && kv "Hysteria2" "UDP/$HY2_PORT · ${HY2_MASQ_HOST:-}"
  ord_has "$order" hy2o-wg && kv "Hysteria2 + obfs" "UDP/$HY2O_PORT · Salamander"
  ord_has "$order" reality-xhttp && kv "XHTTP (auto)" "TCP/$RXH_PORT · ${RXH_SNI:-—}"
  ord_has "$order" reality-xhttp2 && kv "XHTTP (packet-up)" "TCP/$RXH2_PORT · ${RXH2_SNI:-—}"
  kv "DNS через туннель" "DoH: Quad9, затем Cloudflare"
  kv "Списки РФ" "$([[ $ru == y ]] && echo напрямую || echo выключены)"; card_end
  yesno "Начать установку?" y || die "Отменено"

  step "Пакеты"
  run "Базовые пакеты" pkg_install curl openssl unzip tar nftables chrony python3 iproute procps-ng openssh-clients || die "dnf не справился: проверьте репозитории"
  run "WireGuard (wireguard-tools)" pkg_wg || die "wireguard-tools не поставились (нужен EPEL на Rocky 9)"
  run "Служебный пользователь" bash -c 'id rp >/dev/null 2>&1 || useradd -r -s /sbin/nologin -M rp'
  systemctl enable --now chronyd >/dev/null 2>&1 || true
  mkdir -p "$ETC" "$LIB" "$STATE" "$ASSETS" "$BK_DIR"; chown root:rp "$ETC"; chmod 750 "$ETC"; chmod 755 "$STATE" "$ASSETS"
  conf_set ROLE vps1 PUBLIC_IP "$PUBLIC_IP" WG_PORT "$WG_PORT" WG_NET "10.66.0.0/24" WG_NET_GW "10.66.0.1" WG_MTU 1380 \
    TRANSPORT_ORDER "$order" TRANSPORT_FORCE "" HY2_PORT "$HY2_PORT" HY2O_PORT "$HY2O_PORT" RXH_PORT "$RXH_PORT" RXH2_PORT "$RXH2_PORT" \
    RXH_SNI "${RXH_SNI:-www.microsoft.com}" RXH2_SNI "${RXH2_SNI:-www.asus.com}" XHTTP_PATH "/$(rand_hex 4)" XHTTP2_PATH "/$(rand_hex 4)" \
    HY2_MASQ "https://${HY2_MASQ_HOST:-www.microsoft.com}" EXIT_MTU 1080 DOORS "ssh=2222=127.0.0.1:22" \
    RU_DIRECT "$([[ $ru == y ]] && echo 1 || echo 0)" RU_GUARD 1 RU_GEOIP 1 DNS_RU "77.88.8.8" DNS_REMOTE "quad9 cloudflare" \
    DISABLE_IPV6 1 SNIFF 1 RL_FP chrome WATCH_MIN 15 WATCH_MAX 35 CONF_VER 2
  chown root:root "$CONF"; : >"$CLIENTS"; chmod 600 "$CLIENTS"

  step "Xray и Hysteria2"
  run "Xray $(cf XRAY_VER "$XRAY_PINNED")" xray_install "$(cf XRAY_VER "$XRAY_PINNED")" || die "Не удалось поставить Xray"
  if [[ $order == *hy2* ]]; then run "Hysteria2 $(cf HY2_VER "$HY2_PINNED")" hy2_install "$(cf HY2_VER "$HY2_PINNED")" || die "Не удалось поставить Hysteria2"; fi
  run "Хэши релизов для VPS-2" pin_release || warn "Хэши для VPS-2 не получены — блок можно будет собрать позже (rp block)"

  step "Ключи и сертификат"
  py_install; secrets_wg || die "Не удалось создать ключи WireGuard"
  secrets_reality || die "Не удалось создать ключи Reality"
  secrets_extra; conf_set HY2_PASS "$(rand_pass)"
  [[ $order == *hy2* ]] && { hy2_cert "${HY2_MASQ_HOST:-www.microsoft.com}" || die "Сертификат не создан"; }
  ssh_key; ok "Ключи созданы (секреты только в $CONF, права 600)"

  step "Списки РФ"
  if [[ $ru == y ]]; then
    # Сбой списков не должен ломать установку: продолжаем без них, включить позже — rp ru on
    run "Списки РФ (.dat)" ru_update || { warn "Списки РФ не скачались — установка продолжится без них (позже: rp ru on)"; conf_set RU_DIRECT 0; ru=n; }
  else note "Выключены"; fi

  step "Службы и применение"
  units_vps1; self_install
  systemctl enable --now rp-echo >/dev/null 2>&1
  [[ $ru == y ]] && systemctl enable --now rp-ru.timer >/dev/null 2>&1
  fw_open "$WG_PORT/udp"
  fw_trust_if wg0; fw_trust_if wg-exit; selinux_fix
  systemctl enable rp-net rp-xray wg-quick@wg0 >/dev/null 2>&1
  run "Применение конфигурации" vps1_apply || die "Конфигурация не применилась (изменения откатены)"

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

# ── Клиенты WG ───────────────────────────────────────────────────────────
client_names() { awk -F'\t' '!/^#/ && NF>=5 {print $1}' "$CLIENTS" 2>/dev/null; }
cl_show() { # cl_show имя — конфиг и QR
  local n=${1:-}; mapfile -t _l < <(client_names)
  [[ -n $n ]] || pick_from n "Клиент" "${_l[@]}" || { warn "Клиентов нет"; return 1; }
  local conf; conf=$(py client "$n") || return 1
  printf '\n%s\n' "$conf"
  mkdir -p -m 700 /root/rp-clients; chmod 700 /root/rp-clients; printf '%s\n' "$conf" >"/root/rp-clients/$n.conf"; chmod 600 "/root/rp-clients/$n.conf"
  printf '\n'; py qr "/root/rp-clients/$n.conf" || note "QR не построен (конфиг длиннее 458 байт?) — используйте файл"; printf '\n'
  note "Файл: /root/rp-clients/$n.conf"
}
cl_add() {
  need_vps1
  local n=${1:-} ip a b psk backup
  ask n "Имя клиента" "" '^[A-Za-z0-9_-]{1,24}$' "Латиница, цифры, _ и -, до 24 знаков"
  client_names | grep -Fxq "$n" && { err "Клиент «$n» уже есть"; return 1; }
  [[ -f $CLIENTS ]] || { err "Отсутствует файл клиентов $CLIENTS"; return 1; }
  ip=$(py next-ip) || return 1
  read -r a b < <(wg_pair) || return 1
  [[ -n $a && -n $b ]] || { err "Не удалось получить ключи WireGuard"; return 1; }
  psk=$(wg genpsk) || return 1
  backup=$(mktemp "$STATE/clients.XXXXXX") || return 1
  cp -p "$CLIENTS" "$backup" || { rm -f "$backup"; return 1; }
  if ! printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$a" "$b" "$psk" "$ip" >>"$CLIENTS"; then
    cp -p "$backup" "$CLIENTS"; rm -f "$backup"; return 1
  fi
  # Проверка конфигурации до установки и после применения.
  if ! py client "$n" >/dev/null || ! vps1_apply ||
     ! wg show wg0 peers 2>/dev/null | grep -Fxq "$b"; then
    err "Клиент не был успешно добавлен в работающий wg0; возвращаю прежний список"
    cp -p "$backup" "$CLIENTS"
    vps1_apply || warn "Не удалось повторно применить прежний список — проверьте wg show wg0"
    rm -f "$backup"
    return 1
  fi
  rm -f "$backup"
  ok "Клиент «$n» добавлен ($ip); peer подтверждён в wg0"
  cl_show "$n"
}

cl_del() {
  need_vps1; local n=${1:-}; mapfile -t _l < <(client_names)
  [[ -n $n ]] || pick_from n "Удалить клиента" "${_l[@]}" || { warn "Клиентов нет"; return 1; }
  client_names | grep -qx "$n" || die "Клиента «$n» нет"
  cp -p "$CLIENTS" "$CLIENTS.bak"; grep -v -P "^\Q$n\E\t" "$CLIENTS.bak" >"$CLIENTS" || true
  vps1_apply || { mv "$CLIENTS.bak" "$CLIENTS"; die "Не удалось применить, клиент возвращён"; }
  rm -f "$CLIENTS.bak" "/root/rp-clients/$n.conf"; ok "Клиент «$n» удалён"
}
cl_list() {
  need_vps1; local n=0 name ip
  while IFS=$'\t' read -r name _ _ _ ip; do [[ -n $name && $name != \#* ]] || continue; printf '   %-24s %s\n' "$name" "$ip"; n=$((n + 1)); done <"$CLIENTS"
  ((n)) || note "Клиентов нет: rp client add"
}

# ── Блок для VPS-2 ───────────────────────────────────────────────────────
block_make() { # block_make [каталог] [single] → печатает пути файлов; single — одним файлом, без деления на части
  need_vps1; local out=${1:-/root/rp-block} extra bund max raw gz n i sha
  [[ -n $(cf XRAY_SHA_64) && -n $(cf HY2_SHA_AMD64) ]] || pin_release || die "Нет хэшей релизов (GitHub недоступен?)"
  rm -rf "${out:?}"; mkdir -p "$out"; chmod 700 "$out"
  extra=$(mktemp -d "$STATE/ex.XXXXXX"); bund=$(mktemp -d "$STATE/bd.XXXXXX")
  vps2_files "$extra"; py bundle "$bund" "$extra" >/dev/null || { rm -rf "${extra:?}" "${bund:?}"; return 1; }
  vps2_installer "$bund/bundle.tgz" >"$out/block.sh"
  max=$(cf BLOCK_MAX 60000); [[ ${2:-} == single ]] && max=999999999; raw=$(stat -c %s "$out/block.sh")
  if ((raw <= max)); then
    ok "Блок: $out/block.sh ($raw байт, SHA256 внутри)"
  else
    gz=$(mktemp "$STATE/gz.XXXXXX"); gzip -9 -c "$out/block.sh" | base64 -w0 >"$gz"
    sha=$(sha256sum "$gz" | awk '{print $1}'); rm -f "$out/block.sh"
    n=$(py chunk "$gz" $((max - 800)) "$out")
    for ((i = 1; i <= n; i++)); do
      local f; f=$(printf '%s/part%02d' "$out" "$i")
      {
        printf 'set +o history 2>/dev/null; mkdir -p /root/.rp\n'
        ((i == 1)) && printf 'rm -f /root/.rp/blk.b64\n'
        printf "cat >>/root/.rp/blk.b64 <<'RP_PART_END'\n"; cat "$f"; printf 'RP_PART_END\n'
        printf 'echo "rp: часть %d из %d принята"\n' "$i" "$n"
        if ((i == n)); then
          printf '[ "$(tr -d "\\n" </root/.rp/blk.b64 | sha256sum | cut -d" " -f1)" = "%s" ] || { echo "rp: SHA256 частей не совпала — вставьте все части заново по порядку"; rm -f /root/.rp/blk.b64; exit 1; }\n' "$sha"
          printf 'base64 -d /root/.rp/blk.b64 | gunzip | bash; rm -rf /root/.rp\n'
        fi
      } >"$f.sh"; rm -f "$f"
    done
    ok "Блок велик для одной вставки: $n частей в $out (part01.sh … part$(printf '%02d' "$n").sh), вставлять по порядку"
  fi
  rm -rf "${extra:?}" "${bund:?}"; rm -f "${gz:-}"
  note "Содержит секреты: не пересылайте по открытым каналам, удалите после установки (rm -rf $out)"
  printf '%s\n' "$out"
}
cmd_block() {
  local out; out=$(block_make "${1:-}" | tail -n1) || return 1
  note "Вставка на VPS-2: откройте веб-консоль, выполните  cat > b.sh  (вставить, Ctrl-D)  и  bash b.sh"
  note "или сразу вставьте содержимое $out/*.sh в консоль"
  ls -1 "$out"
}

# ── Строка для VPS-2: VPS-2 сам скачивает блок ───────────────────────────
# VPS-1 на время поднимает одноразовый HTTPS-сервер (rp.py serve, пользователь rp). Строка для консоли VPS-2:
#   curl -fsSk --pinnedpubkey sha256//ПИН https://IP:ПОРТ/ТОКЕН|bash
# Самоподписанный сертификат создаётся на сессию; --pinnedpubkey проверяет ключ сервера (без него VPS-1 нельзя
# отличить от подмены, а блок содержит секреты). Токен — одноразовый (12 знаков, ~60 бит), TTL 30 минут.
# Обрыв загрузки безопасен: блок состоит из функций, rp_main вызывается последней строкой.
fw_open_rt() { [[ $(fw_kind) == firewalld ]] || return 0; firewall-cmd --add-port="$1" >/dev/null 2>&1; return 0; }   # только runtime
link_close() { # rp _link_close ПОРТ — после остановки сервера: результат, закрыть порт, удалить файлы с секретами
  local port=${1:-} d=$STATE/serve
  [[ -s $d/result ]] && cp -f "$d/result" "$STATE/link.result" 2>/dev/null
  [[ $port =~ ^[0-9]+$ ]] && { firewall-cmd --remove-port="$port/tcp" >/dev/null 2>&1 || true; }
  rm -rf "${d:?}"; return 0
}
cmd_link() { # rp link [порт]
  need_vps1; conf_load
  local port=${1:-$(cf LINK_PORT 8444)} ttl=${LINK_TTL:-1800} dir=$STATE/serve ip p token pin str res i
  valid_port "$port" || die "Недопустимый порт «$port»"
  ip=$(cf PUBLIC_IP); [[ -n $ip ]] || die "Не задан PUBLIC_IP"
  for p in WG_PORT HY2_PORT HY2O_PORT RXH_PORT RXH2_PORT; do [[ $(cf $p) == "$port" ]] && die "Порт $port занят туннелем ($p): rp link ДРУГОЙ_ПОРТ"; done
  systemctl stop rp-serve >/dev/null 2>&1; systemctl reset-failed rp-serve >/dev/null 2>&1
  ss -ltnH "sport = :$port" 2>/dev/null | grep -q . && die "TCP-порт $port уже занят: rp link ДРУГОЙ_ПОРТ"
  rm -rf "${dir:?}" "$STATE/link.result"; mkdir -p "$dir"; chmod 700 "$dir"   # до появления секретов
  run "Блок для VPS-2" block_make "$dir/blk" single || { rm -rf "${dir:?}"; die "Блок не собран"; }
  [[ -s $dir/blk/block.sh ]] || { rm -rf "${dir:?}"; die "Блок не создан"; }
  mv "$dir/blk/block.sh" "$dir/block.sh"; rm -rf "$dir/blk"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=$ip" \
    -keyout "$dir/key.pem" -out "$dir/crt.pem" >/dev/null 2>&1 || { rm -rf "${dir:?}"; die "openssl: сертификат не создан"; }
  pin=$(openssl x509 -in "$dir/crt.pem" -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64 -w0)
  token=$(LC_ALL=C tr -dc 'a-km-np-z2-9' </dev/urandom | head -c 12)   # без похожих знаков (l, o, 0, 1)
  [[ ${#token} == 12 && ${#pin} == 44 ]] || { rm -rf "${dir:?}"; die "Не удалось создать токен или отпечаток"; }
  chown -R rp:rp "$dir"; chmod 700 "$dir"; chmod 600 "$dir"/*.pem "$dir/block.sh"
  fw_open_rt "$port/tcp"
  systemd-run --quiet --collect --unit=rp-serve --description="rp: одноразовая отдача блока VPS-2" \
    -p User=rp -p Group=rp -p RuntimeMaxSec=$((ttl + 60)) -p NoNewPrivileges=true -p ProtectSystem=strict -p ProtectHome=true \
    -p PrivateTmp=true -p "ReadWritePaths=$dir" -p "ExecStopPost=+$SELF_BIN _link_close $port" \
    /usr/bin/python3 -I "$RP_PY" serve "$port" "$token" "$dir/block.sh" "$dir/crt.pem" "$dir/key.pem" "$ttl" \
    || { link_close "$port"; die "Не удалось запустить сервер (systemd-run)"; }
  sleep 1; systemctl is-active --quiet rp-serve || { err "Сервер не запустился:"; journalctl -u rp-serve -n 8 --no-pager 2>/dev/null | sed 's/^/    /' >&2; link_close "$port"; return 1; }
  str="curl -fsSk --pinnedpubkey sha256//$pin https://$ip:$port/$token|bash"
  printf '\n'; card "Введите на VPS-2 (консоль хостера, root)"; card_line ""; card_line "$str"; card_line ""; card_end
  note "Длина строки: ${#str} символов. Действует $((ttl / 60)) мин и только для одной загрузки; порт $port/tcp открыт лишь на это время."
  note "Если VPS-2 не достаёт порт: rp link ДРУГОЙ_ПОРТ, либо запасной путь — rp block (вставка вручную)."
  trap 'printf "\n"; systemctl stop rp-serve >/dev/null 2>&1; warn "Прервано: сервер остановлен, порт закрыт"; exit 130' INT TERM
  printf '  Жду загрузку блока (Ctrl-C — отмена) '
  for ((i = 0; i < ttl + 90; i++)); do
    systemctl is-active --quiet rp-serve || break
    ((i % 5 == 0)) && printf '.'; sleep 1
  done
  printf '\n'; trap - INT TERM
  for ((i = 0; i < 15; i++)); do [[ -d $dir ]] || break; sleep 1; done   # link_close (ExecStopPost) ещё пишет результат
  res=$(cat "$STATE/link.result" 2>/dev/null)
  case $res in
    ok) ok "VPS-2 скачал блок; сервер остановлен, секреты удалены, порт закрыт" ;;
    timeout) warn "Время вышло: блок не скачан (сервер остановлен, порт закрыт). Повторите: rp link"; return 1 ;;
    *) warn "Сервер остановлен без результата. Повторите: rp link"; return 1 ;;
  esac
  note "VPS-2 ставит пакеты и проверяет транспорты (обычно 2–5 минут); жду подключения до 10 минут…"
  for ((i = 0; i < 300; i++)); do
    if hy2_live || vps2_run true >/dev/null 2>&1; then
      touch "$STATE/linked"; ok "VPS-2 подключился"
      note "Проверка выхода: rp test    (если часть транспортов не прошла — rp prune)"
      return 0
    fi
    sleep 2
  done
  warn "VPS-2 пока не подключился. На VPS-2 смотрите: rp status / rp logs; здесь: rp status, rp test"
  return 1
}

# ── Доступ к VPS-2 ───────────────────────────────────────────────────────
hy2_live() { wg show wg-exit latest-handshakes 2>/dev/null | awk '$2>0 && systime()-$2<180 {f=1} END{exit !f}'; }
door_port() { py_door="$1"; local it; IFS=';' read -ra _d <<<"$(cf DOORS "ssh=2222=127.0.0.1:22")"; for it in "${_d[@]}"; do [[ ${it%%=*} == "$py_door" ]] && { it=${it#*=}; echo "${it%%=*}"; return 0; }; done; return 1; }
ssh_args() { # печатает аргументы ssh в зависимости от живого транспорта
  local host port
  if hy2_live; then host=10.77.0.2; port=22; else host=127.0.0.1; port=$(door_port ssh) || return 1; fi
  printf '%s\n' -i "$ETC/ssh/id_ed25519" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$ETC/ssh/known_hosts" \
    -o StrictHostKeyChecking=accept-new -o HostKeyAlias=vps2 -o ConnectTimeout=10 -o ServerAliveInterval=15 -p "$port" "root@$host"
}
cmd_ssh() {
  need_vps1; local -a a; mapfile -t a < <(ssh_args) || die "Нет двери для SSH (rp door add ssh 2222 127.0.0.1:22)"
  [[ -f $ETC/ssh/known_hosts ]] || note "Первое подключение: сверьте отпечаток с тем, что показал блок на VPS-2"
  exec ssh "${a[@]}" "$@"
}
vps2_run() { local -a a; mapfile -t a < <(ssh_args) || return 1; ssh -o BatchMode=yes "${a[@]}" "$@"; }
cmd_door() {
  need_vps1; local act=${1:-list} name=${2:-} port=${3:-} target=${4:-} d new="" it found=0
  case $act in
    list) IFS=';' read -ra _d <<<"$(cf DOORS)"; for it in "${_d[@]}"; do printf '   %s\n' "$it"; done ;;
    add)
      [[ $name =~ ^[a-z0-9-]{1,16}$ && $port =~ ^[0-9]+$ && $target =~ ^[0-9.]+:[0-9]+$ ]] || die "Формат: rp door add имя порт хост:порт (цель — IPv4)"
      valid_port "$port" || die "Неверный порт"
      d=$(cf DOORS); vps1_set DOORS "${d:+$d;}$name=$port=$target" && ok "Дверь «$name»: 127.0.0.1:$port → $target (VPS-2 заблокирует остальное)"
      warn "Чтобы цель открылась на VPS-2, передайте обновление: rp push" ;;
    del)
      IFS=';' read -ra _d <<<"$(cf DOORS)"; for it in "${_d[@]}"; do [[ ${it%%=*} == "$name" ]] && { found=1; continue; }; new+="${new:+;}$it"; done
      ((found)) || die "Двери «$name» нет"; [[ $name != ssh ]] || warn "Дверь ssh нужна для rp ssh в режимах Reality"
      vps1_set DOORS "$new" && ok "Дверь «$name» удалена" ;;
    *) die "rp door list | add имя порт хост:порт | del имя" ;;
  esac
}

# ── Обновление VPS-2 по SSH: передача, ожидание, подтверждение ───────────
# push_start [задержка_с] — блок на VPS-2 и запуск в отдельном сеансе (туннель при проверке транспортов
# перезапускается, SSH-сеанс оборвётся); откат на VPS-2 сработает сам через 10 минут без подтверждения
push_start() {
  local delay=${1:-0} out blk
  out=$(block_make /root/rp-block single | tail -n1); blk="$out/block.sh"
  [[ -f $blk ]] || { err "Блок состоит из нескольких частей; для push задайте BLOCK_MAX побольше (rp.conf) или вставьте части вручную"; return 1; }
  local -a a; mapfile -t a < <(ssh_args) || { err "Нет доступа к VPS-2"; return 1; }
  ssh -o BatchMode=yes "${a[@]}" 'mkdir -p /var/lib/rp; rm -f /var/lib/rp/push.rc; cat >/root/.rp-push.sh' <"$blk" || { err "Не удалось передать блок"; return 1; }
  ssh -o BatchMode=yes "${a[@]}" "setsid -f bash -c 'sleep $delay; RP_SAFE=1 bash /root/.rp-push.sh' >/var/lib/rp/push.log 2>&1 </dev/null" || { err "Не удалось запустить обновление"; return 1; }
  rm -rf "${out:?}"
  ok "Обновление запущено на VPS-2 (откат через 10 минут, если не подтвердить)"
}
# push_wait — ждём окончания установки на VPS-2 (до 9 минут), затем выход через VPS-2 и подтверждение
push_wait() {
  local t=0 rc=""
  note "Жду, пока VPS-2 проверит все транспорты и переподключится (до 9 минут)…"
  sleep 20; t=20
  while ((t < 540)); do
    rc=$(vps2_run 'cat /var/lib/rp/push.rc 2>/dev/null' 2>/dev/null) && [[ -n $rc ]] && break
    rc=""; sleep 6; t=$((t + 6))
  done
  [[ -n $rc ]] || { err "VPS-2 не вернулся на связь за 9 минут (откат на VPS-2 сработает сам)"; return 1; }
  ((rc == 0)) || { err "Установка на VPS-2 завершилась с ошибкой (код $rc); журнал: rp ssh 'cat /var/lib/rp/push.log'"; return 1; }
  wait_exit || { err "Выход через VPS-2 не работает после обновления (откат на VPS-2 сработает сам)"; return 1; }
  touch "$STATE/linked"
  vps2_run '/usr/local/bin/rp confirm' >/dev/null 2>&1 || { warn "Подтвердите вручную на VPS-2: rp confirm"; return 0; }
  ok "VPS-2 обновлён и подтверждён"
}
cmd_push() {
  need_vps1; push_start 0 && push_wait || return 1
  prune_offer
}
# rotate — новые UUID, пароли, shortId и ключи Reality; VPS-1 применяет значения, пока VPS-2 ставит блок
cmd_rotate() {
  need_vps1; yesno "Сменить UUID, пароли, shortId и ключи Reality? Туннель переподключится" y || return 0
  hy2_live || vps2_run true >/dev/null 2>&1 || die "Нет связи с VPS-2: сначала поднимите туннель"
  local bk a b; bk=$(mktemp "$STATE/conf.XXXXXX"); cp -p "$CONF" "$bk"
  read -r a b < <(x25519_pair) || { rm -f "$bk"; die "Ключи x25519 не созданы"; }
  conf_set HY2_PASS "$(rand_pass)" HY2O_OBFS "$(rand_pass)" RL_SID "$(rand_hex 8)" RL_PRIV "$a" RL_PUB "$b" \
    RL_UUID_X "$(uuid)" RL_UUID_T "$(uuid)" RL_UUID_PX "$(uuid)" RL_UUID_PT "$(uuid)"
  push_start 25 || { cp -p "$bk" "$CONF"; rm -f "$bk"; conf_load; die "Не удалось передать обновление"; }
  rm -f "$STATE/linked"
  vps1_apply || { cp -p "$bk" "$CONF"; conf_load; vps1_apply || true; rm -f "$bk"; die "Не применилось; VPS-2 откатится сам через 10 минут"; }
  if push_wait; then rm -f "$bk"; ok "Секреты сменены, туннель работает"
  else cp -p "$bk" "$CONF"; conf_load; vps1_apply || true; rm -f "$bk"; die "VPS-2 не переподключился: на VPS-1 возвращены прежние значения, VPS-2 откатится сам"; fi
}

# ── Транспорты: результаты проверки на VPS-2, исключение неработающих ────
tr_results() { vps2_run '/usr/local/bin/rp results' 2>/dev/null; }
cmd_transports() {
  need_vps1; local res t r st
  res=$(tr_results || true)
  card "Транспорты"
  for t in $(cf TRANSPORT_ORDER); do
    r=$(printf '%s\n' "$res" | awk -F= -v t="$t" '$1==t {print $2}')
    case $r in ok) st="${C_OK}работает${R}" ;; fail*) st="${C_ERR}не прошёл (${r#fail:})${R}" ;; *) st="${C_DIM}нет данных${R}" ;; esac
    kv "$t" "$(tr_port "$t") · $st"
    card_line "  ${C_DIM}$(transport_label "$t")${R}"
  done
  card_end
}
prune_apply() { # prune_apply «список-неработающих» → новый порядок на VPS-1 и VPS-2
  local bad=$1 t new=""
  for t in $(cf TRANSPORT_ORDER); do [[ " $bad " == *" $t "* ]] || new+="${new:+ }$t"; done
  new=$(tr_sort "$new")   # единая политика приоритетов
  [[ -n $new ]] || { err "Исключить все транспорты нельзя: сначала смените порты/SNI (rp.conf) и повторите rp select на VPS-2"; return 1; }
  vps1_set TRANSPORT_ORDER "$new" || return 1
  vps2_run "/usr/local/bin/rp _setorder $new" >/dev/null 2>&1 || warn "Порядок на VPS-2 не обновлён: на VPS-2 выполните  rp _setorder $new"
  ok "Остались: $new; порты исключённых закрыты, службы остановлены"
}
cmd_prune() {
  need_vps1; local res bad="" line t r
  res=$(tr_results) || die "Нет связи с VPS-2 — результаты проверки недоступны (выполните rp select на VPS-2)"
  [[ -n $res ]] || die "На VPS-2 нет результатов: выполните там  rp select"
  while IFS='=' read -r t r; do [[ -n $t && $r == fail* ]] && [[ " $(cf TRANSPORT_ORDER) " == *" $t "* ]] && bad+="${bad:+ }$t"; done <<<"$res"
  cmd_transports
  [[ -n $bad ]] || { ok "Все транспорты из конфигурации прошли проверку на VPS-2"; return 0; }
  warn "Не прошли проверку: $bad"
  yesno "Исключить их НАВСЕГДА из резервов (закрыть порты и остановить службы)? Обычно лучше оставить для авто-восстановления" n || return 0
  prune_apply "$bad"
}
prune_offer() { # Никакого автоматического удаления резервов: временная блокировка может исчезнуть.
  local res bad="" t r
  res=$(tr_results) || return 0
  while IFS='=' read -r t r; do [[ -n $t && $r == fail* ]] && [[ " $(cf TRANSPORT_ORDER) " == *" $t "* ]] && bad+="${bad:+ }$t"; done <<<"$res"
  [[ -n $bad ]] || return 0
  warn "Первичную проверку не прошли: $bad; остаются в списке резервов с повторными попытками"
  note "Для намеренного исключения из конфигурации: rp prune (по умолчанию отказ)"
  return 0
}

# ── Диагностика по участкам ──────────────────────────────────────────────
DOH_Q='AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE'   # запрос A example.com для DoH (RFC 8484, GET)
doh_test() { local n; n=$(sx -m 10 -H 'accept: application/dns-message' "$1?dns=$DOH_Q" 2>/dev/null | wc -c); ((n > 28)); }
# rp diag [--fix]: каждый участок пути проверяется отдельно, чтобы причина была названа, а не угадана
cmd_diag() {
  need_vps1; local fix=0 u t rf rfi eff r0 r1 pr code live=0 probe_ok=0 eg k v; local -A E=()
  [[ ${1:-} == --fix ]] && fix=1
  banner "Диагностика выхода в интернет" "$( ((fix)) && echo 'с исправлением' || echo 'только проверка')"
  # 1. службы
  for u in rp-net rp-xray; do systemctl is-active -q "$u" && ok "$u работает" || err "$u не работает (journalctl -u $u)"; done
  # 2. туннель
  if hy2_live; then live=1; ok "Туннель hy2 жив: рукопожатие WG $(wg show wg-exit latest-handshakes | awk '{print systime()-$2}' | head -1) с назад"
    wg show wg-exit transfer 2>/dev/null | awk '{printf "  · wg-exit: принято %d КБ, передано %d КБ\n", $2/1024, $3/1024}' | sed 's/^/  /' | head -1
  elif vps2_run true >/dev/null 2>&1; then ok "Туннель Reality жив (мост подключён); проверка прямого пути wg-exit пропущена"
  else err "VPS-2 не подключён ни одним транспортом: rp status; на VPS-2: rp status / rp select"; return 1; fi
  # 3. rp_filter: ответы из интернета приходят через wg-exit, обратный маршрут к ним ведёт в другой интерфейс
  rf=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo 0); rfi=$(sysctl -n net.ipv4.conf.wg-exit.rp_filter 2>/dev/null || echo 0)
  eff=$((rf > rfi ? rf : rfi))
  if ((eff == 1)); then
    err "rp_filter=строгий (all=$rf, wg-exit=$rfi): ядро выбрасывает ответы из интернета, пришедшие через wg-exit"
    if ((fix)); then sysctl -q -w net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2 net.ipv4.conf.wg-exit.rp_filter=2 && ok "rp_filter=2 (loose) выставлен"; fi
  else ok "rp_filter не мешает (all=$rf, wg-exit=$rfi)"; fi
  # 4. маршрут и прямая проба (минуя Xray)
  if ((live)); then
    ip route get 1.1.1.1 mark 255 2>/dev/null | grep -q 'wg-exit' && ok "Метка 255 ведёт в wg-exit" || err "Метка 255 НЕ ведёт в wg-exit (ip rule / таблица 200): rp restart"
    r0=$(py rpf); pr=$(py probe 1.1.1.1 443); r1=$(py rpf)
    case $pr in
      ok*) probe_ok=1; ok "Прямое TCP-соединение VPS-1 → wg-exit → VPS-2 → 1.1.1.1:443: ${pr#ok } мс (Xray не участвует)" ;;
      *) err "Прямое соединение через wg-exit не прошло: $pr"
         ((r1 > r0)) && err "  счётчик отбросов rp_filter вырос на $((r1 - r0)): ответы выбрасывает ядро VPS-1" ;;
    esac
  fi
  # 5. VPS-2: пересылка и NAT
  if eg=$(vps2_run '/usr/local/bin/rp egress' 2>/dev/null) && [[ -n $eg ]]; then
    while IFS='=' read -r k v; do [[ -n $k ]] && E[$k]=$v; done <<<"$eg"
    local fixv2=0
    [[ ${E[ip_forward]:-} == 1 ]] && ok "VPS-2: пересылка IPv4 включена" || { err "VPS-2: ip_forward=${E[ip_forward]:-?} (пересылка выключена)"; fixv2=1; }
    [[ ${E[nat]:-} == yes ]] && ok "VPS-2: NAT (masquerade) на месте, пакетов: ${E[nat_packets]:-0}" || { err "VPS-2: таблица NAT отсутствует"; fixv2=1; }
    if [[ -n ${E[fw_zone_wg]:-} && ${E[fw_zone_wg]} != нет-firewalld ]]; then
      [[ ${E[fw_forward]:-} == yes ]] && ok "VPS-2: firewalld пересылает трафик rp-wg (зона ${E[fw_zone_wg]})" || { err "VPS-2: firewalld не пересылает трафик rp-wg (зона «${E[fw_zone_wg]}», внешняя «${E[fw_zone_ext]:-?}»)"; fixv2=1; }
    fi
    [[ ${E[internet]:-} == ok ]] && ok "VPS-2: собственный выход в интернет есть" || err "VPS-2: у самого сервера нет выхода в интернет — это не лечится из rp (провайдер/фаервол хостера)"
    if ((fixv2)); then
      if ((fix)); then vps2_run '/usr/local/bin/rp fixnet' 2>&1 | sed 's/^/    /'; ok "На VPS-2 выполнен rp fixnet"; else warn "Исправить: rp diag --fix"; fi
    fi
  else warn "VPS-2: отчёт rp egress недоступен (старая версия на VPS-2? передайте обновление: rp push)"; fi
  # повтор прямой пробы после исправлений
  if ((live && fix)) && [[ $pr != ok* ]]; then sleep 2; pr=$(py probe 1.1.1.1 443); [[ $pr == ok* ]] && { probe_ok=1; ok "После исправления прямое соединение работает: ${pr#ok } мс"; } || err "Прямое соединение по-прежнему не проходит: $pr"; fi
  # 6. путь через Xray
  code=$(sx -m 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true)
  if [[ $code == 204 ]]; then ok "Через Xray (SOCKS) интернет доступен"
  else
    err "Через Xray интернет недоступен (код «${code:-нет ответа}»)"
    if ((probe_ok)); then
      warn "Прямой путь работает, значит причина в маршрутизации Xray. Последние ошибки:"
      journalctl -u rp-xray -n 200 --no-pager 2>/dev/null | grep -iE 'error|failed|reject|blackhole|block' | tail -n 6 | sed 's/^/    /'
      if ((fix)); then systemctl restart rp-xray; sleep 4; code=$(sx -m 12 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null || true); [[ $code == 204 ]] && ok "После перезапуска Xray выход работает" || err "Не помогло: пришлите вывод rp diag и rp logs 100"; fi
    fi
  fi
  # 7. DNS через туннель (DoH)
  local first; first=$(py dns | head -1)
  [[ -n $first ]] && { doh_test "$first" && ok "DoH через туннель отвечает ($first)" || err "DoH через туннель не отвечает ($first): rp dns"; }
  return 0
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
      kv "Российские домены" "обычный DNS (UDP/53) к $(cf DNS_RU 77.88.8.8), напрямую с VPS-1, в России"
      kv "Остальные домены" "DoH через туннель, с IP VPS-2; порядок: $(cf DNS_REMOTE)"
      card_end
      printf '\n  %sДоступные серверы (все — DoH, шифруются HTTPS внутри туннеля)%s\n' "$B" "$R"
      while IFS='|' read -r k n a t; do printf '   %s%-11s%s %s — %s\n     %s%s%s\n' "$C_ACC" "$k" "$R" "$n" "$a" "$C_DIM" "$t" "$R"; done < <(dns_info) ;;
    set)
      shift; local v="$*"
      [[ -n $v ]] || die "rp dns set quad9 cloudflare   (пресеты: quad9 cloudflare google adguard; или https://адрес/dns-query)"
      vps1_set DNS_REMOTE "$v" && ok "DNS через туннель: $v" ;;
    test)
      for u in $(py dns); do if doh_test "$u"; then ok "$u (DoH) отвечает"; else err "$u (DoH) не отвечает"; fi; done ;;
    *) die "rp dns [show] | set СЕРВЕРЫ | test" ;;
  esac
}

# ── Тесты T1–T8 ──────────────────────────────────────────────────────────
TR=(); t_res() { TR+=("$1|$2|$3"); case $2 in ok) ok "$1 $3" ;; fail) err "$1 $3" ;; *) note "– $1 $3" ;; esac; }
cmd_test() {
  need_vps1; TR=(); local long=0 n=204800 got live="" ip want act
  [[ ${1:-} == --long ]] && long=1
  banner "Проверка туннеля" "T1–T8"
  # T1: порты и серверы транспортов
  local t miss=""
  for t in $(cf TRANSPORT_ORDER); do
    case $t in
      hy2-wg) systemctl is-active -q rp-hy2 || miss+=" hy2" ;;
      hy2o-wg) systemctl is-active -q rp-hy2o || miss+=" hy2+obfs" ;;
      reality-xhttp) ss -lnt | grep -q ":$(cf RXH_PORT) " || miss+=" xhttp" ;;
      reality-xhttp2) ss -lnt | grep -q ":$(cf RXH2_PORT) " || miss+=" xhttp2" ;;
    esac
  done
  [[ -z $miss ]] && t_res T1 ok "серверы транспортов слушают (доступность снаружи проверяет VPS-2 при выборе)" || t_res T1 fail "не слушают:$miss"
  # T2: какой транспорт живой
  if hy2_live; then
    act=$(vps2_run 'cat /var/lib/rp/active' 2>/dev/null); live=${act:-hy2-wg}; t_res T2 ok "рукопожатие: $live (WG handshake свежий)"
  elif vps2_run true >/dev/null 2>&1; then
    act=$(vps2_run 'cat /var/lib/rp/active' 2>/dev/null); live=${act:-reality}; t_res T2 ok "рукопожатие: $live (дверь SSH отвечает)"
  else t_res T2 fail "VPS-2 не подключён: выполните «rp link» и введите строку на VPS-2 (или «rp block»); затем «rp status»"; fi
  if [[ -z $live ]]; then
    t_res T3 skip ""; t_res T4 skip ""; t_res T5 skip ""; t_res T6 skip ""; t_res T7 skip ""; t_res T8 skip ""
    warn "Если VPS-2 не достаёт VPS-1 ни одним транспортом — прямой путь заблокирован целиком: нужна цепочка через третий узел."; return 1
  fi
  # T3: ≥200 КБ в обе стороны через SSH-канал поверх самого транспорта
  got=$(vps2_run "head -c $n /dev/zero" 2>/dev/null | wc -c)
  if ((got == n)); then
    printf '%0*d' "$n" 0 | vps2_run 'wc -c' 2>/dev/null | grep -qx "$n" && t_res T3 ok "≥200 КБ в обе стороны" || t_res T3 fail "обрыв на передаче (VPS-1 → VPS-2)"
  else t_res T3 fail "обрыв после ~$((got / 1024)) КБ: замирание потока (ТСПУ) → смените порт, SNI или транспорт (rp prune)"; fi
  if ((long)); then local w; for w in 60 240 600; do note "Повтор T3 через $((w / 60)) мин…"; sleep "$w"; got=$(vps2_run "head -c $n /dev/zero" 2>/dev/null | wc -c); ((got == n)) && t_res T3+ ok "повтор: ок" || { t_res T3+ fail "повтор: обрыв после ~$((got / 1024)) КБ"; break; }; done; fi
  # T4: баннер SSH
  local -a a; mapfile -t a < <(ssh_args); local host=${a[-1]#root@} port=${a[-2]}
  timeout 8 bash -c 'exec 3<>/dev/tcp/$0/$1 && read -r -t 5 l <&3 && [[ $l == SSH-* ]]' "$host" "$port" 2>/dev/null && t_res T4 ok "баннер SSH получен" || t_res T4 fail "баннера SSH нет (sshd на VPS-2 слушает? rp door list)"
  # T5: выход через IP VPS-2 (адрес сравнивается по отпечатку и на экран не выводится)
  want=$(vps2_run 'curl -4 -fsS -m 8 https://api.ipify.org' 2>/dev/null)
  ip=$(sx -m 10 https://api.ipify.org 2>/dev/null)
  if [[ -n $want && -n $ip && $ip == "$want" ]]; then conf_set VPS2_IPH "$(ip_hash "$want")"; touch "$STATE/linked"; t_res T5 ok "выход через VPS-2 ($(mask_ip "$ip"))"
  else
    t_res T5 fail "выход «$(mask_ip "${ip:-}")», ожидался «$(mask_ip "${want:-}")»"
    note "  Запускаю диагностику по участкам (rp diag --fix исправит найденное):"; cmd_diag || true
  fi
  # T6: DNS и заблокированный ресурс
  local d1 code; d1=$(py dns | head -1)
  doh_test "$d1" && t_res T6 ok "DoH через туннель ($d1)" || t_res T6 fail "DoH через туннель не отвечает ($d1)"
  code=$(sx -m 12 -o /dev/null -I -w '%{http_code}' https://www.instagram.com/ 2>/dev/null || true)
  [[ -n $code && $code != 000 ]] && t_res T6b ok "заблокированный в РФ ресурс открывается (HTTP $code)" || t_res T6b fail "заблокированный ресурс не открылся"
  note "  UDP/DNS клиентов wg0 проверьте с клиента: nslookup example.com (перехват 53 включён)"
  # T7: остановка туннеля не даёт утечки; при остановленном туннеле Xray перезапускается
  if hy2_live; then
    ip route get 1.1.1.1 mark 255 2>/dev/null | grep -q 'wg-exit' || t_res T7a fail "метка 255 не ведёт в wg-exit"
    systemctl stop wg-quick@wg-exit; sleep 2
    if sx -m 8 https://api.ipify.org >/dev/null 2>&1; then t_res T7 fail "УТЕЧКА: при остановленном туннеле трафик идёт"
    else systemctl restart rp-xray; sleep 4
      sx -m 8 https://api.ipify.org >/dev/null 2>&1 && t_res T7 fail "УТЕЧКА после перезапуска Xray при остановленном туннеле" || t_res T7 ok "туннель остановлен — выхода нет, утечки нет (в том числе после перезапуска Xray)"; fi
    ip route show table 200 | grep -q prohibit && note "  запрет-маршрут в таблице 200 на месте"
    systemctl start wg-quick@wg-exit; sleep 3
  else t_res T7 skip "в режиме Reality выход держится на reverse-соединении: нет моста — балансировщик отдаёт block"; fi
  # T8: перезапуск VPS-1 и повторное подключение
  systemctl restart rp-xray; tr_has hy2-wg && systemctl restart rp-hy2; tr_has hy2o-wg && systemctl restart rp-hy2o
  local t0=0 up=0; while ((t0 < 90)); do wait_exit_once && { up=1; break; }; sleep 3; t0=$((t0 + 3)); done
  ((up)) && t_res T8 ok "после перезапуска VPS-1 выход восстановился за ${t0} с" || t_res T8 fail "выход не восстановился за 90 с"
  note "  Перезапуск стороны VPS-2 проверяется командой на VPS-2: rp restart (сторож вернёт туннель сам)"
  local bad=0 r; for r in "${TR[@]}"; do [[ $r == *"|fail|"* ]] && bad=1; done
  prune_offer
  return $bad
}
cmd_doctor() {
  need_vps1; banner "Сводка" "rp doctor"
  local v2 ip
  card "VPS-1"; kv "rp" "$SELF_VERSION"; kv "Xray" "$($XRAY_BIN version 2>/dev/null | awk 'NR==1{print $2}')"
  [[ -x $HY2_BIN ]] && kv "Hysteria2" "$($HY2_BIN version 2>/dev/null | awk '/^Version:/{print $2}')"
  kv "Транспорты" "$(cf TRANSPORT_ORDER)"
  ip=$(sx -m 8 https://api.ipify.org 2>/dev/null)
  kv "Выход (факт)" "$(mask_ip "${ip:-}")"
  [[ -n $ip && -n $(cf VPS2_IPH) ]] && { [[ $(ip_hash "$ip") == "$(cf VPS2_IPH)" ]] && kv "Выход = VPS-2" "да" || kv "Выход = VPS-2" "${C_ERR}нет${R}"; }
  card_end
  if v2=$(vps2_run '/usr/local/bin/rp version' 2>/dev/null); then
    card "VPS-2"; kv "Версии" "$v2"; card_end
    local mine; mine="xray $(cf XRAY_VER) hysteria $(cf HY2_VER)"
    local a b; a=$(sed -E 's/(^| )v([0-9])/\1\2/g' <<<"$v2"); b=$(sed -E 's/(^| )v([0-9])/\1\2/g' <<<"$mine")   # префикс «v» не различие
    [[ $a == "$b" ]] && ok "Версии на обоих концах согласованы" || warn "Версии различаются (VPS-1: $mine) — rp push"
  else warn "VPS-2 недоступен по SSH"; fi
  return 0
}

# ── Обновления Xray и Hysteria2 ──────────────────────────────────────────
# Порядок: ставим на VPS-1 → применяем (проверка конфига новым Xray, откат при сбое) → передаём на VPS-2 с таймером отката.
upg_list() { # upg_list xray|hy2 → «текущая» + последние стабильные
  local cur n; case $1 in xray) cur=$(cf XRAY_VER); n=$(gh_tags XTLS/Xray-core v 6) ;; hy2) cur=$(cf HY2_VER); n=$(gh_tags apernet/hysteria app/v 6) ;; esac
  [[ -n $n ]] || return 1; printf '%s\n' "$n"
}
cmd_upgrade() {
  need_vps1; local what=${1:-check} ver=${2:-} cur list v
  case $what in
    check)
      for v in xray hy2; do
        cur=$(cf "$([[ $v == xray ]] && echo XRAY_VER || echo HY2_VER)")
        list=$(upg_list "$v") || { warn "$v: лента релизов GitHub недоступна"; continue; }
        printf '   %-8s установлена %s%s%s; доступны: %s\n' "$v" "$B" "${cur:-—}" "$R" "$(tr '\n' ' ' <<<"$list")"
      done ;;
    xray|hy2)
      local verkey bin label; if [[ $what == xray ]]; then verkey=XRAY_VER; bin=$XRAY_BIN; label=Xray; else verkey=HY2_VER; bin=$HY2_BIN; label=Hysteria2; fi
      cur=$(cf "$verkey")
      if [[ -z $ver ]]; then
        list=$(upg_list "$what") || die "Не удалось получить список версий (GitHub недоступен). Версию можно указать вручную: rp upgrade $what 1.2.3"
        mapfile -t _v <<<"$list"; note "Установлена: $cur. Новые версии принимаются только после проверки и с откатом."
        pick_from ver "$label: какую версию поставить" "${_v[@]}" || return 1
      fi
      [[ $ver =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Версия вида 1.2.3"
      [[ $ver == "$cur" ]] && { ok "$label $ver уже установлен"; return 0; }
      yesno "Обновить $label $cur → $ver (VPS-1, затем VPS-2 с откатом)?" y || return 0
      cp -p "$bin" "$bin.old" 2>/dev/null; local bk; bk=$(mktemp "$STATE/conf.XXXXXX"); cp -p "$CONF" "$bk"
      if [[ $what == xray ]]; then run "Xray $ver" xray_install "$ver"; else run "Hysteria2 $ver" hy2_install "$ver"; fi || { mv -f "$bin.old" "$bin" 2>/dev/null; cp -p "$bk" "$CONF"; rm -f "$bk"; conf_load; die "Не установилось; прежняя версия на месте"; }
      run "Хэши релизов для VPS-2" pin_release || { warn "Хэши не получены"; upg_revert "$what" "$bin" "$bk"; return 1; }
      if [[ $what == hy2 ]]; then systemctl restart rp-hy2 rp-hy2o 2>/dev/null; fi
      vps1_apply || { upg_revert "$what" "$bin" "$bk"; die "Новая версия не прошла применение на VPS-1; возвращена $cur"; }
      if hy2_live || vps2_run true >/dev/null 2>&1; then
        if push_start 0 && push_wait; then rm -f "$bin.old" "$bk"; ok "$label $ver работает на обоих концах"; prune_offer
        else upg_revert "$what" "$bin" "$bk"; die "На VPS-2 не удалось: VPS-2 откатится сам; на VPS-1 возвращена $cur"; fi
      else rm -f "$bin.old" "$bk"; warn "VPS-2 не на связи: обновление поставлено на VPS-1; на VPS-2 передайте блок (rp link или rp block)"; fi ;;
    ru) ru_update --latest ;;
    self) self_upgrade ;;
    *) die "rp upgrade [check] | xray [версия] | hy2 [версия] | ru | self" ;;
  esac
}
upg_revert() { # upg_revert xray|hy2 бинарник копия-конфига
  local bin=$2 bk=$3
  mv -f "$bin.old" "$bin" 2>/dev/null; cp -p "$bk" "$CONF"; rm -f "$bk"; conf_load
  [[ $1 == hy2 ]] && systemctl restart rp-hy2 rp-hy2o 2>/dev/null
  vps1_apply || true
}

# ── Списки РФ ────────────────────────────────────────────────────────────
ru_lists_edit() { # ru_lists_edit proxy|direct домен
  local kind=$1 d=${2,,} other; other=$([[ $kind == proxy ]] && echo direct || echo proxy)
  [[ $d =~ ^[a-z0-9.-]+\.[a-z0-9-]+$ ]] || die "Нужен домен вида example.com"
  touch "$ETC/ru-$kind.list" "$ETC/ru-$other.list"
  grep -qxF "$d" "$ETC/ru-$kind.list" || echo "$d" >>"$ETC/ru-$kind.list"
  grep -vxF "$d" "$ETC/ru-$other.list" >"$ETC/ru-$other.list.tmp"; mv "$ETC/ru-$other.list.tmp" "$ETC/ru-$other.list"
  vps1_apply && ok "$d: ${kind/proxy/через туннель}${kind/direct/напрямую}"
}
cmd_ru() {
  need_vps1; case ${1:-status} in
    update) ru_update "${2:-}" ;;
    on) ru_update && vps1_set RU_DIRECT 1 && systemctl enable --now rp-ru.timer >/dev/null 2>&1 ;;
    off) vps1_set RU_DIRECT 0 && systemctl disable --now rp-ru.timer >/dev/null 2>&1; ok "Всё идёт через туннель" ;;
    proxy|direct) ru_lists_edit "$1" "${2:-}" ;;
    del) [[ -n ${2:-} ]] || die "rp ru del домен"; sed -i "/^${2//./\\.}\$/d" "$ETC/ru-proxy.list" "$ETC/ru-direct.list" 2>/dev/null; vps1_apply ;;
    status) card "Списки РФ"; kv "Режим" "$([[ $(cf RU_DIRECT) == 1 ]] && echo 'напрямую с VPS-1' || echo выключены)"; kv "Релиз" "$(cf RU_TAG —)"
      kv "Исключения: туннель" "$(wc -l <"$ETC/ru-proxy.list" 2>/dev/null || echo 0)"; kv "Исключения: напрямую" "$(wc -l <"$ETC/ru-direct.list" 2>/dev/null || echo 0)"; card_end ;;
    *) die "rp ru update|on|off|proxy ДОМЕН|direct ДОМЕН|del ДОМЕН|status" ;;
  esac
}

# ── Статус, журнал, удаление ─────────────────────────────────────────────
cmd_status() {
  need_vps1; banner "rp · VPS-1" "$(cf PUBLIC_IP)"
  card "Службы"
  kv "Xray (TPROXY, маршруты)" "$(dot_state rp-xray)"; kv "WG клиентов (wg0)" "$(dot_state wg-quick@wg0)"
  tr_has hy2-wg && kv "Hysteria2 (сервер)" "$(dot_state rp-hy2)"
  tr_has hy2o-wg && kv "Hysteria2 + obfs" "$(dot_state rp-hy2o)"
  [[ $(cf TRANSPORT_ORDER) == *hy2* ]] && kv "WG к VPS-2 (wg-exit)" "$(dot_state wg-quick@wg-exit)"
  kv "Правила сети" "$(dot_state rp-net)"; card_end
  card "Туннель"
  kv "Порядок транспортов" "$(cf TRANSPORT_ORDER)"
  local act; act=$(vps2_run 'cat /var/lib/rp/active' 2>/dev/null)
  if hy2_live || [[ -n $act ]]; then kv "Живой транспорт" "${act:-hy2}"; else kv "Живой транспорт" "${C_ERR}нет${R}"; fi
  kv "Клиентов WG" "$(client_names | wc -l)"; kv "Выход VPS-2" "$([[ -n $(cf VPS2_IPH) ]] && echo "проверен (адрес не хранится)" || echo "ещё не проверялся: rp test")"; card_end
}
cmd_logs() { journalctl -u rp-xray -u rp-hy2 -u rp-hy2o -u rp-net -u wg-quick@wg0 -u wg-quick@wg-exit -n "${1:-80}" --no-pager; }
cmd_restart() { need_vps1; systemctl restart rp-net rp-xray; tr_has hy2-wg && systemctl restart rp-hy2; tr_has hy2o-wg && systemctl restart rp-hy2o; [[ $(cf TRANSPORT_ORDER) == *hy2* ]] && systemctl restart wg-quick@wg-exit; ok "Перезапущено"; }
cmd_uninstall() {
  need_vps1; yesno "Удалить rp с VPS-1 (клиенты потеряют выход)?" n || return 0
  # по одной: общий «disable --now» со списком обрывается на первой несуществующей службе (rp-hy2o нет в установках 1.0),
  # и остальные, включая rp-xray, продолжают работать
  systemctl stop rp-serve >/dev/null 2>&1   # временный unit без файла: disable для него не сработает
  local u; for u in rp-serve rp-xray rp-hy2 rp-hy2o rp-echo rp-ru.timer rp-net wg-quick@wg0 wg-quick@wg-exit; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
  done
  fw_close "$(cf LINK_PORT 8444)/tcp"
  nft delete table inet rp_guard 2>/dev/null; nft delete table ip rp_tp 2>/dev/null; nft delete table ip6 rp_block6 2>/dev/null
  while ip rule del fwmark 1 lookup 100 2>/dev/null; do :; done; while ip rule del fwmark 255 lookup 200 2>/dev/null; do :; done
  fw_close "$(cf WG_PORT)/udp"; fw_close "$(cf HY2_PORT)/udp"; fw_close "$(cf HY2O_PORT)/udp"; fw_close "$(cf RXH_PORT)/tcp"; fw_close "$(cf RXH2_PORT)/tcp"; fw_close "$(cf RTCP_PORT)/tcp"
  rm -f /etc/systemd/system/rp-*.service /etc/systemd/system/rp-*.timer /etc/wireguard/wg0.conf /etc/wireguard/wg-exit.conf /etc/sysctl.d/99-rp.conf
  rm -rf /etc/systemd/system/wg-quick@wg0.service.d "$LIB" "$STATE"
  if yesno "Удалить и настройки с секретами ($ETC)?" n; then rm -rf "$ETC" /root/rp-clients /root/rp-block; fi
  systemctl daemon-reload; ok "Удалено. Бинарники xray/hysteria оставлены в /usr/local/bin"
}
cmd_sni() { # rp sni [хост …] — проверка кандидатов (по умолчанию весь пул)
  local h
  local -a hosts=("$@")
  ((${#hosts[@]})) || hosts=("${SNI_RU[@]}" "${SNI_WORLD[@]}")
  for h in "${hosts[@]}"; do printf '  %-24s %s\n' "$h" "$(sni_check "$h")"; done
}

# ── Меню ─────────────────────────────────────────────────────────────────
menu_clients() {
  local c
  while :; do cls; banner "Клиенты WG" "OpenWrt и другие"; cl_list
    mhead "Действия"; mi 1 "Добавить"; mi 2 "Конфиг и QR"; mi 3 "Удалить"; mi 0 "Назад"; mpick c
    case $c in 1) (cl_add); pause ;; 2) (cl_show); pause ;; 3) (cl_del); pause ;; 0) return ;; *) warn "Введите число от 0 до 3"; sleep 1 ;; esac
  done
}
menu_ru() {
  local c
  while :; do cls; banner "Российские сайты напрямую" "списки .dat"; cmd_ru status
    mhead "Действия"; mi 1 "Обновить списки"; mi 2 "Включить"; mi 3 "Выключить"; mi 4 "Исключение: через туннель"; mi 5 "Исключение: напрямую"; mi 0 "Назад"; mpick c
    case $c in 1) (cmd_ru update); pause ;; 2) (cmd_ru on); pause ;; 3) (cmd_ru off); pause ;;
      4) local d=""; ask d "Домен" "" '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$' "Нужен домен"; (cmd_ru proxy "$d"); pause ;;
      5) local d=""; ask d "Домен" "" '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$' "Нужен домен"; (cmd_ru direct "$d"); pause ;;
      0) return ;; *) warn "Введите число от 0 до 5"; sleep 1 ;; esac
  done
}
menu_dns() {
  local c v
  while :; do cls; banner "DNS" "DoH через туннель"; cmd_dns show
    mhead "Действия"; mi 1 "Выбрать серверы"; mi 2 "Проверить серверы"; mi 3 "Быстро: Quad9 + Cloudflare"; mi 4 "Быстро: только Quad9"; mi 0 "Назад"; mpick c
    case $c in
      1) v=""; ask v "Серверы через пробел (quad9 cloudflare google adguard или https://…/dns-query)" "$(cf DNS_REMOTE)" '^[A-Za-z0-9:/._ -]+$' "Недопустимые символы"; (cmd_dns set "$v"); pause ;;
      2) (cmd_dns test); pause ;; 3) (cmd_dns set quad9 cloudflare); pause ;; 4) (cmd_dns set quad9); pause ;;
      0) return ;; *) warn "Введите число от 0 до 4"; sleep 1 ;; esac
  done
}
menu_upd() {
  local c
  while :; do cls; banner "Обновления" "Xray, Hysteria2, списки"; cmd_upgrade check
    mhead "Действия"; mi 1 "Обновить Xray"; mi 2 "Обновить Hysteria2"; mi 3 "Обновить списки РФ"; mi 4 "Обновить сам rp.sh (GitHub)"; mi 0 "Назад"; mpick c
    case $c in 1) (cmd_upgrade xray); pause ;; 2) (cmd_upgrade hy2); pause ;; 3) (cmd_upgrade ru); pause ;; 4) (cmd_upgrade self); pause ;; 0) return ;; *) warn "Введите число от 0 до 4"; sleep 1 ;; esac
  done
}
menu_tunnel() {
  local c
  while :; do cls; banner "Туннель к VPS-2" "$(cf TRANSPORT_ORDER)"; cmd_door list
    mhead "Действия"; mi 1 "Строка для VPS-2 (он сам скачает блок)"; mi 2 "Блок для VPS-2 (вставка вручную)"; mi 3 "Обновить VPS-2 по SSH (откат 10 мин)"; mi 4 "SSH на VPS-2"
    mi 5 "Двери (Reality)"; mi 6 "Сменить секреты"; mi 7 "Проверка сайтов SNI"; mi 8 "Транспорты: результаты проверки"; mi 9 "Исключить неработающие транспорты"; mi 0 "Назад"; mpick c
    case $c in 1) (cmd_link); pause ;; 2) (cmd_block); pause ;; 3) (cmd_push); pause ;; 4) (cmd_ssh); pause ;; 5) (cmd_door list); pause ;; 6) (cmd_rotate); pause ;; 7) (cmd_sni); pause ;;
      8) (cmd_transports); pause ;; 9) (cmd_prune); pause ;; 0) return ;; *) warn "Введите число от 0 до 9"; sleep 1 ;; esac
  done
}
menu_main() {
  local c
  conf_load
  if (($(cf CONF_VER 1) < 2)); then   # конфигурация от версии 1.0: без перехода меню покажет устаревшие значения
    warn "Конфигурация создана версией 1.0 — нужен переход на $SELF_VERSION (ключи и клиенты сохраняются)"
    yesno "Выполнить rp migrate сейчас?" y && { (cmd_migrate); pause; }
  fi
  while :; do
    conf_load; cls; banner "rp" "VPS-1 · $(cf PUBLIC_IP) · v$SELF_VERSION"
    printf '  Xray %s   WG %s\n' "$(dot_state rp-xray)" "$(dot_state wg-quick@wg0)"
    mhead "Клиенты и туннель"
    mi 1 "Клиенты WG ›" "$(client_names | wc -l) шт."
    mi 2 "Туннель к VPS-2 ›" "$(cf TRANSPORT_ORDER)"
    mi 3 "Российские сайты напрямую ›" "$([[ $(cf RU_DIRECT) == 1 ]] && echo вкл || echo выкл)"
    mi 4 "DNS ›" "DoH: $(cf DNS_REMOTE)"
    mhead "Контроль"
    mi 5 "Проверка T1–T8"; mi 6 "Диагностика выхода (по участкам)"; mi 7 "Сводка (doctor)"; mi 8 "Статус"; mi 9 "Журнал"
    mhead "Обслуживание"
    mi 10 "Обновления (Xray, Hysteria2) ›"; mi 11 "Перезапуск"; mi 12 "Удалить rp"; mi 0 "Выход"; mpick c
    case $c in
      1) menu_clients ;; 2) menu_tunnel ;; 3) menu_ru ;; 4) menu_dns ;;
      5) (cmd_test); pause ;; 6) (cmd_diag --fix); pause ;; 7) (cmd_doctor); pause ;; 8) (cmd_status); pause ;; 9) (cmd_logs 60); pause ;;
      10) menu_upd ;; 11) (cmd_restart); pause ;; 12) (cmd_uninstall); pause; [[ -d $STATE ]] || exit 0 ;;   # после удаления меню не нужно
      0) exit 0 ;; *) warn "Введите число от 0 до 12"; sleep 1 ;;
    esac
  done
}

# ── VPS-2 из этого же скрипта ────────────────────────────────────────────
vps2_entry() {
  banner "VPS-2" "выход в интернет"
  note "На VPS-2 всё ставится блоком, который создаёт VPS-1 командой «rp block»."
  note "Блок — чистый bash: бинарники закреплены по SHA256, входящие порты не открываются, туннель инициирует VPS-2."
  yesno "Вставить блок сейчас (в конце — Ctrl-D)?" y || { note "Позже: вставьте блок в консоль или выполните bash block.sh"; return 0; }
  local f; f=$(mktemp); cat >"$f" </dev/tty; [[ -s $f ]] || die "Пусто"
  bash "$f"; local rc=$?; rm -f "$f"; return $rc
}

# ── Установка, справка, точка входа ──────────────────────────────────────
usage() {
  cat <<EOT
rp $SELF_VERSION — цепочка «клиенты WG → VPS-1 → туннель, устойчивый к ТСПУ → VPS-2»

  rp                       меню (VPS-1) или установка
  rp install               установка; роль VPS-1 / VPS-2 выбирается здесь
  rp migrate               перейти с версии 1.0 (конфиг, службы, QR-пакеты) и применить
  VPS-1:
  rp client add|del|list|show [имя]   клиенты WG (конфиг и QR; QR строит сам скрипт)
  rp link [порт]           короткая строка для VPS-2: он сам скачает блок с VPS-1 (одноразовый HTTPS, TTL 30 мин)
  rp block [каталог]       блок для VPS-2 вручную (при большом размере — части с SHA256)
  rp push                  передать блок на VPS-2 по SSH, дождаться и подтвердить (откат через 10 мин)
  rp ssh [команда]         SSH на VPS-2 через туннель (по ключу, с отпечатком host key)
  rp door list|add имя порт хост:порт|del имя    «двери» в Reality-режимах
  rp test [--long]         проверки T1–T8 (--long: повтор T3 через 1, 5, 15 мин)
  rp diag [--fix]          диагностика выхода по участкам; --fix исправляет найденное
  rp transports            транспорты и результаты их проверки на VPS-2
  rp prune                 ручное исключение транспортов (по умолчанию НЕТ; сторож пробует все)
  rp dns [show|set СЕРВЕРЫ|test]   DoH-серверы через туннель (quad9 cloudflare google adguard)
  rp doctor                версии на обоих концах, выход
  rp rotate                сменить UUID, пароли, shortId, ключи Reality (с откатом)
  rp upgrade [check|xray [версия]|hy2 [версия]|ru|self]   Xray, Hysteria2, списки, сам rp.sh (с откатом)
  rp ru update|on|off|proxy ДОМЕН|direct ДОМЕН|del ДОМЕН|status   списки РФ
  rp sni [хост…]           проверка кандидатов SNI/masquerade
  rp apply | status | logs [N] | restart | uninstall
  rp version | help
Запуск без установки: bash <(curl -fsSL $RP_URL)
Настройки: $CONF (после правки — rp apply). Переменная ASSUME_YES=1 — без вопросов.
EOT
}

cmd_install() {
  need_root; os_check; mkdir -p "$ETC" "$STATE"; chmod 755 "$STATE"; : >>"$LOG"; chmod 600 "$LOG"
  conf_load; ROLE_CHOICE=${ROLE_CHOICE:-}
  if [[ $(cf ROLE) == vps1 ]]; then
    local act=""; choose act "rp уже установлен на этом VPS-1" menu \
      "menu|Открыть управление|" "migrate|Перейти на версию $SELF_VERSION|обновить конфигурацию и службы, ключи сохраняются" \
      "reinstall|Изменить настройки|заново пройти вопросы (ключи клиентов сохранятся)" "update|Обновить списки РФ|только списки"
    case $act in menu) menu_main; return ;; migrate) cmd_migrate; return ;; update) ru_update --latest; return ;; esac
  fi
  banner "rp $SELF_VERSION" "установка"
  choose ROLE_CHOICE "Роль этого сервера" vps1 \
    "vps1|VPS-1 (Россия)|принимает WG-клиентов и ведёт трафик в туннель" \
    "vps2|VPS-2 (за границей)|выход в интернет; ставится блоком, созданным на VPS-1"
  case $ROLE_CHOICE in vps1) vps1_install ;; vps2) vps2_entry ;; esac
}

lock() { exec 9>/run/rp.lock; flock -n 9 || die "Другая операция rp уже выполняется"; }

main() {
  local cmd=${1:-}; shift || true
  case $cmd in
    ""|menu) need_root; conf_load; if [[ $(cf ROLE) == vps1 ]]; then menu_main; else cmd_install; fi ;;
    install) cmd_install ;;
    install-self) need_root; self_install && ok "Установлено: $SELF_BIN" ;;
    migrate) need_root; lock; cmd_migrate ;;
    version|-v|--version) echo "rp $SELF_VERSION" ;;
    help|-h|--help) usage ;;
    client) need_root; need_vps1; case ${1:-list} in add) lock; cl_add "${2:-}" ;; del) lock; cl_del "${2:-}" ;; list) cl_list ;; show) cl_show "${2:-}" ;; *) die "rp client add|del|list|show [имя]" ;; esac ;;
    block) need_root; cmd_block "$@" ;;
    link) need_root; lock; cmd_link "$@" ;;
    _link_close) link_close "$@" ;;     # служебная: вызывает systemd после остановки rp-serve (без lock)
    push) need_root; lock; cmd_push ;;
    ssh) need_root; cmd_ssh "$@" ;;
    door) need_root; lock; cmd_door "$@" ;;
    test) need_root; lock; cmd_test "$@" ;;
    diag) need_root; lock; cmd_diag "$@" ;;
    transports) need_root; cmd_transports ;;
    prune) need_root; lock; cmd_prune ;;
    dns) need_root; lock; cmd_dns "$@" ;;
    doctor) need_root; cmd_doctor ;;
    rotate) need_root; lock; cmd_rotate ;;
    upgrade|update) need_root; lock; cmd_upgrade "$@" ;;
    ru) need_root; lock; cmd_ru "$@" ;;
    sni) cmd_sni "$@" ;;
    apply) need_root; need_vps1; lock; vps1_apply && ok "Применено" ;;
    status) need_root; cmd_status ;;
    logs) need_root; cmd_logs "$@" ;;
    restart) need_root; lock; cmd_restart ;;
    uninstall) need_root; lock; cmd_uninstall ;;
    *) usage; exit 2 ;;
  esac
}

# ── Встроенный Python (только стандартная библиотека) ────────────────────
# rp-build: hardened113a
py_source() { cat <<'RP_PY_EOF'
#!/usr/bin/env python3
# rp.py — генератор конфигов VPS-1 и пакета для VPS-2. Только стандартная библиотека (3.9+).
# Ничего не меняет в системе: пишет файлы в каталог, который передал rp.sh.
# Ошибки: die("…") → «Ошибка: …».
import hashlib
import io
import ipaddress
import json
import os
import socket
import sys
import tarfile
import tempfile
import time

CONF = os.environ.get("RP_CONF", "/etc/rp/rp.conf")
CLIENTS = os.environ.get("RP_CLIENTS", "/etc/rp/clients.tsv")
ETC = os.environ.get("RP_ETC", "/etc/rp")
TPROXY_PORT = 14205
SOCKS_PORT = 1080
ECHO_PORT = 7000
EXIT_MARK = 255          # метка исходящих пакетов Xray в режимах hy2 (ip rule → таблица 200)
EXIT_TABLE = 200
PROBE_URL = "https://www.gstatic.com/generate_204"

# Транспорты. reality-tcp убран: ТСПУ замораживает один TCP-поток после ~16 КБ,
# XHTTP делит передачу на несколько запросов и этого не боится.
ALL_TR = ("hy2-wg", "hy2o-wg", "reality-xhttp", "reality-xhttp2")
LEGACY = {"reality-tcp": "reality-xhttp2"}
# Единый согласованный с Bash порядок предпочтения транспортов.
DEFAULT_ORDER = "reality-xhttp2 reality-xhttp hy2-wg hy2o-wg"
VARIANTS = {
    "reality-xhttp": {"tag": "rx", "port": "RXH_PORT", "sni": "RXH_SNI", "path": "XHTTP_PATH",
                      "uuid": "RL_UUID_X", "probe": "RL_UUID_PX", "rev": "r-xhttp", "mode": "auto"},
    "reality-xhttp2": {"tag": "rx2", "port": "RXH2_PORT", "sni": "RXH2_SNI", "path": "XHTTP2_PATH",
                       "uuid": "RL_UUID_T", "probe": "RL_UUID_PT", "rev": "r-xhttp2", "mode": "packet-up"},
}

# DNS через туннель: DoH (RFC 8484, HTTPS), адреса по IP — имя сервера резолвить не нужно.
DNS_PRESETS = {
    "quad9": ["https://9.9.9.9/dns-query", "https://149.112.112.112/dns-query"],
    "cloudflare": ["https://1.1.1.1/dns-query", "https://1.0.0.1/dns-query"],
    "google": ["https://8.8.8.8/dns-query", "https://8.8.4.4/dns-query"],
    "adguard": ["https://94.140.14.14/dns-query", "https://94.140.15.15/dns-query"],
}


def die(msg):
    sys.stderr.write("Ошибка: %s\n" % msg)
    sys.exit(1)


def load_conf(path=CONF):
    cfg = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] == '"':
                    v = v[1:-1]
                cfg[k.strip()] = v
    except OSError as e:
        die("не удалось прочитать %s: %s" % (path, e))
    return cfg


def need(cfg, *keys):
    miss = [k for k in keys if not cfg.get(k)]
    if miss:
        die("в rp.conf не заданы: %s" % ", ".join(miss))


def write_atomic(path, data, mode=0o644):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".rp-")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_list(path):
    """Один домен на строку, # комментарии; без дублей, порядок сохраняется."""
    out, seen = [], set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                s = line.split("#", 1)[0].strip().lower()
                if not s or s in seen:
                    continue
                try:
                    s.encode("idna")
                except UnicodeError:
                    continue
                seen.add(s)
                out.append(s)
    except OSError:
        pass
    return out


def read_clients():
    rows = []
    try:
        with open(CLIENTS, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 5 and not line.startswith("#"):
                    rows.append({"name": p[0], "priv": p[1], "pub": p[2], "psk": p[3], "ip": p[4]})
    except OSError:
        pass
    return rows


def transports(cfg):
    raw = cfg.get("TRANSPORT_ORDER", DEFAULT_ORDER).split()
    order = []
    for t in raw:
        t = LEGACY.get(t, t)
        if t not in ALL_TR:
            die("неизвестный транспорт в TRANSPORT_ORDER: %s" % t)
        if t not in order:
            order.append(t)
    force = cfg.get("TRANSPORT_FORCE", "").strip()
    if force:
        force = LEGACY.get(force, force)
        if force not in ALL_TR:
            die("TRANSPORT_FORCE: неизвестный транспорт «%s»" % force)
        order = [force]
    if not order:
        die("TRANSPORT_ORDER пуст")
    return order


def has_hy2(order):
    return any(t.startswith("hy2") for t in order)


def doors(cfg):
    """DOORS="имя=порт=хост:порт;…" → [(имя, порт, хост, порт_цели)]"""
    out = []
    for item in cfg.get("DOORS", "ssh=2222=127.0.0.1:22").split(";"):
        item = item.strip()
        if not item:
            continue
        try:
            name, lport, target = item.split("=", 2)
            host, tport = target.rsplit(":", 1)
            ipaddress.ip_address(host)
            out.append((name, int(lport), host, int(tport)))
        except ValueError:
            die("DOORS: неверная запись «%s» (нужно имя=порт=ip:порт)" % item)
    return out


def dns_remote(cfg):
    """DNS_REMOTE — пресеты и/или адреса DoH через пробел; порядок = порядок опроса (запасные следом)."""
    urls = []
    for it in cfg.get("DNS_REMOTE", "quad9 cloudflare").split():
        if it in DNS_PRESETS:
            urls += DNS_PRESETS[it]
        elif it.startswith("https://") and "\"" not in it:
            urls.append(it)
        else:
            die("DNS_REMOTE: неизвестный пресет или адрес «%s» (пресеты: %s)" % (it, ", ".join(sorted(DNS_PRESETS))))
    out = []
    for u in urls:
        if u not in out:
            out.append(u)
    if not out:
        die("DNS_REMOTE пуст")
    return out


def dns_hosts(cfg):
    """IP первых двух DoH-серверов — для строки DNS в конфигах клиентов WG (запросы всё равно перехватываются)."""
    hosts = []
    for u in dns_remote(cfg):
        h = u.split("//", 1)[1].split("/", 1)[0]
        try:
            ipaddress.ip_address(h)
            hosts.append(h)
        except ValueError:
            pass
    return hosts[:2] or ["9.9.9.9", "149.112.112.112"]


# ── Xray на VPS-1 ───────────────────────────────────────────────────────

def xh_settings(cfg, v, server):
    s = {"path": cfg.get(v["path"]) or "/rp", "mode": "auto" if server else v["mode"],
         "xPaddingBytes": "100-1000"}
    if not server and v["mode"] == "packet-up":
        # второй вариант: запросы POST разной длины и случайный срок жизни соединений
        s["scMaxEachPostBytes"] = "500000-1000000"
        s["scMinPostsIntervalMs"] = "20-60"
        s["xmux"] = {"maxConcurrency": "8-16", "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "1800-3000"}
    return s


def reality_stream(cfg, t):
    v = VARIANTS[t]
    sni = cfg[v["sni"]]
    return {"network": "xhttp", "security": "reality",
            "realitySettings": {"show": False, "target": "%s:443" % sni, "xver": 0,
                                "serverNames": [sni], "privateKey": cfg["RL_PRIV"],
                                "shortIds": [cfg["RL_SID"]]},
            "xhttpSettings": xh_settings(cfg, v, True)}


def xray_server(cfg):
    order = transports(cfg)
    xh = [t for t in order if t in VARIANTS]
    hy = has_hy2(order)
    need(cfg, "SOCKS_USER", "SOCKS_PASS")
    if xh:
        need(cfg, "RL_PRIV", "RL_SID")
    for t in xh:
        v = VARIANTS[t]
        need(cfg, v["port"], v["sni"], v["uuid"], v["probe"])

    # Local-only metadata used to route RU domains; routeOnly preserves the actual destination IP.
    # Turning it off would remove domain-based split rules for IP-only WireGuard flows.
    sniff = {"enabled": True, "destOverride": ["http", "tls"], "routeOnly": True}
    wg_tp = {"tag": "wg-tp", "listen": "0.0.0.0", "port": TPROXY_PORT, "protocol": "tunnel",
             "settings": {"network": "tcp,udp", "followRedirect": True},
             "streamSettings": {"sockopt": {"tproxy": "tproxy"}}}
    if cfg.get("SNIFF", "1") == "1":
        wg_tp["sniffing"] = sniff
    inb = [wg_tp,
           # локальный SOCKS только с паролем (127.0.0.1): пароль в rp.conf, в аргументы процессов не попадает
           {"tag": "socks-in", "listen": "127.0.0.1", "port": SOCKS_PORT, "protocol": "socks",
            "settings": {"auth": "password", "accounts": [{"user": cfg["SOCKS_USER"], "pass": cfg["SOCKS_PASS"]}],
                         "udp": False}}]
    in_tags = []
    for t in xh:
        v = VARIANTS[t]
        in_tags.append(v["tag"])
        inb.append({"tag": v["tag"], "listen": "0.0.0.0", "port": int(cfg[v["port"]]), "protocol": "vless",
                    "settings": {"decryption": "none", "clients": [
                        {"id": cfg[v["uuid"]], "reverse": {"tag": v["rev"]}},
                        {"id": cfg[v["probe"]]}]},
                    "streamSettings": reality_stream(cfg, t)})
    door_tags = []
    if xh:
        for name, lport, host, tport in doors(cfg):
            tag = "door-%s" % name
            door_tags.append(tag)
            inb.append({"tag": tag, "listen": "127.0.0.1", "port": lport, "protocol": "tunnel",
                        "settings": {"address": host, "port": tport, "network": "tcp"}})

    # Первый outbound — по умолчанию: blackhole (при любой путанице трафик не уходит напрямую).
    out = [{"tag": "block", "protocol": "blackhole"},
           {"tag": "direct", "protocol": "freedom"}]
    if hy:
        out.append({"tag": "to-exit", "protocol": "freedom",
                    "streamSettings": {"sockopt": {"mark": EXIT_MARK}}})
    if xh:
        # ipsBlocked=[]: Xray 26.x иначе блокирует 127.0.0.1 («blocked target IP») и проба к эхо не проходит;
        # сюда попадает только трафик с reality-входов по правилу «127.0.0.1:ECHO_PORT», остальное — block
        out.append({"tag": "local-echo", "protocol": "freedom",
                    "settings": {"redirect": "127.0.0.1:%d" % ECHO_PORT, "ipsBlocked": []}})
    out.append({"tag": "dns-out", "protocol": "dns",
                "settings": {"nonIPQuery": "reject", "blockTypes": [64, 65]}})

    rev_tags = [VARIANTS[t]["rev"] for t in xh]
    sel = (["to-exit"] if hy else []) + rev_tags
    use_bal = bool(rev_tags)       # балансировщик нужен, только если есть reverse-транспорты
    exit_ref = {"balancerTag": "exit"} if use_bal else {"outboundTag": "to-exit"}

    ru_dns = cfg.get("DNS_RU", "77.88.8.8")
    ru_on = cfg.get("RU_DIRECT", "1") == "1"
    ru_sets = [s for s in cfg.get("RU_SETS", "category-ru yandex vk category-gov-ru 2gis").split() if s]
    ru_domains = ["geosite:%s" % s for s in ru_sets]
    # domain: — суффиксное сопоставление (быстрее regexp, который Xray проверяет перебором по каждому запросу)
    ru_domains += ["domain:ru", "domain:su", "domain:xn--p1ai"]

    def rule(**kw):
        kw["type"] = "field"
        return kw

    rules = [rule(inboundTag=["socks-in"], **exit_ref),
             rule(inboundTag=["wg-tp"], port="53", network="tcp,udp", outboundTag="dns-out")]
    if in_tags:
        rules.append(rule(inboundTag=in_tags, ip=["127.0.0.1"], port=str(ECHO_PORT), outboundTag="local-echo"))
        rules.append(rule(inboundTag=in_tags, outboundTag="block"))
    if door_tags:
        rules.append(rule(inboundTag=door_tags, balancerTag="rev"))
    if ru_on:
        rules.append(rule(inboundTag=["dns-in"], ip=[ru_dns], outboundTag="direct"))
    rules.append(rule(inboundTag=["dns-in"], **exit_ref))
    priv = ["geoip:private"]
    if cfg.get("PUBLIC_IP"):
        priv.append("%s/32" % cfg["PUBLIC_IP"])
    rules.append(rule(inboundTag=["wg-tp"], ip=priv, outboundTag="block"))
    etc = cfg.get("ETC", ETC)
    force_proxy = read_list(os.path.join(etc, "ru-proxy.list"))
    force_direct = read_list(os.path.join(etc, "ru-direct.list"))
    if force_proxy:
        rules.append(rule(inboundTag=["wg-tp"], domain=["domain:%s" % d for d in force_proxy], **exit_ref))
    if ru_on and cfg.get("RU_GUARD", "1") == "1":
        rules.append(rule(inboundTag=["wg-tp"], domain=["geosite:ru-blocked"], **exit_ref))
    if force_direct:
        rules.append(rule(inboundTag=["wg-tp"], domain=["domain:%s" % d for d in force_direct], outboundTag="direct"))
    if ru_on:
        rules.append(rule(inboundTag=["wg-tp"], domain=ru_domains, outboundTag="direct"))
        if cfg.get("RU_GEOIP", "1") == "1":
            rules.append(rule(inboundTag=["wg-tp"], ip=["geoip:ru"], outboundTag="direct"))
    rules.append(rule(inboundTag=["wg-tp"], **exit_ref))

    dns_servers = []
    if ru_on:
        dns_servers.append({"address": ru_dns, "domains": ru_domains, "skipFallback": True})
    dns_servers += dns_remote(cfg)

    routing = {"domainStrategy": "AsIs", "rules": rules}
    res = {"log": {"loglevel": "warning", "access": "none"},
           "dns": {"tag": "dns-in", "servers": dns_servers, "queryStrategy": "UseIPv4"},
           "inbounds": inb, "outbounds": out, "routing": routing}
    if use_bal:
        bals = [{"tag": "exit", "selector": sel, "strategy": {"type": "leastPing"}, "fallbackTag": "block"}]
        if door_tags:
            bals.append({"tag": "rev", "selector": rev_tags, "strategy": {"type": "leastPing"}, "fallbackTag": "block"})
        routing["balancers"] = bals
        res["observatory"] = {"subjectSelector": sel, "probeUrl": cfg.get("PROBE_URL", PROBE_URL),
                              "probeInterval": "45s", "enableConcurrency": True}
    return json.dumps(res, indent=2, ensure_ascii=False) + "\n"


# ── Hysteria2, WireGuard ────────────────────────────────────────────────

def hy2_server(cfg, obfs=False):
    port = "HY2O_PORT" if obfs else "HY2_PORT"
    need(cfg, port, "HY2_PASS", "HY2_MASQ")
    if obfs:
        need(cfg, "HY2O_OBFS")
    etc = cfg.get("ETC", ETC)
    s = ("listen: :%s\n"
         "tls:\n  cert: %s/hy2.crt\n  key: %s/hy2.key\n  sniGuard: disable\n"
         "auth:\n  type: password\n  password: \"%s\"\n"
         % (cfg[port], etc, etc, cfg["HY2_PASS"]))
    if obfs:
        s += "obfs:\n  type: salamander\n  salamander:\n    password: \"%s\"\n" % cfg["HY2O_OBFS"]
    s += ("masquerade:\n  type: proxy\n  proxy:\n    url: %s\n    rewriteHost: true\n"
          "udp:\n  enabled: true\n  idleTimeout: 120s\n"
          "# Без bandwidth (Brutal): остаётся BBR.%s\n"
          % (cfg["HY2_MASQ"], " Salamander включён: пакеты не похожи на QUIC." if obfs
             else " Без obfs: трафик похож на HTTP/3."))
    return s


def hy2_client(cfg, obfs=False):
    port = "HY2O_PORT" if obfs else "HY2_PORT"
    need(cfg, "PUBLIC_IP", port, "HY2_PASS", "HY2_SNI", "HY2_PIN")
    pin = cfg["HY2_PIN"].upper()
    if ":" not in pin:
        pin = ":".join(pin[i:i + 2] for i in range(0, len(pin), 2))
    s = ("server: %s:%s\nauth: \"%s\"\n"
         "tls:\n  sni: %s\n  insecure: true\n  pinSHA256: \"%s\"\n"
         % (cfg["PUBLIC_IP"], cfg[port], cfg["HY2_PASS"], cfg["HY2_SNI"], pin))
    if obfs:
        need(cfg, "HY2O_OBFS")
        s += "obfs:\n  type: salamander\n  salamander:\n    password: \"%s\"\n" % cfg["HY2O_OBFS"]
    s += ("transport:\n  type: udp\n"
          "udpForwarding:\n  - listen: 127.0.0.1:51820\n    remote: 127.0.0.1:51821\n    timeout: 120s\n")
    return s


def wg_exit_server(cfg):
    need(cfg, "EXIT_PRIV1", "EXIT_PUB2", "EXIT_PSK")
    mtu = cfg.get("EXIT_MTU", "1080")
    # rp_filter=2 (loose): ответы из интернета приходят в wg-exit, а обратный маршрут к их адресам
    # в основной таблице ведёт в публичный интерфейс — при strict (1) ядро такие ответы выбрасывает.
    return ("[Interface]\nAddress = 10.77.0.1/30\nListenPort = 51821\nPrivateKey = %s\nMTU = %s\nTable = off\n"
            "PostUp = sysctl -q -w net.ipv4.conf.%%i.rp_filter=2 || true\n"
            "PostUp = ip route replace default dev wg-exit table %d metric 10\n"
            "PostDown = ip route del default dev wg-exit table %d metric 10 || true\n\n"
            "[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = 0.0.0.0/0\n"
            % (cfg["EXIT_PRIV1"], mtu, EXIT_TABLE, EXIT_TABLE, cfg["EXIT_PUB2"], cfg["EXIT_PSK"]))


def wg_exit_client(cfg):
    need(cfg, "EXIT_PRIV2", "EXIT_PUB1", "EXIT_PSK")
    return ("[Interface]\nAddress = 10.77.0.2/30\nPrivateKey = %s\nMTU = %s\nTable = off\n\n"
            "[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = 127.0.0.1:51820\n"
            "AllowedIPs = 10.77.0.1/32\n"
            "# Bootstrap handshake via probe; refresh inner WG link at a non-default 28s.\n"
            "# VPS-2 initiates to loopback; WG is encapsulated by Hysteria2, not public UDP.\n"
            "PersistentKeepalive = 28\n"
            % (cfg["EXIT_PRIV2"], cfg.get("EXIT_MTU", "1080"), cfg["EXIT_PUB1"], cfg["EXIT_PSK"]))


def wg0_server(cfg):
    need(cfg, "WG_PORT", "WG_PRIV", "WG_NET_GW")
    s = ("[Interface]\nAddress = %s/24\nListenPort = %s\nPrivateKey = %s\nMTU = %s\n"
         "# Правила перехвата и kill switch ставит rp-net.service (до подъёма wg0)\n"
         % (cfg["WG_NET_GW"], cfg["WG_PORT"], cfg["WG_PRIV"], cfg.get("WG_MTU", "1380")))
    for c in read_clients():
        s += "\n# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n" % (c["name"], c["pub"], c["psk"], c["ip"])
    return s


def client_conf(cfg, name):
    for c in read_clients():
        if c["name"] == name:
            need(cfg, "WG_PUB", "PUBLIC_IP", "WG_PORT")
            return ("[Interface]\nPrivateKey = %s\nAddress = %s/32, fd66::%s/128\nDNS = %s\nMTU = %s\n\n"
                    "[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\n"
                    "AllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = 25\n"
                    % (c["priv"], c["ip"], c["ip"].split(".")[-1], cfg.get("WG_NET_GW", "10.66.0.1"),
                       cfg.get("WG_MTU", "1380"), cfg["WG_PUB"], c["psk"], cfg["PUBLIC_IP"], cfg["WG_PORT"]))
    die("клиент «%s» не найден" % name)


def nft_rules(cfg):
    """Fail-closed: forward с/на wg0 запрещён, TCP/UDP уходит в TPROXY, IPv6 блокируется."""
    net = cfg.get("WG_NET", "10.66.0.0/24")
    return """#!/usr/sbin/nft -f
# Сгенерировано rp. Правка вручную не сохраняется — используйте rp apply.
table inet rp_guard
delete table inet rp_guard
table inet rp_guard {
  chain forward {
    type filter hook forward priority -100; policy accept;
    iifname "wg0" counter drop
    oifname "wg0" counter drop
  }
  chain input {
    type filter hook input priority -100; policy accept;
    # WG между VPS слушает только loopback: снаружи порт закрыт
    iifname != "lo" udp dport 51821 drop
    # эхо-сервер для проб доступен только с loopback и из внутреннего WG-интерфейса
    iifname != "lo" iifname != "wg-exit" tcp dport 7000 drop
  }
}
table ip rp_tp
delete table ip rp_tp
table ip rp_tp {
  chain pre {
    type filter hook prerouting priority -150; policy accept;
    iifname "wg0" ip daddr %(gw)s icmp type echo-request accept
    iifname "wg0" meta l4proto tcp tproxy to :%(tp)d meta mark set 1 accept
    iifname "wg0" meta l4proto udp tproxy to :%(tp)d meta mark set 1 accept
    iifname "wg0" drop
  }
  chain in {
    type filter hook input priority -50; policy accept;
    iifname "wg0" ip saddr != %(net)s drop
  }
}
table ip6 rp_block6
delete table ip6 rp_block6
table ip6 rp_block6 {
  chain pre {
    type filter hook prerouting priority -150; policy accept;
    iifname "wg0" drop
  }
}
""" % {"tp": TPROXY_PORT, "net": net, "gw": cfg.get("WG_NET_GW", "10.66.0.1")}


# ── Пакет для VPS-2 ──────────────────────────────────────────────────────

def xray_client(cfg, t):
    """Мост VLESS Reverse + проба 127.0.0.1:7777 → эхо VPS-1."""
    v = VARIANTS[t]
    need(cfg, "PUBLIC_IP", "RL_PUB", "RL_SID", v["port"], v["sni"], v["uuid"], v["probe"])
    port = int(cfg[v["port"]])
    rs = {"serverName": cfg[v["sni"]], "fingerprint": cfg.get("RL_FP", "chrome"), "publicKey": cfg["RL_PUB"],
          "shortId": cfg["RL_SID"], "spiderX": "/"}
    stream = {"network": "xhttp", "security": "reality", "realitySettings": rs,
              "xhttpSettings": xh_settings(cfg, v, False)}

    def vless(tag, user_id, reverse=None):
        # Xray 26.x: для reverse (и для единообразия — для пробы) нужен «упрощённый» стиль outbound
        # (address/port/id без vnext/users); со старым vnext Xray отвечает «VLESS users: please use
        # simplified outbound's config style to use "reverse"» и мост не стартует (проверено xray run -test).
        st = {"address": cfg["PUBLIC_IP"], "port": port, "id": user_id, "encryption": "none"}
        if reverse:
            st["reverse"] = {"tag": reverse}
        return {"tag": tag, "protocol": "vless", "settings": st, "streamSettings": stream}

    rules = [{"type": "field", "inboundTag": ["probe-in"], "outboundTag": "probe"}]
    for name, lport, host, tport in doors(cfg):
        rules.append({"type": "field", "inboundTag": ["r-in"], "ip": ["%s/32" % host],
                      "port": str(tport), "network": "tcp", "outboundTag": "direct"})
    rules += [{"type": "field", "inboundTag": ["r-in"], "ip": ["geoip:private"], "outboundTag": "block"},
              {"type": "field", "inboundTag": ["r-in"], "outboundTag": "direct"}]
    return json.dumps({
        "log": {"loglevel": "warning", "access": "none"},
        "inbounds": [{"tag": "probe-in", "listen": "127.0.0.1", "port": 7777, "protocol": "tunnel",
                      "settings": {"address": "127.0.0.1", "port": ECHO_PORT, "network": "tcp"}}],
        # Xray 26.x: freedom по умолчанию блокирует частные адреса (127.0.0.1…) для трафика reverse-входа —
        # «дверь» к SSH VPS-2 и проба иначе получают «blocked target IP». Защита остаётся в маршрутах r-in:
        # только адреса дверей идут в direct, geoip:private → block (проверено xray run на localhost).
        "outbounds": [{"tag": "direct", "protocol": "freedom", "settings": {"ipsBlocked": []}},
                      {"tag": "block", "protocol": "blackhole"},
                      vless("bridge", cfg[v["uuid"]], reverse="r-in"),
                      vless("probe", cfg[v["probe"]])],
        "routing": {"domainStrategy": "AsIs", "rules": rules},
    }, indent=2) + "\n"


def vps2_conf(cfg, order):
    keys = ["PUBLIC_IP", "TRANSPORT_FORCE", "HY2_PORT", "HY2O_PORT", "RXH_PORT", "RXH2_PORT",
            "XRAY_VER", "HY2_VER", "SSH_PUB", "DISABLE_IPV6"]
    lines = ["# /etc/rp/rp2.conf — параметры VPS-2 (создан блоком из VPS-1)",
             'TRANSPORT_ORDER="%s"' % " ".join(order)]
    for k in keys:
        lines.append('%s="%s"' % (k, cfg.get(k, "1" if k == "DISABLE_IPV6" else "")))
    # 15..35 s default: random interval between VPS-2 health/activity probes.
    # Keep values in rp2.conf to avoid changes silently reverting on rp push.
    def watch_interval(key, default):
        try:
            n = int(cfg.get(key, str(default)))
        except ValueError:
            die("%s: требуется целое количество секунд" % key)
        if n < 5 or n > 120:
            die("%s: допустимо 5..120 секунд" % key)
        return n
    wmin = watch_interval("WATCH_MIN", 15)
    wmax = watch_interval("WATCH_MAX", 35)
    if wmax < wmin:
        die("WATCH_MAX должен быть >= WATCH_MIN")
    lines += [f'WATCH_MIN="{wmin}"', f'WATCH_MAX="{wmax}"']
    lines.append('ECHO_PORT="%d"' % ECHO_PORT)
    return "\n".join(lines) + "\n"


def build_bundle(cfg, outdir, extra_files):
    """tar.gz с файлами VPS-2. extra_files: {путь_в_архиве: (байты, режим)} от rp.sh (юниты, скрипты)."""
    order = transports(cfg)
    files = {
        "etc/rp/rp2.conf": (vps2_conf(cfg, order).encode(), 0o640),
        "etc/rp/rp-wg.conf": (wg_exit_client(cfg).encode(), 0o600),
    }
    if "hy2-wg" in order:
        files["etc/rp/hy2.yaml"] = (hy2_client(cfg).encode(), 0o640)
    if "hy2o-wg" in order:
        files["etc/rp/hy2o.yaml"] = (hy2_client(cfg, True).encode(), 0o640)
    if "reality-xhttp" in order:
        files["etc/rp/xray-xhttp.json"] = (xray_client(cfg, "reality-xhttp").encode(), 0o640)
    if "reality-xhttp2" in order:
        files["etc/rp/xray-xhttp2.json"] = (xray_client(cfg, "reality-xhttp2").encode(), 0o640)
    files.update(extra_files)
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name in sorted(files):
            data, mode = files[name]
            ti = tarfile.TarInfo(name)
            ti.size, ti.mode, ti.mtime = len(data), mode, 0
            ti.uname = ti.gname = "root"
            tf.addfile(ti, io.BytesIO(data))
    raw = buf.getvalue()
    write_atomic(os.path.join(outdir, "bundle.tgz"), raw)
    return hashlib.sha256(raw).hexdigest(), order


# ── Команды ─────────────────────────────────────────────────────────────

def cmd_render(args):
    """render <stage-dir> — все конфиги VPS-1 + манифест (файл|путь|режим|владелец|действие)."""
    if len(args) != 1:
        die("render: нужен каталог")
    stage = args[0]
    cfg = load_conf()
    cfg["ETC"] = ETC
    order = transports(cfg)
    man = []

    def put(name, text, path, mode, owner, action):
        write_atomic(os.path.join(stage, name), text, 0o600)
        man.append("%s|%s|%s|%s|%s" % (name, path, mode, owner, action))

    put("xray.json", xray_server(cfg), "/etc/rp/xray.json", "0640", "root:rp", "restart:rp-xray")
    put("wg0.conf", wg0_server(cfg), "/etc/wireguard/wg0.conf", "0600", "root:root", "wg0")
    put("rp.nft", nft_rules(cfg), "/etc/rp/rp.nft", "0644", "root:root", "nft")
    if "hy2-wg" in order:
        put("hy2.yaml", hy2_server(cfg), "/etc/rp/hy2.yaml", "0640", "root:rp", "restart:rp-hy2")
    if "hy2o-wg" in order:
        put("hy2o.yaml", hy2_server(cfg, True), "/etc/rp/hy2o.yaml", "0640", "root:rp", "restart:rp-hy2o")
    if has_hy2(order):
        put("wg-exit.conf", wg_exit_server(cfg), "/etc/wireguard/wg-exit.conf", "0600", "root:root", "wgexit")
    sys.stdout.write("\n".join(man) + "\n")


def cmd_client(args):
    if len(args) != 1:
        die("client: нужно имя")
    sys.stdout.write(client_conf(load_conf(), args[0]))


def cmd_bundle(args):
    """bundle <outdir> <extra-dir> — пакет VPS-2; extra-dir: каталог с юнитами/скриптами (путь внутри = путь в архиве)."""
    if len(args) != 2:
        die("bundle: нужны каталоги")
    outdir, extra = args
    extra_files = {}
    for root, _, names in os.walk(extra):
        for n in names:
            p = os.path.join(root, n)
            rel = os.path.relpath(p, extra)
            with open(p, "rb") as f:
                extra_files[rel] = (f.read(), 0o755 if rel.startswith("usr/") else 0o644)
    cfg = load_conf()
    h, order = build_bundle(cfg, outdir, extra_files)
    sys.stdout.write("%s %s\n" % (h, " ".join(order)))


def cmd_next_ip(args):
    cfg = load_conf()
    net = ipaddress.ip_network(cfg.get("WG_NET", "10.66.0.0/24"))
    used = {c["ip"] for c in read_clients()} | {cfg.get("WG_NET_GW", "")}
    for h in list(net.hosts())[1:]:
        if str(h) not in used:
            print(h)
            return
    die("в подсети %s нет свободных адресов" % net)


def cmd_dns(args):
    """dns — адреса DoH из DNS_REMOTE по одному в строке (пресеты раскрыты)."""
    for u in dns_remote(load_conf()):
        print(u)


def cmd_chunk(args):
    """chunk <файл-b64> <размер> <каталог> — делит строку base64 на части."""
    src, size, outdir = args[0], int(args[1]), args[2]
    with open(src, encoding="ascii") as f:
        data = f.read().strip()
    n = 0
    for i in range(0, len(data), size):
        n += 1
        write_atomic(os.path.join(outdir, "part%02d" % n), data[i:i + size] + "\n", 0o600)
    print(n)


def cmd_probe(args):
    """probe <ip> <порт> — TCP-соединение с меткой выхода (как у Xray), без участия Xray. Для rp diag."""
    ip, port = args[0], int(args[1])
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(6)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, EXIT_MARK)
        t0 = time.time()
        s.connect((ip, port))
        print("ok %d" % int((time.time() - t0) * 1000))
    except socket.timeout:
        print("timeout")
    except OSError as e:
        print("err %s" % (e.strerror or e.errno))
    finally:
        s.close()


def cmd_rpf(args):
    """rpf — счётчик отбрасываний по rp_filter (TcpExt IPReversePathFilter)."""
    try:
        with open("/proc/net/netstat", encoding="ascii") as f:
            rows = [ln.split() for ln in f]
        for i in range(0, len(rows) - 1, 2):
            if rows[i][0] == "TcpExt:" and "IPReversePathFilter" in rows[i]:
                print(rows[i + 1][rows[i].index("IPReversePathFilter")])
                return
    except OSError:
        pass
    print(0)


def cmd_echo(args):
    """Эхо-сервер для проб T3: «DN n» — отдать n байт, «UP n» — принять n байт и ответить «OK n»."""
    import asyncio

    async def handle(r, w):
        try:
            line = (await asyncio.wait_for(r.readline(), 10)).decode("ascii", "ignore").split()
            if len(line) != 2 or not line[1].isdigit() or int(line[1]) > 8 * 1024 * 1024:
                return
            n = int(line[1])
            if line[0] == "DN":
                chunk = b"\x55" * 16384
                while n > 0:
                    w.write(chunk[:min(n, len(chunk))])
                    n -= min(n, len(chunk))
                    await w.drain()
            elif line[0] == "UP":
                while n > 0:
                    b = await asyncio.wait_for(r.read(min(n, 65536)), 20)
                    if not b:
                        return
                    n -= len(b)
                w.write(("OK %s\n" % line[1]).encode())
                await w.drain()
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        finally:
            w.close()

    async def main():
        srv = await asyncio.start_server(handle, "0.0.0.0", ECHO_PORT)
        async with srv:
            await srv.serve_forever()

    asyncio.run(main())


# ── QR-код (ISO/IEC 18004): байтовый режим, коррекция L, версии 1–14 (до 458 байт) ──────────────
# Свой генератор вместо qrencode: пакет из EPEL на практике ставился десятки минут и падал, а QR нужен
# только для конфигов клиентов WG. Проверено декодированием всех версий (OpenCV).
_QR_L = {1: (26, 7, 1, 19, 0, 0), 2: (44, 10, 1, 34, 0, 0), 3: (70, 15, 1, 55, 0, 0), 4: (100, 20, 1, 80, 0, 0),
         5: (134, 26, 1, 108, 0, 0), 6: (172, 18, 2, 68, 0, 0), 7: (196, 20, 2, 78, 0, 0), 8: (242, 24, 2, 97, 0, 0),
         9: (292, 30, 2, 116, 0, 0), 10: (346, 18, 2, 68, 2, 69), 11: (404, 20, 4, 81, 0, 0),
         12: (466, 24, 2, 92, 2, 93), 13: (532, 26, 4, 107, 0, 0), 14: (581, 30, 3, 115, 1, 116)}
_QR_ALIGN = {1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30], 6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42],
             9: [6, 26, 46], 10: [6, 28, 50], 11: [6, 30, 54], 12: [6, 32, 58], 13: [6, 34, 62], 14: [6, 26, 46, 66]}


def _gf_tables():
    exp, log = [0] * 512, [0] * 256
    x = 1
    for i in range(255):
        exp[i] = x
        log[x] = i
        x <<= 1
        if x & 0x100:
            x ^= 0x11d
    for i in range(255, 512):
        exp[i] = exp[i - 255]
    return exp, log


_EXP, _LOG = _gf_tables()


def _rs_ec(data, n):
    gen = [1]
    for i in range(n):
        nxt = [0] * (len(gen) + 1)
        for j, c in enumerate(gen):
            nxt[j] ^= c
            if c:
                nxt[j + 1] ^= _EXP[_LOG[c] + i]
        gen = nxt
    rem = [0] * n
    for b in data:
        f = b ^ rem[0]
        rem = rem[1:] + [0]
        if f:
            for i in range(n):
                if gen[i + 1]:
                    rem[i] ^= _EXP[_LOG[gen[i + 1]] + _LOG[f]]
    return rem


def qr_matrix(data):
    """Матрица модулей (список строк bool) для байтов data."""
    ver = None
    for v in sorted(_QR_L):
        total, ec, b1, d1, b2, d2 = _QR_L[v]
        cap = b1 * d1 + b2 * d2
        need = 4 + (8 if v < 10 else 16) + 8 * len(data)
        if need <= cap * 8:
            ver = v
            break
    if ver is None:
        die("QR: данных слишком много (%d байт, максимум 458)" % len(data))
    total, ec, b1, d1, b2, d2 = _QR_L[ver]
    cap = b1 * d1 + b2 * d2
    bits = [0, 1, 0, 0]
    n = len(data)
    bits += [(n >> i) & 1 for i in range(7 if ver < 10 else 15, -1, -1)]
    for b in data:
        bits += [(b >> i) & 1 for i in range(7, -1, -1)]
    bits += [0] * min(4, cap * 8 - len(bits))
    bits += [0] * (-len(bits) % 8)
    cw = [int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8)]
    pad = [0xEC, 0x11]
    while len(cw) < cap:
        cw.append(pad[(len(cw) - len(bits) // 8) % 2])
    blocks, pos = [], 0
    for cnt, dl in ((b1, d1), (b2, d2)):
        for _ in range(cnt):
            blocks.append(cw[pos:pos + dl])
            pos += dl
    ecs = [_rs_ec(b, ec) for b in blocks]
    out = []
    for i in range(max(len(b) for b in blocks)):
        for b in blocks:
            if i < len(b):
                out.append(b[i])
    for i in range(ec):
        for e in ecs:
            out.append(e[i])
    assert len(out) == total, "QR: ошибка таблицы версии %d" % ver
    allbits = []
    for c in out:
        allbits += [(c >> i) & 1 for i in range(7, -1, -1)]

    size = ver * 4 + 17
    mod = [[False] * size for _ in range(size)]
    fn = [[False] * size for _ in range(size)]

    def setfn(x, y, v):
        mod[y][x] = bool(v)
        fn[y][x] = True

    for i in range(size):
        setfn(6, i, i % 2 == 0)
        setfn(i, 6, i % 2 == 0)
    for cx, cy in ((3, 3), (size - 4, 3), (3, size - 4)):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                x, y = cx + dx, cy + dy
                if 0 <= x < size and 0 <= y < size:
                    setfn(x, y, max(abs(dx), abs(dy)) not in (2, 4))
    ap = _QR_ALIGN[ver]
    for i, cx in enumerate(ap):
        for j, cy in enumerate(ap):
            if (i == 0 and j == 0) or (i == 0 and j == len(ap) - 1) or (i == len(ap) - 1 and j == 0):
                continue
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    setfn(cx + dx, cy + dy, max(abs(dx), abs(dy)) != 1)

    def fmt(mask):
        d = (1 << 3) | mask                       # уровень L = 01
        r = d
        for _ in range(10):
            r = (r << 1) ^ ((r >> 9) * 0x537)
        b = ((d << 10) | r) ^ 0x5412
        g = lambda i: (b >> i) & 1
        for i in range(6):
            setfn(8, i, g(i))
        setfn(8, 7, g(6))
        setfn(8, 8, g(7))
        setfn(7, 8, g(8))
        for i in range(9, 15):
            setfn(14 - i, 8, g(i))
        for i in range(8):
            setfn(size - 1 - i, 8, g(i))
        for i in range(8, 15):
            setfn(8, size - 15 + i, g(i))
        setfn(8, size - 8, True)

    fmt(0)
    if ver >= 7:
        r = ver
        for _ in range(12):
            r = (r << 1) ^ ((r >> 11) * 0x1F25)
        b = (ver << 12) | r
        for i in range(18):
            a, c = size - 11 + i % 3, i // 3
            setfn(a, c, (b >> i) & 1)
            setfn(c, a, (b >> i) & 1)
    k = 0
    for right in range(size - 1, 0, -2):
        if right <= 6:                            # вертикальный тайминг (x=6) пропускаем: пары 5-4, 3-2, 1-0
            right -= 1
        for vert in range(size):
            for j in range(2):
                x = right - j
                y = size - 1 - vert if ((right + 1) & 2) == 0 else vert
                if not fn[y][x] and k < len(allbits):
                    mod[y][x] = bool(allbits[k])
                    k += 1
    masks = [lambda x, y: (x + y) % 2 == 0, lambda x, y: y % 2 == 0, lambda x, y: x % 3 == 0,
             lambda x, y: (x + y) % 3 == 0, lambda x, y: (x // 3 + y // 2) % 2 == 0,
             lambda x, y: x * y % 2 + x * y % 3 == 0, lambda x, y: (x * y % 2 + x * y % 3) % 2 == 0,
             lambda x, y: ((x + y) % 2 + x * y % 3) % 2 == 0]

    def penalty(m):
        p = 0
        for lines in (m, [list(c) for c in zip(*m)]):
            for row in lines:
                run = 1
                for i in range(1, size):
                    if row[i] == row[i - 1]:
                        run += 1
                    else:
                        if run >= 5:
                            p += 3 + run - 5
                        run = 1
                if run >= 5:
                    p += 3 + run - 5
                s = "".join("1" if v else "0" for v in row)
                p += 40 * (s.count("10111010000") + s.count("00001011101"))
        for y in range(size - 1):
            for x in range(size - 1):
                if m[y][x] == m[y][x + 1] == m[y + 1][x] == m[y + 1][x + 1]:
                    p += 3
        dark = sum(v for row in m for v in row)
        p += 10 * int(abs(dark * 100 / (size * size) - 50) / 5)
        return p

    best, bm = None, 0
    base = [row[:] for row in mod]
    for mk in range(8):
        m = [row[:] for row in base]
        for y in range(size):
            for x in range(size):
                if not fn[y][x] and masks[mk](x, y):
                    m[y][x] = not m[y][x]
        mod = m
        fmt(mk)
        pen = penalty(mod)
        if best is None or pen < best:
            best, bm = pen, mk
    m = [row[:] for row in base]
    for y in range(size):
        for x in range(size):
            if not fn[y][x] and masks[bm](x, y):
                m[y][x] = not m[y][x]
    mod = m
    fmt(bm)
    return mod


def qr_text(data, quiet=2):
    """QR для терминала: чёрные модули на белом фоне (не зависит от темы), по две строки в знаке."""
    m = qr_matrix(data)
    n = len(m)
    q = quiet
    full = [[False] * (n + 2 * q) for _ in range(q)] + \
           [[False] * q + row + [False] * q for row in m] + [[False] * (n + 2 * q) for _ in range(q)]
    if len(full) % 2:
        full.append([False] * (n + 2 * q))
    lines = []
    for y in range(0, len(full), 2):
        s = "".join({(True, True): "█", (True, False): "▀", (False, True): "▄", (False, False): " "}[(t, b)]
                     for t, b in zip(full[y], full[y + 1]))
        lines.append("\x1b[30;47m%s\x1b[0m" % s)
    return "\n".join(lines)


def cmd_qr(args):
    """qr [файл] — QR из файла или stdin."""
    data = open(args[0], "rb").read() if args else sys.stdin.buffer.read()
    print(qr_text(data.rstrip(b"\n")))


def cmd_serve(args):
    """serve ПОРТ ТОКЕН ФАЙЛ СЕРТ КЛЮЧ ТТЛ_СЕК — одноразовая отдача файла по HTTPS (блок для VPS-2).
    Отдаёт только GET /ТОКЕН и только один раз; результат («ok»/«timeout») пишет в файл result рядом."""
    import hmac
    import http.server
    import socketserver
    import ssl
    import threading
    if len(args) != 6:
        die("serve ПОРТ ТОКЕН ФАЙЛ СЕРТ КЛЮЧ ТТЛ")
    port, token, path, crt, key, ttl = args[0], args[1], args[2], args[3], args[4], int(args[5])
    resf = os.path.join(os.path.dirname(os.path.abspath(path)), "result")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(crt, key)
    done, lock, state = threading.Event(), threading.Lock(), {"taken": False}

    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        timeout = 15

        def setup(self):
            self.request.do_handshake()          # рукопожатие в потоке соединения: сканер не вешает сервер
            super().setup()

        def do_GET(self):
            if not hmac.compare_digest(self.path.encode(), ("/" + token).encode()):
                time.sleep(1)
                self.send_error(404)
                return
            with lock:
                if state["taken"]:
                    self.send_error(404)
                    return
                state["taken"] = True
            try:
                with open(path, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
            except Exception:
                state["taken"] = False
                raise
            done.set()

        def log_message(self, *a):
            pass

    class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

        def get_request(self):
            s, a = self.socket.accept()
            s.settimeout(15)
            return ctx.wrap_socket(s, server_side=True, do_handshake_on_connect=False), a

        def handle_error(self, request, client_address):
            pass

    srv = S(("0.0.0.0", int(port)), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    ok = done.wait(ttl)
    time.sleep(1)                                 # дать закончить отправку
    srv.shutdown()
    for p in (path, key):
        try:
            os.remove(p)
        except OSError:
            pass
    with open(resf, "w") as f:
        f.write("ok\n" if ok else "timeout\n")
    sys.exit(0 if ok else 3)


COMMANDS = {"qr": cmd_qr, "serve": cmd_serve, "echo": cmd_echo, "render": cmd_render, "client": cmd_client, "bundle": cmd_bundle,
            "next-ip": cmd_next_ip, "chunk": cmd_chunk, "probe": cmd_probe, "rpf": cmd_rpf, "dns": cmd_dns}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        die("команды: %s" % ", ".join(sorted(COMMANDS)))
    COMMANDS[sys.argv[1]](sys.argv[2:])
RP_PY_EOF
}

main "$@"
