#!/usr/bin/env bash
rp_transliterate() {
  LC_ALL=C sed \
    -e 's/Ё/Yo/g' \
    -e 's/Ж/Zh/g' \
    -e 's/Х/Kh/g' \
    -e 's/Ц/Ts/g' \
    -e 's/Ч/Ch/g' \
    -e 's/Ш/Sh/g' \
    -e 's/Щ/Shch/g' \
    -e 's/Ю/Yu/g' \
    -e 's/Я/Ya/g' \
    -e 's/А/A/g' \
    -e 's/Б/B/g' \
    -e 's/В/V/g' \
    -e 's/Г/G/g' \
    -e 's/Д/D/g' \
    -e 's/Е/E/g' \
    -e 's/З/Z/g' \
    -e 's/И/I/g' \
    -e 's/Й/Y/g' \
    -e 's/К/K/g' \
    -e 's/Л/L/g' \
    -e 's/М/M/g' \
    -e 's/Н/N/g' \
    -e 's/О/O/g' \
    -e 's/П/P/g' \
    -e 's/Р/R/g' \
    -e 's/С/S/g' \
    -e 's/Т/T/g' \
    -e 's/У/U/g' \
    -e 's/Ф/F/g' \
    -e 's/Ъ//g' \
    -e 's/Ы/Y/g' \
    -e 's/Ь//g' \
    -e 's/Э/E/g' \
    -e 's/ё/yo/g' \
    -e 's/ж/zh/g' \
    -e 's/х/kh/g' \
    -e 's/ц/ts/g' \
    -e 's/ч/ch/g' \
    -e 's/ш/sh/g' \
    -e 's/щ/shch/g' \
    -e 's/ю/yu/g' \
    -e 's/я/ya/g' \
    -e 's/а/a/g' \
    -e 's/б/b/g' \
    -e 's/в/v/g' \
    -e 's/г/g/g' \
    -e 's/д/d/g' \
    -e 's/е/e/g' \
    -e 's/з/z/g' \
    -e 's/и/i/g' \
    -e 's/й/y/g' \
    -e 's/к/k/g' \
    -e 's/л/l/g' \
    -e 's/м/m/g' \
    -e 's/н/n/g' \
    -e 's/о/o/g' \
    -e 's/п/p/g' \
    -e 's/р/r/g' \
    -e 's/с/s/g' \
    -e 's/т/t/g' \
    -e 's/у/u/g' \
    -e 's/ф/f/g' \
    -e 's/ъ//g' \
    -e 's/ы/y/g' \
    -e 's/ь//g' \
    -e 's/э/e/g' \
    -e 's/✓/OK/g' \
    -e 's/✗/ERROR/g' \
    -e 's/●/*/g' \
    -e 's/◆/==/g' \
    -e 's/›/>/g' \
    -e 's/—/-/g' \
    -e 's/–/-/g' \
    -e 's/→/->/g' \
    -e 's/≥/>=/g' \
    -e 's/≤/<=/g' \
    -e 's/┌/+/g' \
    -e 's/└/+/g' \
    -e 's/─/-/g' \
    -e 's/│/|/g' \
    -e 's/·/-/g' \
    -e 's/⠋/-/g' \
    -e 's/⠙/-/g' \
    -e 's/⠹/-/g' \
    -e 's/⠸/-/g' \
    -e 's/⠼/-/g' \
    -e 's/⠴/-/g' \
    -e 's/⠦/-/g' \
    -e 's/⠧/-/g' \
    -e 's/⠇/-/g' \
    -e 's/⠏/-/g'
}
# Console text conversion is deliberately presentation-only, never used for
# configuration files, command arguments, secrets or machine-readable output.
ui_printf() {
  if (( ASCII_MODE )); then
    if command -v iconv >/dev/null 2>&1; then
      printf "$@" | rp_transliterate | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null
    else
      printf "$@" | rp_transliterate
    fi
  else
    printf "$@"
  fi
}
ok()   { if (( ASCII_MODE )); then ui_printf '  [OK] %s\n' "$*"; else printf '  %s✓%s %s\n' "$C_OK" "$R" "$*"; fi; }
note() { ui_printf '  %s%s%s\n' "$C_DIM" "$*" "$R"; }
warn() { if (( ASCII_MODE )); then ui_printf '  [!] %s\n' "$*" >&2; else printf '  %s!%s %s\n' "$C_WARN" "$R" "$*" >&2; fi; }
err()  { if (( ASCII_MODE )); then ui_printf '  [ERROR] %s\n' "$*" >&2; else printf '  %s✗%s %s\n' "$C_ERR" "$R" "$*" >&2; fi; }
die()  { err "$*"; exit 1; }
rule() { if (( ASCII_MODE )); then printf '%s\n' '--------------------------------------------------------'; else printf '%s%s%s\n' "$C_DIM" '────────────────────────────────────────────────────────' "$R"; fi; }
banner() { if (( ASCII_MODE )); then ui_printf '\n== %s ==' "$1"; [[ -n "${2:-}" ]] && ui_printf '  %s' "$2"; printf '\n'; else printf '\n%s%s◆ %s%s' "$B" "$C_ACC" "$1" "$R"; [[ -n "${2:-}" ]] && printf '  %s%s%s' "$C_DIM" "$2" "$R"; printf '\n'; fi; rule; }
section() { ui_printf '\n%s%s%s\n' "$B" "$1" "$R"; shift; local l; for l in "$@"; do note "$l"; done; }
cls() { [[ -t 1 ]] && printf '\033[H\033[2J'; return 0; }
pause() { [[ -t 0 ]] && { ui_printf '\n%s  Любая клавиша - назад%s' "$C_DIM" "$R"; read -rsn1 _ </dev/tty || true; }; return 0; }
steps() { STEP_N=$1; STEP_I=0; }
step() { STEP_I=$((STEP_I + 1)); ui_printf '\n%s%s%d/%d%s  %s\n' "$B" "$C_ACC" "$STEP_I" "$STEP_N" "$R" "$*"; }
dot_state() {
  if systemctl is-active --quiet "$1" 2>/dev/null; then
    if (( ASCII_MODE )); then printf '[UP] running'; else printf '%s●%s работает' "$C_OK" "$R"; fi
  else
    if (( ASCII_MODE )); then printf '[DOWN] stopped'; else printf '%s●%s остановлена' "$C_ERR" "$R"; fi
  fi
}

