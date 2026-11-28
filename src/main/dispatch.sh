#!/usr/bin/env bash
# rp — локальная точка входа VPS-1.
# rp-distribution: dispatcher
# migrate_apply() { — поддерживается загружаемым модулем миграции.
set -uo pipefail
SELF_VERSION="@VERSION@"
RP_RELEASE_ID="@RELEASE_ID@"
RP_ROOT=/usr/local/lib/rp/releases/$RP_RELEASE_ID
if [[ ${RP_STAGE_ID:-} == "$RP_RELEASE_ID" && -n ${RP_STAGE:-} ]]; then
  RP_ROOT=$RP_STAGE
fi
RP_ENTRY_SOURCE=$RP_ROOT/dispatch.sh
if [[ ! -r $RP_ROOT/main/init.sh ]]; then
  printf >&2 'rp: отсутствует локальный пакет %s\n' "$RP_RELEASE_ID"
  exit 1
fi
@SOURCES@
main "$@"
