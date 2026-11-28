#!/usr/bin/env bash
# ── Установка, справка, точка входа ──────────────────────────────────────
maybe_save_launched_build() {
  # Runs when an already configured VPS-1 was opened via a separate script.
  # On /usr/local/bin/rp itself, avoid network and prompts.
  local current="${RP_ENTRY_SOURCE:-${BASH_SOURCE[0]}}" installed="" here="" src_version=""
  here=$(readlink -f "$current" 2>/dev/null || true)
  installed=$(readlink -f "$SELF_BIN" 2>/dev/null || true)
  [[ -n $here && $here == "$installed" ]] && return 0
  src_version=$(self_version_of "$SELF_BIN")
  if [[ $src_version == "$SELF_VERSION" ]] && [[ -f $SELF_BIN ]]; then
    return 0
  fi
  note "Запущен rp $SELF_VERSION, в команде rp установлено: ${src_version:-ничего}"
  if yesno "Сохранить запущенную версию как команду rp?" y; then
    (lock; self_install) || warn "Версия не сохранена; используйте меню 'Сохранить' или проверьте RP_URL"
  fi
}
lock() {
  # A self-update's migration child must share, not release/reopen, the lock.
  # Check the actual descriptor/inode and acquire it: an environment variable
  # alone is never proof of ownership. Other callers retain the bounded wait.
  if ! { [[ /proc/self/fd/9 -ef /run/rp.lock ]] && flock -n 9; }; then
    exec 9>/run/rp.lock
    flock -w 5 9 || die "Другая операция rp уже выполняется"
  fi
  if [[ -f $STATE/migration/state.json ]]; then
    python3 "$STATE/migration/runner.py" guard || die "Незавершённая миграция: дождитесь восстановления или выполните rp migrate-recover"
  fi
}

main() {
  local cmd=${1:-}; shift || true
  if [[ $cmd == --ascii ]]; then
    RP_ASCII=1; ASCII_MODE=1; export RP_ASCII
    cmd=${1:-}; shift || true
    R=''; B=''; C_ACC=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''
  fi
  case $cmd in
    ""|menu) need_root; conf_load; if [[ $(cf ROLE) == vps1 ]]; then maybe_save_launched_build; menu_main; else cmd_install; fi ;;
    install) cmd_install ;;
    install-self|save) need_root; lock; self_install ;;
    migrate) need_root; lock; cmd_migrate ;;
    _migrate_apply) need_root; lock; python3 "$STATE/migration/runner.py" guard --internal || return 1; migrate_apply ;;
    migrate-recover) need_root; python3 "$STATE/migration/runner.py" recover ;;
    version|-v|--version) echo "rp $SELF_VERSION" ;;
    help|-h|--help) usage ;;
    client) need_root; need_vps1; case ${1:-list} in add) lock; cl_add "${2:-}" ;; del) lock; cl_del "${2:-}" ;; list) cl_list ;; show) cl_show "${2:-}" ;; *) die "rp client add|del|list|show [имя]" ;; esac ;;
    block) need_root; lock; cmd_block "$@" ;;
    link) need_root; lock; cmd_link "$@" ;;
    _link_close) link_close "$@" ;;     # служебная: вызывает systemd после остановки rp-serve (без lock)
    push) need_root; lock; cmd_push ;;
    ssh) need_root; cmd_ssh "$@" ;;
    door) need_root; lock; cmd_door "$@" ;;
    test) need_root; lock; cmd_test "$@" ;;
    diag) need_root; lock; cmd_diag "$@" ;;
    transports) need_root; cmd_transports ;;
    tunnel) need_root; [[ ${1:-status} == status ]] || lock; cmd_tunnel "$@" ;;
    _route_sync) need_root; need_vps1; route_sync ;;
    prune) need_root; lock; cmd_prune ;;
    dns) need_root; lock; cmd_dns "$@" ;;
    doctor) need_root; cmd_doctor ;;
    rotate) need_root; lock; cmd_rotate ;;
    upgrade) need_root; lock; cmd_upgrade "$@" ;;
    update) need_root; lock; if (($# == 0)); then self_upgrade; else cmd_upgrade "$@"; fi ;;
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
