rp_plain_console() {
  case "${RP_ASCII:-auto}" in
    1|yes|true) return 0 ;; 0|no|false) return 1 ;;
  esac
  case "${TERM:-}" in linux|dumb|vt100|vt102|cons25|ansi) return 0 ;; esac
  [[ -t 1 && -z "${SSH_TTY:-}${SSH_CONNECTION:-}" ]]
}
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
rp_msg() {
  if rp_plain_console; then
    if command -v iconv >/dev/null 2>&1; then
      printf '%s\n' "$*" | rp_transliterate | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null
    else
      printf '%s\n' "$*" | rp_transliterate
    fi
  else
    printf '%s\n' "$*"
  fi
}
rp_fail() { rp_msg "ERROR: $*" >&2; exit 1; }
rp_dl() { local d=2; for _ in 1 2 3 4 5; do curl -fsSL --connect-timeout 10 -m 180 -o "$2" "$1" && [[ -s $2 ]] && return 0; sleep $d; d=$((d * 2)); done; return 1; }
rp_pkg_install() {
  local p; local -a missing=()
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  # A code update must not depend on repository availability or upgrade already
  # installed OS packages. Fresh installations still require every dependency.
  if ((${#missing[@]})); then
    dnf -y install "${missing[@]}" || return 1
  fi
  rpm -q "$@" >/dev/null 2>&1
}
rp_main() {
  exec </dev/null   # скрипт уже прочитан целиком (rp_main — последняя строка): команды не должны читать остаток потока
  [[ $EUID -eq 0 ]] || rp_fail "Нужен root"
  command -v dnf >/dev/null || rp_fail "Нужен dnf (Rocky Linux 9/10)"
  exec 8>/run/rp-vps2-mutation.lock
  flock -n 8 || rp_fail "Другая операция VPS-2 выполняется"
  command -v python3 >/dev/null || dnf -y install python3 >/dev/null 2>&1 || rp_fail "Не удалось установить python3 для безопасного обновления"
  local xurl xsha hurl hsha
  tmp=$(mktemp -d) || rp_fail "mktemp"
  mkdir -p /var/lib/rp; rm -f /var/lib/rp/push.rc
  # код завершения читает VPS-1 (rp push ждёт его, прежде чем подтвердить обновление)
  rp_mutated=0
  # При ошибке после начала изменений (RP_SAFE=1) откатываемся сразу, не дожидаясь таймера.
  trap 'rc=$?; rm -rf "$tmp"; if [[ $rc -ne 0 && $RP_SAFE == 1 && $rp_mutated == 1 ]]; then python3 /var/lib/rp/transaction/runner.py rollback --from-installer || true; fi; printf "%s\n" "$rc" >/var/lib/rp/push.rc' EXIT
  # Validate and extract ONLY the transaction helper before mutation. Its hash
  # is covered by the generated bundle digest. The backup runner is immutable.
  rp_bundle | base64 -d >"$tmp/b.tgz" 2>/dev/null || rp_fail "Бандл повреждён (base64)"
  [[ $(sha256sum "$tmp/b.tgz" | awk '{print $1}') == "$RP_BUNDLE_SHA" ]] || rp_fail "SHA256 бандла не совпала"
  if [[ $RP_SAFE == 1 ]]; then
    tar -xOzf "$tmp/b.tgz" usr/local/lib/rp/transaction.py >"$tmp/transaction.py" || rp_fail "Нет transaction helper"
    python3 "$tmp/transaction.py" prepare "$$" || rp_fail "Транзакция не подготовлена"
    rp_mutated=1
  fi
  rp_msg "rp: установка VPS-2"
  # 2. пакеты
  rp_msg "Пакеты"
  install -m 600 /dev/null /var/lib/rp/packages.log || rp_fail "Не удалось создать журнал пакетов"
  rp_pkg_install chrony nftables curl unzip tar >"/var/lib/rp/packages.log" 2>&1 || rp_fail "Не установлены базовые пакеты; подробности: /var/lib/rp/packages.log"
  local tool; for tool in chronyd nft curl unzip tar; do
    command -v "$tool" >/dev/null || rp_fail "Пакет установлен, но команда $tool отсутствует; восстановите пакет"
  done
  command -v wg >/dev/null || { dnf -y install wireguard-tools >/dev/null 2>&1 || { dnf -y install epel-release >/dev/null 2>&1 && dnf -y install wireguard-tools >/dev/null 2>&1; }; }
  command -v wg >/dev/null || rp_fail "wireguard-tools не установились (нужен EPEL на Rocky 9)"
  systemctl enable --now chronyd >/dev/null 2>&1 || rp_fail "Не удалось запустить chronyd"
  id xray >/dev/null 2>&1 || useradd -r -s /sbin/nologin -M xray || rp_fail "Не удалось создать пользователя xray"
  # 3. бинарники: закреплённые URL и SHA256
  case $(uname -m) in
    x86_64) xurl=$RP_X_URL_64; xsha=$RP_X_SHA_64; hurl=$RP_H_URL_AMD64; hsha=$RP_H_SHA_AMD64 ;;
    aarch64) xurl=$RP_X_URL_ARM; xsha=$RP_X_SHA_ARM; hurl=$RP_H_URL_ARM64; hsha=$RP_H_SHA_ARM64 ;;
    *) rp_fail "Архитектура $(uname -m) не поддерживается" ;;
  esac
  rp_msg "Xray и Hysteria2"
  rp_dl "$xurl" "$tmp/x.zip" || rp_fail "не скачался Xray"
  [[ $(sha256sum "$tmp/x.zip" | awk '{print $1}') == "$xsha" ]] || rp_fail "SHA256 Xray не совпала"
  unzip -qo "$tmp/x.zip" xray geoip.dat geosite.dat -d "$tmp/x" || rp_fail "не распаковался Xray"
  install -m 755 "$tmp/x/xray" /usr/local/bin/xray.new && mv /usr/local/bin/xray.new /usr/local/bin/xray || rp_fail "Не удалось записать/заменить Xray"
  install -d -m 755 /usr/local/share/rp || rp_fail "Не удалось создать каталог данных Xray"
  install -m 644 "$tmp/x/geoip.dat" "$tmp/x/geosite.dat" /usr/local/share/rp/ || rp_fail "Не удалось записать данные Xray"
  rp_dl "$hurl" "$tmp/h" || rp_fail "не скачалась Hysteria2"
  [[ $(sha256sum "$tmp/h" | awk '{print $1}') == "$hsha" ]] || rp_fail "SHA256 Hysteria2 не совпала"
  install -m 755 "$tmp/h" /usr/local/bin/hysteria.new && mv /usr/local/bin/hysteria.new /usr/local/bin/hysteria || rp_fail "Не удалось записать/заменить Hysteria2"
  # 4. files: distinguish an ordinary code update from re-provisioning after
  # VPS-1 was deleted and its management key was regenerated.  A stale manual
  # transport on VPS-2 otherwise pins the wrong newly installed bridge.
  local old_ssh_pub="" new_ssh_pub="" rp_new_identity=0
  old_ssh_pub=$(grep '^SSH_PUB=' /etc/rp/rp2.conf 2>/dev/null || true)
  new_ssh_pub=$(tar -xOzf "$tmp/b.tgz" etc/rp/rp2.conf 2>/dev/null | grep '^SSH_PUB=' | head -1 || true)
  if [[ -n $old_ssh_pub && -n $new_ssh_pub && $old_ssh_pub != "$new_ssh_pub" ]]; then
    rp_new_identity=1
    rp_msg "Обнаружен новый ключ управления VPS-1: прежняя фиксация транспорта не переносится"
    if [[ $RP_SAFE == 1 ]]; then
      for f in mode active since; do
        if [[ -f /var/lib/rp/$f ]]; then cp -p /var/lib/rp/$f /var/lib/rp/$f.before-identity || rp_fail "Не удалось сохранить состояние $f"; fi
      done
    fi
  fi
  rp_msg "Конфигурация и службы"
  install -d -m 755 /var/lib/rp || rp_fail "Не удалось создать каталог состояния"
  tar -xzf "$tmp/b.tgz" -C / || rp_fail "не распаковался бандл"
  chown root:xray /etc/rp && chmod 750 /etc/rp || rp_fail "Не удалось защитить каталог конфигурации"
  local f; for f in /etc/rp/rp2.conf /etc/rp/hy2.yaml /etc/rp/hy2o.yaml /etc/rp/xray-xhttp.json /etc/rp/xray-xhttp2.json; do
    if [[ -f $f ]]; then
      chown root:xray "$f" && chmod 640 "$f" || rp_fail "Не удалось защитить $f"
    fi
  done
  # shellcheck disable=SC1091
  . /etc/rp/rp2.conf || rp_fail "Не удалось прочитать настройки VPS-2"
  local ord=" ${TRANSPORT_ORDER:-} "
  if [[ $ord == *" hy2-wg "* || $ord == *" hy2o-wg "* ]]; then
    install -d -m 700 /etc/wireguard && install -m 600 /etc/rp/rp-wg.conf /etc/wireguard/rp-wg.conf &&
      chmod 600 /etc/rp/rp-wg.conf || rp_fail "Не удалось установить защищённый конфиг WireGuard"
  else
    # wg-quick needs the old configuration to tear the link down. Never remove
    # it first and strand an active interface during an interrupted update.
    if ip link show rp-wg >/dev/null 2>&1; then
      systemctl stop wg-quick@rp-wg || rp_fail "Не удалось остановить исключённый внутренний WG"
      if ip link show rp-wg >/dev/null 2>&1; then rp_fail "Внутренний WG остался активным; конфиг сохранён"; fi
    fi
    rm -f /etc/rp/rp-wg.conf /etc/wireguard/rp-wg.conf || rp_fail "Не удалён исключённый конфиг WireGuard"
  fi
  # конфиги исключённых транспортов не должны оставаться от прежнего бандла
  rm -f /etc/rp/xray-tcp.json || rp_fail "Не удалён устаревший конфиг TCP"
  [[ $ord == *" hy2-wg "* ]] || rm -f /etc/rp/hy2.yaml || rp_fail "Не удалён устаревший конфиг HY2"
  [[ $ord == *" hy2o-wg "* ]] || rm -f /etc/rp/hy2o.yaml || rp_fail "Не удалён устаревший конфиг HY2 obfs"
  [[ $ord == *" reality-xhttp "* ]] || rm -f /etc/rp/xray-xhttp.json || rp_fail "Не удалён устаревший конфиг XHTTP"
  [[ $ord == *" reality-xhttp2 "* ]] || rm -f /etc/rp/xray-xhttp2.json || rp_fail "Не удалён устаревший конфиг XHTTP2"
  # VPS-2 may host unrelated services; never toggle its global IPv6 or
  # global rp_filter. ip_forward is necessary for the inner WG egress only.
  printf '# Managed by rp (VPS-2); do not disable global IPv6/rp_filter\nnet.ipv4.ip_forward=1\n' \
    >/etc/sysctl.d/99-rp.conf || rp_fail "Не удалось записать sysctl"
  sysctl -q -p /etc/sysctl.d/99-rp.conf >/dev/null 2>&1 || rp_fail "Не удалось применить sysctl"
  if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) == 1 ]]; then
    rp_msg '! IPv6 сейчас выключен на VPS-2 (возможно, прежней версией rp). rp его не включает автоматически; проверьте настройки других сервисов.'
  fi
  if command -v restorecon >/dev/null; then
    restorecon -R /etc/rp /usr/local/bin /usr/local/lib/rp /usr/local/share/rp 2>/dev/null || rp_fail "Не восстановлены контексты SELinux"
  fi
  systemctl daemon-reload || rp_fail "Не удалось перечитать службы systemd"
  # 5. NAT и пересылка, фаервол (порты наружу не открываются); rp fixnet — единая реализация
  rp_msg "NAT и пересылка"
  RP_TX_INTERNAL=1 /usr/local/bin/rp fixnet || rp_fail "не удалось включить NAT/firewalld на VPS-2"
  # 6. SSH: ключ с ограничениями (только с loopback и внутреннего WG-адреса, без форвардинга)
  install -d -m 700 /root/.ssh && touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys || rp_fail "Не удалось подготовить SSH"
  sed -i '/ rp@vps1$/d' /root/.ssh/authorized_keys || rp_fail "Не удалось обновить ключ управления"
  printf 'from="127.0.0.1,10.77.0.1",restrict,pty %s rp@vps1\n' "$(grep '^SSH_PUB=' /etc/rp/rp2.conf | cut -d'"' -f2)" >>/root/.ssh/authorized_keys || rp_fail "Не удалось записать ключ управления"
  systemctl is-active --quiet sshd || systemctl enable --now sshd >/dev/null 2>&1 || rp_fail "Не удалось запустить SSH"
  local prl; prl=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/{print $2}')
  [[ $prl == no ]] && rp_msg "! В sshd запрещён вход root (PermitRootLogin no): ключ rp работать не будет"
  # 7. Fresh provisioning intentionally resets old manual pin/state from a
  # previous installation, because UUIDs, WG keys and REALITY secrets differ.
  # An ordinary safe 'rp push' preserves the operator's manual mode.
  if [[ $RP_SAFE != 1 || $rp_new_identity == 1 ]]; then
    rm -f /var/lib/rp/mode /var/lib/rp/mode-request /var/lib/rp/mode-result \
          /var/lib/rp/active /var/lib/rp/since || rp_fail "Не удалось очистить прежний режим"
    rp_msg "Новая установка: прежний ручной режим VPS-2 сброшен в auto"
  fi
  if [[ $RP_SAFE == 1 ]] && ! systemctl is-active --quiet rp-transaction-rollback.timer; then rp_fail "Таймер отката пропал во время установки"; fi
  # Full T1/T2/T3 for EVERY configured transport on both fresh install and push.
  # The selected manual transport is enforced only for final activation.
  RP_TX_INTERNAL=1 /usr/local/bin/rp select
  local rc=$?
  if [[ $RP_SAFE == 1 && $rc == 0 ]]; then
    python3 /var/lib/rp/transaction/runner.py ready || rc=1
  fi
  echo
  rp_msg "Отпечаток host key (сверьте при первом rp ssh):"
  ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null || ssh-keygen -lf /etc/ssh/ssh_host_ecdsa_key.pub 2>/dev/null
  rp_msg "SSH снаружи можно закрыть: доступ с VPS-1 по туннелю сохранится (правило для 10.77.0.1)."
  return $rc
}
