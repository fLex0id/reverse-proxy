#!/usr/bin/env bash
# rp — загрузчик релизной сборки.
# rp-distribution: bootstrap
set -uo pipefail
SELF_VERSION="1.2.9-lab.27"
RP_RELEASE_ID="c02c6c4154f6862cb594fdcefde24281bac51a71819edc541eb0e4b64a25052a"
RP_BUNDLE_SHA256="87ede55724998db9935c2f9624c4d81637e2c3f025a8dddde05825ed870617b7"

bootstrap_fetch() {
  local url=$1 out=$2 attempt delay=2 rc=0
  for ((attempt=1; attempt<=5; attempt++)); do
    rc=0
    curl -fsSL --connect-timeout 10 -m 180 -C - -o "$out" -- "$url" || rc=$?
    if [[ -f $out ]] && printf '%s  %s\n' "$RP_BUNDLE_SHA256" "$out" | sha256sum -c --status; then
      return 0
    fi
    # A completed invalid download, or a server without range support, needs a fresh start.
    if ((rc == 0 || rc == 33)); then rm -f -- "$out" || return 1; fi
    sleep "$delay"
    delay=$((delay * 2))
    if ((delay > 20)); then delay=20; fi
  done
  return 1
}

bootstrap_mirror() {
  if [[ -n ${GH_MIRROR:-} ]]; then printf '%s\n' "$GH_MIRROR"; return; fi
  [[ -r /etc/rp/rp.conf ]] || return 0
  sed -n 's/^GH_MIRROR="\(.*\)"$/\1/p' /etc/rp/rp.conf | tail -1
}

main() (
  local url tmp mirror
  url="https://github.com/fLex0id/reverse-proxy/releases/download/v$SELF_VERSION/rp-$SELF_VERSION.tar.gz"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/rp-bootstrap.XXXXXXXX") || return 1
  trap 'rm -rf -- "$tmp"' EXIT
  if ! bootstrap_fetch "$url" "$tmp/bundle.tar.gz"; then
    mirror=$(bootstrap_mirror)
    if [[ -z $mirror ]]; then
      printf >&2 'rp: не удалось скачать и проверить SHA256 пакета %s\n' "$url"
      return 1
    fi
    printf >&2 'rp: пробую зеркало GitHub\n'
    rm -f -- "$tmp/bundle.tar.gz" || return 1
    bootstrap_fetch "${mirror%/}/$url" "$tmp/bundle.tar.gz" || return 1
  fi
  mkdir "$tmp/payload" &&
    tar -xzf "$tmp/bundle.tar.gz" -C "$tmp/payload" &&
    bash -n "$tmp/payload/dispatch.sh" || return 1
  RP_STAGE="$tmp/payload" RP_STAGE_ID="$RP_RELEASE_ID" bash "$tmp/payload/dispatch.sh" "$@"
)


main "$@"
