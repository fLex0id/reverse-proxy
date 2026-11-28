#!/usr/bin/env bash
# rp — клиенты WG → VPS-1 (РФ) → туннель (XHTTP/HY2) → VPS-2 (выход).
# 1.2.9-lab.2: durable prepare recovery, bounded failover, identity-preserving reinstall, scoped removal; lab acceptance pending.
# 1.2.8: audit fixes (backup perms, early rollback timer, confirm checks, menu locks, rp.sh URL, stale files).
# 1.2.7: RU-list download fallbacks/resume, fast observatory, SSH-door wait in rp test, exact probe byte counts.
# 1.2.6: complete SNI + all transport validation, Xray 26.4.25-compatible DNS, strict RU lists.
# 1.2.3: DNS routing consistency, fail-closed name resolution and verified geosite updates.
# Сборка 1.2.1: согласование обоих Xray-балансировщиков, журнал переключений, восстановление управления.
# Один файл: роль VPS-1 (сервер, меню, генератор) или VPS-2 (блок на чистом bash, сторож).
# Образец по структуре и стилю — tt.sh; отступления помечены «ОТСТУПЛЕНИЕ» с причиной.
# Rocky Linux 9/10. Конфигурация: /etc/rp/rp.conf (единственный источник правды).
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 022
SELF_VERSION="@VERSION@"

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
# RU_REF=latest: get an immutable timestamped release tag from GitHub API before downloading.
# Set RU_REF to a known numeric tag (e.g. 202611111121) in rp.conf for pinned updates.
SOCKS_PORT=1080
# Адрес для установки команды rp и обновления самого скрипта (можно переопределить переменной RP_URL)
RP_URL="${RP_URL:-https://raw.githubusercontent.com/fLex0id/reverse-proxy/main/rp.sh}"

declare -gA CFG=()
ASSUME_YES="${ASSUME_YES:-0}"

# ── UI ───────────────────────────────────────────────────────────────────
# VNC/SPICE text consoles commonly expose TERM=linux and lack Unicode glyphs.
# RP_ASCII=1 forces the safe text UI; RP_ASCII=0 forces Unicode.
# The command-line switch --ascii is accepted in main() below.
RP_ASCII="${RP_ASCII:-auto}"
case "$RP_ASCII" in
  1|true|yes) ASCII_MODE=1 ;;
  0|false|no) ASCII_MODE=0 ;;
  auto|*) case "${TERM:-dumb}" in
    linux|dumb|vt100|vt102|cons25|ansi) ASCII_MODE=1 ;;
    *) if [[ -t 1 && -z "${SSH_TTY:-}${SSH_CONNECTION:-}" ]]; then ASCII_MODE=1; else ASCII_MODE=0; fi ;;
  esac ;;
esac
if [[ -t 1 && -z "${NO_COLOR:-}" && $ASCII_MODE == 0 ]]; then
  c() { printf '\033[38;5;%sm' "$1"; }; R=$'\033[0m'; B=$'\033[1m'
  C_ACC=$(c 39); C_OK=$(c 42); C_WARN=$(c 214); C_ERR=$(c 203); C_DIM=$(c 245)
else
  R=""; B=""; C_ACC=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""
fi
export LC_ALL=C.UTF-8 2>/dev/null || true

STEP_N=0; STEP_I=0
KV_W=18
MI_W=34
RP_PY=$LIB/rp.py
SNI_RU=(www.rzd.ru www.mos.ru www.aeroflot.ru www.vtb.ru www.pochta.ru www.hh.ru www.drom.ru www.lenta.com
  www.dns-shop.ru www.citilink.ru www.mvideo.ru www.sportmaster.ru www.ozon.ru www.sberbank.ru ya.ru)
SNI_WORLD=(www.lovelive-anime.jp www.msi.com www.asus.com www.gigabyte.com www.logitech.com www.razer.com
  www.corsair.com www.synology.com www.mikrotik.com www.jetbrains.com www.sap.com www.cisco.com www.lenovo.com
  www.canon.com www.nikon.com www.philips.com www.bosch.com www.siemens.com www.decathlon.com www.ikea.com
  www.zalando.com dl.google.com www.microsoft.com)
SNI_CACHE=""
# Приоритет для этой инсталляции: XHTTP packet-up, затем XHTTP stream-up,
# затем HY2/QUIC и HY2+Salamander. Это политика, а не гарантия невидимости DPI.
# Один рабочий транспорт VPS-2 за раз; остальные сохраняются для повторных попыток.
TR_RANK=(reality-xhttp2 reality-xhttp hy2-wg hy2o-wg)
# ── Диагностика по участкам ──────────────────────────────────────────────
DOH_Q='AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE'   # запрос A example.com для DoH (RFC 8484, GET)
declare -gA ACT=()
TR=()
