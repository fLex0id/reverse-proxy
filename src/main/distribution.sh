#!/usr/bin/env bash

rp_distribution_kind() {
  local file=$1 marker version id checksum
  [[ -f $file && -r $file ]] || return 1
  [[ $(head -n 1 "$file") == '#!/usr/bin/env bash' ]] || return 1
  [[ $(sed -n '2p' "$file") == '# rp — '* ]] || return 1
  version=$(self_version_of "$file")
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+[-+a-zA-Z0-9.]*$ ]] || return 1
  [[ $(grep -c '^SELF_VERSION=' "$file") == 1 ]] || return 1
  id=$(sed -n 's/^RP_RELEASE_ID="\([^"]*\)"$/\1/p' "$file")
  [[ $id =~ ^[a-f0-9]{64}$ ]] || return 1
  marker=$(sed -n '3p' "$file")
  case $marker in
    '# rp-distribution: bootstrap')
      checksum=$(sed -n 's/^RP_BUNDLE_SHA256="\([^"]*\)"$/\1/p' "$file")
      [[ $checksum =~ ^[a-f0-9]{64}$ ]] || return 1 ;;
    '# rp-distribution: dispatcher')
      grep -Fxq 'RP_ROOT=/usr/local/lib/rp/releases/$RP_RELEASE_ID' "$file" || return 1 ;;
    *) return 1 ;;
  esac
  [[ $(tail -n 1 "$file") == 'main "$@"' ]] && bash -n "$file" || return 1
  printf '%s\n' "${marker##* }"
}

rp_publish_modules() {
  local releases=$LIB/releases target stage
  target=$releases/$RP_RELEASE_ID
  if [[ -d $target ]]; then
    if [[ $RP_ROOT == "$target" ]]; then return 0; fi
    # Never replace a tree that a running dispatcher may still be reading.
    diff -qr -- "$RP_ROOT" "$target" >/dev/null || {
      err "Локальный пакет $RP_RELEASE_ID отличается от проверенного архива"
      return 1
    }
    return 0
  fi
  mkdir -p -- "$releases" || return 1
  stage=$(mktemp -d "$releases/.rp-stage.XXXXXXXX") || return 1
  if ! cp -a --no-preserve=context -- "$RP_ROOT/." "$stage/" ||
    ! chmod 755 "$stage" ||
    ! sync -f "$stage" ||
    ! mv -T -- "$stage" "$target" ||
    ! sync -f "$releases"; then
    rm -rf -- "$stage"
    err "Не удалось опубликовать локальный пакет $RP_RELEASE_ID"
    return 1
  fi
}

rp_restore_single() {
  # The legacy uninstall leaves the rp command available for a subsequent install.
  self_install_file "$RP_ROOT/rp-single.sh"
}