card() { if (( ASCII_MODE )); then ui_printf '  +-- %s\n' "$1"; else printf '  %s┌─ %s%s\n' "$C_DIM" "$1" "$R"; fi; }
kv() { if (( ASCII_MODE )); then ui_printf '  | %-*s %s\n' "$KV_W" "$1" "$2"; else printf '  %s│%s %-*s %s\n' "$C_DIM" "$R" "$KV_W" "$1" "$2"; fi; }
card_line() { if (( ASCII_MODE )); then ui_printf '  | %s\n' "$*"; else printf '  %s│%s %s\n' "$C_DIM" "$R" "$*"; fi; }
card_end() { if (( ASCII_MODE )); then printf '  +--\n'; else printf '  %s└─%s\n' "$C_DIM" "$R"; fi; }

# run «Что делаем» команда… — вывод в журнал, на экране спиннер и итог.
run() {
  local what=$1; shift
  local t0=$SECONDS rc pid i=0 fr=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) aspin=(\ \| / -) off
  mkdir -p "$(dirname "$LOG")"; printf '\n### %s: %s\n' "$(date '+%F %T')" "$what" >>"$LOG"
  off=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  "$@" >>"$LOG" 2>&1 &
  pid=$!
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      if (( ASCII_MODE )); then
        printf '\r  [%s] %s' "${aspin[i % 4]}" "$(ui_printf '%s' "$what")"
      else
        printf '\r  %s%s%s %s' "$C_ACC" "${fr[i % 10]}" "$R" "$what"
      fi
      i=$((i + 1)); sleep 0.1
    done
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
    ui_printf '  %s%s%s%s %s>%s ' "$B" "$_uq" "$R" "${_ud:+ [$_ud]}" "$C_ACC" "$R"
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
    ui_printf '  %s%s%s [%s] %s>%s ' "$B" "$q" "$R" "$([[ $d == y ]] && echo Y/n || echo y/N)" "$C_ACC" "$R"
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
  ui_printf '\n  %s%s%s\n' "$B" "$_ct" "$R"
  for it in "${items[@]}"; do
    i=$((i + 1)); k=${it%%|*}; e=${it#*|}; n=${e%%|*}; e=${e#"$n"}; e=${e#|}
    ui_printf '   %s%d%s  %s%s%s%s\n' "$C_ACC" "$i" "$R" "$B" "$n" "$R" "${e:+  ${C_DIM}$e${R}}"
  done
  while :; do
    ui_printf '  Номер %s[%s]%s %s>%s ' "$C_DIM" "$_cd" "$R" "$C_ACC" "$R"; read -r sel </dev/tty || die "Ввод прерван"
    [[ -z "$sel" ]] && { printf -v "$_cn" '%s' "$_cd"; return 0; }
    [[ $sel =~ ^[0-9]+$ ]] && ((sel >= 1 && sel <= ${#keys[@]})) && { printf -v "$_cn" '%s' "${keys[sel-1]}"; return 0; }
    warn "Введите число от 1 до ${#keys[@]}"
  done
}
# Меню
mhead() { ui_printf '\n  %s%s%s\n' "$C_DIM" "$1" "$R"; }
mi() { ui_printf '   %s%2s%s  %-*s %s%s%s\n' "$C_ACC" "$1" "$R" "$MI_W" "$2" "$C_DIM" "${3:-}" "$R"; }
mpick() { ui_printf '\n  %s>%s ' "$C_ACC" "$R"; read -r "$1" </dev/tty || exit 0; }
pick_from() { # pick_from ПЕРЕМЕННАЯ «Заголовок» элементы… (номер или имя; один элемент — Enter)
  local _pn=$1 _pt=$2; shift 2; local -a a=("$@"); local s i
  ((${#a[@]})) || return 1
  if ((${#a[@]} == 1)); then printf -v "$_pn" '%s' "${a[0]}"; return 0; fi
  ui_printf '\n  %s%s%s\n' "$B" "$_pt" "$R"; for i in "${!a[@]}"; do ui_printf '   %s%d%s  %s\n' "$C_ACC" $((i + 1)) "$R" "${a[i]}"; done
  while :; do
    ui_printf '  Номер или имя %s>%s ' "$C_ACC" "$R"; read -r s </dev/tty || return 1
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
conf_set_abort() { rm -rf -- "$1"; die "$2"; }
conf_set() {
  local k v tmp rc
  (($# > 0 && $# % 2 == 0)) || die "conf_set: нужны пары ключ/значение"
  mkdir -p "$ETC" || die "Не удалось создать каталог конфигурации"
  # Every intermediate copy is private, including grep's replacement file.
  tmp=$(mktemp -d "$ETC/.rp.XXXXXX") || die "Не удалось подготовить запись конфигурации"
  if [[ -e $CONF ]]; then
    cp -p "$CONF" "$tmp/config" || conf_set_abort "$tmp" "Не удалось прочитать прежнюю конфигурацию"
  else
    : >"$tmp/config" || conf_set_abort "$tmp" "Не удалось создать новую конфигурацию"
  fi
  while (($# >= 2)); do
    k=$1; v=$2; shift 2
    [[ $k =~ ^[A-Z0-9_]+$ ]] || conf_set_abort "$tmp" "Неверное имя параметра: $k"
    [[ $v == *[\"\$\`\\]* || $v == *$'\n'* ]] && conf_set_abort "$tmp" "Недопустимые символы в значении $k"
    if grep -v "^${k}=" "$tmp/config" >"$tmp/next"; then :; else
      rc=$?
      ((rc == 1)) || conf_set_abort "$tmp" "Ошибка чтения или записи конфигурации"
    fi
    mv "$tmp/next" "$tmp/config" || conf_set_abort "$tmp" "Не удалось подготовить конфигурацию"
    printf '%s="%s"\n' "$k" "$v" >>"$tmp/config" || conf_set_abort "$tmp" "Не удалось записать конфигурацию"
  done
  chmod 600 "$tmp/config" || conf_set_abort "$tmp" "Не удалось защитить конфигурацию"
  mv "$tmp/config" "$CONF" || conf_set_abort "$tmp" "Не удалось заменить конфигурацию"
  rmdir "$tmp" || warn "Не удалось удалить пустой каталог записи конфигурации"
  conf_load
}

rand_hex() { openssl rand -hex "$1"; }
rand_pass() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }
uuid() { cat /proc/sys/kernel/random/uuid; }
