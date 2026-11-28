#!/usr/bin/env bash
# ── Доступ к VPS-2 ───────────────────────────────────────────────────────
hy2_live() { wg show wg-exit latest-handshakes 2>/dev/null | awk '$2>0 && systime()-$2<180 {f=1} END{exit !f}'; }
door_port() { py_door="$1"; local it; IFS=';' read -ra _d <<<"$(cf DOORS "ssh=2222=127.0.0.1:22")"; for it in "${_d[@]}"; do [[ ${it%%=*} == "$py_door" ]] && { it=${it#*=}; echo "${it%%=*}"; return 0; }; done; return 1; }
# Два независимых пути управления VPS-2. Внешний SSH-порт VPS-2 не открываем.
# XHTTP: SSH через локальную дверь 127.0.0.1:2222, доступную лишь после
# регистрации обратного моста; HY2: SSH через внутренний WG 10.77.0.2:22.
ssh_args_for() { # ssh_args_for xhttp|hy2 — аргументы для конкретного пути
  local method=$1 host port
  case $method in
    xhttp)
      { tr_has reality-xhttp || tr_has reality-xhttp2; } || return 1
      host=127.0.0.1; port=$(door_port ssh) || return 1
      [[ $port =~ ^[0-9]+$ ]] || return 1
      ;;
    hy2)
      hy2_live || return 1
      host=10.77.0.2; port=22
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' -i "$ETC/ssh/id_ed25519" -o IdentitiesOnly=yes -o "UserKnownHostsFile=$ETC/ssh/known_hosts" \
    -o StrictHostKeyChecking=accept-new -o HostKeyAlias=vps2 -o ConnectTimeout=6 \
    -o ConnectionAttempts=1 -o ServerAliveInterval=15 -o ServerAliveCountMax=2 -p "$port" "root@$host"
}
ssh_args() { # confirm the currently active transport before opening the management path
  local active method
  active=$(cat "$STATE/vps2-active-cache" 2>/dev/null || true)
  method=$(control_method "$active" 2>/dev/null || true)
  if [[ -n $method ]] && ssh_method_ready "$method"; then
    ssh_args_for "$method"; return 0
  fi
  for method in xhttp hy2; do
    if ssh_method_ready "$method"; then ssh_args_for "$method"; return 0; fi
  done
  return 1
}
cmd_ssh() {
  need_vps1; local -a a=(); mapfile -t a < <(ssh_args)
  [[ ${a[-1]:-} == root@* ]] || die "SSH к VPS-2 сейчас недоступен (rp diag; проверьте active на VPS-2)"
  [[ -f $ETC/ssh/known_hosts ]] || note "Первое подключение: сверьте отпечаток с тем, что показал блок на VPS-2"
  exec ssh "${a[@]}" "$@"
}
vps2_run() { local -a a=(); mapfile -t a < <(ssh_args); [[ ${a[-1]:-} == root@* ]] || return 1; ssh -o BatchMode=yes "${a[@]}" "$@"; }
# Prefer the last CONFIRMED VPS-2 transport, not a stale WG handshake.
# Fall back to the alternate path on a switch without printing transient SSH errors.
control_paths() {
  local cached method
  cached=$(cat "$STATE/vps2-active-cache" 2>/dev/null || true)
  case $cached in
    hy2-wg|hy2o-wg) printf '%s\n' hy2 xhttp ;;
    reality-xhttp|reality-xhttp2) printf '%s\n' xhttp hy2 ;;
    *) printf '%s\n' xhttp hy2 ;;
  esac
}
cache_vps2_state() {
  local data=$1 active mode
  active=$(sed -n 's/^active=//p' <<<"$data" | head -1)
  mode=$(sed -n 's/^mode=//p' <<<"$data" | head -1)
  case "$active" in
    hy2-wg|hy2o-wg|reality-xhttp|reality-xhttp2)
      printf '%s\n' "$active" >"$STATE/vps2-active-cache.new" &&
        mv -f "$STATE/vps2-active-cache.new" "$STATE/vps2-active-cache" ;;
  esac
}
# Read-only commands may be retried after a watchdog switch.
# Never use this function for installation, confirmation, or other mutating commands.
vps2_read() {
  local method attempt rc output order max_attempts=${RP_READ_RETRIES:-3}
  local -a a=()
  [[ $max_attempts =~ ^[1-3]$ ]] || max_attempts=3
  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    while IFS= read -r method; do
      if [[ $method == hy2 ]]; then
        hy2_live || continue
      else
        { tr_has reality-xhttp || tr_has reality-xhttp2; } || continue
        door_port ssh >/dev/null || continue
      fi
      a=()
      mapfile -t a < <(ssh_args_for "$method")
      ((${#a[@]})) || continue
      # Buffer each attempt. A dropped SSH stream must not leak partial output
      # into a later successful attempt (e.g. false IP or active-transport name).
      if output=$(ssh -o BatchMode=yes -o ConnectionAttempts=1 -o ConnectTimeout=4 -o ServerAliveInterval=4 -o ServerAliveCountMax=2 "${a[@]}" "$@" </dev/null 2>/dev/null); then
        [[ $* == *'mode status'* ]] && cache_vps2_state "$output"
        printf '%s\n' "$output"
        return 0
      fi
    done < <(control_paths)
    ((attempt < max_attempts)) && sleep 2
  done
  return 1
}
# A freshly observed WG handshake does not tell us what the VPS-2 watchdog
# is CURRENTLY using. Only /var/lib/rp/active is authoritative for transport.
control_method() {
  case $1 in
    reality-xhttp|reality-xhttp2) printf 'xhttp\n' ;;
    hy2-wg|hy2o-wg) printf 'hy2\n' ;;
    *) return 1 ;;
  esac
}
ssh_method_ready() {
  local method=$1
  local -a a=()
  [[ $method == xhttp || $method == hy2 ]] || return 1
  [[ $method != hy2 ]] || hy2_live || return 1
  mapfile -t a < <(ssh_args_for "$method")
  ((${#a[@]})) || return 1
  ssh -o BatchMode=yes -o ConnectionAttempts=1 "${a[@]}" true </dev/null >/dev/null 2>&1
}
# Дверь SSH открывается не сразу после подключения моста (balancer rev ждёт observatory).
# Ждём готовность вместо немедленного отказа, чтобы T2/T3 не падали из-за этой паузы.
wait_ssh_method() { # wait_ssh_method метод [секунд]
  local m=$1 max=${2:-60} t=0
  while ((t < max)); do
    ssh_method_ready "$m" && return 0
    sleep 3; t=$((t + 3))
  done
  return 1
}
# Verify exactly 200 KiB both ways through a single, explicitly selected SSH path.
# If the watcher switches paths mid-test, do not attribute an SSH reset to DPI.
t3_ssh_method() {
  local method=$1 n=${2:-204800} got tries
  local -a a=()
  local -a before=()
  mapfile -t a < <(ssh_args_for "$method")
  ((${#a[@]})) || return 1
  for tries in 1 2 3; do
    got=$(timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=6 "${a[@]}" "head -c $n /dev/zero" </dev/null 2>/dev/null | wc -c) || got=0
    if [[ $got =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && ((got == n)); then
      got=$(head -c "$n" /dev/zero | timeout 45 ssh -o BatchMode=yes -o ConnectTimeout=6 "${a[@]}" 'wc -c' 2>/dev/null) || got=0
      if [[ $got =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && ((got == n)); then return 0; fi
    fi
    ((tries < 3)) && sleep 2
  done
  return 1
}
ssh_method_banner() {
  local method=$1 host port
  case $method in
    xhttp) host=127.0.0.1; port=$(door_port ssh) || return 1 ;;
    hy2) host=10.77.0.2; port=22 ;;
    *) return 1 ;;
  esac
  timeout 8 bash -c 'exec 3<>/dev/tcp/$0/$1 && read -r -t 5 l <&3 && [[ $l == SSH-* ]]' "$host" "$port" 2>/dev/null
}
# Fail-closed configuration verification, WITHOUT deliberately killing a live tunnel.
# Confirms rp's firewall and Xray fallback rules, not a live leak simulation.
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
